// MODEL of por_reset -- simulation only, never synthesized, NOT the RTL. It gives the other
// models a reset so testbench/system can be shown to pass before the RTL exists.
// Same ports as src/por_reset.sv.
module por_reset #(
    parameter int unsigned CNT_W = 4
) (
    input  logic clk,
    output logic rst   // synchronous, active-high
);
    logic [CNT_W-1:0] cnt_q = '0;

    assign rst = (cnt_q != '1);

    // always, not always_ff: Questa counts the declaration initializer as a second driver (vlog-7061).
    always @(posedge clk) if (rst) cnt_q <= cnt_q + 1'b1;
endmodule
