# ARCHITECTURE (owner: lead)

Status: **v2, for lead sign-off.** Port lists freeze when PR #1 merges; after that a port change
needs the lead. Decisions and their evidence are in `docs/DECISIONS.md` (D-numbers below).

What is and is not proven:
- **Measured**: Gowin synthesis accepts this SystemVerilog style; what the judged LUT line counts;
  LUT cost of the three window storage options (`results/storage_experiment/`).
- **Proven by test**: the stubs in `src/` compile and elaborate as one design with 0 warnings.
- **Read from the organizer scripts** (D10–D13): item packing, warm-up rule, timing around port open.
- **[UNVERIFIED]**: everything tagged so. No RTL behaviour exists yet and nothing has run on the board.

## 0. What drives the shape
- **Correctness first.** 70 points directly, and latency and LUT points are zero below 95%
  packet correctness. One TIMEOUT ends the run (guide §10.2.7).
- **LUT: be under 542, not minimal.** Score is `15 × min(1, 542/ours)`. The judged number is the
  `LUT` row of the Resource Usage Summary; adders and comparators on carry chains (`ALU`) and
  RAM16 (`SSRAM`) are separate rows (D7). Counters and arithmetic are therefore cheap.
- **Latency: host-dominated.** The reference averages 16.6 ms against 1.39 ms of wire time
  (guide §11). Our compute is a handful of 37 ns cycles. The only latency we control is the
  idle gap between response bytes.
- **Fewest places to be wrong.** One clock, one reset, one control FSM, two handshakes.

## 1. Modules
| Module | File | Area | Role |
|---|---|---|---|
| `gqh_pkg` | src/gqh_pkg.sv | integ | Every shared constant and type. |
| `top` | src/top.sv | integ | Pins and wiring. No logic. |
| `por_reset` | src/por_reset.sv | integ | The only reset source: a power-on counter. |
| `uart_rx` | src/uart_rx.sv | io | Pin → bytes. |
| `pkt_ctrl` | src/pkt_ctrl.sv | io | The one control FSM: collect 8 bytes, sequence the engine, send 8 bytes. |
| `ma_engine` | src/ma_engine.sv | datapath | All per-item state and the update rule; one sample per command. |
| `uart_tx` | src/uart_tx.sv | io | Bytes → pin, with the inter-byte idle gap. |

```
                 por_reset ── rst ──► (all)
uart_rx_i ─► uart_rx ─B1─► pkt_ctrl ─B3─► uart_tx ─► uart_tx_o
                              ▲ │
                              │ B2
                              ▼ │
                           ma_engine
```
The guide's suggested blocks map as: packet parser + item router + response builder = `pkt_ctrl`;
A/B state engines + crossing logic = `ma_engine`.

## 2. Shared types (`gqh_pkg`)
| Name | Definition |
|---|---|
| `CLKS_PER_BIT` | 234 |
| `TX_GAP_BITS` | 4 (D18) |
| `RX_TIMEOUT_CLKS` | 2^20 = 38.8 ms (D13) |
| `index_t`, `price_t` | `logic [15:0]` |
| `item_id_t` | `logic [7:0]`; `ITEM_A = 8'h11`, `ITEM_B = 8'h22` |
| `action_e` | `enum logic [1:0]` — `ACT_NONE = 0`, `ACT_SELL = 1`, `ACT_BUY = 2` |
| `item_sel_e` | `enum logic` — `SEL_A = 0`, `SEL_B = 1` |
| `sum_t` | `logic [19:0]` |
| `req_t` | packed, 64 bits: `{index, item1, price1, item2, price2}`; first wire byte is the MSB |
| `rsp_t` | packed, 64 bits: `{index, item1, action1[7:0], item2, action2[7:0], reserved[15:0]}` |
| `WARMUP_END` | 16: `index < 16` is warm-up |

`req_t`/`rsp_t` are not port types. They exist so `pkt_ctrl` and the testbench name fields the
same way, and they match one `vectors/*.hex` line: `{req_t, rsp_t}`.

## 3. Ports and handshakes
Every module except `top` and `gqh_pkg` has `input clk`; every module except those and
`por_reset` has `input rst` (synchronous, active-high). **Every `*_valid` and `*_ready` output is
0 from the second clock of `rst` onward** (D16): a registered output needs one clock of reset to clear.

"valid/ready" means: the transfer happens on the cycle both are 1; once valid is 1 it stays 1 with
stable payload until the transfer; valid never waits for ready.

