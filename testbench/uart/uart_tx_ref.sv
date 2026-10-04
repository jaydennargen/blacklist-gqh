// uart_tx_ref -- simulation only: the v1 uart_tx (main 18e292b) verbatim, renamed. tb_uart runs it in
// lockstep with src/uart_tx.sv and requires tx_o and tx_ready to match on every clock, so a
// logic reduction of uart_tx cannot change its behavior. Do not edit except to rename.
// uart_tx -- 8N1 transmitter, LSB first, with a guaranteed idle gap after every frame.
// Contract: docs/ARCHITECTURE.md §3 (B3), §5. Owner: io.
// On a transfer the whole frame {stop, data, start} is loaded into a shift register whose bit 0
// drives tx_o; every bit-time it shifts right and fills with 1, so after the stop bit the line
// stays idle for the GAP_BITS bit-times that tx_ready is still held low (DECISIONS D8). The
// FSM of ARCHITECTURE §5 (START, DATA, STOP, GAP) is the count of bit-times left.
module uart_tx_ref #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT,  // clocks per bit; must be >= 2
    parameter int unsigned GAP_BITS     = gqh_pkg::TX_GAP_BITS    // idle bit-times after the stop bit
) (
    input  logic       clk,
    input  logic       rst,       // synchronous, active-high
    input  logic [7:0] tx_data,   // sampled on the cycle tx_valid && tx_ready
    input  logic       tx_valid,
    output logic       tx_ready,  // 0 in reset and from the transfer until stop bit + gap have ended
    output logic       tx_o       // idle high
);
    localparam int unsigned      FRAME_BITS = 10;                         // start + 8 data + stop
    localparam int unsigned      TOTAL_BITS = FRAME_BITS + GAP_BITS;      // bit-times per transfer
    localparam int unsigned      CNT_W      = $clog2(CLKS_PER_BIT);
    localparam int unsigned      LEFT_W     = $clog2(TOTAL_BITS + 1);
    localparam logic [CNT_W-1:0] BIT_LAST   = CNT_W'(CLKS_PER_BIT - 1);

    logic [FRAME_BITS-1:0] shift_q, shift_d;  // bit 0 is on the line; idles all ones
    logic [LEFT_W-1:0]     left_q, left_d;    // bit-times left in frame + gap; 0 = done
    logic [CNT_W-1:0]      cnt_q, cnt_d;      // clocks left in the current bit-time
    logic                  ready_q, ready_d;  // tx_ready
    logic                  xfer;              // transfer on this cycle

    assign xfer = tx_valid && ready_q;

    always_comb begin
        shift_d = shift_q;
        left_d  = left_q;
        cnt_d   = cnt_q;
        ready_d = ready_q;

        if (xfer) begin
            shift_d = {1'b1, tx_data, 1'b0};
            left_d  = LEFT_W'(TOTAL_BITS);
            cnt_d   = BIT_LAST;
            ready_d = 1'b0;
        end else if (!ready_q) begin
            if (left_q == '0) begin
                ready_d = 1'b1;                       // frame and gap done (or reset just ended)
            end else if (cnt_q == '0) begin
                shift_d = {1'b1, shift_q[FRAME_BITS-1:1]};
                left_d  = left_q - LEFT_W'(1);
                cnt_d   = BIT_LAST;
            end else begin
                cnt_d   = cnt_q - CNT_W'(1);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            shift_q <= '1;
            left_q  <= '0;
            cnt_q   <= '0;
            ready_q <= 1'b0;
        end else begin
            shift_q <= shift_d;
            left_q  <= left_d;
            cnt_q   <= cnt_d;
            ready_q <= ready_d;
        end
    end

    assign tx_ready = ready_q;
    assign tx_o     = shift_q[0];
endmodule
