// top -- board top level. Port names are fixed by the organizer .cst (guide §9).
// Wiring only; no logic lives here. docs/ARCHITECTURE.md §1-3. Owner: integ.
module top
    import gqh_pkg::*;
(
    input  logic sys_clk,    // 27 MHz
    input  logic reset_btn,  // unused (DECISIONS D2); must exist for the .cst
    input  logic uart_rx_i,  // BL616 -> FPGA
    output logic uart_tx_o,  // FPGA -> BL616
    output logic led0_n,     // unused: driven 1 (off)
    output logic led1_n      // unused: driven 1 (off)
);
    logic       rst;

    logic [7:0] rx_data;
    logic       rx_valid;

    logic       cmd_valid;
    logic       cmd_ready;
    logic       cmd_clear;
    item_sel_e  cmd_item_sel;
    logic       cmd_eval;
    price_t     cmd_price;
    logic       act_valid;
    action_e    act;

    logic [7:0] tx_data;
    logic       tx_valid;
    logic       tx_ready;

    por_reset u_por_reset (
        .clk (sys_clk),
        .rst (rst)
    );

    uart_rx u_uart_rx (
        .clk      (sys_clk),
        .rst      (rst),
        .rx_i     (uart_rx_i),
        .rx_data  (rx_data),
        .rx_valid (rx_valid)
    );

    pkt_ctrl u_pkt_ctrl (
        .clk          (sys_clk),
        .rst          (rst),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .cmd_valid    (cmd_valid),
        .cmd_ready    (cmd_ready),
        .cmd_clear    (cmd_clear),
        .cmd_item_sel (cmd_item_sel),
        .cmd_eval     (cmd_eval),
        .cmd_price    (cmd_price),
        .act_valid    (act_valid),
        .act          (act),
        .tx_data      (tx_data),
        .tx_valid     (tx_valid),
        .tx_ready     (tx_ready)
    );

    ma_engine u_ma_engine (
        .clk          (sys_clk),
        .rst          (rst),
        .cmd_valid    (cmd_valid),
        .cmd_ready    (cmd_ready),
        .cmd_clear    (cmd_clear),
        .cmd_item_sel (cmd_item_sel),
        .cmd_eval     (cmd_eval),
        .cmd_price    (cmd_price),
        .act_valid    (act_valid),
        .act          (act)
    );

    uart_tx u_uart_tx (
        .clk      (sys_clk),
        .rst      (rst),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .tx_o     (uart_tx_o)
    );

    assign led0_n = 1'b1;
    assign led1_n = 1'b1;

endmodule