### top (names fixed by the organizer .cst, guide §9)
| Port | Dir | W | Note |
|---|---|---|---|
| `sys_clk` | in | 1 | 27 MHz |
| `reset_btn` | in | 1 | unused (D2) |
| `uart_rx_i` | in | 1 | |
| `uart_tx_o` | out | 1 | idle high |
| `led0_n`, `led1_n` | out | 1, 1 | driven 1 (off) |

### por_reset `#(CNT_W = 4)`
| Port | Dir | W | Note |
|---|---|---|---|
| `rst` | out | 1 | 1 for 15 clocks after configuration, then 0 forever |

The counter is the one register in the design with an agreed init value (0). **[UNVERIFIED]**
that GW2AR flops come up at their init value after SRAM configuration; first board run.

### uart_rx `#(CLKS_PER_BIT)`
| Port | Dir | W | Note |
|---|---|---|---|
| `rx_i` | in | 1 | asynchronous; 2-flop synchronizer inside |
| `rx_data` | out | 8 | valid on the `rx_valid` cycle only |
| `rx_valid` | out | 1 | strobe |

### pkt_ctrl `#(RX_TIMEOUT_CLKS)`
| Port | Dir | W | Note |
|---|---|---|---|
| `rx_data`, `rx_valid` | in | 8, 1 | B1 |
| `cmd_valid` / `cmd_ready` | out / in | 1 / 1 | B2 |
| `cmd_clear` | out | 1 | |
| `cmd_item_sel` | out | `item_sel_e` (1) | |
| `cmd_eval` | out | 1 | |
| `cmd_price` | out | `price_t` (16) | |
| `act_valid` | in | 1 | B2 |
| `act` | in | `action_e` (2) | |
| `tx_data` | out | 8 | B3 |
| `tx_valid` / `tx_ready` | out / in | 1 / 1 | |

### ma_engine
| Port | Dir | W | Note |
|---|---|---|---|
| `cmd_valid` / `cmd_ready` | in / out | 1 / 1 | B2 |
| `cmd_clear`, `cmd_eval` | in | 1, 1 | |
| `cmd_item_sel` | in | `item_sel_e` (1) | |
| `cmd_price` | in | `price_t` (16) | |
| `act_valid` | out | 1 | |
| `act` | out | `action_e` (2) | |

### uart_tx `#(CLKS_PER_BIT, GAP_BITS)`
| Port | Dir | W | Note |
|---|---|---|---|
| `tx_data` | in | 8 | B3 |
| `tx_valid` / `tx_ready` | in / out | 1 / 1 | |
| `tx_o` | out | 1 | idle high |

### B1: uart_rx → pkt_ctrl — strobe, no back-pressure
- A UART cannot be stalled. `rx_valid` is one cycle; `rx_data` is valid on that cycle.
- A frame whose start bit is not still low at mid-bit, or whose stop bit samples 0, produces no
  strobe.
- `pkt_ctrl` takes a strobe only while collecting a request. A byte arriving during compute or
  transmit is dropped. The judge is stop-and-wait, so this cannot occur in a run (D4).

### B2: pkt_ctrl ↔ ma_engine — valid/ready command, strobe result
- The engine samples every `cmd_*` field on the transfer.
- `cmd_clear = 1`: clear all state of both items. The other fields are ignored. No `act_valid`
  follows; the clear is complete when `cmd_ready` is 1 again.
- `cmd_clear = 0`: apply one sample to item `cmd_item_sel`. `cmd_eval = 0` is a warm-up sample,
  `cmd_eval = 1` an update with crossing evaluation (§4).
- Exactly one `act_valid` strobe per accepted non-clear command, at least one cycle after the
  transfer. `act` is valid on that cycle only; `pkt_ctrl` latches it.
- A strobe needs no ready here because `pkt_ctrl` is the only consumer and is, by construction,
  waiting for it from the transfer onward. `pkt_ctrl` issues no command until the previous one
  has returned.
- **No cycle count is part of the contract.** `pkt_ctrl` waits on `cmd_ready` and `act_valid`.

### B3: pkt_ctrl → uart_tx — valid/ready
- One byte per transfer. Wire format per byte: start, 8 data bits LSB first, 1 stop bit, then
  `GAP_BITS` further idle bit-times. `tx_ready` is 0 from the transfer until all of that has
  elapsed, so the idle gap between response bytes is enforced by the handshake itself.
