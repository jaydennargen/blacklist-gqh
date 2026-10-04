// MODEL of ma_engine -- simulation only, never synthesized, NOT the RTL and not a source of
// expected values. It exists so testbench/ma_engine and testbench/system can be shown to pass on
// a design that follows docs/ARCHITECTURE.md §3 (B2) and §4, and to fail on a broken one:
//   python tools/run.py sim ma_engine --models [--plusargs "+MUT=<n>"]
// +MUT (docs/VERIFICATION.md mutation set):
//   1 BUY: prev <= old_avg -> <      2 BUY: price > new_avg -> >=    3 old_avg / new_avg swapped
//   4 round instead of floor         6 clear command ignored          7 warm-up sample evaluated
//   9 SELL: prev >= old_avg -> >     10 SELL: price < new_avg -> <=
// Same ports and state register names as src/ma_engine.sv (b2_bind reads the state by name). Not ready on the act_valid cycle, so a command can stall.
module ma_engine
    import gqh_pkg::*;
(
    input  logic      clk,
    input  logic      rst,           // synchronous, active-high
    input  logic      cmd_valid,
    output logic      cmd_ready,     // 0 in reset and while a command is executing
    input  logic      cmd_clear,     // 1: clear all state of both items; no act_valid follows
    input  item_sel_e cmd_item_sel,  // sampled on the transfer
    input  logic      cmd_eval,      // 1: update + crossing; 0: warm-up sample, action NONE
    input  price_t    cmd_price,
    output logic      act_valid,     // 1-cycle strobe, >= 1 cycle after the transfer
    output action_e   act            // valid on the act_valid cycle only
);
    localparam int unsigned N_ITEMS = 2;

    int unsigned mut = 0;
    initial void'($value$plusargs("MUT=%d", mut));

    price_t  window_q  [N_ITEMS][WINDOW_LEN];  // stage 0 = newest
    sum_t    sum_q  [N_ITEMS];
    price_t  prev_price_q [N_ITEMS];
    action_e last_action_q [N_ITEMS];

    logic    eval;
    sum_t    avg_bias;
    sum_t    new_sum;
    price_t  old_avg;
    price_t  new_avg;
    price_t  lo_avg;    // the average compared with prev
    price_t  hi_avg;    // the average compared with price
    logic    buy;
    logic    sell;
    action_e act_d;

    assign cmd_ready = !rst && !act_valid;

    always_comb begin
        eval     = cmd_eval || (mut == 7);
        avg_bias = (mut == 4) ? sum_t'(1 << (AVG_SHIFT - 1)) : '0;
        new_sum  = sum_q[cmd_item_sel] + sum_t'(cmd_price);
        if (eval) new_sum = new_sum - sum_t'(window_q[cmd_item_sel][WINDOW_LEN-1]);
        old_avg  = price_t'((sum_q[cmd_item_sel] + avg_bias) >> AVG_SHIFT);
        new_avg  = price_t'((new_sum + avg_bias) >> AVG_SHIFT);
        lo_avg   = (mut == 3) ? new_avg : old_avg;
        hi_avg   = (mut == 3) ? old_avg : new_avg;
        buy      = ((mut == 1)  ? prev_price_q[cmd_item_sel] <  lo_avg : prev_price_q[cmd_item_sel] <= lo_avg)
                && ((mut == 2)  ? cmd_price >= hi_avg : cmd_price >  hi_avg);
        sell     = ((mut == 9)  ? prev_price_q[cmd_item_sel] >  lo_avg : prev_price_q[cmd_item_sel] >= lo_avg)
                && ((mut == 10) ? cmd_price <= hi_avg : cmd_price <  hi_avg);
        act_d    = last_action_q[cmd_item_sel];
        if (!eval)     act_d = ACT_NONE;
        else if (buy)  act_d = ACT_BUY;
        else if (sell) act_d = ACT_SELL;
    end

    always_ff @(posedge clk) begin
        act_valid <= 1'b0;
        if (rst || (cmd_valid && cmd_ready && cmd_clear && mut != 6)) begin
            for (int i = 0; i < N_ITEMS; i++) begin
                for (int k = 0; k < WINDOW_LEN; k++) window_q[i][k] <= '0;
                sum_q[i]  <= '0;
                prev_price_q[i] <= '0;
                last_action_q[i] <= ACT_NONE;
            end
        end else if (cmd_valid && cmd_ready && !cmd_clear) begin
            window_q[cmd_item_sel][0] <= cmd_price;
            for (int k = 1; k < WINDOW_LEN; k++) window_q[cmd_item_sel][k] <= window_q[cmd_item_sel][k-1];
            sum_q[cmd_item_sel]  <= new_sum;
            prev_price_q[cmd_item_sel] <= cmd_price;
            if (eval) last_action_q[cmd_item_sel] <= act_d;
            act_valid <= 1'b1;
            act       <= act_d;
        end
    end
endmodule
