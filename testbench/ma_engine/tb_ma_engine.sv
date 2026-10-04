`timescale 1ns / 1ps
// tb_ma_engine -- replays vectors/*.hex at B2 and compares every action with the oracle's.
//   python tools/gen_vectors.py --profile all --seeds 2          (once; vectors are gitignored)
//   python tools/run.py sim ma_engine --plusargs "+REQUIRE_COVERS"
//   python tools/run.py sim ma_engine --plusargs "+VEC=vectors/cross_s2.hex"     one file
// Each vector becomes what pkt_ctrl would send (docs/ARCHITECTURE.md §5): a clear on index 0,
// then slot 1 and slot 2 with cmd_eval = (index >= WARMUP_END). The seed only moves the idle
// cycles between commands; it never changes an expected value.
module tb_ma_engine;
    import gqh_pkg::*;
    import tb_vec_pkg::*;

    localparam int unsigned MAX_IDLE      = 3;     // idle cycles before a command, 0..MAX_IDLE
    localparam int unsigned WATCHDOG_CLKS = 1000;  // no B2 progress for this long ends the test
    localparam int unsigned MAX_PRINT     = 10;    // mismatches printed in full

    logic      clk          = 1'b0;
    logic      rst          = 1'b1;
    logic      cmd_valid    = 1'b0;
    logic      cmd_ready;
    logic      cmd_clear    = 1'b0;
    item_sel_e cmd_item_sel = SEL_A;
    logic      cmd_eval     = 1'b0;
    price_t    cmd_price    = '0;
    logic      act_valid;
    action_e   act;

    vec_t        vecs [$];
    req_t        req       = '0;
    rsp_t        exp       = '0;    // from the vector file
    rsp_t        got       = '0;    // exp with the two actions replaced by what the engine returned
    logic        pkt_valid = 1'b0;
    int unsigned mismatches = 0;
    int unsigned idle_clks  = 0;

    always #18.519 clk = ~clk;      // 27 MHz

    ma_engine dut (.*);
    func_cov  u_func_cov (.clk(clk), .pkt_valid(pkt_valid), .req(req), .rsp(got));

    task automatic finish(input logic ok, input string why);
        if (ok) $display("TEST_RESULT: PASS %0d packets", vecs.size());
        else    $display("TEST_RESULT: FAIL %s, %0d mismatches", why, mismatches);
        $finish;
    endtask

    // One B2 command: offer it after a random idle, hold it until the transfer.
    task automatic send_cmd(input logic clear, input item_sel_e sel, input logic eval, input price_t price);
        repeat ($urandom_range(0, MAX_IDLE)) @(posedge clk);
        cmd_valid    <= 1'b1;
        cmd_clear    <= clear;
        cmd_item_sel <= sel;
        cmd_eval     <= eval;
        cmd_price    <= price;
        do @(posedge clk); while (cmd_ready !== 1'b1);
        cmd_valid    <= 1'b0;
    endtask

    // One slot of a request: command, then wait for its act_valid.
    task automatic run_slot(input item_id_t item, input price_t price, output logic [7:0] action);
        send_cmd(1'b0, (item == ITEM_B) ? SEL_B : SEL_A, req.index >= WARMUP_END, price);
        do @(posedge clk); while (act_valid !== 1'b1);
        action = {6'b0, act};
    endtask

    task automatic compare(input int unsigned n, input int unsigned slot_no, input item_id_t item,
                           input price_t price, input logic [7:0] got_act, input logic [7:0] exp_act);
        if (got_act !== exp_act) begin
            mismatches++;
            if (mismatches <= MAX_PRINT)
                $error("MISMATCH vector %0d index %0d slot %0d item %h price %h: act %0d, oracle %0d",
                       n, req.index, slot_no, item, price, got_act, exp_act);
        end
    endtask

    always @(posedge clk) begin
        if ((cmd_valid && cmd_ready === 1'b1) || act_valid === 1'b1) idle_clks <= 0;
        else                                                       idle_clks <= idle_clks + 1;
        if (idle_clks == WATCHDOG_CLKS) begin
            $error("WATCHDOG: no B2 transfer or act_valid for %0d clocks", WATCHDOG_CLKS);
            finish(1'b0, "engine stopped responding");
        end
    end

    initial begin
        logic [7:0] action1;
        logic [7:0] action2;
        load_all(vecs);
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        foreach (vecs[n]) begin
            {req, exp} = vecs[n];
            if (req.index == '0) send_cmd(1'b1, SEL_A, 1'b0, '0);
            run_slot(req.item1, req.price1, action1);
            run_slot(req.item2, req.price2, action2);
            compare(n, 1, req.item1, req.price1, action1, exp.action1);
            compare(n, 2, req.item2, req.price2, action2, exp.action2);
            got         = exp;
            got.action1 = action1;
            got.action2 = action2;
            pkt_valid <= 1'b1;
            @(posedge clk);
            pkt_valid <= 1'b0;
        end
        repeat (4) @(posedge clk);
        finish(mismatches == 0 && vecs.size() != 0, vecs.size() == 0 ? "no vectors" : "actions differ from the oracle");
    end
endmodule
