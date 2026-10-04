`timescale 1ns / 1ps
// tb_por_reset -- rst is 1 for exactly 2**CNT_W - 1 clocks from time 0, then 0 for good, and is
// never X (the counter has no reset of its own; DECISIONS D2, D15).
//   python tools/run.py sim por_reset
module tb_por_reset;
    localparam int unsigned CNT_W      = 4;
    localparam int unsigned RST_CLKS   = (1 << CNT_W) - 1;
    localparam int unsigned AFTER_CLKS = 200;

    logic        clk    = 1'b0;
    logic        rst;
    int unsigned errors = 0;

    always #18.519 clk = ~clk;      // 27 MHz

    por_reset #(.CNT_W(CNT_W)) dut (.*);

    initial begin
        for (int unsigned n = 0; n < RST_CLKS + AFTER_CLKS; n++) begin
            @(posedge clk);            // rst as the rest of the design samples it on edge n
            if (rst !== (n < RST_CLKS)) begin
                errors++;
                $error("MISMATCH clock %0d: rst=%b, want %b", n, rst, n < RST_CLKS);
            end
        end
        if (errors == 0) $display("TEST_RESULT: PASS rst high for %0d clocks", RST_CLKS);
        else             $display("TEST_RESULT: FAIL %0d errors", errors);
        $finish;
    end
endmodule
