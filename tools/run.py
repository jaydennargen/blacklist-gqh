#!/usr/bin/env python3
"""Single entry point for sim / synth / board tests. Prints ONE summary line per run;
full output goes to a log file. Read the summary line; open the log only on a failure.

  python tools/run.py sim <test> [--seed N | --seeds K] [--plusargs "+VEC=vectors/x.hex"] [--models]
  python tools/run.py synth
  python tools/run.py hw quick|robust [--port COM5]   (or set GQH_PORT)

Conventions
  src/*.sv                 synthesizable RTL (also what Gowin builds); *_pkg.sv compile first
  testbench/common/*.sv    shared TB code; *_pkg.sv compile first
  testbench/<test>/*.sv    one test; top module must be named tb_<test>
  testbench/models/*.sv    simulation-only stand-ins, same module names as src/. `sim --models`
                           compiles them in place of the src/ files, to test a TB, never the RTL.
  Pass = vlog/vsim clean (0 errors, 0 warnings) AND transcript contains "TEST_RESULT: PASS".

Tool locations: vlog/vlib/vsim on PATH (Questa). gw_sh via env GW_SH or PATH.
Synth builds the Gowin project gowin/gqh.gprj through gowin/build.tcl; outputs land in gowin/impl/.
Lines marked VERIFY have not been checked against this team's installed tools yet.
"""
import argparse, os, pathlib, random, re, shutil, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
RESULTS = ROOT / "results"
PASS_MARK = "TEST_RESULT: PASS"
ERR_RE = re.compile(r"^(?:# )?\*\* (?:Error|Fatal)", re.M)   # vsim prefixes transcript lines with "# "
WARN_RE = re.compile(r"^(?:# )?\*\* Warning", re.M)


def sh(cmd, cwd, log):
    """Run a command, append all output to log, return (rc, output)."""
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    out = p.stdout + p.stderr
    with open(log, "a", encoding="utf-8") as f:
        f.write(f"\n$ {' '.join(map(str, cmd))}\n{out}")
    return p.returncode, out


def git_rev():
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                             capture_output=True, text=True).stdout.strip() or "nogit"
        dirty = subprocess.run(["git", "status", "--porcelain", "--", "src", "constraints"],
                               cwd=ROOT, capture_output=True, text=True).stdout.strip()
        return sha + ("-dirty" if dirty else "")
    except FileNotFoundError:
        return "nogit"


def first_failure(text):
    for line in text.splitlines():
        if ERR_RE.match(line) or "TEST_RESULT: FAIL" in line or "MISMATCH" in line:
            return line.strip()[:200]
    return ""


# ---------------------------------------------------------------- sim
def src_files(models):
    """src/*.sv; with --models, a file of the same name in testbench/models/ takes its place."""
    mdir = ROOT / "testbench" / "models"
    return [mdir / p.name if models and (mdir / p.name).exists() else p for p in (ROOT / "src").glob("*.sv")]


def sim_files(test, models):
    pkg_first = lambda p: (not p.name.endswith("_pkg.sv"), p.name)
    tdir = ROOT / "testbench" / test
    if not tdir.is_dir():
        sys.exit(f"run.py: no test dir testbench/{test}")
    return (sorted(src_files(models), key=pkg_first)
            + sorted((ROOT / "testbench" / "common").glob("*.sv"), key=pkg_first)
            + sorted(tdir.glob("*.sv")))


BIND_RE = re.compile(r"^module\s+(\w+_bind)\s*;\s*bind\s+(\w+)", re.M)


def bind_tops(test, models):
    """Extra vsim tops: each `module <x>_bind; bind <target> ...` in testbench/common whose target
    module the test instantiates, directly or through src/. A bind to a module that is not in the
    design is a vopt error (vopt-10717), so unit tests load only the binds they can use."""
    src = {p.stem: p for p in src_files(models)}
    todo, used = list((ROOT / "testbench" / test).glob("*.sv")), set()
    while todo:
        text = todo.pop().read_text(encoding="utf-8")
        for name, path in src.items():
            if name not in used and re.search(rf"^\s*{name}\s+(?:#\s*\(|[A-Za-z_]\w*\s*\()", text, re.M):
                used.add(name)
                todo.append(path)
    return [mod for p in sorted((ROOT / "testbench" / "common").glob("*.sv"))
            for mod, target in BIND_RE.findall(p.read_text(encoding="utf-8")) if target in used]


