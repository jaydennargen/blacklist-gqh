# DECISIONS — append-only. One entry per decision or rejected approach.

Format (keep each entry ≤ 6 lines):
```
## D<n>: <title>  [<who>, <time>]
Decision: ...
Why / evidence: <test output, CSV name, script line> — never "seems right"
Rejected: <alternative> because <specific failure mode>
Guarded by: <assertion / test / cover name that fails if this regresses>
```

## Open (lead resolves; owner writes the D-entry)
- Closed: O5 → D18. O1 → D10. O2 → D11. O3 → D12. O4 → D13. O6 → D2. O7 → D4. O8 → D6, D7. O9 → D9.

## Decided

## D1: Repo at the git root, guide layout, RTL in SystemVerilog  [jayden, 2026-10-03 14:20]
Decision: src/ constraints/ testbench/ gowin/ bitstream/ results/ at the root; all RTL is `.sv`, shared types in src/gqh_pkg.sv.
Why / evidence: guide Part 3 §2 recommended layout. gw_sh V1.9.11.03 with `-verilog_std sysv2017` built a package, enum-typed ports, always_ff/always_comb with 0 errors (results/storage_experiment/).
Rejected: Verilog-2001 RTL — no enums or packages, so action codes and widths get restated per file.
Guarded by: `python tools/run.py sim compile` and `python tools/run.py synth` (both must stay clean).

## D2: One clock, one reset from a power-on counter; reset_btn unused  [jayden, 2026-10-03 14:20]
Decision: sys_clk only. `rst` is synchronous active-high from por_reset. Its counter is the only register with an init value (0). reset_btn is a port and nothing else.
Why / evidence: guide §10.2.2 "the board is not reset or reprogrammed between runs"; index 0 is the session reset. Guide §9 marks reset_btn optional.
Rejected: wiring reset_btn into rst — unknown polarity or a floating pin holds the design in reset for a whole run (0 points) for no judged benefit.
Guarded by: a_valid_low_in_rst; first board run confirms the counter's power-on value (UNVERIFIED until then).

## D3: UART divisor 234, mid-bit sampling  [jayden, 2026-10-03 14:20]
Decision: CLKS_PER_BIT = 234 for RX and TX. RX: 2-flop synchronizer, start bit re-checked at mid-bit, one sample per bit.
Why / evidence: 27e6/115200 = 234.375; 234 is 0.16% fast, 1.5% of a bit over a 10-bit frame. Arithmetic only — UNVERIFIED against the BL616.
Rejected: fractional divider or oversampling/majority vote — extra logic for an error budget already 30× inside tolerance.
Guarded by: testbench/uart with ±2% baud error (to be written).

## D4: One control FSM owns the packet; bytes outside S_RX are dropped  [jayden, 2026-10-03 14:20]
Decision: pkt_ctrl: S_RX(8) → S_CLEAR (index 0 only) → slot 1 → slot 2 → S_TX(8) → S_RX. Replaces pkt_rx/router/pkt_tx.
Why / evidence: "no response before byte 8", "exactly one 8-byte response" and slot order (guide §10.1.6–7) hold by state order, not by cross-module handshakes. Judge is stop-and-wait (§10.2.1), so no byte can arrive outside S_RX.
Rejected: separate pkt_rx → router → pkt_tx with two extra valid/ready boundaries and two 64-bit registers — more interfaces to verify, nothing gained.
Guarded by: a_no_tx_outside_s_tx, a_rsp_8_bytes, a_rx_drop_only_when_busy.

## D5: One time-shared engine, selected by item ID  [jayden, 2026-10-03 14:20]
Decision: ma_engine processes slot 1 then slot 2; `cmd_item_sel` picks the state set.
Why / evidence: compute is ~4 cycles of 37 ns against a 16.6 ms reference latency (guide §11). Sequential slots match a sequential software model, including the same item twice (O1).
Rejected: one engine per item — duplicates the arithmetic and adds a slot→engine steering mux.
Guarded by: a_other_item_untouched; vectors with B in slot 1.

## D6: Window = flop shift registers, cleared on index 0 with everything else  [jayden, 2026-10-03 14:35]
Decision: per item 16×16 flops + sum, prev, last_action in flops. Clear zeroes all of it. No vendor attribute.
Why / evidence: results/storage_experiment/README.md — engine prototype LUT row: flops cleared 126; RAM16 + pointers 138; flops with window not cleared 382.
Rejected: not clearing the window (lead A7) — +256 LUT on this tool and correct only if indices 0..15 always follow index 0 in order (O3). BSRAM — needs a multi-cycle read for no LUT gain.
Guarded by: a_clear_on_index0; multi-session vectors (index 0 mid-stream); LUT= in the `run.py synth` line.

