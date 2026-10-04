# SPEC — distilled from the GQH Hardware Track Participant Guide (§ = guide section)

Authoritative over everything except `organizer/` files. If this disagrees with the
organizer's reference model, the model wins and this file gets fixed (log a DECISION).

## Board / ports (§9) — names fixed by organizer .cst
| Port | Pin | Dir | Note |
|---|---|---|---|
| sys_clk | 4 | in | 27 MHz |
| reset_btn | 87 | in | pull-down, optional |
| uart_rx_i | 70 | in | BL616 → FPGA |
| uart_tx_o | 69 | out | FPGA → BL616 |
| led0_n, led1_n | 15, 16 | out | active-low, optional; drive 1 if unused |
All six ports must exist on the top module even if unused.

## UART (§10.1.1)
115200 baud, 8N1, LSB first. Multi-byte fields big-endian.
27 MHz / 115200 = 234.375 clocks/bit.

## Request: 8 bytes, in this order (§10.1.2)
`index[15:8] index[7:0] item1 price1[15:8] price1[7:0] item2 price2[15:8] price2[7:0]`
Prices unsigned 16-bit.

## Response: 8 bytes, in this order (§10.1.3)
`index[15:8] index[7:0] item1 action1 item2 action2 0x00 0x00`
index and item fields echo the request. Reserved bytes always 0x00.

## Codes (§10.1.4–5)
Items: A = 0x11, B = 0x22. Actions: NONE 0x00, SELL 0x01, BUY 0x02.

## Protocol rules (§10.1.6–7, §10.2)
- Exactly one response per request. No response before all 8 request bytes. No unsolicited bytes.
- Response slot order mirrors the request. The tester may place either item in either slot on any packet.
- NONE is sent only before that item's first crossing; with no crossing, the item's last action is sent again.
- Judge is stop-and-wait. Run = indices 0..99. 0..15 warm-up, 16..99 scored (84 packets, 168 actions).
- Response must fully arrive within 1 s or the run ends (TIMEOUT).
- BL616 can drop/corrupt bytes if TX bytes are back-to-back: insert idle between response bytes.
  Gap length is a measured DECISION, not a guess. Latency includes the gap.

## Per-item state (§10.3) — keyed by item ID, never by slot or index
window[16] of uint16, sum (uint20), prev_price (uint16), last_action (2 bits, NONE at session start).

## Session reset (§10.3)
On index == 0: clear ALL state for both items first (every window, sum, previous price, last action),
then process index 0's prices as the first samples. The board is not reset or reprogrammed between runs (§10.2.2).

## Warm-up: index 0..15 (§10.3)
Per item: push price into window, sum += price, prev_price = price. No crossing evaluation.
Respond NONE for both actions.

## Update: index ≥ 16 (§10.3), per item
```
old_avg  = old_sum >> 4                       // floor
new_sum  = old_sum - oldest_price + cur_price // oldest = price from 16 samples ago
new_avg  = new_sum >> 4
if      (prev_price <= old_avg && cur_price > new_avg) action = BUY
else if (prev_price >= old_avg && cur_price < new_avg) action = SELL
else                                                   action = last_action
last_action = action; prev_price = cur_price; push cur_price into window
```
All compares unsigned.

## Scoring (§11)
Correctness 70 (50 packet, 20 action). Latency 15: ≤20.8 ms full, ≤33.3 ms 8 pts. LUT 15: 15×min(1, 542/ours).
Latency = average over received packets, measured on the judge PC from just before the request is sent until the
8th response byte is received; reference average 16.626 ms, mostly USB/BL616/host overhead.
Latency and LUT points are ZERO if packet correctness < 95%.
LUT = total LUT line of Gowin synthesis report Resource Usage Summary.

## Submission (Part 3)
Public repo; final .fs in `bitstream/` built from the committed source; README; organizer .cst included.
SHA goes in Devpost, not README. Deadline Sun Oct 4 11:00 EDT; board to Reitz 2345 by 11:00.

## Confirmed from the organizer scripts (DECISIONS D10–D13)
- Every request has exactly one A and one B, in either order. No other item byte is sent.
- The reference model warms up on an item's first 16 samples; with indices 0..99 sent in order this equals index < 16.
- The judge opens the port, waits 0.2 s, then sends index 0. Warm-up response contents are not checked, but must arrive.
- Practice prices are 0..100; the official seed differs. Design for the full 16-bit range.

## Open questions → see docs/DECISIONS.md "Open"
