`timescale 1ns / 1ps
// tb_pkt_ctrl -- pkt_ctrl alone. The testbench plays uart_rx (B1 strobes), ma_engine (B2, with
// random stalls and random latency) and uart_tx (B3, with random back-pressure).
//   python tools/run.py sim pkt_ctrl --plusargs "+REQUIRE_COVERS"
// Checked per packet: the commands issued (clear iff index 0, then slot 1 and slot 2 with the
// item's select, cmd_eval = index >= WARMUP_END and the slot's price) and the 8 response bytes
// (index, item and action per slot in request order, reserved 0).
// Then: resync after 1..7 stray bytes and a timeout, a request with every byte just inside the
// timeout, and a byte arriving during compute and during transmit (dropped, DECISIONS D4).
// The actions the testbench hands back are stimulus: they are not values of the algorithm.
module tb_pkt_ctrl #(
    parameter int unsigned RX_TIMEOUT_CLKS = 200 // override with -gRX_TIMEOUT_CLKS=1048576
);
    import gqh_pkg::*;

    localparam int unsigned MARGIN_CLKS     = 10;    // distance kept from the timeout on either side
    localparam int unsigned RSP_LIMIT_CLKS  = 2000;  // a response not complete by then is a failure
    localparam int unsigned N_RANDOM        = 200;
    localparam int unsigned MAX_PRINT       = 10;

    typedef struct packed {
        logic      clear;
        item_sel_e sel;
        logic      eval;
        price_t    price;
    } cmd_t;

    typedef enum {STRAY_NONE, STRAY_COMPUTE, STRAY_TX} stray_e;

    logic       clk       = 1'b0;
    logic       rst       = 1'b1;
    logic [7:0] rx_data   = '0;
    logic       rx_valid  = 1'b0;
    logic       cmd_valid;
    logic       cmd_ready = 1'b0;
    logic       cmd_clear;
    item_sel_e  cmd_item_sel;
    logic       cmd_eval;
    price_t     cmd_price;
    logic       act_valid = 1'b0;
    action_e    act       = ACT_NONE;
    logic [7:0] tx_data;
    logic       tx_valid;
    logic       tx_ready  = 1'b0;

    cmd_t        cmd_log [$];   // B2 transfers of the current packet
    action_e     act_log [$];   // actions handed back for it
    logic [7:0]  tx_log  [$];   // B3 transfers of the current packet
    int unsigned errors   = 0;
    int unsigned packets  = 0;
    int unsigned latency_hits [1:20] = '{default: 0};
    int unsigned slots_seen [0:1][0:1] = '{default: '{default: 0}};

    always #18.519 clk = ~clk;      // 27 MHz

    pkt_ctrl #(.RX_TIMEOUT_CLKS(RX_TIMEOUT_CLKS)) dut (.*);
    pkt_timeout_bind u_timeout_bind ();

    // The B2 checker, here because the testbench is the engine. (It is bound only into ma_engine.)
    b2_sva u_b2_sva (.*);

    // B3 from pkt_ctrl's side. (b3_sva also checks the serial line, which this test does not have.)
    int unsigned c_tx_stable_hits = 0;
    a_tx_stable: assert property (@(posedge clk) disable iff (rst)
            tx_valid && !tx_ready |=> tx_valid && $stable(tx_data))
        else $error("a_tx_stable: tx_valid dropped or tx_data changed before the transfer");
    c_tx_stable: cover property (@(posedge clk) !rst && tx_valid && !tx_ready) c_tx_stable_hits++;

    task automatic fail(input string msg);
        errors++;
        if (errors <= MAX_PRINT) $error("MISMATCH packet %0d: %s", packets, msg);
    endtask

    task automatic finish();
        if (errors == 0) $display("TEST_RESULT: PASS %0d packets", packets);
        else             $display("TEST_RESULT: FAIL %0d errors in %0d packets", errors, packets);
        $finish;
    endtask

    // ---- ma_engine side: stall, accept, answer a non-clear command after 1..20 cycles
    initial begin : engine
        action_e a;
        int unsigned latency;
        @(negedge rst);
        forever begin
            repeat ($urandom_range(0, 2)) @(posedge clk);
            cmd_ready <= 1'b1;
            do @(posedge clk); while (cmd_valid !== 1'b1);
            cmd_ready <= 1'b0;
            cmd_log.push_back('{clear: cmd_clear, sel: cmd_item_sel, eval: cmd_eval, price: cmd_price});
            if (!cmd_clear) begin
                latency = $urandom_range(1, 20);
                latency_hits[latency]++;
                // NBA drives the strobe for the next sampling edge: latency is never zero.
                repeat (latency - 1) @(posedge clk);
                a = cmd_eval ? action_e'($urandom_range(0, 2)) : ACT_NONE;  // B2: NONE for a warm-up sample
                act_log.push_back(a);
                act_valid <= 1'b1;
                act       <= a;
                @(posedge clk);
                act_valid <= 1'b0;
                act       <= action_e'('x); // no valid data outside the strobe; prove latching
            end
        end
    end

    // ---- uart_tx side: not ready for 0..4 cycles, then take one byte
    initial begin : tx_sink
        @(negedge rst);
        forever begin
            repeat ($urandom_range(0, 4)) @(posedge clk);
            tx_ready <= 1'b1;
            do @(posedge clk); while (tx_valid !== 1'b1);
            tx_ready <= 1'b0;
            tx_log.push_back(tx_data);
        end
    end

    // ---- uart_rx side
    task automatic rx_byte(input logic [7:0] data, input int unsigned gap);
        repeat (gap) @(posedge clk);
        rx_valid <= 1'b1;
        rx_data  <= data;
        @(posedge clk);
        rx_valid <= 1'b0;
    endtask

    // Sends one request and checks everything pkt_ctrl does with it.
    task automatic run_packet(input req_t req, input int unsigned max_gap, input stray_e stray = STRAY_NONE);
        int unsigned n_cmd = (req.index == '0) ? 3 : 2;
        int unsigned waited = 0;
        cmd_t        want;
        rsp_t        rsp;
        cmd_log.delete();
        act_log.delete();
        tx_log.delete();
        for (int k = 0; k < PKT_BYTES; k++)
            // First byte can transfer immediately after the preceding eighth TX transfer.
            rx_byte(req[$bits(req_t) - 1 - 8 * k -: 8],
                    (k == 0) ? 0 : ((max_gap <= 6) ? $urandom_range(1, max_gap) : max_gap));
        if (stray == STRAY_COMPUTE) rx_byte($urandom, 0);
        if (stray == STRAY_TX) begin
            while (tx_log.size() == 0 && waited < RSP_LIMIT_CLKS) begin
                @(posedge clk);
                waited++;
            end
            rx_byte($urandom, 0);
        end
        while (tx_log.size() < PKT_BYTES && waited < RSP_LIMIT_CLKS) begin
            @(negedge clk); // sample after DUT and sink have processed the transfer
            waited++;
        end
        if (tx_log.size() < PKT_BYTES) begin
            $error("WATCHDOG: %0d of 8 response bytes after %0d clocks", tx_log.size(), RSP_LIMIT_CLKS);
            errors++;
            finish();
        end

        if (cmd_log.size() != n_cmd) begin
            fail($sformatf("index %0d: %0d commands, want %0d", req.index, cmd_log.size(), n_cmd));
        end else begin
            if (req.index == '0 && !cmd_log[0].clear) fail("index 0: first command is not a clear");
            for (int s = 0; s < 2; s++) begin
                want.clear = 1'b0;
                want.sel   = ((s == 0 ? req.item1 : req.item2) == ITEM_B) ? SEL_B : SEL_A;
                want.eval  = (req.index >= WARMUP_END);
                want.price = (s == 0) ? req.price1 : req.price2;
                slots_seen[s][want.sel]++;
                if (cmd_log[n_cmd - 2 + s] !== want)
                    fail($sformatf("index %0d slot %0d: command clear=%b sel=%0d eval=%b price=%h, want clear=0 sel=%0d eval=%b price=%h",
                                   req.index, s + 1, cmd_log[n_cmd - 2 + s].clear, cmd_log[n_cmd - 2 + s].sel,
                                   cmd_log[n_cmd - 2 + s].eval, cmd_log[n_cmd - 2 + s].price, want.sel, want.eval, want.price));
            end
        end
        if (act_log.size() == 2) begin
            rsp = '{index: req.index, item1: req.item1, action1: {6'b0, act_log[0]},
                    item2: req.item2, action2: {6'b0, act_log[1]}, reserved: '0};
            for (int k = 0; k < PKT_BYTES; k++)
                if (tx_log[k] !== rsp[$bits(rsp_t) - 1 - 8 * k -: 8])
                    fail($sformatf("index %0d: response byte %0d is %h, want %h", req.index, k,
                                   tx_log[k], rsp[$bits(rsp_t) - 1 - 8 * k -: 8]));
        end else fail($sformatf("%0d action strobes, want 2", act_log.size()));
        packets++;
    endtask

    function automatic req_t random_req();
        req_t r;
        logic swap = $urandom_range(0, 1);
        case ($urandom_range(0, 7))
            0:       r.index = 16'd0;
            1:       r.index = WARMUP_END - 16'd1;
            2:       r.index = WARMUP_END;
            3:       r.index = WARMUP_END + 16'd1;
            4:       r.index = 16'hFFFF;
            default: r.index = index_t'($urandom);
        endcase
        r.item1  = swap ? ITEM_B : ITEM_A;
        r.item2  = swap ? ITEM_A : ITEM_B;
        r.price1 = price_t'($urandom);
        r.price2 = price_t'($urandom);
        return r;
    endfunction

    // Nothing may come out of pkt_ctrl while it holds less than a request.
    task automatic expect_quiet(input string what);
        if (cmd_log.size() != 0 || tx_log.size() != 0)
            fail($sformatf("%s: %0d commands and %0d response bytes with no complete request",
                           what, cmd_log.size(), tx_log.size()));
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        repeat (N_RANDOM) run_packet(random_req(), 6);

        // Resync: k stray bytes, then silence past the timeout, then a request that must be answered.
        for (int k = 1; k < PKT_BYTES; k++) begin
            cmd_log.delete();
            tx_log.delete();
            repeat (k) rx_byte($urandom, $urandom_range(1, 6));
            repeat (RX_TIMEOUT_CLKS + MARGIN_CLKS) @(posedge clk);
            expect_quiet($sformatf("%0d stray bytes", k));
            run_packet(random_req(), 6);
        end

        // The timeout restarts on every byte: a request with each gap just inside it is answered.
        run_packet(random_req(), RX_TIMEOUT_CLKS - MARGIN_CLKS);
        // A byte sampled on the expiry edge must win over the timeout (D13).
        run_packet(random_req(), RX_TIMEOUT_CLKS - 1);
        run_packet(random_req(), 6);

        // A byte during compute or transmit is dropped; the packets around it are unaffected.
        repeat (10) begin
            run_packet(random_req(), 6, STRAY_COMPUTE);
            run_packet(random_req(), 6);
            run_packet(random_req(), 6, STRAY_TX);
            run_packet(random_req(), 6);
        end

        repeat (4) @(posedge clk);
        if (tx_log.size() != PKT_BYTES) fail("response contains extra bytes");
        for (int delay_cycles = 1; delay_cycles <= 20; delay_cycles++)
            if (latency_hits[delay_cycles] == 0) fail($sformatf("latency %0d never exercised", delay_cycles));
        for (int slot = 0; slot < 2; slot++)
            for (int item = 0; item < 2; item++)
                if (slots_seen[slot][item] == 0) fail("item not exercised in both slots");
        if ($test$plusargs("REQUIRE_COVERS")) begin
            if (u_b2_sva.c_cmd_stable_hits == 0) $error("COVER_ZERO c_cmd_stable");
            if (c_tx_stable_hits == 0)           $error("COVER_ZERO c_tx_stable");
            if (dut.u_pkt_ctrl_sva.c_rx_while_busy_hits == 0) $error("COVER_ZERO c_rx_while_busy");
        end
        finish();
    end
endmodule
