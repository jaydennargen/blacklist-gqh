# VERIFICATION plan (owner: lead) — read only when working in testbench/

## Oracle
Expected values come only from tools/oracle.py (verbatim copy of the organizer model).
Pipeline: gen_vectors.py (constrained-random data + oracle) -> vectors/*.hex -> SV TB replays + compares.

## Where randomness lives
- Python (changes expected values): prices, slot order, multi-session index-0 restarts. Profiles: organizer (the judge script's own generation: prices 0..100, A first in warm-up; the official seed is unpublished), judge (wide random walk), cross, equal, extreme.
- SV (never changes expected values): inter-byte gap, idle between packets, baud error within UART tolerance.

## Test ladder (each rung must pass before the next)
1. Unit: uart (loopback, baud error), pkt (framing, resync), ma_engine (vectors at engine boundary)
2. System, 1 seed per profile
3. System, >= 20 seeds per profile, random SV timing
4. Hardware: quick, then robust x 20+

## Running the ladder (vectors first: `python tools/gen_vectors.py --profile all --seeds 2`)
| Rung | Command | Checks |
|---|---|---|
| 1 | `python tools/run.py sim uart --plusargs "+REQUIRE_COVERS"` | uart_tx -> host, uart_tx -> uart_rx, host -> uart_rx with baud error; false start; broken stop bit |
| 1 | `python tools/run.py sim pkt_ctrl --plusargs "+REQUIRE_COVERS"` | commands and response bytes per packet; resync after stray bytes; byte dropped while busy |
| 1 | `python tools/run.py sim ma_engine --plusargs "+REQUIRE_COVERS"` | every action vs the oracle, 5 profiles, at B2 |
| 2 | `python tools/run.py sim system --plusargs "+REQUIRE_COVERS"` | every response vs the oracle at the pins, 5 profiles (about 5 min); stray byte + 100 ms first (D13) |
| 3 | `python tools/run.py sim system --seeds 5 --plusargs "+VEC=vectors/<profile>_s<n>.hex"` | one file (about 1 min a seed); the seed moves timing only |

`--models` runs the same test on `testbench/models/` instead of `src/`. That tests the testbench, never
the RTL, and the summary line says so. With `--models`, `+MUT=<n>` breaks the model in one place (list at
the top of each model file) and the run must go red.

## Assertions (written before RTL; bound via `bind`, in testbench/common/)
Protocol: no TX before 8th RX byte; exactly 8 TX bytes per request; reserved bytes 0; TX idle gap >= configured minimum.
Functional: index 0 clears all state before use; warm-up actions NONE; routing by item ID; response slot order mirrors request.

## Covers (test fails if any is 0)
BUY, SELL, repeat-last (no crossing), prev==old_avg, cur==new_avg (no-cross equality), index 0 mid-stream, B-in-slot-1, price 0, price 0xFFFF.

## Mutation set (each must turn the regression red; record kill ratio in DECISIONS)
<= -> <, > -> >=, old_avg/new_avg swapped, round instead of floor, route by slot, skip index-0 clear, skip warm-up NONE, reserved != 0.