def sim_one(test, seed, plusargs, allow_warn, models):
    name = f"{test}[MODELS, not RTL]" if models else test   # what the summary line calls this run
    work = BUILD / "sim" / (test + ("_models" if models else ""))
    work.mkdir(parents=True, exist_ok=True)
    log = work / f"seed{seed}.log"
    log.write_text("", encoding="utf-8")
    lib = (work / "work").relative_to(ROOT).as_posix()  # vopt-2253 on an absolute Windows path (Questa 2026.2)
    files = [str(f) for f in sim_files(test, models)]
    sh(["vlib", lib], ROOT, log)
    defs = ["+define+GQH_MODELS"] if models else []      # b2_bind names the engine's state differently for a model
    rc, out = sh(["vlog", "-sv", "-lint", "-work", lib, f"+incdir+{ROOT / 'testbench' / 'common'}", *defs, *files], ROOT, log)
    comp_err, comp_warn = len(ERR_RE.findall(out)), len(WARN_RE.findall(out))
    if rc != 0 or comp_err:
        return False, f"SIM {name} seed={seed}: COMPILE FAIL errors={comp_err} :: {first_failure(out)} log={log.relative_to(ROOT)}"
    do = "run -all; quit -f"
    cmd = ["vsim", "-c", "-lib", lib, f"tb_{test}", *bind_tops(test, models), "-sv_seed", str(seed), "-do", do]
    cmd += plusargs.split() if plusargs else []
    rc, out = sh(cmd, ROOT, log)
    err, warn = len(ERR_RE.findall(out)), len(WARN_RE.findall(out)) + comp_warn
    passed = rc == 0 and err == 0 and PASS_MARK in out and (allow_warn or warn == 0)
    verdict = "PASS" if passed else "FAIL"
    detail = "" if passed else f" :: {first_failure(out) or ('warnings present' if warn else 'no PASS marker')}"
    return passed, f"SIM {name} seed={seed}: {verdict} errors={err} warnings={warn}{detail} log={log.relative_to(ROOT)}"


def cmd_sim(a):
    seeds = [a.seed] if a.seed is not None else [random.randrange(1, 2**31) for _ in range(a.seeds)]
    fails = 0
    for s in seeds:
        ok, line = sim_one(a.test, s, a.plusargs, a.allow_warnings, a.models)
        fails += not ok
        if not ok or len(seeds) <= 3:
            print(line)
    print(f"SIM SUMMARY {a.test}{'[MODELS, not RTL]' if a.models else ''}: {len(seeds) - fails}/{len(seeds)} seeds passed @ {git_rev()}")
    sys.exit(1 if fails else 0)


# ---------------------------------------------------------------- synth
def cmd_synth(a):
    gw_sh = os.environ.get("GW_SH", "gw_sh")
    impl = ROOT / "gowin" / "impl"                      # the Gowin project gowin/gqh.gprj builds here
    BUILD.mkdir(exist_ok=True)
    log = BUILD / "synth.log"
    log.write_text("", encoding="utf-8")
    for d in ("gwsynthesis", "pnr", "temp"):            # never report a stale .fs or report;
        shutil.rmtree(impl / d, ignore_errors=True)     # gowin/impl/gqh_process_config.json is committed and stays
    diff = project_mismatch()
    if diff:
        print(f"SYNTH: FAIL :: gqh.gprj and src/ disagree: {diff}")
        sys.exit(1)
    rc, out = sh([gw_sh, "build.tcl"], ROOT / "gowin", log)
    usage = resource_usage(impl / "gwsynthesis" / "gqh_syn.rpt.html")
    logic = pnr_logic(impl / "pnr" / "gqh.rpt.txt")
    fs = sorted(impl.glob("pnr/*.fs"), key=lambda p: p.stat().st_mtime)
    if rc != 0 or not usage or not fs:
        why = first_failure(out) or ("no synthesis report" if not usage else "no .fs produced")
        print(f"SYNTH: FAIL rc={rc} :: {why} log={log.relative_to(ROOT)}")
        sys.exit(1)
    dest = ROOT / "bitstream" / "gqh.fs"
    if dest.exists():
        dest.chmod(0o644)  # Gowin writes the .fs read-only and copy2 keeps that; a rebuild must overwrite it
    shutil.copy2(fs[-1], dest)
    print(f"SYNTH: PASS @ {git_rev()} {usage} {logic} fs={dest.relative_to(ROOT)}")


def project_mismatch():
    """'' when gqh.gprj lists exactly src/*.sv; otherwise what differs. The judges build the project,
    so a source file missing from it would be missing from the judged build."""
    listed = set(re.findall(r'<File path="\.\./(src/[^"]+)"', (ROOT / "gowin" / "gqh.gprj").read_text(encoding="utf-8")))
    on_disk = {p.relative_to(ROOT).as_posix() for p in (ROOT / "src").glob("*.sv")}
    parts = [f"not in gqh.gprj: {sorted(on_disk - listed)}"] if on_disk - listed else []
    parts += [f"not in src/: {sorted(listed - on_disk)}"] if listed - on_disk else []
    return "; ".join(parts)


