# O5 TX gap sweep (hw robust, COM5, Wihl's PC)

Method: TX_GAP_BITS = N by temporary local edit of src/gqh_pkg.sv (lead OK'd; never committed, restored to 10),
`run.py synth`, SRAM-program (programmer_cli -r 2), 20x `python tools/run.py hw robust --port COM5`.
Failures = scored packets not CORRECT + timeouts, summed over the 20 runs. Run label `a0ddb5f-dirty` = a0ddb5f + only that edit.

| TX_GAP_BITS | SYNTH line | runs | correct / scored | timeouts | avg RTT (ms) | per-run avg min-max (ms) | files |
|---|---|---|---|---|---|---|---|
| 10 | LUT=313 ALU=72 SSRAM=0 BSRAM=0 REG=705 (eff7e59) | 20 | 1680/1680 | 0 | 17.066 | 16.735-18.079 | results/1003-194335 .. 1003-194426 (label 9054a78, same RTL) |
| 4 | LUT=308 ALU=72 SSRAM=0 BSRAM=0 REG=704 | 20 | 1680/1680 | 0 | 17.006 | 16.824-17.348 | results/1003-195902 .. 1003-195950 |
| 2 | LUT=322 ALU=71 SSRAM=0 BSRAM=0 REG=704 | 20 | 1680/1680 | 0 | 17.179 | 16.822-19.457 | results/1003-200011 .. 1003-200100 |
| 1 | LUT=310 ALU=71 SSRAM=0 BSRAM=0 REG=704 | 20 | 1680/1680 | 0 | 17.239 | 16.797-18.247 | results/1003-200120 .. 1003-200209 |
| 0 | LUT=322 ALU=71 SSRAM=0 BSRAM=0 REG=704 | 20 | 1680/1680 | 0 | 17.123 | 16.828-17.787 | results/1003-200223 .. 1003-200310 |

## Reading
- Zero failures at every value, including 0: on this PC the BL616 did not drop back-to-back bytes.
- Latency does not move measurably with the gap: all averages are 17.0-17.2 ms, inside run-to-run spread.
  The gap's ideal saving (10 -> 0) is ~0.7 ms; ~15 ms of the RTT is host/USB side (sim wire latency ~2 ms).
- LUT moves 308-322 with no trend (P&R noise), all well under the 500 target.

## Proposal (lead writes the D-entry)
Smallest value with zero failures = 0. Team proposal (Wihl): **TX_GAP_BITS = 4** -- extra margin for an unknown judge PC/driver.
Cost vs 0: 8 bytes x 4 bit-times x 8.68 us = ~0.28 ms/packet in theory; not measurable here (spread is larger).
LUT/latency differences between gap values above are P&R and run-to-run noise, not a reason to pick any one value.
