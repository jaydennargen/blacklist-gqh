// b2_sva -- B2 (pkt_ctrl <-> ma_engine) checks, bound into every ma_engine.
// Contract: docs/ARCHITECTURE.md §3 (B2); assertion list §7. Simulation only.
// No cycle count is assumed between a transfer and its act_valid.
`include "gqh_sva.svh"

module b2_sva
    import gqh_pkg::*;
(
    input logic      clk,
    input logic      rst,           // synchronous, active-high
    input logic      cmd_valid,
    input logic      cmd_ready,
    input logic      cmd_clear,
    input item_sel_e cmd_item_sel,
    input logic      cmd_eval,
    input price_t    cmd_price,
    input logic      act_valid,     // 1-cycle strobe
    input action_e   act            // valid on the act_valid cycle only
);
    logic cmd_xfer;         // B2 transfer this cycle
    logic pending_q;        // a non-clear command has transferred and its act_valid is still owed
    logic pending_eval_q;   // cmd_eval of that command

    assign cmd_xfer = cmd_valid && cmd_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q      <= 1'b0;
            pending_eval_q <= 1'b0;
        end else if (cmd_xfer && !cmd_clear) begin
            pending_q      <= 1'b1;
            pending_eval_q <= cmd_eval;
        end else if (act_valid) begin
            pending_q      <= 1'b0;
        end
    end

    // ---- protocol
    // ma_engine's own outputs. Checked from the second cycle of rst: a registered output needs
    // one clock of synchronous reset before it reads 0. cmd_valid is checked in pkt_ctrl_sva.
    a_valid_low_in_rst: assert property (@(posedge clk) rst ##1 rst |-> !cmd_ready && !act_valid)
        else $error("a_valid_low_in_rst: cmd_ready=%b act_valid=%b while rst", cmd_ready, act_valid);
    `GQH_COVER(c_valid_low_in_rst, rst ##1 rst)

    a_cmd_stable: assert property (@(posedge clk) disable iff (rst)
            cmd_valid && !cmd_ready |=> cmd_valid && $stable({cmd_clear, cmd_item_sel, cmd_eval, cmd_price}))
        else $error("a_cmd_stable: cmd_valid dropped or cmd_* changed before the transfer");
    // Not a required cover here: an engine that is ready whenever it is idle never stalls a
    // command, and that is legal. testbench/pkt_ctrl stalls on purpose and requires it there.
    `GQH_COVER(c_cmd_stable, !rst && cmd_valid && !cmd_ready)

    // pending_q is registered, so this also enforces "at least one cycle after the transfer".
    a_one_act_per_cmd: assert property (@(posedge clk) disable iff (rst) act_valid |-> pending_q)
        else $error("a_one_act_per_cmd: act_valid with no non-clear command outstanding");
    `GQH_COVER(c_one_act_per_cmd, !rst && act_valid)
    `GQH_COVER(c_clear_no_act, !rst && cmd_xfer && cmd_clear)

    a_no_cmd_while_busy: assert property (@(posedge clk) disable iff (rst) pending_q |-> !cmd_xfer)
        else $error("a_no_cmd_while_busy: B2 transfer before the previous command's act_valid");
    `GQH_COVER(c_no_cmd_while_busy, !rst && pending_q)

    // ---- functional
    a_warmup_none: assert property (@(posedge clk) disable iff (rst)
            act_valid && pending_q && !pending_eval_q |-> act == ACT_NONE)
        else $error("a_warmup_none: act=%0d for a cmd_eval=0 command", $sampled(act));
    `GQH_COVER(c_warmup_none, !rst && act_valid && pending_q && !pending_eval_q)

    final begin
        // The "at least one" half of a_one_act_per_cmd: nothing may still be owed at the end.
        if (pending_q) $error("a_one_act_per_cmd: test ended with an act_valid still owed (%m)");
        if ($test$plusargs("REQUIRE_COVERS")) begin
            `GQH_COVER_REQUIRED(c_valid_low_in_rst)
            `GQH_COVER_REQUIRED(c_one_act_per_cmd)
            `GQH_COVER_REQUIRED(c_clear_no_act)
            `GQH_COVER_REQUIRED(c_no_cmd_while_busy)
            `GQH_COVER_REQUIRED(c_warmup_none)
        end
    end
endmodule

// The bind sits in a module because Questa does not elaborate a bind at file scope (vlog-2650).
// tools/run.py loads b2_bind as an extra top when the test instantiates ma_engine.
module b2_bind;
    bind ma_engine b2_sva u_b2_sva (.*);
    // a_other_item_untouched: each item's whole state as one vector, by ma_engine's own names.
`ifdef GQH_MODELS
    // testbench/models/ma_engine.sv: flops (run.py defines GQH_MODELS for `sim --models`).
    bind ma_engine ma_engine_state_sva #(.STATE_W(WINDOW_LEN * $bits(price_t) + $bits(sum_t) + $bits(price_t) + $bits(action_e))) u_state_sva (
        .state_a({window_q[0][0], window_q[0][1], window_q[0][2], window_q[0][3], window_q[0][4], window_q[0][5], window_q[0][6], window_q[0][7],
                  window_q[0][8], window_q[0][9], window_q[0][10], window_q[0][11], window_q[0][12], window_q[0][13], window_q[0][14], window_q[0][15],
                  sum_q[0], prev_price_q[0], last_action_q[0]}),
        .state_b({window_q[1][0], window_q[1][1], window_q[1][2], window_q[1][3], window_q[1][4], window_q[1][5], window_q[1][6], window_q[1][7],
                  window_q[1][8], window_q[1][9], window_q[1][10], window_q[1][11], window_q[1][12], window_q[1][13], window_q[1][14], window_q[1][15],
                  sum_q[1], prev_price_q[1], last_action_q[1]}),
        .*);
`else
    // src/ma_engine.sv (DECISIONS D20): the state is the four RAMs; the item is the top address bit,
    // so item A is the lower half of each memory and item B the upper half.
    bind ma_engine ma_engine_state_sva #(.STATE_W($bits(u_win.mem) / 2 + $bits(u_sum.mem) / 2 + $bits(u_prev.mem) / 2 + $bits(u_last.mem) / 2)) u_state_sva (
        .state_a({>>{u_win.mem[0 : $size(u_win.mem) / 2 - 1], u_sum.mem[0 : $size(u_sum.mem) / 2 - 1],
                     u_prev.mem[0 : $size(u_prev.mem) / 2 - 1], u_last.mem[0]}}),
        .state_b({>>{u_win.mem[$size(u_win.mem) / 2 : $size(u_win.mem) - 1], u_sum.mem[$size(u_sum.mem) / 2 : $size(u_sum.mem) - 1],
                     u_prev.mem[$size(u_prev.mem) / 2 : $size(u_prev.mem) - 1], u_last.mem[1]}}),
        .*);
