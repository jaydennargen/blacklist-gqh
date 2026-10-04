// uart_tx -- 8N1 transmitter, LSB first, with a guaranteed idle gap after every frame.
// Contract: docs/ARCHITECTURE.md §3 (B3), §5. Owner: io.
// On a transfer the whole frame {stop, data, start} is loaded into a shift register whose bit 0
// drives tx_o; every bit-time it shifts right and fills with 1, so after the stop bit the line
// stays idle for the GAP_BITS bit-times that tx_ready is still held low (DECISIONS D8). The
// FSM of ARCHITECTURE §5 (START, DATA, STOP, GAP) is the count of bit-times left.
// The bit-time is timed by an LFSR instead of a binary counter: no adder, one XOR and a compare.
// It runs freely and reloads its seed at the end of every bit-time and on a transfer.
module uart_tx #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT,  // clocks per bit; 2 .. 65535
    parameter int unsigned GAP_BITS     = gqh_pkg::TX_GAP_BITS    // idle bit-times after the stop bit
) (
    input  logic       clk,
    input  logic       rst,       // synchronous, active-high
    input  logic [7:0] tx_data,   // sampled on the cycle tx_valid && tx_ready
    input  logic       tx_valid,
    output logic       tx_ready,  // 0 in reset and from the transfer until stop bit + gap have ended
    output logic       tx_o       // idle high
);
    localparam int unsigned FRAME_BITS = 10;                              // start + 8 data + stop
    localparam int unsigned TOTAL_BITS = FRAME_BITS + GAP_BITS;           // bit-times per transfer
    localparam int unsigned LEFT_W     = $clog2(TOTAL_BITS + 2);          // TOTAL_BITS + 1 LFSR states
    localparam int unsigned BAUD_W     = $clog2(CLKS_PER_BIT + 1);        // 2**W - 1 states >= CLKS_PER_BIT

    // Maximal-length Fibonacci LFSR feedback taps (bit i set = state bit i feeds the XOR), per width.
    function automatic logic [15:0] lfsr_taps(input int unsigned w);
        case (w)
            2:       return 16'h0003;
            3:       return 16'h0006;
            4:       return 16'h000C;
            5:       return 16'h0014;
            6:       return 16'h0030;
            7:       return 16'h0060;
            8:       return 16'h00B8;
            9:       return 16'h0110;
            10:      return 16'h0240;
            11:      return 16'h0500;
            12:      return 16'h0829;
            13:      return 16'h100D;
            14:      return 16'h2015;
            15:      return 16'h6000;
            default: return 16'hD008;  // 16
        endcase
    endfunction

    localparam logic [BAUD_W-1:0] BAUD_TAPS = BAUD_W'(lfsr_taps(BAUD_W));
    localparam logic [BAUD_W-1:0] BAUD_SEED = '1;

    function automatic logic [BAUD_W-1:0] baud_step(input logic [BAUD_W-1:0] s);
        return {s[BAUD_W-2:0], ^(s & BAUD_TAPS)};
    endfunction

    // The state CLKS_PER_BIT - 1 steps after the seed: the last clock of a bit-time.
    function automatic logic [BAUD_W-1:0] baud_after(input int unsigned n);
        logic [BAUD_W-1:0] s;
        s = BAUD_SEED;
        for (int unsigned i = 0; i < n; i++) s = baud_step(s);
        return s;
    endfunction

    localparam logic [BAUD_W-1:0] BAUD_LAST = baud_after(CLKS_PER_BIT - 1);

    // Bit-times left, also an LFSR: LEFT_FULL on a transfer, one step per bit-time, LEFT_DONE
    // TOTAL_BITS steps later.
    localparam logic [LEFT_W-1:0] LEFT_TAPS = LEFT_W'(lfsr_taps(LEFT_W));
    localparam logic [LEFT_W-1:0] LEFT_FULL = '1;

    function automatic logic [LEFT_W-1:0] left_step(input logic [LEFT_W-1:0] s);
        return {s[LEFT_W-2:0], ^(s & LEFT_TAPS)};
    endfunction

    function automatic logic [LEFT_W-1:0] left_after(input int unsigned n);
        logic [LEFT_W-1:0] s;
        s = LEFT_FULL;
        for (int unsigned i = 0; i < n; i++) s = left_step(s);
        return s;
    endfunction

    localparam logic [LEFT_W-1:0] LEFT_DONE = left_after(TOTAL_BITS);

    logic [FRAME_BITS-1:0] shift_q, shift_d;  // bit 0 is on the line; idles all ones
    logic [LEFT_W-1:0]     left_q, left_d;    // bit-times left in frame + gap (LFSR); LEFT_DONE = done
    logic [BAUD_W-1:0]     baud_q, baud_d;    // LFSR, BAUD_SEED on the first clock of a bit-time
    logic                  ready_q, ready_d;  // tx_ready
    logic                  xfer;              // transfer on this cycle
    logic                  bit_end;           // last clock of the current bit-time

    assign xfer    = tx_valid && ready_q;
    assign bit_end = (baud_q == BAUD_LAST);

    always_comb begin
        shift_d = shift_q;
        left_d  = left_q;
        baud_d  = (xfer || bit_end) ? BAUD_SEED : baud_step(baud_q);
        ready_d = ready_q;

        if (xfer) begin
            shift_d = {1'b1, tx_data, 1'b0};
            left_d  = LEFT_FULL;
            ready_d = 1'b0;
        end else if (!ready_q) begin
            if (left_q == LEFT_DONE) begin
                ready_d = 1'b1;                       // frame and gap done (or reset just ended)
            end else if (bit_end) begin
                shift_d = {1'b1, shift_q[FRAME_BITS-1:1]};
                left_d  = left_step(left_q);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            shift_q <= '1;
            left_q  <= LEFT_DONE;
            baud_q  <= BAUD_SEED;
            ready_q <= 1'b0;
        end else begin
            shift_q <= shift_d;
            left_q  <= left_d;
            baud_q  <= baud_d;
            ready_q <= ready_d;
        end
    end

    assign tx_ready = ready_q;
    assign tx_o     = shift_q[0];
endmodule
