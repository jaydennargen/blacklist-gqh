// por_reset -- the design's only reset source: holds rst high for 2**CNT_W - 1 clocks after
// configuration, then low forever. Contract: docs/ARCHITECTURE.md §3. Owner: integ.
module por_reset #(
    parameter int unsigned CNT_W = 4
) (
    input  logic clk,
    output logic rst   // synchronous, active-high
);
    // The one register in the design with an init value (DECISIONS D2): there is nothing to
    // reset it from. It counts up from 0 and stops at all-ones.
    logic [CNT_W-1:0] cnt_q = '0;

    assign rst = (cnt_q != '1);

    // always, not always_ff: with -lint Questa counts the declaration initializer as a second
    // driver of an always_ff variable (vlog-7061). DECISIONS D15.
    always @(posedge clk) begin
        if (rst) cnt_q <= cnt_q + 1'b1;
    end
endmodule
