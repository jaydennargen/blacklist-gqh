// ma_engine -- owns both items' moving-average state and applies one sample per command.
// Contract: docs/ARCHITECTURE.md sections 3 (B2) and 4; storage and datapath: DECISIONS D20.
//
// All per-item state is in block RAM, one bit per address, and the datapath is bit-serial, LSB
// first: one step per sum bit, SUM_W steps per sample. Block RAM is not counted as logic (D19) and
// a serial adder, subtractor and two comparators are a handful of LUTs where the parallel ones
// were 72 ALUs. A sample takes SUM_W + 3 clocks from its transfer to act_valid.
//
//   u_win   window:        bit b of the price in slot s of item i at {i, s, b}
//   u_sum   rolling sum:   bit b of item i at {i, b}
//   u_prev  previous price: bit b of item i at {i, b}
//   u_last  last action of item i at {i}
//
// Nothing is cleared in the RAMs. A clear command only zeroes cnt_q, the count of samples since
// the clear, and that is enough because of how the samples arrive (D10, D12):
//   - both items get one sample per packet, so slot = cnt_q / 2 is the same for both and a
//     slot is rewritten exactly WINDOW_LEN packets after it was written: the bit read from a
//     slot just before it is overwritten is the oldest price;
//   - a warm-up sample (cmd_eval = 0) in slot 0 is the first sample after the clear and takes
//     the old sum as 0; warm-up samples subtract nothing and store ACT_NONE as the last action;
//   - the first cmd_eval = 1 sample comes after WINDOW_LEN warm-up samples per item, so by then
//     every window slot, the sum, the previous price and the last action have been written.
module ma_engine
    import gqh_pkg::*;