- `pkt_ctrl` returns to collecting as soon as byte 8 is transferred. It does not wait for the
  line to finish, so the trailing gap never blocks reception of the next request.

## 4. Per-item state (all inside ma_engine)
| Guide §10.3 state | Bits (2 items) | Storage (D20) |
|---|---|---|
| window of 16 prices | 2 × 16 × 16 = 512 | Block RAM `u_win`, one bit per address `{item, slot, bit}`. Slot = samples since the clear / 2. |
| sum | 2 × 20 | Block RAM `u_sum`, `{item, bit}` |
| previous price | 2 × 16 | Block RAM `u_prev`, `{item, bit}` |
| last action | 2 × 2 | Block RAM `u_last`, `{item}` |

- **Why block RAM and a bit-serial datapath** (D20, measured): placement is by total logic and
  block RAM is not counted (D19). Engine 40 LUT + 8 ALU / 52 registers, against 130 + 72 / 559
  for the v1 flop engine (D6, superseded).
- **Clear zeroes one counter, not the RAMs**: the count of samples since the clear. The first
  sample of each item after it takes the old sum as 0, warm-up samples subtract nothing and store
  ACT_NONE, and by the first evaluated sample every word has been rewritten. This depends on
  D10 (one sample per item per packet) and D12 (indices in order after index 0).
- **Keyed by item, never by slot or index**: `cmd_item_sel` selects which item's state is read
  and which is written; the other item's state does not change.
- State changes only as the result of a B2 transfer (the RAM writes follow it by up to SUM_W + 2 clocks). One sample:

```
cmd_eval = 0 (warm-up):   sum += price;  prev = price;  push price;  act = NONE
                          last_action unchanged
cmd_eval = 1 (update):    old_avg = sum >> 4
                          new_sum = sum - window[15] + price;   new_avg = new_sum >> 4
                          BUY   if prev <= old_avg && price > new_avg
                          SELL  else if prev >= old_avg && price < new_avg
                          else  last_action
                          sum = new_sum;  prev = price;  push price;  last_action = act
```
All compares unsigned. This is guide §10.3 restated for reading; **expected values come only from
the oracle**, never from this block.

Implementation inside `ma_engine`: multi-cycle and bit-serial, LSB first, one step per sum bit; `act_valid`
comes SUM_W + 3 clocks after the transfer. Post-route Fmax of the whole design 176 MHz against a 27 MHz clock.

## 5. FSMs
### pkt_ctrl — the only packet-level state in the design (D4)
| State | Does | Leaves when |
|---|---|---|
| `S_RX` | Byte count 0…7; shifts each `rx_valid` byte into a 64-bit `req_t` register. Count 0 is idle. | 8th byte → `S_CLEAR` if `index == 0`, else `S_CMD1` |
| `S_CLEAR` | `cmd_valid`, `cmd_clear = 1` | transfer → `S_CMD1` |
| `S_CMD1` | `cmd_valid` for slot 1: `item1`, `price1` | transfer → `S_ACT1` |
| `S_ACT1` | waits | `act_valid`: latch `act` as action1 → `S_CMD2` |
| `S_CMD2` | `cmd_valid` for slot 2: `item2`, `price2` | transfer → `S_ACT2` |
| `S_ACT2` | waits | `act_valid`: latch `act` as action2 → `S_TX` |
| `S_TX` | Byte count 0…7; `tx_valid` with byte k of `rsp_t` | 8th transfer → `S_RX` |

- `cmd_eval = (index >= WARMUP_END)`, the same for both slots (D12).
- `cmd_item_sel`: `ITEM_A` → `SEL_A`, `ITEM_B` → `SEL_B`. No other item byte is ever sent, so any
  decode that gets those two right is acceptable (D11). The item byte is echoed unchanged.
- Response bytes come straight from the request register and the two latched actions:
  `index[15:8], index[7:0], item1, {6'b0, action1}, item2, {6'b0, action2}, 8'h00, 8'h00`.
- Partial-packet timeout: while the byte count is 1…7, a counter restarts on every `rx_valid`;
  reaching `RX_TIMEOUT_CLKS` sets the count back to 0. It never fires in a healthy run. Its job
  is to stop one stray byte (for example at COM-port open) from misaligning every later packet.
  The judge sends index 0 only 200 ms after opening the port, so the timeout must be well under
  that (D13).
