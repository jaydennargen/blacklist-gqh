// MODEL of pkt_ctrl -- simulation only, never synthesized, NOT the RTL. It exists so the
// testbenches can be shown to pass on a design that follows docs/ARCHITECTURE.md §3, §5 and to
// fail on a broken one:  python tools/run.py sim pkt_ctrl --models [--plusargs "+MUT=<n>"]
// +MUT (docs/VERIFICATION.md mutation set, then extras):
//   5 route by slot, not by item ID   8 reserved bytes != 0   11 no clear on index 0
//   12 no partial-packet timeout      16 action1 / action2 swapped in the response
//   19 warm-up ends one index late    20 a byte during compute or transmit is not dropped
// Same ports as src/pkt_ctrl.sv.
module pkt_ctrl
    import gqh_pkg::*;
#(
    parameter int unsigned RX_TIMEOUT_CLKS = gqh_pkg::RX_TIMEOUT_CLKS  // 0 disables the timeout
) (
    input  logic       clk,
    input  logic       rst,           // synchronous, active-high
    // B1: bytes from uart_rx
    input  logic [7:0] rx_data,
    input  logic       rx_valid,      // 1-cycle strobe; taken only while collecting a request
    // B2: command to ma_engine (valid/ready) and its result
    output logic       cmd_valid,     // held, with stable cmd_* fields, until cmd_ready
    input  logic       cmd_ready,
    output logic       cmd_clear,     // 1: clear all state of both items; other cmd_* fields ignored
    output item_sel_e  cmd_item_sel,  // which item's state this sample belongs to
    output logic       cmd_eval,      // 1: update + crossing; 0: warm-up sample, action NONE
    output price_t     cmd_price,
    input  logic       act_valid,     // 1-cycle strobe, one per accepted non-clear command
    input  action_e    act,           // valid on the act_valid cycle only
    // B3: bytes to uart_tx (valid/ready)
    output logic [7:0] tx_data,       // stable while tx_valid = 1
    output logic       tx_valid,      // held until tx_ready
    input  logic       tx_ready
);
    typedef enum logic [2:0] {S_RX, S_CLEAR, S_CMD1, S_ACT1, S_CMD2, S_ACT2, S_TX} state_e;

    int unsigned mut = 0;
    initial void'($value$plusargs("MUT=%d", mut));

    state_e      state_q;
    req_t        req_q;
    int unsigned cnt_q;        // bytes collected (S_RX) or sent (S_TX)
    int unsigned idle_q;       // clocks since the last byte of a partial request
    action_e     act1_q;
    action_e     act2_q;
    req_t        req_d;        // req_q with this cycle's byte shifted in
    rsp_t        rsp;
    logic        slot2;
    item_id_t    item;

    always_comb begin
        req_d        = {req_q[$bits(req_t)-9:0], rx_data};
        slot2        = (state_q == S_CMD2);
        item         = slot2 ? req_q.item2 : req_q.item1;
        cmd_valid    = (state_q == S_CLEAR) || (state_q == S_CMD1) || (state_q == S_CMD2);
        cmd_clear    = (state_q == S_CLEAR);
        cmd_item_sel = (item == ITEM_B) ? SEL_B : SEL_A;
        if (mut == 5) cmd_item_sel = slot2 ? SEL_B : SEL_A;
        cmd_eval     = (req_q.index >= WARMUP_END + ((mut == 19) ? 16'd1 : 16'd0));
        cmd_price    = slot2 ? req_q.price2 : req_q.price1;
        rsp          = '{index: req_q.index, item1: req_q.item1, action1: {6'b0, act1_q},
                         item2: req_q.item2, action2: {6'b0, act2_q}, reserved: (mut == 8) ? 16'h0001 : 16'h0000};
        if (mut == 16) begin
            rsp.action1 = {6'b0, act2_q};
            rsp.action2 = {6'b0, act1_q};
        end
        tx_valid     = (state_q == S_TX);
        tx_data      = rsp[$bits(rsp_t) - 1 - 8 * cnt_q -: 8];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_RX;
            cnt_q   <= 0;
            idle_q  <= 0;
        end else begin
            if (rx_valid && mut == 20 && state_q != S_RX) req_q <= req_d;
            case (state_q)
                S_RX: begin
                    idle_q <= idle_q + 1;
                    if (rx_valid) begin
                        req_q  <= req_d;
                        idle_q <= 0;
                        cnt_q  <= cnt_q + 1;
                        if (cnt_q == PKT_BYTES - 1) begin
                            cnt_q   <= 0;
                            state_q <= (req_d.index == '0 && mut != 11) ? S_CLEAR : S_CMD1;
                        end
                    end else if (RX_TIMEOUT_CLKS != 0 && mut != 12 && idle_q == RX_TIMEOUT_CLKS - 1) begin
                        cnt_q <= 0;
                    end
                end
                S_CLEAR: if (cmd_ready) state_q <= S_CMD1;
                S_CMD1:  if (cmd_ready) state_q <= S_ACT1;
                S_ACT1:  if (act_valid) begin
                    act1_q  <= act;
                    state_q <= S_CMD2;
                end
                S_CMD2:  if (cmd_ready) state_q <= S_ACT2;
                S_ACT2:  if (act_valid) begin
                    act2_q  <= act;
                    state_q <= S_TX;
                end
                default: if (tx_ready) begin   // S_TX
                    cnt_q <= cnt_q + 1;
                    if (cnt_q == PKT_BYTES - 1) begin
                        cnt_q   <= 0;
                        idle_q  <= 0;
                        state_q <= S_RX;
                    end
                end
            endcase
        end
    end
endmodule
