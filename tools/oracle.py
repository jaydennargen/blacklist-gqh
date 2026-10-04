"""Adapter around the ORGANIZER's reference model. This is the only source of expected values.

DO NOT re-implement the algorithm here from SPEC.md. The model below the marker is a VERBATIM
copy from organizer/22_robust_uart_test.py; never edit it. If the organizer script changes,
re-copy and update COPIED_FROM.
Copy rather than import: importing the script may open the serial port at import time.

Interface used by tools/gen_vectors.py:
  o = Oracle(); o.step(req: bytes(8)) -> bytes(8)   # stateful; index 0 resets, as on the board

  python tools/oracle.py     replays the organizer practice run through Oracle.step and compares
"""
import struct
from collections import deque

COPIED_FROM = ("organizer/22_robust_uart_test.py lines 77-107 (class MovingAverageReference) "
               "+ lines 29, 43-45 (WINDOW_SIZE, ACTION_*), "
               "sha256 72233f776973409f48dad7f350ec7423e8f11a16dd5004d4506fe5fd1342caaa")

REQ_STRUCT = struct.Struct(">HBHBH")   # index16, item1_8, price1_16, item2_8, price2_16
RSP_STRUCT = struct.Struct(">HBBBBH")  # index16, item1_8, action1_8, item2_8, action2_8, reserved16
ITEM_IDS = (0x11, 0x22)                # the only item IDs (DECISIONS D11)


class Oracle:
    def __init__(self):
        self._fresh()

    def _fresh(self):
        self.models = {item: MovingAverageReference() for item in ITEM_IDS}

    def step(self, req: bytes) -> bytes:
        index, item1, price1, item2, price2 = REQ_STRUCT.unpack(req)
        if index == 0:  # DECISIONS D12: index 0 starts a new session with two fresh models
            self._fresh()
        actions = []
        for item, price in ((item1, price1), (item2, price2)):
            if item not in self.models:
                raise ValueError(f"item ID 0x{item:02X} is not in the protocol (DECISIONS D11)")
            action = self.models[item].process(price)
            actions.append(ACTION_NONE if action is None else action)
        return RSP_STRUCT.pack(index, item1, actions[0], item2, actions[1], 0)


def _selfcheck():
    """Practice run exactly as the organizer script builds it (lines 114-128), through step()."""
    import random
    PACKET_COUNT, PRICE_MIN, PRICE_MAX = 100, 0, 100  # organizer lines 28, 31, 32
    ITEM_A, ITEM_B = 0x11, 0x22                       # organizer lines 34, 35
    RANDOM_SEED = 0x57214720                          # organizer line 38

    rng = random.Random(RANDOM_SEED)
    prices_a = [rng.randint(PRICE_MIN, PRICE_MAX) for _ in range(PACKET_COUNT)]
    prices_b = [rng.randint(PRICE_MIN, PRICE_MAX) for _ in range(PACKET_COUNT)]
    slot_rng = random.Random(RANDOM_SEED ^ 0xA5A5A5A5)
    swap_slots = [
        (i >= WINDOW_SIZE and slot_rng.random() < 0.5) for i in range(PACKET_COUNT)
    ]
    ref_a = MovingAverageReference()
    ref_b = MovingAverageReference()
    expected_a = [ref_a.process(p) for p in prices_a]
    expected_b = [ref_b.process(p) for p in prices_b]

    o = Oracle()
    bad = 0
    for i in range(PACKET_COUNT):
        slots = [(ITEM_A, prices_a[i]), (ITEM_B, prices_b[i])]
        if swap_slots[i]:
            slots.reverse()
        rsp = o.step(REQ_STRUCT.pack(i, slots[0][0], slots[0][1], slots[1][0], slots[1][1]))
        index, item1, act1, item2, act2, reserved = RSP_STRUCT.unpack(rsp)
        got = {item1: act1, item2: act2}
        want_a = ACTION_NONE if expected_a[i] is None else expected_a[i]
        want_b = ACTION_NONE if expected_b[i] is None else expected_b[i]
        ok = (index == i and (item1, item2) == (slots[0][0], slots[1][0]) and reserved == 0
              and got[ITEM_A] == want_a and got[ITEM_B] == want_b)
        if not ok:
            bad += 1
            print(f"MISMATCH index {i}: rsp={rsp.hex()} want A={want_a} B={want_b}")
    scored = PACKET_COUNT - WINDOW_SIZE
    print(f"ORACLE selfcheck: {PACKET_COUNT - bad}/{PACKET_COUNT} packets match expected_a/expected_b "
          f"({scored} scored, {sum(swap_slots)} slot-swapped) -> {'PASS' if bad == 0 else 'FAIL'}")
    return bad


# ---- organizer code copied verbatim below this line ----

WINDOW_SIZE = 16  # indices 0-15 are warm-up

ACTION_NONE = 0x00
ACTION_SELL = 0x01
ACTION_BUY = 0x02


class MovingAverageReference:
    def __init__(self):
        self.window = deque(maxlen=WINDOW_SIZE)
        self.running_sum = 0
        self.last_price = None
        self.action = ACTION_NONE

    def process(self, price):
        # Warm-up: fill the window AND keep the previous price current.
        if len(self.window) < WINDOW_SIZE:
            self.window.append(price)
            self.running_sum += price
            self.last_price = price
            return None

        old_avg = self.running_sum >> 4

        oldest = self.window[0]
        new_sum = self.running_sum - oldest + price
        new_avg = new_sum >> 4

        if self.last_price <= old_avg and price > new_avg:
            self.action = ACTION_BUY
        elif self.last_price >= old_avg and price < new_avg:
            self.action = ACTION_SELL
        # No crossing -> repeat the previous action.

        self.window.append(price)
        self.running_sum = new_sum
        self.last_price = price
        return self.action

# ---- end of verbatim copy ----


if __name__ == "__main__":
    raise SystemExit(1 if _selfcheck() else 0)
