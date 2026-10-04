// b3_sva -- B3 (pkt_ctrl -> uart_tx) checks and the tx_o idle gap, bound into every uart_tx.
// Contract: docs/ARCHITECTURE.md §3 (B3); assertion list §7. Simulation only.
`include "gqh_sva.svh"

module b3_sva #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT,
    parameter int unsigned GAP_BITS     = gqh_pkg::TX_GAP_BITS
) (
    input logic       clk,
    input logic       rst,       // synchronous, active-high
    input logic [7:0] tx_data,
    input logic       tx_valid,
    input logic       tx_ready,
    input logic       tx_o       // serial line, idle high
);
    localparam int unsigned FRAME_BITS             = 10;  // 8N1: start + 8 data + stop
    localparam int unsigned FRAME_CLKS             = FRAME_BITS * CLKS_PER_BIT;
    localparam int unsigned MIN_START_SPACING_CLKS = (FRAME_BITS + GAP_BITS) * CLKS_PER_BIT;

    // Frame tracker on tx_o alone: a falling edge is a start bit unless it lies inside the 10
    // bit-times of the frame already running (there it is a data bit).
    logic        tx_o_q;          // tx_o one cycle ago
    logic        frame_seen_q;    // at least one start bit since reset
    logic [31:0] since_start_q;   // cycles since the last start edge, saturating
    logic        tx_fall;         // falling edge on tx_o
    logic        start_edge;      // that edge begins a frame

    assign tx_fall    = tx_o_q && !tx_o;
    assign start_edge = tx_fall && (!frame_seen_q || since_start_q >= FRAME_CLKS);

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_o_q        <= 1'b1;
            frame_seen_q  <= 1'b0;
            since_start_q <= '0;
        end else begin
            tx_o_q <= tx_o;
            if (start_edge) begin
                frame_seen_q  <= 1'b1;
                since_start_q <= 32'd1;
            end else if (since_start_q < MIN_START_SPACING_CLKS) begin
                since_start_q <= since_start_q + 32'd1;
            end
        end
    end

    // ---- protocol
    // uart_tx's own output. Checked from the second cycle of rst: a registered output needs one
    // clock of synchronous reset before it reads 0. tx_valid is checked in pkt_ctrl_sva.
    a_valid_low_in_rst: assert property (@(posedge clk) rst ##1 rst |-> !tx_ready)
        else $error("a_valid_low_in_rst: tx_ready=1 while rst");
    `GQH_COVER(c_valid_low_in_rst, rst ##1 rst)

    a_tx_stable: assert property (@(posedge clk) disable iff (rst)
            tx_valid && !tx_ready |=> tx_valid && $stable(tx_data))
        else $error("a_tx_stable: tx_valid dropped or tx_data changed before the transfer");
    `GQH_COVER(c_tx_stable, !rst && tx_valid && !tx_ready)

    // Start-to-start spacing of a full frame plus GAP_BITS is the same statement as "GAP_BITS
    // idle bit-times between a stop bit and the next start bit".
    a_tx_gap_min: assert property (@(posedge clk) disable iff (rst)
            start_edge && frame_seen_q |-> since_start_q >= MIN_START_SPACING_CLKS)
        else $error("a_tx_gap_min: start bit %0d clocks after the previous one, minimum %0d",
                    $sampled(since_start_q), MIN_START_SPACING_CLKS);
    `GQH_COVER(c_tx_gap_min, !rst && start_edge && frame_seen_q)

    final begin
        if ($test$plusargs("REQUIRE_COVERS")) begin
            `GQH_COVER_REQUIRED(c_valid_low_in_rst)
            `GQH_COVER_REQUIRED(c_tx_stable)
            `GQH_COVER_REQUIRED(c_tx_gap_min)
        end
    end
endmodule

// The bind sits in a module because Questa does not elaborate a bind at file scope (vlog-2650).
// tools/run.py loads b3_bind as an extra top when the test instantiates uart_tx.
module b3_bind;
    bind uart_tx b3_sva #(.CLKS_PER_BIT(CLKS_PER_BIT), .GAP_BITS(GAP_BITS)) u_b3_sva (.*);
endmodule