def pnr_logic(rpt):
    """'LOGIC=n' = the Logic line of the place-and-route report's Resource Usage Summary (LUT + ALU + ROM16
    after packing). Can differ from LUT + ALU in the synthesis report. Format checked against V1.9.11.03."""
    m = re.search(r"^\s*Logic\s*\|\s*(\d+)/", rpt.read_text(encoding="utf-8", errors="replace"), re.M) if rpt.exists() else None
    return f"LOGIC={m.group(1)}" if m else "LOGIC=?"


def resource_usage(rpt):
    """'LUT=n ALU=n SSRAM=n BSRAM=n REG=n' from the synthesis report's Resource Usage Summary.
    LUT is the judged number (guide §11). Format checked against Gowin V1.9.11.03 Education."""
    if not rpt.exists():
        return ""
    txt = rpt.read_text(encoding="utf-8", errors="replace")
    start = txt.rfind("Resource Usage Summary")
    end = txt.find("Resource Utilization Summary", start)
    if start < 0 or end < 0:
        return ""
    cells = [c for c in (" ".join(c.replace("&nbsp", " ").split())
                         for c in re.sub(r"<[^>]+>", "\n", txt[start:end]).splitlines()) if c]
    table = {cells[i]: cells[i + 1] for i in range(len(cells) - 1)}
    names = {"LUT": "LUT", "ALU": "ALU", "SSRAM": "SSRAM", "BSRAM": "BSRAM", "Register": "REG"}
    return " ".join(f"{short}={table[k] if table.get(k, '').isdigit() else 0}" for k, short in names.items())   # a resource with no row is 0


# ---------------------------------------------------------------- hardware
def cmd_hw(a):
    port = a.port or os.environ.get("GQH_PORT")
    if not port:
        sys.exit("run.py: pass --port COMx or set GQH_PORT")
    name = {"quick": "21_quick_uart_test.py", "robust": "22_robust_uart_test.py"}[a.which]
    src = ROOT / "organizer" / name
    if not src.exists():
        sys.exit(f"run.py: organizer/{name} missing")
    run_dir = BUILD / "hw"
    shutil.rmtree(run_dir, ignore_errors=True)
    run_dir.mkdir(parents=True)
    script = run_dir / name
    text, n = re.subn(r"^PORT\s*=.*$", f'PORT = "{port}"', src.read_text(encoding="utf-8"), count=1, flags=re.M)
    if n != 1:
        sys.exit("run.py: could not find a top-level 'PORT = ...' line; check the script and update this regex")
    script.write_text(text, encoding="utf-8")  # only PORT changed, per guide §7
    t0 = time.time()
    p = subprocess.run([sys.executable, name], cwd=run_dir, capture_output=True, text=True, errors="replace")
    out = p.stdout + p.stderr
    rev = git_rev()
    stamp = time.strftime("%m%d-%H%M%S")
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"{stamp}_{rev}_{a.which}.out.txt").write_text(out, encoding="utf-8")
    csvs = [c for c in run_dir.glob("*.csv")]
    for c in csvs:
        shutil.move(str(c), RESULTS / f"{stamp}_{rev}_{a.which}_{c.name}")
    tail = [l for l in out.strip().splitlines() if l.strip()][-4:]
    print(f"HW {a.which} @ {rev} rc={p.returncode} {time.time() - t0:.1f}s csv={len(csvs)} -> results/{stamp}_{rev}_*")
    for l in tail:
        print(f"  > {l[:150]}")
    if rev.endswith("-dirty"):
        print("  WARNING: src/ or constraints/ uncommitted; this result is not traceable to a commit")
    sys.exit(p.returncode)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sim"); s.add_argument("test")
    g = s.add_mutually_exclusive_group(); g.add_argument("--seed", type=int); g.add_argument("--seeds", type=int, default=1)
    s.add_argument("--plusargs", default=""); s.add_argument("--allow-warnings", action="store_true")
    s.add_argument("--models", action="store_true", help="testbench/models/ in place of src/: tests the TB, not the RTL")
    s.set_defaults(fn=cmd_sim)
    s = sub.add_parser("synth"); s.set_defaults(fn=cmd_synth)
    s = sub.add_parser("hw"); s.add_argument("which", choices=["quick", "robust"]); s.add_argument("--port")
    s.set_defaults(fn=cmd_hw)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