## D7: The judged number is the LUT row; ALU and SSRAM are separate rows  [jayden, 2026-10-03 14:35]
Decision: budget against `LUT=` printed by `python tools/run.py synth`. Target < 542 with margin; do not trade risk for LUTs below that.
Why / evidence: guide §11 "LUT line of the Gowin Resource Usage Summary". Measured report layout: rows LUT / ALU / SSRAM / Register are distinct (results/storage_experiment/README.md).
Rejected: reading "Logic: n(LUT, ALU, RAM16)" from the Utilization Summary — that sum is not what the guide names.
Guarded by: resource_usage() in tools/run.py parses only the Resource Usage Summary.

## D8: Inter-byte gap lives in uart_tx as idle bit-times after the stop bit  [jayden, 2026-10-03 14:35]
Decision: uart_tx holds tx_ready low for stop bit + GAP_BITS bit-times. pkt_ctrl goes back to S_RX right after byte 8 is handed over.
Why / evidence: guide §10 warning — the BL616 drops bytes sent back-to-back. Reuses the baud counter; the gap is enforced by the handshake, and the trailing gap cannot block the next request. Value is O5.
Rejected: a gap counter in pkt_ctrl waiting after byte 8 — a second wide counter, and RX would be deaf during the last gap.
Guarded by: a_tx_gap_min.

## D9: Latency is measured on the judge PC, request sent → 8th response byte received  [jayden, 2026-10-03 14:35]
Decision: the only latency lever is TX_GAP_BITS: 60.7 µs per gap bit on top of 1.38 ms of wire time.
Why / evidence: guide §11 — reference average 16.626 ms, full points ≤ 20.8 ms, "dominated by BL616, USB, operating-system" overhead.
Rejected: optimizing compute cycles — a few hundred ns in a 16 ms measurement.
Guarded by: MEAS log entries from robust-test CSVs.

## D10 (O1): Every request carries one A and one B; the same item twice is never sent  [jayden, 2026-10-03 14:55]
Decision: not a supported input. The design processes slot 1 then slot 2 through one engine, so it stays deterministic, but no expected value exists for it.
Why / evidence: organizer/22_robust_uart_test.py:159-164 — the only two packings are (A,B) and (B,A). Same in organizer/21_quick_uart_test.py:96-101. Each item has its own model fed once per packet (organizer/22_robust_uart_test.py:125-128).
Rejected: generating same-item-twice vectors — the oracle has no definition for them, so any expected value would be invented.
Guarded by: gen_vectors.py emits only A/B and B/A; a_other_item_untouched.

## D11 (O2): An item byte other than 0x11 / 0x22 is never sent; not handled  [jayden, 2026-10-03 14:55]
Decision: behaviour for any other item byte is undefined. pkt_ctrl may use any decode that maps 0x11 → SEL_A and 0x22 → SEL_B. The item byte is still echoed unchanged.
Why / evidence: organizer/22_robust_uart_test.py:34-35 define the only IDs; organizer/22_robust_uart_test.py:160-164 are the only places an item byte is chosen. The checker compares the echo only against those (organizer/22_robust_uart_test.py:224-225).
Rejected: an "unknown item → NONE, no state change" path — logic and test matrix for an input that does not exist.
Guarded by: cover that both IDs appear in both slots; no vector contains another ID.

## D12 (O3): Warm-up is `index < 16` in hardware; the model counts samples, and the two agree on every run the judge can send  [jayden, 2026-10-03 14:55]
Decision: `cmd_eval = (index >= 16)`; index 0 clears all state first. Keep as designed.
Why / evidence: model warms up while `len(self.window) < WINDOW_SIZE` (organizer/22_robust_uart_test.py:86) — by sample count per item, not by index. Indices are sent as `range(PACKET_COUNT)`, once each, in order (organizer/22_robust_uart_test.py:154), and every packet has both items (organizer/22_robust_uart_test.py:159-164), so count == index. The model has no reset: it is built once (organizer/22_robust_uart_test.py:125-126); the index-0 clear is from guide §10.2.2 / §10.3.
Rejected: a per-item sample counter instead of the index — more state, and it would not start a new session on index 0 as the guide requires.
Guarded by: a_warmup_none, a_clear_on_index0; oracle vectors. NOTE for verif: tools/oracle.py must build fresh models on index 0 — that wrapper is ours, not organizer code.

