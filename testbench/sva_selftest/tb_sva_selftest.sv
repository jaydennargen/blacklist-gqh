`timescale 1ns / 1ps
// tb_sva_selftest -- tests the checkers in testbench/common/, not the RTL. It drives the checker
// ports directly with contract-legal traffic for two packets (index 0 and index 16) and must
// pass with every required cover hit:
//   python tools/run.py sim sva_selftest --seed 1 --plusargs "+REQUIRE_COVERS"
// +BREAK=<n> injects one contract violation; that run must FAIL:
//   1 act_valid after a clear   2 reserved byte != 0   3 TX gap too short   4 no clear on index 0
//   5 cmd_price changes while stalled   6 item B state moves on an item A command
//   7 non-NONE action for a warm-up command
// Actions and prices here are stimulus for the checkers, not expected values of the algorithm.
module tb_sva_selftest;
    import gqh_pkg::*;

    localparam int unsigned CLKS_PER_BIT    = 4;
    localparam int unsigned GAP_BITS        = 2;
    localparam int unsigned RX_TIMEOUT_CLKS = 64;
    localparam int unsigned STATE_W         = 8;

    logic               clk          = 1'b0;
    logic               rst          = 1'b1;
    logic [7:0]         rx_data      = '0;
    logic               rx_valid     = 1'b0;
    logic               cmd_valid    = 1'b0;
    logic               cmd_ready    = 1'b0;
    logic               cmd_clear    = 1'b0;
    item_sel_e          cmd_item_sel = SEL_A;
    logic               cmd_eval     = 1'b0;
    price_t             cmd_price    = '0;
    logic               act_valid    = 1'b0;
    action_e            act          = ACT_NONE;
    logic [7:0]         tx_data      = '0;
    logic               tx_valid     = 1'b0;
    logic               tx_ready     = 1'b0;
    logic               tx_o         = 1'b1;
    logic [STATE_W-1:0] state_a      = '0;
    logic [STATE_W-1:0] state_b      = '0;
    int unsigned        break_id     = 0;

    always #5 clk = ~clk;

    b1_sva                                                             u_b1    (.*);
    b2_sva                                                             u_b2    (.*);
    b3_sva #(.CLKS_PER_BIT(CLKS_PER_BIT), .GAP_BITS(GAP_BITS))         u_b3    (.*);
    pkt_ctrl_sva #(.RX_TIMEOUT_CLKS(RX_TIMEOUT_CLKS))                  u_pkt   (.*);
    ma_engine_state_sva #(.STATE_W(STATE_W))                           u_state (.*);

    function automatic item_sel_e sel_of(input item_id_t id);
        return (id == ITEM_A) ? SEL_A : SEL_B;
    endfunction

    // One B1 strobe. The 8th byte of a request is followed by the command with no idle cycle.
    task automatic send_rx(input logic [7:0] b, input bit last);
        rx_valid <= 1'b1;
        rx_data  <= b;
        @(posedge clk);
        rx_valid <= 1'b0;
        if (!last) @(posedge clk);
    endtask

    // One B2 command: one stalled cycle, the transfer, then act_valid a cycle later (not for a clear).
    task automatic do_cmd(input logic clear, input item_sel_e sel, input logic ev,
                          input price_t price, input action_e a);
        cmd_valid    <= 1'b1;
        cmd_ready    <= 1'b0;
        cmd_clear    <= clear;
        cmd_item_sel <= sel;
        cmd_eval     <= ev;
        cmd_price    <= price;
        @(posedge clk);
        if (break_id == 5) cmd_price <= price ^ 16'h0001;
        cmd_ready <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;
        cmd_ready <= 1'b0;
        if (!clear || break_id == 1) begin
            if (!clear) begin
                if (sel == SEL_A) state_a <= state_a + 1'b1;
                else              state_b <= state_b + 1'b1;
                if (break_id == 6 && sel == SEL_A) state_b <= state_b + 1'b1;
            end
            act_valid <= 1'b1;
            act       <= a;
            @(posedge clk);
            act_valid <= 1'b0;
        end
    endtask

    // One B3 byte: one stalled cycle, the transfer, then the frame and its gap on tx_o.
    task automatic send_tx(input logic [7:0] b, input bit rx_during);
        tx_valid <= 1'b1;
        tx_ready <= 1'b0;
        tx_data  <= b;
        @(posedge clk);
        tx_ready <= 1'b1;
        @(posedge clk);
        tx_valid <= 1'b0;
        tx_ready <= 1'b0;
        tx_o     <= 1'b0;
        repeat (CLKS_PER_BIT) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            tx_o <= b[i];
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
        tx_o <= 1'b1;
        if (rx_during) begin                 // a byte while busy: must be ignored, not counted
            rx_valid <= 1'b1;
            rx_data  <= 8'hEE;
        end
        @(posedge clk);
        rx_valid <= 1'b0;
        repeat (CLKS_PER_BIT * (1 + ((break_id == 3) ? 0 : GAP_BITS)) - 1) @(posedge clk);
    endtask

    task automatic packet(input index_t idx, input item_id_t i1, input item_id_t i2,
                          input action_e a1, input action_e a2);
        req_t req;
        rsp_t rsp;
        logic ev;
        req = '{index: idx, item1: i1, price1: 16'h1234, item2: i2, price2: 16'h00FF};
        rsp = '{index: idx, item1: i1, action1: {6'b0, a1}, item2: i2, action2: {6'b0, a2},
                reserved: (break_id == 2) ? 16'h0001 : 16'h0000};
        ev  = (idx >= WARMUP_END);
        for (int k = 0; k < PKT_BYTES; k++) send_rx(req[$bits(req_t)-1-8*k -: 8], k == PKT_BYTES - 1);
        if (idx == '0 && break_id != 4) do_cmd(1'b1, SEL_A, 1'b0, '0, ACT_NONE);
        do_cmd(1'b0, sel_of(i1), ev, req.price1, a1);
        do_cmd(1'b0, sel_of(i2), ev, req.price2, a2);
        for (int k = 0; k < PKT_BYTES; k++) send_tx(rsp[$bits(rsp_t)-1-8*k -: 8], k == 0);
    endtask

    initial begin
        void'($value$plusargs("BREAK=%d", break_id));
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        packet(16'd0, ITEM_A, ITEM_B, (break_id == 7) ? ACT_BUY : ACT_NONE, ACT_NONE);
        // A stray byte, then silence past the partial-packet timeout: the next packet still aligns.
        send_rx(8'hEE, 1'b0);
        repeat (RX_TIMEOUT_CLKS + 8) @(posedge clk);
        packet(WARMUP_END, ITEM_B, ITEM_A, ACT_BUY, ACT_SELL);
        repeat (4) @(posedge clk);
        $display("TEST_RESULT: PASS");
        $finish;
    end
endmodule
