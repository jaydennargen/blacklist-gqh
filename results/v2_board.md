# v2 board check: main's bitstream on hardware (COM7, lead's PC)

Build: main @ddc51c7 (uart_tx v2 #25, pkt_ctrl timeout LFSR #27, block-RAM bit-serial engine #26). Clean tree.
`SYNTH: PASS @ ddc51c7 LUT=203 ALU=8 SSRAM=0 BSRAM=4 REG=197 LOGIC=214 fs=bitstream\gqh.fs`
The rebuilt .fs differs from the committed one only in its `//Created Time` line. Committed .fs sha256 cda31d1d...

Place-and-route Resource Usage Summary: Logic 214 (204 LUT, 10 ALU, 0 ROM16), SSRAM 0, Register 197, BSRAM 4.
Timing (gowin/impl/pnr/gqh_tr_content.html): sys_clk 27.000 MHz, post-route Fmax 164.005 MHz, 0 setup / 0 hold violated
endpoints, worst setup slack +30.940 ns, worst hold slack +0.425 ns.

Programmed: `programmer_cli --device GW2AR-18C --run 2 --fsFile <absolute path to bitstream/gqh.fs>` (SRAM), the
judging condition. No reprogramming or replug between the tests below.

`HW quick @ ddc51c7 rc=0 1.1s csv=0 -> results/1004-025745_ddc51c7_*` / `> PASS`

| test | runs | correct / scored | timeouts | avg RTT (ms) | files |
|---|---|---|---|---|---|
| robust (practice range, seed 0x57214720) | 20 | 1680/1680 | 0 | median 16.928, per-run 16.767-16.941 | results/1004-025748 .. 1004-025838 |
| full-range (organizer script, prices 0..65535, seed 0x1F00D16B) | 5 | 420/420 | 0 | mean 16.910 | results/1004-0259_ddc51c7_fullrange_1..5 |

Per packet over the 20 robust runs (2000 packets): median 16.92 ms, 99th percentile 17.36 ms, worst 19.00 ms.
All robust runs use the same seed, and all full-range runs use the same seed: this shows repeatability, and that a
session starting on RAM contents left by the previous session is handled, not wider data coverage.
The full-range script ran as a copy with only PORT changed (tools/run.py has no mode for it).
