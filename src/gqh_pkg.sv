// gqh_pkg -- every constant and type shared between modules. docs/ARCHITECTURE.md §2.
// Protocol values are from the participant guide §10.1; do not restate them anywhere else.
package gqh_pkg;

    // ---- clock / UART (guide §9, §10.1.1)
    localparam int unsigned CLK_HZ       = 27_000_000;
    localparam int unsigned BAUD         = 115_200;
    localparam int unsigned CLKS_PER_BIT = 234;          // 27e6 / 115200 = 234.375, rounded. DECISIONS D3.

    // ---- tunables that need board evidence
    localparam int unsigned TX_GAP_BITS     = 4;         // idle bit-times after each stop bit. DECISIONS D18.
    localparam int unsigned RX_TIMEOUT_CLKS = 1 << 20;   // 38.8 ms partial-packet discard; must beat the judge's 200 ms. DECISIONS D13.

    // ---- packet format (guide §10.1.2 - §10.1.5)
    localparam int unsigned PKT_BYTES = 8;

    typedef logic [15:0] index_t;
    typedef logic [15:0] price_t;
    typedef logic [7:0]  item_id_t;

    localparam item_id_t ITEM_A = 8'h11;
    localparam item_id_t ITEM_B = 8'h22;

    typedef enum logic [1:0] {
        ACT_NONE = 2'd0,
        ACT_SELL = 2'd1,
        ACT_BUY  = 2'd2
    } action_e;

    // First byte on the wire is the most significant byte of each struct.
    typedef struct packed {
        index_t   index;
        item_id_t item1;
        price_t   price1;
        item_id_t item2;
        price_t   price2;
    } req_t;

    typedef struct packed {
        index_t      index;
        item_id_t    item1;
        logic [7:0]  action1;
        item_id_t    item2;
        logic [7:0]  action2;
        logic [15:0] reserved;                           // always 16'h0000
    } rsp_t;

    // ---- algorithm (guide §10.3)
    localparam int unsigned WINDOW_LEN = 16;
    localparam int unsigned AVG_SHIFT  = 4;              // average = sum >> 4 (floor)
    localparam int unsigned SUM_W      = 20;             // 16 * 0xFFFF < 2**20
    localparam index_t      WARMUP_END = 16'd16;         // index < WARMUP_END is warm-up. DECISIONS D12.

    typedef logic [SUM_W-1:0] sum_t;

    // Item slot inside ma_engine: which of the two per-item state sets a command addresses.
    typedef enum logic {
        SEL_A = 1'b0,
        SEL_B = 1'b1
    } item_sel_e;

endpackage
