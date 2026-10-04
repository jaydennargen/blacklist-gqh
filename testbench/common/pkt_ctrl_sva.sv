// pkt_ctrl_sva -- packet-level checks on pkt_ctrl, bound into every pkt_ctrl.
// Contract: docs/ARCHITECTURE.md §3, §5; assertion list §7. Simulation only.
//
// Ports only: nothing here reads pkt_ctrl's state register. The packet phase is rebuilt from
// what pkt_ctrl does at its ports, so the checks hold for any state encoding or naming:
//   PH_RX  -> PH_CMD  first cycle of cmd_valid            (pkt_ctrl left S_RX)
//   PH_CMD -> PH_TX   second act_valid                    (pkt_ctrl enters S_TX)
//   PH_TX  -> PH_RX   8th B3 transfer                     (pkt_ctrl back in S_RX)
`include "gqh_sva.svh"

module pkt_ctrl_sva
    import gqh_pkg::*;
#(
    parameter int unsigned RX_TIMEOUT_CLKS = gqh_pkg::RX_TIMEOUT_CLKS  // 0 disables the timeout
) (
    input logic       clk,
    input logic       rst,        // synchronous, active-high
    input logic [7:0] rx_data,    // B1
    input logic       rx_valid,
    input logic       cmd_valid,  // B2
    input logic       cmd_ready,
    input logic       cmd_clear,
    input logic       act_valid,
    input logic [7:0] tx_data,    // B3
    input logic       tx_valid,
    input logic       tx_ready
);
    localparam int unsigned CNT_W      = $clog2(PKT_BYTES);
    localparam int unsigned RSVD_BYTES = 2;                       // rsp_t.reserved, the last bytes sent
    localparam int unsigned RSVD_FIRST = PKT_BYTES - RSVD_BYTES;
    // The exact cycle the partial-packet timeout fires is pkt_ctrl's business. A byte arriving
    // within GUARD_CLKS of it is not judged either way.
    localparam int unsigned GUARD_CLKS = 4;
    localparam bit          TIMEOUT_EN = (RX_TIMEOUT_CLKS != 0);

    typedef enum logic [1:0] {PH_RX, PH_CMD, PH_TX} phase_e;

    // ---- packet phase, from the ports
    phase_e           phase_q;
    logic             act1_seen_q;    // first act_valid of this packet has arrived
    logic [CNT_W-1:0] tx_cnt_q;       // B3 transfers so far in this response
    logic             clear_seen_q;   // a clear command has transferred in this packet
    logic             slot_seen_q;    // a non-clear command has transferred in this packet
    logic             cmd_xfer;       // B2 transfer this cycle
    logic             tx_xfer;        // B3 transfer this cycle
    logic             tx_last;        // that transfer is response byte 8
    logic             pkt_start;      // first cmd_valid cycle of a packet

    assign cmd_xfer  = cmd_valid && cmd_ready;
    assign tx_xfer   = tx_valid && tx_ready;
    assign tx_last   = tx_xfer && (tx_cnt_q == CNT_W'(PKT_BYTES - 1));
    assign pkt_start = (phase_q == PH_RX) && cmd_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            phase_q      <= PH_RX;
            act1_seen_q  <= 1'b0;
            tx_cnt_q     <= '0;
            clear_seen_q <= 1'b0;
            slot_seen_q  <= 1'b0;
        end else begin
            if (cmd_xfer && cmd_clear)  clear_seen_q <= 1'b1;
            if (cmd_xfer && !cmd_clear) slot_seen_q  <= 1'b1;
            case (phase_q)
                PH_RX: if (cmd_valid) phase_q <= PH_CMD;
                PH_CMD: if (act_valid) begin
                    act1_seen_q <= 1'b1;
                    if (act1_seen_q) phase_q <= PH_TX;
                end
                PH_TX: if (tx_xfer) begin
                    tx_cnt_q <= tx_cnt_q + 1'b1;
                    if (tx_last) begin
                        phase_q      <= PH_RX;
                        act1_seen_q  <= 1'b0;
                        tx_cnt_q     <= '0;
                        clear_seen_q <= 1'b0;
                        slot_seen_q  <= 1'b0;
                    end
                end
                default: phase_q <= PH_RX;
            endcase
        end
    end

    // ---- request side: the last 8 bytes taken, and how many pkt_ctrl must be holding
    req_t             req_q;           // most recent 8 bytes taken while collecting
    logic [CNT_W-1:0] rx_cnt_q;        // bytes pkt_ctrl holds of the current request
    logic             rx_cnt_known_q;  // 0 after a byte too close to the timeout to call
    logic [31:0]      rx_gap_q;        // cycles since the last byte taken, saturating
    logic             rx_idle;         // pkt_ctrl is collecting
    logic             rx_take;         // a byte pkt_ctrl must take
    logic             gap_expired;     // the timeout has certainly fired since the last byte
    logic             gap_unsure;      // the timeout may or may not have fired
    logic             rx_eighth;       // this byte certainly completes a request

    assign rx_idle     = (phase_q == PH_RX) && !cmd_valid;
    assign rx_take     = rx_valid && rx_idle;
    assign gap_expired = TIMEOUT_EN && (rx_gap_q > RX_TIMEOUT_CLKS + GUARD_CLKS);
    assign gap_unsure  = TIMEOUT_EN && !gap_expired && (rx_cnt_q != '0)
                         && (rx_gap_q + GUARD_CLKS >= RX_TIMEOUT_CLKS);
    assign rx_eighth   = rx_take && rx_cnt_known_q && !gap_expired && !gap_unsure
                         && (rx_cnt_q == CNT_W'(PKT_BYTES - 1));

    always_ff @(posedge clk) begin
        if (rx_take) req_q <= {req_q[$bits(req_t)-9:0], rx_data};

        if (rst || pkt_start) begin
            rx_cnt_q       <= '0;
            rx_cnt_known_q <= 1'b1;
            rx_gap_q       <= '0;
        end else if (rx_take) begin
            rx_gap_q <= '0;
            if (gap_expired) begin
                rx_cnt_q       <= CNT_W'(1);
                rx_cnt_known_q <= 1'b1;
            end else if (gap_unsure) begin
                rx_cnt_known_q <= 1'b0;
            end else begin
                rx_cnt_q <= rx_cnt_q + 1'b1;
            end
        end else if (rx_gap_q <= RX_TIMEOUT_CLKS + GUARD_CLKS) begin
            rx_gap_q <= rx_gap_q + 32'd1;
        end
    end

    // ---- protocol
    // pkt_ctrl's own outputs. Checked from the second cycle of rst: a registered output needs
    // one clock of synchronous reset before it reads 0.
    a_valid_low_in_rst: assert property (@(posedge clk) rst ##1 rst |-> !cmd_valid && !tx_valid)
        else $error("a_valid_low_in_rst: cmd_valid=%b tx_valid=%b while rst", cmd_valid, tx_valid);
    `GQH_COVER(c_valid_low_in_rst, rst ##1 rst)

    a_no_tx_outside_s_tx: assert property (@(posedge clk) disable iff (rst) tx_valid |-> phase_q == PH_TX)
        else $error("a_no_tx_outside_s_tx: tx_valid outside the response phase (phase=%s)", phase_q.name());
    `GQH_COVER(c_no_tx_outside_s_tx, !rst && tx_valid)

    // With a_no_tx_outside_s_tx this is "exactly 8": a 9th byte is a tx_valid outside PH_TX, and
    // a response cut short shows as the next packet's command, or the end of the test, in PH_TX.
    a_rsp_8_bytes: assert property (@(posedge clk) disable iff (rst) phase_q == PH_TX |-> !cmd_valid)
        else $error("a_rsp_8_bytes: new command after only %0d response bytes", tx_cnt_q);
    `GQH_COVER(c_rsp_8_bytes, !rst && tx_last)

    a_reserved_zero: assert property (@(posedge clk) disable iff (rst)
            tx_xfer && tx_cnt_q >= CNT_W'(RSVD_FIRST) |-> tx_data == 8'h00)
        else $error("a_reserved_zero: response byte %0d = 0x%02h", $sampled(tx_cnt_q), $sampled(tx_data));
    `GQH_COVER(c_reserved_zero, !rst && tx_xfer && tx_cnt_q >= CNT_W'(RSVD_FIRST))

    // Every byte offered while collecting is taken: the 8th one starts the commands next cycle
    // (§6: T+1). The converse keeps a command from starting on anything but an 8th byte.
    a_rx_drop_only_when_busy: assert property (@(posedge clk) disable iff (rst) rx_eighth |=> cmd_valid)
        else $error("a_rx_drop_only_when_busy: 8 bytes offered while collecting, no command followed");
    `GQH_COVER(c_rx_drop_only_when_busy, !rst && rx_eighth)
    a_cmd_only_after_8_bytes: assert property (@(posedge clk) disable iff (rst)
            pkt_start && rx_cnt_known_q |-> $past(rx_eighth))
        else $error("a_cmd_only_after_8_bytes: command started with %0d request bytes held", rx_cnt_q);
    // The drop itself. Expected 0 in a stop-and-wait run, so it is not a required cover.
    `GQH_COVER(c_rx_while_busy, !rst && rx_valid && !rx_idle)

    // ---- functional
    // At the slot-1 command, a clear has gone before iff the request's index is 0.
    a_clear_on_index0: assert property (@(posedge clk) disable iff (rst)
            cmd_xfer && !cmd_clear && !slot_seen_q |-> clear_seen_q == (req_q.index == '0))
        else $error("a_clear_on_index0: index=%0d, clear before slot 1 = %b", req_q.index, clear_seen_q);
    `GQH_COVER(c_clear_on_index0, !rst && cmd_xfer && !cmd_clear && !slot_seen_q && req_q.index == '0)
    `GQH_COVER(c_no_clear_on_index_nz, !rst && cmd_xfer && !cmd_clear && !slot_seen_q && req_q.index != '0)
    a_clear_only_before_slot1: assert property (@(posedge clk) disable iff (rst)
            cmd_xfer && cmd_clear |-> !clear_seen_q && !slot_seen_q)
        else $error("a_clear_only_before_slot1: second clear, or a clear after slot 1");

    final begin
        if (phase_q == PH_TX) $error("a_rsp_8_bytes: test ended %0d bytes into a response (%m)", tx_cnt_q);
        if ($test$plusargs("REQUIRE_COVERS")) begin
            `GQH_COVER_REQUIRED(c_valid_low_in_rst)
            `GQH_COVER_REQUIRED(c_no_tx_outside_s_tx)
            `GQH_COVER_REQUIRED(c_rsp_8_bytes)
            `GQH_COVER_REQUIRED(c_reserved_zero)
            `GQH_COVER_REQUIRED(c_rx_drop_only_when_busy)
            `GQH_COVER_REQUIRED(c_clear_on_index0)
            `GQH_COVER_REQUIRED(c_no_clear_on_index_nz)
        end
    end
endmodule

// The bind sits in a module because Questa does not elaborate a bind at file scope (vlog-2650).
// tools/run.py loads pkt_ctrl_bind as an extra top when the test instantiates pkt_ctrl.
module pkt_ctrl_bind;
    bind pkt_ctrl pkt_ctrl_sva #(.RX_TIMEOUT_CLKS(RX_TIMEOUT_CLKS)) u_pkt_ctrl_sva (.*);
endmodule
