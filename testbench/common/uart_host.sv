`timescale 1ns / 1ps
// uart_host -- the PC side of the serial link, for testbenches: 8N1, LSB first, timed in real
// time at BAUD and not in sys_clk cycles, so it shares no divider with the design. The sender
// can run off-baud, shorten or break the stop bit and inject glitches. The receiver samples
// mid-bit and keeps what it got; a frame whose stop bit is not 1 is counted, not stored.
module uart_host #(
    parameter real BAUD = 115200.0
) (
    output logic txd,  // host -> FPGA, idle high
    input  logic rxd   // FPGA -> host
);
    localparam real BIT_NS = 1.0e9 / BAUD;

    logic [7:0]  rx_bytes [$];           // good frames received, oldest first
    int unsigned rx_frame_errs = 0;      // frames whose stop bit sampled 0 or X
    realtime     rx_last_start = 0;      // time of the last start edge seen
    realtime     tx_first_start = 0;     // time send() last drove a start edge with mark = 1

    initial txd = 1'b1;

    // One frame. scale stretches every bit-time (1.02 = 2 % slow). stop_ok = 0 sends a broken
    // stop bit: low for 3/4 of a bit-time, then idle.
    task automatic send(input logic [7:0] data, input real scale = 1.0, input logic stop_ok = 1'b1,
                        input logic mark = 1'b0);
        if (mark) tx_first_start = $realtime;
        txd = 1'b0;
        #(BIT_NS * scale);
        for (int i = 0; i < 8; i++) begin
            txd = data[i];
            #(BIT_NS * scale);
        end
        if (stop_ok) begin
            txd = 1'b1;
            #(BIT_NS * scale);
        end else begin
            txd = 1'b0;
            #(BIT_NS * scale * 0.75);
            txd = 1'b1;
            #(BIT_NS * scale * 0.25);
        end
    endtask

    // Line idle (high) for a number of bit-times.
    task automatic idle(input real bits);
        txd = 1'b1;
        #(BIT_NS * bits);
    endtask

    // Line low for a fraction of a bit-time, then high: a false start bit.
    task automatic glitch(input real bits);
        txd = 1'b0;
        #(BIT_NS * bits);
        txd = 1'b1;
    endtask

    always begin : receiver
        logic [7:0] data;
        @(negedge rxd);
        rx_last_start = $realtime;
        #(BIT_NS * 1.5);
        for (int i = 0; i < 8; i++) begin
            data[i] = rxd;
            #(BIT_NS);
        end
        if (rxd === 1'b1 && !$isunknown(data)) rx_bytes.push_back(data);
        else                                   rx_frame_errs++;
    end
endmodule