`endif
endmodule


// ma_engine_state_sva -- a_other_item_untouched. Needs ma_engine's internal per-item state, which
// no port exposes. b2_bind passes each item's whole state as one vector.
module ma_engine_state_sva
    import gqh_pkg::*;
#(
    parameter int unsigned STATE_W = 1  // bits of one item's state: window + sum + prev + last action
) (
    input logic               clk,
    input logic               rst,           // synchronous, active-high
    input logic               cmd_valid,
    input logic               cmd_ready,
    input logic               cmd_clear,
    input item_sel_e          cmd_item_sel,
    input logic [STATE_W-1:0] state_a,       // all state of item A
    input logic [STATE_W-1:0] state_b        // all state of item B
);
    logic      cmd_xfer;      // B2 transfer this cycle
    logic      last_item_q;   // the most recent transfer was a non-clear command
    item_sel_e last_sel_q;    // its item

    assign cmd_xfer = cmd_valid && cmd_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            last_item_q <= 1'b0;
            last_sel_q  <= SEL_A;
        end else if (cmd_xfer) begin
            last_item_q <= !cmd_clear;
            last_sel_q  <= cmd_item_sel;
        end
    end

    // From the transfer of a command to one item until the next transfer, the other item's state
    // holds. Works for a single-cycle or a multi-cycle engine.
    a_other_item_untouched_a: assert property (@(posedge clk) disable iff (rst)
            last_item_q && last_sel_q == SEL_B |-> $stable(state_a))
        else $error("a_other_item_untouched_a: item A state changed on a command to item B");
    `GQH_COVER(c_other_item_untouched_a, !rst && last_item_q && last_sel_q == SEL_B)

    a_other_item_untouched_b: assert property (@(posedge clk) disable iff (rst)
            last_item_q && last_sel_q == SEL_A |-> $stable(state_b))
        else $error("a_other_item_untouched_b: item B state changed on a command to item A");
    `GQH_COVER(c_other_item_untouched_b, !rst && last_item_q && last_sel_q == SEL_A)

    final begin
        if ($test$plusargs("REQUIRE_COVERS")) begin
            `GQH_COVER_REQUIRED(c_other_item_untouched_a)
            `GQH_COVER_REQUIRED(c_other_item_untouched_b)
        end
    end
endmodule
