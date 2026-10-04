// THROWAWAY storage experiment. STYLE: 0 flop shift reg, clear all (srlstyle=registers)
//   1 flop shift reg, window not cleared   2 shift reg, tool's choice, window not cleared
//   3 inferred async-read RAM 32x16 + per-item pointer, window not cleared   4 = 0 without the attribute
module eng #(parameter int STYLE = 0) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cmd_valid,
    input  logic        cmd_clear,
    input  logic        cmd_item,
    input  logic        cmd_eval,
    input  logic [15:0] cmd_price,
    output logic        act_valid,
    output logic [1:0]  act
);
    logic [19:0] sum_q  [2];
    logic [15:0] prev_q [2];
    logic [1:0]  last_q [2];
    logic [15:0] oldest;
    logic        clr, push;
    assign clr  = rst || (cmd_valid && cmd_clear);
    assign push = cmd_valid && !cmd_clear;

    generate
    if (STYLE == 0) begin : g_ff_clr
        logic [15:0] win_q [2][16] /* synthesis syn_srlstyle = "registers" */;
        always_ff @(posedge clk)
            for (int s = 0; s < 2; s++)
                if (clr) for (int i = 0; i < 16; i++) win_q[s][i] <= '0;
                else if (push && cmd_item == s[0]) begin
                    win_q[s][0] <= cmd_price;
                    for (int i = 1; i < 16; i++) win_q[s][i] <= win_q[s][i-1];
                end
        assign oldest = win_q[cmd_item][15];
    end else if (STYLE == 4) begin : g_ff_clr_noattr
        logic [15:0] win_q [2][16];
        always_ff @(posedge clk)
            for (int s = 0; s < 2; s++)
                if (clr) for (int i = 0; i < 16; i++) win_q[s][i] <= '0;
                else if (push && cmd_item == s[0]) begin
                    win_q[s][0] <= cmd_price;
                    for (int i = 1; i < 16; i++) win_q[s][i] <= win_q[s][i-1];
                end
        assign oldest = win_q[cmd_item][15];
    end else if (STYLE == 1) begin : g_ff_noclr
        logic [15:0] win_q [2][16] /* synthesis syn_srlstyle = "registers" */;
        always_ff @(posedge clk)
            for (int s = 0; s < 2; s++)
                if (push && cmd_item == s[0]) begin
                    win_q[s][0] <= cmd_price;
                    for (int i = 1; i < 16; i++) win_q[s][i] <= win_q[s][i-1];
                end
        assign oldest = win_q[cmd_item][15];
    end else if (STYLE == 2) begin : g_auto
        logic [15:0] win_q [2][16];
        always_ff @(posedge clk)
            for (int s = 0; s < 2; s++)
                if (push && cmd_item == s[0]) begin
                    win_q[s][0] <= cmd_price;
                    for (int i = 1; i < 16; i++) win_q[s][i] <= win_q[s][i-1];
                end
        assign oldest = win_q[cmd_item][15];
    end else begin : g_ram
        logic [15:0] mem [32];
        logic [3:0]  ptr_q [2];
        always_ff @(posedge clk) begin
            if (clr) begin ptr_q[0] <= '0; ptr_q[1] <= '0; end
            else if (push) ptr_q[cmd_item] <= ptr_q[cmd_item] + 4'd1;
            if (push) mem[{cmd_item, ptr_q[cmd_item]}] <= cmd_price;
        end
        assign oldest = mem[{cmd_item, ptr_q[cmd_item]}];
    end
    endgenerate

    logic [19:0] sum, new_sum;
    logic [15:0] prev, old_avg, new_avg;
    logic [1:0]  last, act_d;
    always_comb begin
        sum     = sum_q[cmd_item];
        prev    = prev_q[cmd_item];
        last    = last_q[cmd_item];
        old_avg = sum[19:4];
        new_sum = cmd_eval ? sum - {4'd0, oldest} + {4'd0, cmd_price} : sum + {4'd0, cmd_price};
        new_avg = new_sum[19:4];
        act_d   = last;
        if (!cmd_eval)                                        act_d = 2'd0;
        else if (prev <= old_avg && cmd_price > new_avg)      act_d = 2'd2;
        else if (prev >= old_avg && cmd_price < new_avg)      act_d = 2'd1;
    end
    always_ff @(posedge clk) begin
        act_valid <= !rst && push;
        act       <= act_d;
        if (clr) begin
            for (int s = 0; s < 2; s++) begin sum_q[s] <= '0; prev_q[s] <= '0; last_q[s] <= '0; end
        end else if (push) begin
            sum_q[cmd_item]  <= new_sum;
            prev_q[cmd_item] <= cmd_price;
            if (cmd_eval) last_q[cmd_item] <= act_d;
        end
    end
endmodule