(
    input  logic      clk,
    input  logic      rst,           // synchronous, active-high
    input  logic      cmd_valid,
    output logic      cmd_ready,     // 0 in reset, while a sample is being worked and on its act_valid
    input  logic      cmd_clear,     // start a new session for both items
    input  item_sel_e cmd_item_sel,  // sampled on the transfer
    input  logic      cmd_eval,      // 1: update + crossing; 0: warm-up sample
    input  price_t    cmd_price,
    output logic      act_valid,     // one-cycle strobe, SUM_W + 3 clocks after a non-clear transfer
    output action_e   act            // valid on the act_valid cycle only
);
    localparam int unsigned PRICE_W = $bits(price_t);
    localparam int unsigned BIT_W   = $clog2(PRICE_W);     // bit index inside a price
    localparam int unsigned STEP_W  = $clog2(SUM_W + 2);   // steps 0 .. SUM_W, read step one ahead
    localparam int unsigned SLOT_W  = $clog2(WINDOW_LEN);

    // The command, latched on the transfer: cmd_* is stable only until then.
    price_t    price_q;
    item_sel_e sel_q;
    logic      eval_q;

    logic              busy_q;       // a sample is being worked
    logic              vld_q;        // the RAM outputs are the bits of step_q
    logic [STEP_W-1:0] rstep_q;      // step whose bits are being read
    logic [STEP_W-1:0] step_q;       // step being computed and written: rstep_q one clock ago
    logic [SLOT_W:0]   cnt_q;        // samples since the clear; window slot = cnt_q / 2
    logic              act_valid_q;
    action_e           act_q;

    logic       carry_q;             // adder: sum + price
    logic       borrow_q;            // subtractor: - oldest price
    logic [AVG_SHIFT-1:0] prev_dly_q;   // previous-price bits, [AVG_SHIFT-1] = bit step_q - AVG_SHIFT
    logic [AVG_SHIFT-1:0] price_dly_q;  // price bits, same alignment
    logic       prev_gt_q;           // previous price > old average, over the bits compared so far
    logic       prev_lt_q;           // previous price < old average
    logic       price_gt_q;          // price > new average
    logic       price_lt_q;          // price < new average

    logic       cmd_xfer;            // B2 transfer this cycle
    logic       start;               // a non-clear command transfers: work one sample
    logic       fin;                 // all SUM_W bits are done: answer and store the action
    logic       price_step;          // step_q addresses a price bit (step_q < PRICE_W)
    logic       avg_step;            // step_q addresses an average bit (step_q >= AVG_SHIFT)
    logic       first;               // first sample of this item since the clear
    logic [SLOT_W-1:0] slot;
    logic       sum_rd;              // RAM outputs for step_q
    logic       win_rd;
    logic       prev_rd;
    logic [1:0] last_rd;
    logic       price_bit;
    logic       sum_bit;             // old sum bit, 0 on the first sample
    logic       old_bit;             // oldest price bit, 0 on a warm-up sample
    logic       add_bit;             // bit of sum + price
    logic       new_bit;             // bit of the new sum
    logic       carry_d;
    logic       borrow_d;
    action_e    action;

    always_comb begin
        cmd_ready = !rst && !busy_q && !act_valid_q;
        act_valid = act_valid_q;
        act       = act_q;
        cmd_xfer  = cmd_valid && cmd_ready;
        start     = cmd_xfer && !cmd_clear;

        slot       = cnt_q[SLOT_W:1];
        first      = !eval_q && (slot == '0);
        price_step = (step_q < STEP_W'(PRICE_W));
        avg_step   = (step_q >= STEP_W'(AVG_SHIFT));
        fin        = vld_q && (step_q == STEP_W'(SUM_W));

        price_bit = price_step && price_q[step_q[BIT_W-1:0]];
        sum_bit   = !first && sum_rd;
        old_bit   = eval_q && price_step && win_rd;

        add_bit  = sum_bit ^ price_bit ^ carry_q;
        carry_d  = (sum_bit && price_bit) || (carry_q && (sum_bit ^ price_bit));
        new_bit  = add_bit ^ old_bit ^ borrow_q;
        borrow_d = (!add_bit && old_bit) || (borrow_q && !(add_bit ^ old_bit));

        action = action_e'(last_rd);
        if (!eval_q) begin
            action = ACT_NONE;
        end else if (!prev_gt_q && price_gt_q) begin
            action = ACT_BUY;
        end else if (!prev_lt_q && price_lt_q) begin
            action = ACT_SELL;
        end
    end

    always_ff @(posedge clk) begin
        if (start) begin
            price_q <= cmd_price;
            sel_q   <= cmd_item_sel;
            eval_q  <= cmd_eval;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q      <= 1'b0;
            vld_q       <= 1'b0;
            cnt_q       <= '0;
            act_valid_q <= 1'b0;
            act_q       <= ACT_NONE;
        end else begin
            if (start)    busy_q <= 1'b1;
            else if (fin) busy_q <= 1'b0;
            vld_q <= busy_q && !fin;
            if (cmd_xfer && cmd_clear) cnt_q <= '0;
            else if (fin)              cnt_q <= cnt_q + 1'b1;
            act_valid_q <= fin;
            if (fin) act_q <= action;
        end
    end

    // Per-sample registers: cleared while idle, so every sample starts from the same state.
    always_ff @(posedge clk) begin
        step_q <= rstep_q;
        if (!busy_q) begin
            rstep_q     <= '0;
            carry_q     <= 1'b0;
            borrow_q    <= 1'b0;
            prev_dly_q  <= '0;
            price_dly_q <= '0;
            prev_gt_q   <= 1'b0;
            prev_lt_q   <= 1'b0;
            price_gt_q  <= 1'b0;
            price_lt_q  <= 1'b0;
        end else begin
            rstep_q <= rstep_q + 1'b1;
            if (vld_q) begin
                carry_q     <= carry_d;
                borrow_q    <= borrow_d;
                prev_dly_q  <= {prev_dly_q[AVG_SHIFT-2:0], prev_rd};
                price_dly_q <= {price_dly_q[AVG_SHIFT-2:0], price_bit};
                // Average bit k is sum bit k + AVG_SHIFT. LSB first, so the last differing bit decides.
                if (avg_step && (prev_dly_q[AVG_SHIFT-1] != sum_rd)) begin
                    prev_gt_q <= prev_dly_q[AVG_SHIFT-1];
                    prev_lt_q <= sum_rd;
                end
                if (avg_step && (price_dly_q[AVG_SHIFT-1] != new_bit)) begin
                    price_gt_q <= price_dly_q[AVG_SHIFT-1];
                    price_lt_q <= new_bit;
                end
            end
        end
    end

    ram_sdp #(
        .AW (1 + SLOT_W + BIT_W),
        .DW (1)
    ) u_win (
        .clk (clk),
        .we  (vld_q && price_step),
        .wa  ({sel_q, slot, step_q[BIT_W-1:0]}),
        .wd  (price_bit),
        .ra  ({sel_q, slot, rstep_q[BIT_W-1:0]}),
        .rd  (win_rd)
    );

    ram_sdp #(
        .AW (1 + STEP_W),
        .DW (1)
    ) u_sum (
        .clk (clk),
        .we  (vld_q && !fin),
        .wa  ({sel_q, step_q}),
        .wd  (new_bit),
        .ra  ({sel_q, rstep_q}),
        .rd  (sum_rd)
    );

    ram_sdp #(
        .AW (1 + BIT_W),
        .DW (1)
    ) u_prev (
        .clk (clk),
        .we  (vld_q && price_step),
        .wa  ({sel_q, step_q[BIT_W-1:0]}),
        .wd  (price_bit),
        .ra  ({sel_q, rstep_q[BIT_W-1:0]}),
        .rd  (prev_rd)
    );

    ram_sdp #(
        .AW (1),
        .DW ($bits(action_e))
    ) u_last (
        .clk (clk),
        .we  (fin),
        .wa  (sel_q),
        .wd  (action),
        .ra  (sel_q),
        .rd  (last_rd)
    );
endmodule
