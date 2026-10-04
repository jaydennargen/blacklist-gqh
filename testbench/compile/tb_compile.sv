`timescale 1ns / 1ps
// tb_compile -- proves src/ compiles and elaborates as one design and that the pins idle at
// the right level. Not a functional test: the modules are stubs.
module tb_compile;
    logic sys_clk   = 1'b0;
    logic reset_btn = 1'b0;
    logic uart_rx_i = 1'b1;
    logic uart_tx_o;
    logic led0_n;
    logic led1_n;

    always #18.519 sys_clk = ~sys_clk;      // 27 MHz

    top dut (.*);

    initial begin
        repeat (32) @(posedge sys_clk);
        if (uart_tx_o === 1'b1 && led0_n === 1'b1 && led1_n === 1'b1)
            $display("TEST_RESULT: PASS");
        else
            $display("TEST_RESULT: FAIL uart_tx_o=%b led0_n=%b led1_n=%b", uart_tx_o, led0_n, led1_n);
        $finish;
    end
endmodule
