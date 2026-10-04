# Storage experiment (2026-10-03) — evidence for DECISIONS D6, D7

**Not design source.** A throwaway single-cycle engine (`eng.sv`) behind a pin wrapper (`top.sv`),
synthesized with GowinSynthesis V1.9.11.03 Education for GW2AR-LV18QN88C8/I7, `-verilog_std sysv2017`,
`run syn` only (no place & route, no constraints). The prototype was never simulated; the numbers
compare storage styles and are not a prediction for the final engine.

| STYLE | Window storage | LUT | ALU | SSRAM | Register |
|---|---|---|---|---|---|
| 0 | flop shift registers, cleared, `syn_srlstyle="registers"` | 126 | 89 | 10 | 543 |
| 4 | same as 0 without the attribute | 126 | 89 | 10 | 543 |
| 1 | flop shift registers, window not cleared, attribute | 382 | 89 | 10 | 543 |
| 2 | same as 1 without the attribute | 382 | 89 | 10 | 543 |
| 3 | inferred async-read RAM 32×16 + per-item pointer, not cleared | 138 | 92 | 18 | 39 |

Numbers are the rows of the report's **Resource Usage Summary**, where LUT, ALU, SSRAM and Register
are separate rows. Estimated Fmax for STYLE 0: 73.598 MHz (synthesis estimate; clock is 27 MHz).

Reproduce: copy `eng.sv` and `top.sv` into an empty `src/`, set `STYLE` in `top.sv`, run
`gowin/build.tcl` with `gw_sh`, read `impl/gwsynthesis/gqh_syn.rpt.html`.