- Structural guarantees: a response byte can only be offered in `S_TX`, which is only reachable
  through all 8 request bytes; `S_TX` sends exactly 8 bytes; slot order is fixed by the state
  order.

### uart_rx
`IDLE` (wait for synchronized rx = 0) → `START` (half a bit; back to `IDLE` if rx is 1) →
`DATA` (8 mid-bit samples) → `STOP` (mid-bit sample; strobe if 1) → `IDLE`.

### uart_tx
`IDLE` (ready) → `START` → `DATA` (8 bits) → `STOP` → `GAP` (`GAP_BITS` bit-times) → `IDLE`.

### ma_engine
No FSM required. `cmd_ready` = not in reset and no command in progress.

### por_reset
Saturating counter; `rst = (count != max)`.

## 6. Cycle-level timeline, one packet
**Design intent [UNVERIFIED]** until RTL exists; assumes a single-cycle engine and back-to-back
request bytes. Units: `sys_clk` cycles (37.04 ns). Bit = 234, frame = 2340.

| Cycle | Event |
|---|---|
| 0 | Falling edge of request byte 0's start bit at `uart_rx_i` |
| ≈ 2340·k + 2226 | `rx_valid` for byte k: middle of its stop bit, plus the synchronizer |
| T ≈ 18 606 | `rx_valid` for byte 7; `pkt_ctrl` leaves `S_RX` |
| T+1 | `S_CMD1`: B2 transfer, slot 1 |
| T+2 | `act_valid`, action1 latched |
| T+3 | `S_CMD2`: B2 transfer, slot 2 |
| T+4 | `act_valid`, action2 latched |
| T+5 | `S_TX`: B3 transfer, byte 0 |
| T+6 | Falling edge of response byte 0's start bit at `uart_tx_o` |
| T+6 + 234·(10+G)·k | Start bit of response byte k (G = `GAP_BITS`) |
| T+6 + 234·(10+G)·7 + 2340 | End of byte 7's stop bit: response complete on the wire |

Index 0 inserts `S_CLEAR` after T: about 2 more cycles.

First request edge to last response stop bit = `37 332 + 1638·G` cycles = **1.38 ms + 60.7 µs
per gap bit**. At the placeholder G = 10 that is 1.99 ms. The judge's number also contains
USB, BL616 and host time, which is most of the reference's 16.6 ms and which we cannot see from
here; the threshold for full latency points is 20.8 ms.

## 7. Assertions to write before RTL (`testbench/common/`, attached with `bind`)
Each is paired with a cover of its trigger; the test fails if a cover never hits.

| Name | Checks |
|---|---|
| `a_valid_low_in_rst` | every valid/ready output is 0 from the second clock of `rst` (D16) |
| `a_cmd_stable` | `cmd_*` unchanged from `cmd_valid` until the transfer |
| `a_tx_stable` | `tx_data` unchanged from `tx_valid` until the transfer |
| `a_one_act_per_cmd` | one `act_valid` per non-clear command, none for a clear, none unsolicited |
| `a_no_cmd_while_busy` | no B2 transfer between a transfer and its `act_valid` |
| `a_no_tx_outside_s_tx` | `tx_valid` only in `S_TX` |
| `a_rsp_8_bytes` | exactly 8 B3 transfers per visit to `S_TX` |
| `a_reserved_zero` | response bytes 6 and 7 are 0 |
| `a_tx_gap_min` | at least `GAP_BITS` idle bit-times between a stop bit and the next start bit on `tx_o` |
| `a_clear_on_index0` | a clear command precedes the slot-1 command iff `index == 0` |
| `a_warmup_none` | `act == ACT_NONE` whenever `cmd_eval` was 0 |
| `a_other_item_untouched` | a command to one item changes no state of the other |
| `a_rx_drop_only_when_busy` | an `rx_valid` outside `S_RX` is the only way a byte is ignored (cover: never in a stop-and-wait run) |

## 8. Still open
| | Question | Needs |
|---|---|---|
| — | Power-on init of the `por_reset` counter; `CLKS_PER_BIT = 234` against the real BL616. | first board run |
| — | Byte spacing inside a request through the BL616 (D13 assumes far below 38.8 ms). | first board run |

What the judge does not check, from the script: the contents of warm-up responses (indices 0–15)
are ignored, but all 8 bytes must still arrive within 1 s or the run ends. Latency is averaged
over every received packet, warm-up included.
