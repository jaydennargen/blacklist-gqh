#!/usr/bin/env python3
"""Constrained-random stimulus + oracle-computed expected responses -> vectors for the SV TB.

Data randomness lives HERE because the oracle is Python. Timing randomness (inter-byte gaps,
baud jitter, idle between packets) lives in the SV TB; it never changes expected values.

  python tools/gen_vectors.py --profile judge --seed 7            -> vectors/judge_s7.hex
  python tools/gen_vectors.py --profile all --seeds 20            -> many files
  python tools/gen_vectors.py --profile organizer --seed 0x57214720 --sessions 1   -> the practice run

Output: one line per packet, 32 hex digits = {request[63:0], expected_response[63:0]},
readable by $readmemh into `logic [127:0] vec [];` Comment lines start with //.
"""
import argparse, pathlib, random, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from oracle import Oracle, REQ_STRUCT, WINDOW_SIZE  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "vectors"
ITEM_A, ITEM_B = 0x11, 0x22
PROFILES = ["organizer", "judge", "cross", "equal", "extreme"]


def rand_walk(rng, start, step, n, lo=0, hi=0xFFFF):
    p, out = start, []
    for _ in range(n):
        p = max(lo, min(hi, p + rng.randint(-step, step)))
        out.append(p)
    return out


def prices_for(profile, rng, n):
    """Per-item price streams. Each profile targets a specific risk."""
    if profile == "judge":      # wide random walk, like an unseen judge seed
        s = lambda: rand_walk(rng, rng.randint(1000, 60000), rng.choice([50, 500, 3000]), n)
    elif profile == "cross":    # small steps around a level: many BUY/SELL/repeat transitions
        s = lambda: rand_walk(rng, rng.randint(200, 65000), 8, n)
    elif profile == "equal":    # flat runs: exercises <= / >= equality edges and floor(>>4)
        s = lambda: [v for v in rand_walk(rng, 1000, 3, n // 4 + 1) for _ in range(4)][:n]
    elif profile == "extreme":  # 0 and 0xFFFF: 20-bit sum overflow / unsigned compare bugs
        s = lambda: [rng.choice([0, 1, 0xFFFE, 0xFFFF, rng.randint(0, 0xFFFF)]) for _ in range(n)]
    else:
        raise ValueError(profile)
    return s(), s()


def organizer_session(seed, n):
    """One run exactly as organizer/22_robust_uart_test.py builds it (lines 114-123), for any seed:
    prices uniform in PRICE_MIN..PRICE_MAX (lines 31-32), A first during warm-up, then either order.
    The official seed is not published (line 37), so this is the judged distribution, other seeds."""
    rng = random.Random(seed)
    a = [rng.randint(0, 100) for _ in range(n)]
    b = [rng.randint(0, 100) for _ in range(n)]
    slot_rng = random.Random(seed ^ 0xA5A5A5A5)
    swap = [(i >= WINDOW_SIZE and slot_rng.random() < 0.5) for i in range(n)]
    return a, b, swap


def packets(profile, rng, sessions, seed):
    """Yields 8-byte requests. Indices 0..99 per session; slot order randomized per packet."""
    for k in range(sessions):
        if profile == "organizer":  # session 0 uses the seed itself, so seed 0x57214720 is the practice run
            a, b, swap = organizer_session(seed if k == 0 else rng.getrandbits(32), 100)
        else:
            a, b = prices_for(profile, rng, 100)
            swap = [rng.random() >= 0.5 for _ in range(100)]
        for idx in range(100):
            first, second = ((ITEM_B, b[idx]), (ITEM_A, a[idx])) if swap[idx] else ((ITEM_A, a[idx]), (ITEM_B, b[idx]))
            yield bytes([idx >> 8, idx & 0xFF, first[0], first[1] >> 8, first[1] & 0xFF,
                         second[0], second[1] >> 8, second[1] & 0xFF])


COVERS = ("prev_eq_old_avg", "cur_eq_new_avg", "no_cross")


def cover_points(o, req):
    """Covers that need the model's averages (docs/VERIFICATION.md), read from the oracle's state
    just before it takes req. Coverage bookkeeping only: nothing here is an expected value."""
    index, item1, price1, item2, price2 = REQ_STRUCT.unpack(req)
    hits = dict.fromkeys(COVERS, 0)
    if index == 0:          # a new session: both items are back in warm-up
        return hits
    for item, price in ((item1, price1), (item2, price2)):
        m = o.models[item]
        if len(m.window) < WINDOW_SIZE:
            continue
        old_avg = m.running_sum >> 4
        new_avg = (m.running_sum - m.window[0] + price) >> 4
        hits["prev_eq_old_avg"] += m.last_price == old_avg
        hits["cur_eq_new_avg"] += price == new_avg
        hits["no_cross"] += not ((m.last_price <= old_avg and price > new_avg)
                                 or (m.last_price >= old_avg and price < new_avg))
    return hits


def generate(profile, seed, sessions):
    rng = random.Random(seed)
    o = Oracle()
    lines = [f"// profile={profile} seed={seed} sessions={sessions} oracle=tools/oracle.py"]
    cov = dict.fromkeys(COVERS, 0)
    for req in packets(profile, rng, sessions, seed):
        for name, n in cover_points(o, req).items():
            cov[name] += n
        rsp = o.step(req)
        if len(rsp) != 8:
            sys.exit(f"oracle returned {len(rsp)} bytes")
        lines.append(req.hex() + rsp.hex())
    OUT.mkdir(exist_ok=True)
    path = OUT / f"{profile}_s{seed}.hex"
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return path, len(lines) - 1, cov


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--profile", default="judge", choices=PROFILES + ["all"])
    p.add_argument("--seed", type=lambda x: int(x, 0), default=1)
    p.add_argument("--seeds", type=int, default=1, help="generate seeds seed..seed+N-1")
    p.add_argument("--sessions", type=int, default=3, help=">1 exercises mid-stream index-0 reset")
    a = p.parse_args()
    profs = PROFILES if a.profile == "all" else [a.profile]
    total = dict.fromkeys(COVERS, 0)
    for prof in profs:
        for s in range(a.seed, a.seed + a.seeds):
            path, n, cov = generate(prof, s, a.sessions)
            for name in COVERS:
                total[name] += cov[name]
            print(f"VEC {path.relative_to(ROOT)}: {n} packets  " + " ".join(f"{k}={v}" for k, v in cov.items()))
    zero = [k for k, v in total.items() if v == 0]
    print(f"VEC COVERS over this set: " + " ".join(f"{k}={v}" for k, v in total.items())
          + (f"  COVER_ZERO {' '.join(zero)}" if zero else ""))
    if zero and a.profile == "all":
        sys.exit(1)


if __name__ == "__main__":
    main()
