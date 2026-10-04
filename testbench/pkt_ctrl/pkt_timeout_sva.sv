`timescale 1ns / 1ps
// D13: independent elapsed-clock reference, never an LFSR-state expectation.
module pkt_timeout_sva
    import gqh_pkg::*;
#(
    parameter int unsigned RX_TIMEOUT_CLKS = gqh_pkg::RX_TIMEOUT_CLKS
) (
    input logic clk,                         // sampling clock
    input logic rst,                         // synchronous reset
    input logic receiving,                   // DUT is collecting a request
    input logic rx_valid,                    // received byte wins over expiry
    input logic [$clog2(PKT_BYTES)-1:0] byte_q // partial-packet length
);
    int unsigned quiet_q;
    logic [$clog2(PKT_BYTES)-1:0] count_q;
    int unsigned expiry_hits = 0;
    int unsigned restart_hits = 0;

    always_ff @(posedge clk) begin
        if (rst || !receiving) begin
            quiet_q <= 0;
            count_q <= '0;
        end else if (rx_valid) begin
            quiet_q <= 0;
            count_q <= count_q + 1'b1;
        end else if ((RX_TIMEOUT_CLKS != 0) && (count_q != '0)) begin
            if (quiet_q == RX_TIMEOUT_CLKS - 1) begin
                quiet_q <= 0;
                count_q <= '0;
            end else quiet_q <= quiet_q + 1;
        end
    end

    a_exact_timeout: assert property (@(posedge clk) disable iff (rst)
        receiving |-> byte_q == count_q)
        else $fatal(1, "partial-packet timeout/restart differs from elapsed-clock reference");
    c_expiry: cover property (@(posedge clk) !rst && receiving && !rx_valid &&
        count_q != '0 && quiet_q == RX_TIMEOUT_CLKS - 1) expiry_hits++;
    c_restart: cover property (@(posedge clk) !rst && receiving && rx_valid &&
        count_q != '0 && quiet_q == RX_TIMEOUT_CLKS - 1) restart_hits++;

    final begin
        if ($test$plusargs("REQUIRE_COVERS")) begin
            if (expiry_hits == 0) $error("COVER_ZERO timeout expiry");
            if (restart_hits == 0) $error("COVER_ZERO byte on timeout expiry edge");
        end
    end
endmodule

module pkt_timeout_bind;
    bind pkt_ctrl pkt_timeout_sva #(.RX_TIMEOUT_CLKS(RX_TIMEOUT_CLKS)) u_timeout_sva (
        .clk(clk), .rst(rst), .receiving(state_q == S_RX),
        .rx_valid(rx_valid), .byte_q(byte_q)
    );
endmodule
