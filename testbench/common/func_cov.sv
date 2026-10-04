// func_cov -- functional covers over whole packets (docs/VERIFICATION.md "Covers"), for the
// tests that replay vectors. Counts what was sent and what came back; it checks nothing and
// computes no expected value. With +REQUIRE_COVERS a cover with 0 hits is an error.
// The two covers that need the model's averages (prev == old_avg, cur == new_avg) cannot be seen
// from a packet; tools/gen_vectors.py reports those per vector file from the oracle's own state.
module func_cov
    import gqh_pkg::*;
(
    input logic clk,
    input logic pkt_valid,  // 1 cycle per completed packet; req and rsp are valid on it
    input var req_t req,    // the request as sent
    input var rsp_t rsp         // the response as received
);
    localparam int unsigned N_ITEMS = 2;

    int unsigned c_buy_hits         = 0;  // scored BUY
    int unsigned c_sell_hits        = 0;  // scored SELL
    int unsigned c_none_scored_hits = 0;  // scored NONE: no crossing yet in this session
    int unsigned c_act_repeat_hits  = 0;  // scored action equal to the item's previous scored action
    int unsigned c_act_change_hits  = 0;  // scored action different from it
    int unsigned c_price_min_hits   = 0;  // scored price 0
    int unsigned c_price_max_hits   = 0;  // scored price 0xFFFF
    int unsigned c_a_slot1_hits     = 0;  // item A first
    int unsigned c_b_slot1_hits     = 0;  // item B first
    int unsigned c_index0_mid_hits  = 0;  // index 0 after a scored packet
    int unsigned c_first_scored_hits = 0; // index == WARMUP_END

    logic       scored_seen_q            = 1'b0;      // a scored packet has been seen since reset of the test
    logic       last_valid_q [N_ITEMS]   = '{default: 1'b0};
    logic [7:0] last_act_q   [N_ITEMS];               // per item, its previous scored action byte

    function automatic void slot(input item_id_t item, input price_t price, input logic [7:0] action);
        int unsigned i = (item == ITEM_B) ? 1 : 0;
        if (action == 8'(ACT_BUY))  c_buy_hits++;
        if (action == 8'(ACT_SELL)) c_sell_hits++;
        if (action == 8'(ACT_NONE)) c_none_scored_hits++;
        if (price == '0)            c_price_min_hits++;
        if (price == '1)            c_price_max_hits++;
        if (last_valid_q[i]) begin
            if (action == last_act_q[i]) c_act_repeat_hits++;
            else                         c_act_change_hits++;
        end
        last_valid_q[i] = 1'b1;
        last_act_q[i]   = action;
    endfunction

    always @(posedge clk) if (pkt_valid === 1'b1) begin
        if (req.item1 == ITEM_A) c_a_slot1_hits++;
        if (req.item1 == ITEM_B) c_b_slot1_hits++;
        if (req.index == '0) begin
            if (scored_seen_q) c_index0_mid_hits++;
            last_valid_q = '{default: 1'b0};
        end
        if (req.index == WARMUP_END) c_first_scored_hits++;
        if (req.index >= WARMUP_END) begin
            scored_seen_q = 1'b1;
            slot(req.item1, req.price1, rsp.action1);
            slot(req.item2, req.price2, rsp.action2);
        end
    end

    `define FUNC_COV_REQUIRED(name) if (name``_hits == 0) $error("COVER_ZERO %m.%s", `"name`");
    final begin
        $display("FUNC_COV buy=%0d sell=%0d none=%0d repeat=%0d change=%0d price0=%0d priceFFFF=%0d a_slot1=%0d b_slot1=%0d index0_mid=%0d first_scored=%0d",
                 c_buy_hits, c_sell_hits, c_none_scored_hits, c_act_repeat_hits, c_act_change_hits,
                 c_price_min_hits, c_price_max_hits, c_a_slot1_hits, c_b_slot1_hits, c_index0_mid_hits,
                 c_first_scored_hits);
        if ($test$plusargs("REQUIRE_COVERS")) begin
            `FUNC_COV_REQUIRED(c_buy)
            `FUNC_COV_REQUIRED(c_sell)
            `FUNC_COV_REQUIRED(c_none_scored)
            `FUNC_COV_REQUIRED(c_act_repeat)
            `FUNC_COV_REQUIRED(c_act_change)
            `FUNC_COV_REQUIRED(c_price_min)
            `FUNC_COV_REQUIRED(c_price_max)
            `FUNC_COV_REQUIRED(c_a_slot1)
            `FUNC_COV_REQUIRED(c_b_slot1)
            `FUNC_COV_REQUIRED(c_index0_mid)
            `FUNC_COV_REQUIRED(c_first_scored)
        end
    end
    `undef FUNC_COV_REQUIRED
endmodule