## D13 (O4): RX partial-packet timeout = 2^20 clocks (38.8 ms)  [jayden, 2026-10-03 14:55]
Decision: RX_TIMEOUT_CLKS = 1 << 20. Was 2^23 (311 ms), which was wrong.
Why / evidence: the script opens the port, sleeps 0.2 s, then sends index 0 (organizer/22_robust_uart_test.py:149-154; quick test :90-92). A stray byte at port open must be discarded inside that 200 ms or every packet is misaligned and index 0 times out. One request is a single 8-byte `ser.write` (organizer/22_robust_uart_test.py:166-169), so bytes inside a request are not seconds apart. UNVERIFIED on the board: actual intra-request spacing through the BL616.
Rejected: no timeout — one stray byte costs the whole run. 311 ms — longer than the 200 ms it has to beat.
Guarded by: testbench/pkt_ctrl: stray byte, 100 ms idle, then a full request must be answered (to be written).

## D14: `logic` only — no `wire`, no `reg`, no `default_nettype none`  [jayden, 2026-10-03 15:10]
Decision: ports are `input logic` / `output logic`; all internal signals `logic`. No `default_nettype` directives. Supersedes the port style in D1.
Why / evidence: Questa (vlog-2892) and Gowin (EX3094) both reject `input logic` under `default_nettype none`. Without the directive, `vlog -lint` reports an undeclared net as `vlog-2623 Undefined variable` (checked with two typo'd nets), and tools/run.py fails on any warning.
Rejected: `input wire logic` — keeps `wire` in every port list. `input var logic` — works in both tools but is unfamiliar and easy to get wrong.
Guarded by: tools/run.py zero-warning rule; never merge with --allow-warnings. Gowin alone does NOT catch a typo'd net, so a sim PASS line is required on every PR.

## D15: por_reset's counter uses a declaration initializer and plain `always`  [jayden, 2026-10-03 17:10]
Decision: `logic [CNT_W-1:0] cnt_q = '0;` clocked by `always @(posedge clk)`. The only exception to "always_ff for state"; no `initial` block in src/.
Why / evidence: `vlog -sv -lint` rejects initializer + always_ff (vlog-7061, "driven in an always_ff block, may not be driven by any other process"). Gowin V1.9.11.03 synthesizes it standalone to 4 DFF + 5 LUT, 0 warnings. In `top` with the other modules still stubs it is optimized away (LUT=0 REG=0), so no in-design number yet.
Rejected: `initial cnt_q = '0;` + always_ff (Questa and Gowin accept it, same 5 LUT) because it breaks "no initial in src/" and an initial block writing an always_ff variable is what the lint rule is about; suppressing 7061 in run.py because it would hide a real second driver anywhere.
Guarded by: testbench/por_reset (rst 1 for exactly 15 clocks, then 0, never X). Power-on value on the board is still UNVERIFIED (D2).

## D16: Valid/ready outputs are 0 from the second clock of `rst`, not the first  [jayden, 2026-10-03 17:45]
Decision: a `*_valid` / `*_ready` output may be a plain register cleared by `rst`; it must read 0 from the second clock of `rst` onward. ARCHITECTURE §3 reworded to say so.
Why / evidence: `rst` is high for 15 consecutive clocks and only at power-on (por_reset, testbench/por_reset PASS @ 4040756), so every such register is 0 for the last 14 of them and no transfer can occur in reset. The checkers were already written this way (`rst ##1 rst |-> ...` in b1/b2/b3/pkt_ctrl_sva).
Rejected: 0 in the same cycle as `rst` because it forces a combinational `!rst` gate on every valid and ready (LUTs on the judged row) for no behaviour the judge or any module can observe.
Guarded by: a_valid_low_in_rst in b1_sva, b2_sva, b3_sva, pkt_ctrl_sva; cover c_valid_low_in_rst.

## D17: uart_rx must receive correctly with the host up to 2 % off 115200 baud  [jayden, 2026-10-03 17:45]
Decision: requirement is +-2 % host baud error per frame, frames back to back, at CLKS_PER_BIT = 234. The 2 % is a chosen margin, not a measurement.
Why / evidence: 27e6 / 234 = 115384.6 baud, 0.16 % fast (D3). A mid-bit sampler's last sample is 9.5 bit-times after the start edge, so it fails near 0.5 / 9.5 = 5.3 % total error before synchronizer and divider quantization; 2 % leaves more than half of that. UNVERIFIED: the BL616's actual bit time and the RTL's real limit (no uart RTL yet; the testbench model passes at 4 %).
Rejected: asking the judges because the bit timing is produced by the BL616 on our board, not by the judge PC; testing at 0 % only because the real error is unknown until measured.
Guarded by: `sim uart` (default `+BAUD_ERR_PM=20`), `sim system` (10). Board: robust test x 20+ with 0 byte errors.

## D18 (O5): TX_GAP_BITS = 4  [jayden, 2026-10-03 20:15]
Decision: `TX_GAP_BITS = 4` idle bit-times after each stop bit (was the placeholder 10).
Why / evidence: results/gap_sweep.md (Wihl, COM5): 20 hw robust runs at each of 10, 4, 2, 1, 0, every value 1680/1680 correct, 0 timeouts; avg RTT 17.0-17.2 ms at every value, inside run-to-run spread. The sweep predates constraints/gqh.sdc: re-run on the final bitstream.
Rejected: 0 or 1 (smallest passing) because only one host PC was measured and the judge's PC/driver is unknown, for a theoretical saving of ~0.28 ms/packet that the sweep could not measure; 10 because nothing was found to need it.
Guarded by: hw robust x 20 on the submitted bitstream (0 failures); `sim system` and b3_sva take GAP_BITS from gqh_pkg, so they check the gap is held, not that 4 is enough.

## D19: v2 target = lowest total logic, then registers; BSRAM is free, DSP is not  [jayden, 2026-10-04 00:30]
Decision: for v2, budget against `LOGIC=` then `REG=` on the line `python tools/run.py synth` prints (baseline LOGIC=386 REG=704, main 93f680d). This supersedes D7 for placement. Prices stay full 16-bit.
Why / evidence: organizer supplement to the guide (posted 10-03). Qualify: 100/100 on the judge run AND a hidden full-range run (prices 0..65535, every packet and action correct, no timeouts, no reprogramming in between). Rank among qualifiers: lowest total logic count in the Resource Usage Summary (LUT + ALU + other logic types), then fewest registers, then median latency over 5 runs (within 5 % is a tie). BSRAM is allowed and not counted. Lead, 10-04: DSP blocks count as logic; only BSRAM is exempt. Judges re-synthesize the committed source with Gowin V1.9.11.03 "using the project settings in your commit" (hence gqh.gprj, PR #21) and check it behaves like the submitted .fs.
Rejected: moving arithmetic into ALUs or DSP (both counted); narrowing the datapath to the practice price range (fails the full-range run).
Guarded by: `LOGIC=` comes from the place-and-route report's Resource Usage Summary (386); the synthesis report's LUT + ALU is 380. Which of the two the judges read is not known; track LOGIC=. Profiles `judge` and `extreme` drive full-range prices in sim.

## D20: ma_engine state in block RAM, bit-serial datapath; nothing in the RAMs is cleared  [jayden, 2026-10-04 01:15]
Decision: window, sum, previous price and last action live in four inferred block RAMs (src/ram_sdp.sv), one bit per address for the first three. The datapath is bit-serial, LSB first, SUM_W steps per sample (SUM_W + 3 clocks from the transfer to act_valid, under 1 us). A clear command only zeroes the count of samples since the clear. This supersedes D6. ram_sdp carries the one synthesis attribute in the design, `syn_ramstyle = "block_ram"`.
Why / evidence: D19 ranks by total logic and block RAM is not counted. Measured on this tool: without the attribute a 512x1 RAM becomes 32 RAM16 + 52 LUT (counted); with it, 1 BSRAM and 0 LUT. Whole design `SYNTH: PASS LUT=220 ALU=8 SSRAM=0 BSRAM=4 REG=197 LOGIC=232` against LOGIC=386 REG=704 for v1; engine alone 40 LUT + 8 ALU / 52 REG against 130 + 72 / 559. Timing met at 27 MHz, post-route Fmax 176 MHz. Not clearing is correct because both items get one sample per packet (D10) and indices arrive in order after index 0 (D12): a window slot is rewritten exactly 16 packets after it was written, the first sample after a clear takes the old sum as 0, warm-up samples subtract nothing and store ACT_NONE, and the first evaluated sample comes after 16 samples per item.
Rejected: word-wide RAM for the window only (results/storage_experiment: no LUT gain, the arithmetic and the per-item muxes stay); DSP blocks (counted, D19); a clear loop over the RAMs (extra control for a case D10/D12 exclude); Gowin SDPB primitives with mixed port widths (vendor primitive, needs the vendor simulation library).
Guarded by: `sim ma_engine` and `sim system` against the oracle on five profiles incl. index 0 mid-stream and full-range prices; a_other_item_untouched reads the RAM contents (b2_bind); board: full-range and practice robust runs alternated without reprogramming, so every session after the first starts on stale RAM contents.
