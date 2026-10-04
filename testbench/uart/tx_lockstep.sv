`timescale 1ns / 1ps
// tx_lockstep -- src/uart_tx and uart_tx_ref (the v1 RTL) side by side on the same inputs, with
// a random valid/ready source and random resets, some in the middle of a frame. tx_o and
// tx_ready must match on every clock. Instantiated by tb_uart, which adds `errors` to its own.
module tx_lockstep #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT,
    parameter int unsigned GAP_BITS     = gqh_pkg::TX_GAP_BITS
) (
    input logic clk
);
    localparam int unsigned MAX_PRINT = 5;

    logic        rst      = 1'b1;
    logic [7:0]  tx_data  = '0;
    logic        tx_valid = 1'b0;
    logic        tx_ready, ref_ready;
    logic        tx_o, ref_o;
    int unsigned errors     = 0;
    int unsigned xfers      = 0;   // transfers seen
    int unsigned mid_resets = 0;   // resets that hit a frame or gap in progress
    int unsigned rst_left   = 4;   // cycles of rst still to drive

    uart_tx     #(.CLKS_PER_BIT(CLKS_PER_BIT), .GAP_BITS(GAP_BITS)) u_dut (.*);
    uart_tx_ref #(.CLKS_PER_BIT(CLKS_PER_BIT), .GAP_BITS(GAP_BITS)) u_ref (
        .clk(clk), .rst(rst), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(ref_ready), .tx_o(ref_o));

    always @(posedge clk) begin
        if (tx_o !== ref_o || tx_ready !== ref_ready) begin
            errors++;
            if (errors <= MAX_PRINT)
                $error("MISMATCH lockstep CLKS_PER_BIT=%0d GAP_BITS=%0d: tx_o=%b ref %b, tx_ready=%b ref %b",
                       CLKS_PER_BIT, GAP_BITS, tx_o, ref_o, tx_ready, ref_ready);
        end
        if (!rst && tx_valid && tx_ready) xfers++;

        // Reset: now and then, for 1..3 cycles, at a random point of a frame.
        if (rst_left != 0) begin
            rst_left--;
            rst <= 1'b1;
        end else if ($urandom_range(0, 40 * CLKS_PER_BIT) == 0) begin
            if (!ref_ready) mid_resets++;
            rst_left = $urandom_range(0, 2);
            rst <= 1'b1;
        end else begin
            rst <= 1'b0;
        end

        // Legal valid/ready source: change only when idle or on a transfer; offers back to back,
        // early (while busy) and late.
        if (!tx_valid || tx_ready) begin
            tx_valid <= ($urandom_range(0, 3) != 0);
            tx_data  <= 8'($urandom);
        end
    end
endmodule
