module top #(parameter int STYLE = 0) (
    input  logic sys_clk,
    input  logic reset_btn,
    input  logic uart_rx_i,
    output logic uart_tx_o,
    output logic led0_n,
    output logic led1_n
);
    logic [19:0] sh_q;
    always_ff @(posedge sys_clk) sh_q <= {sh_q[18:0], uart_rx_i};
    logic [1:0] act;
    eng #(.STYLE(STYLE)) u_eng (.clk(sys_clk), .rst(reset_btn), .cmd_valid(sh_q[19]), .cmd_clear(sh_q[18]),
        .cmd_item(sh_q[17]), .cmd_eval(sh_q[16]), .cmd_price(sh_q[15:0]), .act_valid(led1_n), .act(act));
    assign uart_tx_o = act[0];
    assign led0_n    = act[1];
endmodule
