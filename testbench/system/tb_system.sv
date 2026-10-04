`timescale 1ns / 1ps
// tb_system -- top at its pins, driven the way the judge drives the board: one 8-byte request,
// wait for the 8-byte response, next request. Every response is compared with the oracle's.
//   python tools/gen_vectors.py --profile all --seeds 2          (once; vectors are gitignored)
//   python tools/run.py sim system --plusargs "+REQUIRE_COVERS"                  all four profiles
//   python tools/run.py sim system --plusargs "+VEC=vectors/judge_s2.hex"        one file
// Other plusargs: +NPKT=<n> stop after n packets; +BAUD_ERR_PM=<n> host baud error per packet,
// per mille (default 10); +NO_STRAY skips the stray-byte opening.
// Opening (DECISIONS D13): one stray byte, 100 ms of silence, then the run. The partial-packet
// timeout must have discarded the stray byte or every later packet is misaligned.
// The seed moves only timing: baud error, idle between request bytes, idle between packets.
module tb_system;
    import gqh_pkg::*;
    import tb_vec_pkg::*;

    localparam real         CLK_NS       = 1.0e9 / CLK_HZ;
    localparam real         STRAY_NS     = 100.0e6;  // silence after the stray byte
    localparam real         RSP_LIMIT_NS = 50.0e6;   // the judge allows 1 s; a healthy response takes about 2 ms
    localparam int unsigned MAX_PRINT    = 10;

    logic sys_clk   = 1'b0;
    logic reset_btn = 1'b0;
    logic uart_rx_i;
    logic uart_tx_o;
    logic led0_n;
    logic led1_n;

    vec_t        vecs [$];
    req_t        req       = '0;
    rsp_t        exp       = '0;   // from the vector file
    rsp_t        got       = '0;   // from the wire
    logic        pkt_valid = 1'b0;
    int unsigned mismatches  = 0;
    int unsigned packets     = 0;
    int unsigned npkt        = 0;
    int unsigned baud_err_pm = 10;
    real         lat_sum_ns  = 0.0;
    real         lat_max_ns  = 0.0;

    always #(CLK_NS / 2.0) sys_clk = ~sys_clk;

    top       dut (.*);
    uart_host u_host (.txd(uart_rx_i), .rxd(uart_tx_o));
    func_cov  u_func_cov (.clk(sys_clk), .pkt_valid(pkt_valid), .req(req), .rsp(got));

    task automatic finish(input string why);
        if (mismatches == 0 && packets != 0)
            $display("TEST_RESULT: PASS %0d packets, wire latency avg %.3f ms max %.3f ms (first request edge to end of last response byte, GAP_BITS=%0d)",
                     packets, lat_sum_ns / packets / 1.0e6, lat_max_ns / 1.0e6, TX_GAP_BITS);
        else
            $display("TEST_RESULT: FAIL %s, %0d mismatches in %0d packets", why, mismatches, packets);
        $finish;
    endtask

    // One request out, one response back. Ends the test if the response does not arrive.
    task automatic exchange(input int unsigned n);
        real     scale = 1.0 + (real'($urandom_range(0, 2 * baud_err_pm)) - real'(baud_err_pm)) / 1000.0;
        realtime t_limit;
        real     lat_ns;
        u_host.rx_bytes.delete();
        for (int k = 0; k < PKT_BYTES; k++) begin
            if (k != 0 && $urandom_range(0, 3) == 0) u_host.idle(real'($urandom_range(1, 2000)) / 1000.0);
            u_host.send(req[$bits(req_t) - 1 - 8 * k -: 8], scale, 1'b1, k == 0);
        end
        t_limit = $realtime + RSP_LIMIT_NS;
        while (u_host.rx_bytes.size() < PKT_BYTES && $realtime < t_limit) @(posedge sys_clk);
        if (u_host.rx_bytes.size() < PKT_BYTES) begin
            mismatches++;
            $error("TIMEOUT vector %0d index %0d: %0d of 8 response bytes after %0d ms (frame errors %0d)",
                   n, req.index, u_host.rx_bytes.size(), RSP_LIMIT_NS / 1.0e6, u_host.rx_frame_errs);
            finish("response timeout");
        end
        // The 8th byte is stored at the middle of its stop bit; the frame ends half a bit later.
        lat_ns      = $realtime - u_host.tx_first_start + 0.5e9 / BAUD;
        lat_sum_ns += lat_ns;
        if (lat_ns > lat_max_ns) lat_max_ns = lat_ns;
        for (int k = 0; k < PKT_BYTES; k++) got[$bits(rsp_t) - 1 - 8 * k -: 8] = u_host.rx_bytes[k];
        if (got !== exp) begin
            mismatches++;
            if (mismatches <= MAX_PRINT)
                $error("MISMATCH vector %0d index %0d request %h: response %h, oracle %h", n, req.index, req, got, exp);
        end
        packets++;
        pkt_valid <= 1'b1;
        @(posedge sys_clk);
        pkt_valid <= 1'b0;
    endtask

    initial begin
        void'($value$plusargs("NPKT=%d", npkt));
        void'($value$plusargs("BAUD_ERR_PM=%d", baud_err_pm));
        load_all(vecs);
        repeat (100) @(posedge sys_clk);   // past the power-on reset
        if (!$test$plusargs("NO_STRAY")) begin
            u_host.send(8'h5A);
            #(STRAY_NS);
        end
        foreach (vecs[n]) begin
            if (npkt != 0 && n >= npkt) break;
            {req, exp} = vecs[n];
            exchange(n);
            // The next request may start right after the response, inside uart_tx's trailing gap.
            if ($urandom_range(0, 1)) u_host.idle(real'($urandom_range(1, 5000)) / 1000.0);
        end
        if (u_host.rx_frame_errs != 0) begin
            mismatches++;
            $error("MISMATCH %0d response frames with a bad stop bit", u_host.rx_frame_errs);
        end
        repeat (8) @(posedge sys_clk);
        finish(vecs.size() == 0 ? "no vectors" : "responses differ from the oracle");
    end
endmodule
