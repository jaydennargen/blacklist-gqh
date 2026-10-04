`timescale 1ns / 1ps
// tb_uart -- uart_tx and uart_rx at the real divisor, against a host that keeps real time.
//   python tools/run.py sim uart --plusargs "+REQUIRE_COVERS"
//   python tools/run.py sim uart --plusargs "+BAUD_ERR_PM=30"     host baud error, per mille (default 20)
// Three paths, each compared byte for byte with what was sent:
//   B3 bytes -> uart_tx -> tx_o -> host receiver (115200 baud, mid-bit sampling)
//                           tx_o -> uart_rx (loopback)
//   host sender -> uart_rx, each frame off-baud by up to +-BAUD_ERR_PM, frames back to back or
//                           with a random idle
// Then on the host -> uart_rx path: a false start bit and a frame with a broken stop bit give no
// strobe (docs/ARCHITECTURE.md §3, B1), and the next good frame is received.
// The idle gap after each frame is checked by b3_sva (a_tx_gap_min), bound into uart_tx.
// Lockstep: uart_tx must match uart_tx_ref (the v1 RTL) on tx_o and tx_ready on every clock,
// here (u_tx) and in tx_lockstep at the real and two small divisors with random resets.
module tb_uart;
    localparam int unsigned N_BYTES    = 64;
    localparam real         TIMEOUT_NS = 100.0e6;  // the whole test takes about 12 ms of simulated time
    localparam int unsigned MAX_PRINT  = 10;

    logic       clk      = 1'b0;
    logic       rst      = 1'b1;
    logic [7:0] tx_data  = '0;
    logic       tx_valid = 1'b0;
    logic       tx_ready;
    logic       tx_o;
    logic       host_txd;
    logic [7:0] loop_data;
    logic       loop_valid;
    logic [7:0] rx_data;
    logic       rx_valid;

    logic [7:0]  tx_sent   [$];   // bytes handed to uart_tx
    logic [7:0]  loop_got  [$];   // strobes of the loopback uart_rx
    logic [7:0]  host_sent [$];   // good frames the host sent
    logic [7:0]  rx_got    [$];   // strobes of the host-driven uart_rx
    int unsigned errors = 0;
    int unsigned baud_err_pm = 20;

    always #18.519 clk = ~clk;      // 27 MHz

    uart_tx   u_tx      (.clk(clk), .rst(rst), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_o(tx_o));
    uart_rx   u_rx_loop (.clk(clk), .rst(rst), .rx_i(tx_o),     .rx_data(loop_data), .rx_valid(loop_valid));
    uart_rx   u_rx_host (.clk(clk), .rst(rst), .rx_i(host_txd), .rx_data(rx_data),   .rx_valid(rx_valid));
    uart_host u_host    (.txd(host_txd), .rxd(tx_o));

    logic ref_ready;
    logic ref_o;
    uart_tx_ref u_tx_ref (.clk(clk), .rst(rst), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(ref_ready), .tx_o(ref_o));
    int unsigned ref_errs = 0;

    always @(posedge clk) begin
        if (tx_o !== ref_o || tx_ready !== ref_ready) begin
            ref_errs++;
            if (ref_errs <= MAX_PRINT)
                $error("MISMATCH lockstep u_tx: tx_o=%b ref %b, tx_ready=%b ref %b", tx_o, ref_o, tx_ready, ref_ready);
        end
    end

    tx_lockstep                                           u_ls_real  (.clk(clk));
    tx_lockstep #(.CLKS_PER_BIT(2), .GAP_BITS(0))         u_ls_min   (.clk(clk));
    tx_lockstep #(.CLKS_PER_BIT(5), .GAP_BITS(3))         u_ls_small (.clk(clk));

    // Lockstep result: every pair matched, and each one saw transfers and a reset mid-frame.
    task automatic check_lockstep();
        errors += ref_errs + u_ls_real.errors + u_ls_min.errors + u_ls_small.errors;
        if (u_ls_real.xfers == 0 || u_ls_min.xfers == 0 || u_ls_small.xfers == 0 ||
            u_ls_real.mid_resets == 0 || u_ls_min.mid_resets == 0 || u_ls_small.mid_resets == 0) begin
            errors++;
            $error("LOCKSTEP vacuous: xfers %0d/%0d/%0d, mid-frame resets %0d/%0d/%0d",
                   u_ls_real.xfers, u_ls_min.xfers, u_ls_small.xfers,
                   u_ls_real.mid_resets, u_ls_min.mid_resets, u_ls_small.mid_resets);
        end
        $display("LOCKSTEP: mismatches %0d; xfers %0d/%0d/%0d, mid-frame resets %0d/%0d/%0d",
                 ref_errs + u_ls_real.errors + u_ls_min.errors + u_ls_small.errors,
                 u_ls_real.xfers, u_ls_min.xfers, u_ls_small.xfers,
                 u_ls_real.mid_resets, u_ls_min.mid_resets, u_ls_small.mid_resets);
    endtask

    always @(posedge clk) begin
        if (loop_valid === 1'b1) loop_got.push_back(loop_data);
        if (rx_valid === 1'b1)   rx_got.push_back(rx_data);
    end

    task automatic finish(input string why);
        if (errors == 0) $display("TEST_RESULT: PASS %0d bytes each way", N_BYTES);
        else             $display("TEST_RESULT: FAIL %s, %0d errors", why, errors);
        $finish;
    endtask

    function automatic void compare(input string path, input logic [7:0] sent [$], input logic [7:0] got [$]);
        if (got.size() != sent.size()) begin
            errors++;
            $error("MISMATCH %s: %0d bytes arrived, %0d sent", path, got.size(), sent.size());
        end
        foreach (sent[i]) if (i < got.size() && got[i] !== sent[i]) begin
            errors++;
            if (errors <= MAX_PRINT) $error("MISMATCH %s: byte %0d is %h, sent %h", path, i, got[i], sent[i]);
        end
    endfunction

    function automatic logic [7:0] pick_byte(input int unsigned i);
        static logic [7:0] corners [6] = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80};
        return (i < 6) ? corners[i] : 8'($urandom);
    endfunction

    // B3 driver: sometimes offers the next byte while uart_tx is still busy, sometimes late.
    task automatic drive_tx();
        for (int unsigned i = 0; i < N_BYTES; i++) begin
            if ($urandom_range(0, 1)) repeat ($urandom_range(0, 6000)) @(posedge clk);
            tx_valid <= 1'b1;
            tx_data  <= pick_byte(i);
            do @(posedge clk); while (tx_ready !== 1'b1);
            tx_sent.push_back(tx_data);
            tx_valid <= 1'b0;
        end
        do @(posedge clk); while (tx_ready !== 1'b1);   // last frame and its gap are over
    endtask

    // Host sender: every frame at its own baud error.
    task automatic drive_host();
        logic [7:0] b;
        real        scale;
        for (int unsigned i = 0; i < N_BYTES; i++) begin
            b     = pick_byte(i);
            scale = 1.0 + (real'($urandom_range(0, 2 * baud_err_pm)) - real'(baud_err_pm)) / 1000.0;
            if ($urandom_range(0, 9) >= 4) u_host.idle(real'($urandom_range(1, 3000)) / 1000.0);
            u_host.send(b, scale);
            host_sent.push_back(b);
        end
        // False start bit: low for a quarter of a bit-time.
        u_host.idle(2.0);
        u_host.glitch(0.25);
        u_host.idle(12.0);
        // Broken stop bit: no strobe for this frame.
        u_host.send(8'h3C, 1.0, 1'b0);
        u_host.idle(12.0);
        // The receiver is still usable.
        u_host.send(8'hA5);
        host_sent.push_back(8'hA5);
        u_host.idle(2.0);
    endtask

    initial begin
        #(TIMEOUT_NS);
        $error("WATCHDOG: test not finished after %0d ms (tx bytes accepted: %0d)", TIMEOUT_NS / 1.0e6, tx_sent.size());
        errors++;
        finish("timeout");
    end

    initial begin
        void'($value$plusargs("BAUD_ERR_PM=%d", baud_err_pm));
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        fork
            drive_tx();
            drive_host();
        join
        repeat (8) @(posedge clk);
        compare("uart_tx -> host", tx_sent, u_host.rx_bytes);
        compare("uart_tx -> uart_rx", tx_sent, loop_got);
        compare("host -> uart_rx", host_sent, rx_got);
        if (u_host.rx_frame_errs != 0) begin
            errors++;
            $error("MISMATCH uart_tx -> host: %0d frames with a bad stop bit", u_host.rx_frame_errs);
        end
        check_lockstep();
        finish("bytes differ");
    end
endmodule
