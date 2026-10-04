# v1 board check: main's bitstream (GAP=4 + SDC) on hardware (COM5, Wihl's PC)

First look at main on hardware, not the judged run. Bitstream is NOT committed (lead picks the judged one after rung 3).

Build: main @1d4f524 (includes f9aadd2: D18 TX_GAP_BITS=4, constraints/gqh.sdc). Clean tree, no src/ edits.
`SYNTH: PASS @ 1d4f524 LUT=308 ALU=72 SSRAM=0 BSRAM=0 REG=704 fs=bitstream\gqh.fs` -- same as the reference build (aa7ee59).

Timing (gowin/impl/pnr/gqh_tr_content.html): constraint sys_clk 27.000 MHz, actual Fmax 62.860 MHz,
0 setup / 0 hold violated endpoints (TNS 0.000 both), worst setup slack +21.129 ns. Same as the reference.

Programmed: programmer_cli --device GW2AR-18C --run 2 (SRAM).

hw quick: `HW quick @ 1d4f524 rc=0 0.8s csv=0 -> results/1003-202847_1d4f524_*` / `> PASS`
(also results/1003-202833, PASS; rerun only because the first summary line was cut off in my terminal).

hw robust x20 (same method as gap_sweep.md; failures = scored not CORRECT + timeouts):

| runs | correct / scored | timeouts | avg RTT (ms) | per-run avg min-max (ms) | files |
|---|---|---|---|---|---|
| 20 | 1680/1680 | 0 | 17.122 | 16.766-18.762 | results/1003-202904 .. 1003-202959 |

Reading: same behaviour as the pre-SDC GAP=4 sweep row (1680/1680, 17.006 ms). The new placement changes nothing visible on the board.

## Flash boot (bitstream committed f458462 = same .fs; written to external flash)

`programmer_cli --device GW2AR-18C --run 9 --spiaddr 0x000000 --fsFile bitstream/gqh.fs` -> `SPI program and verify success!`
- `--run 1` (Reprogram from flash) then hw quick straight away: rc=1, 0 of 8 bytes at idx 0 (results/1003-203429). Cause not found.
- Unplug + replug (real power-up from flash): `HW quick @ f458462 rc=0 0.6s csv=0 -> results/1003-203741_f458462_*` / `> PASS`.
  LEDs stay off: top drives led0_n/led1_n = 1; the Sipeed blink demo in flash was overwritten.

| boot | runs | correct / scored | timeouts | avg RTT (ms) | per-run avg min-max (ms) | files |
|---|---|---|---|---|---|---|
| flash, after power cycle | 20 | 1680/1680 | 0 | 2.563 | 2.064-4.103 | results/1003-203751 .. 1003-203822 |

RTT dropped from ~17 ms (every earlier HW run, all done right after JTAG programming without a power cycle) to ~2.6 ms,
close to the ~2 ms wire latency from sim. Unverified guess: the ~15 ms "host/USB" overhead was the BL616 debug bridge state
after a JTAG session, and a power cycle clears it. Not tested yet: SRAM-program, power cycle is impossible (SRAM is lost), so
the check is flash-program -> power cycle -> robust (this table) vs flash-program -> no power cycle -> robust.

## RTT vs power cycle (same .fs throughout)

- Flash write again (-r 9, verify success), no power cycle -> hw quick rc=1, 0 of 8 bytes (results/1003-204123). Reproduces the 20:34 failure:
  after an exFlash write the FPGA does not answer until power-cycled, so "flash, no power cycle" cannot be measured.
- Then SRAM program (-r 2, JTAG), no power cycle -> `HW quick @ 5d3a708 rc=0 0.7s csv=0 -> results/1003-204137_5d3a708_*` / `> PASS`.

| condition | runs | correct / scored | timeouts | avg RTT (ms) | per-run avg min-max (ms) | files |
|---|---|---|---|---|---|---|
| power cycle, boot from flash | 20 | 1680/1680 | 0 | 2.563 | 2.064-4.103 | results/1003-203751 .. 1003-203822 |
| JTAG SRAM load, no power cycle | 20 | 1680/1680 | 0 | 17.120 | 16.823-17.993 | results/1003-204146 .. 1003-204240 |

Reading: the ~15 ms extra appears after a JTAG session and goes away on power-up; RTL and bitstream are identical.
Likely the board's BL616 USB bridge behaves differently after it has been used for JTAG (mechanism not verified).
The judge powers the board up from flash, which is the 2.6 ms condition. All earlier HW RTT numbers (~17 ms) were measured after JTAG.

## Second power cycle (flash boot, replugged 20:45)

Port check: board = one FT2232-style device (VID:PID 0403:6010, serial 2025030317). COM7 = channel A (MI_00, JTAG,
programmer "FT2CH/0"); COM5 = channel B (MI_01, UART). COM3/COM4 are Bluetooth. Every robust run printed `UART port: COM5`.

`HW quick @ cb81efa rc=0 0.5s csv=0 -> results/1003-204541_cb81efa_*` / `> PASS`

| condition | runs | correct / scored | timeouts | avg RTT (ms) | per-run avg min-max (ms) | files |
|---|---|---|---|---|---|---|
| power cycle #2, boot from flash | 20 | 1680/1680 | 0 | 2.779 | 1.971-4.160 | results/1003-204554 .. 1003-204621 |

Reproduces the 2.563 ms power-up result.

## Organizer scripts run as the guide says (results/organizer_run_1003-204819)

Board booting from flash (judged .fs f458462), no JTAG since power cycle #2. organizer/21 and 22 copied byte-exact,
only `PORT = "COM5"` changed (verified: one differing line each), run with `python <script>` in that folder.
- 21_quick_uart_test.py: rc=0, `PASS` (quick_console.txt)
- 22_robust_uart_test.py: rc=0. trade_summary_100.txt: 100/100 received, 84/84 correct, 168/168 actions, 0 timeouts,
  **Estimated correctness points: 70.0 / 70**, avg RTT 2.942 ms, UART port COM5, practice seed 0x57214720.

## Judge condition: SRAM program, no replug (20:57)

Participant guide §10.2.5 and Part 1: "Judges program each board in SRAM mode with the .fs file from your submitted
commit"; §5: "Judging uses SRAM programming, so you do not need to write to external flash." So the judged condition
is a JTAG SRAM load, NOT a flash boot (the 20:42 note "Judge boots from flash" was wrong).

`programmer_cli --device GW2AR-18C --run 2 --fsFile bitstream/gqh.fs` (sha256 3772ada6..., f458462) -> User Code 0x0000770A,
Status 0x00006020, Finished, 3.77 s. No replug before testing.

`HW quick @ af860d5 rc=0 0.8s csv=0 -> results/1003-205719_af860d5_*` / `> PASS`

| condition | runs | correct / scored | timeouts | avg RTT (ms) | per-run avg min-max (ms) | files |
|---|---|---|---|---|---|---|
| SRAM program (judge condition), no replug | 20 | 1680/1680 | 0 | 17.331 | 16.801-19.566 | results/1003-205721 .. 1003-205811 |

Matches the 20:42 SRAM result (17.120 ms). Expect ~17 ms on the judge PC unless the extra ~15 ms is specific to this host.
