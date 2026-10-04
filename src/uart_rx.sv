// uart_rx -- 8N1 receiver, LSB first. Contract: docs/ARCHITECTURE.md §3 (B1), §5. Owner: io.
// One rx_valid strobe per good frame: the start bit must still be low at mid-bit and the stop bit
// must sample high at mid-bit (DECISIONS D3: one mid-bit sample per bit, no oversampling).
// After a low stop bit there is no strobe, and the receiver waits for the line to return high
// before it looks for the next start bit, so a line held low (break) cannot produce bytes.
module uart_rx #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT  // clocks per bit; must be >= 4
) (
    input  logic       clk,
    input  logic       rst,      // synchronous, active-high
    input  logic       rx_i,     // asynchronous pin; synchronized inside this module
    output logic [7:0] rx_data,  // valid on the rx_valid cycle only
    output logic       rx_valid  // 1-cycle strobe per good frame; no back-pressure
);
    localparam int unsigned      CNT_W     = $clog2(CLKS_PER_BIT);
    localparam logic [CNT_W-1:0] BIT_LAST  = CNT_W'(CLKS_PER_BIT - 1);      // one full bit
    localparam logic [CNT_W-1:0] HALF_LAST = CNT_W'(CLKS_PER_BIT / 2 - 1);  // start edge -> mid-bit

    typedef enum logic [2:0] {
        S_IDLE,   // line high, waiting for a start bit
        S_START,  // half a bit, then re-check the start bit
        S_DATA,   // 8 mid-bit samples, LSB first
        S_STOP,   // mid-bit sample of the stop bit
        S_BREAK   // stop bit was low: wait for the line to go high
    } state_e;

    logic             rx_meta_q;          // synchronizer stage 1 (may be metastable)
    logic             rx_sync_q;          // synchronizer stage 2: the only use of rx_i
    state_e           state_q, state_d;
    logic [CNT_W-1:0] cnt_q, cnt_d;       // clocks left until the next sample point
    logic [2:0]       bit_q, bit_d;       // data bit being sampled, 0..7
    logic [7:0]       shift_q, shift_d;   // data bits, shifted in from the top (LSB first)
    logic             valid_q, valid_d;   // rx_valid
    logic             sample;             // this cycle is a sample point

    assign sample = (cnt_q == '0);

    always_comb begin
        state_d = state_q;
        cnt_d   = sample ? cnt_q : cnt_q - CNT_W'(1);
        bit_d   = bit_q;
        shift_d = shift_q;
        valid_d = 1'b0;

        case (state_q)
            S_IDLE: begin
                if (!rx_sync_q) begin
                    state_d = S_START;
                    cnt_d   = HALF_LAST;
                end
            end
            S_START: begin
                if (sample) begin
                    if (rx_sync_q) begin
                        state_d = S_IDLE;            // glitch: start bit gone by mid-bit
                    end else begin
                        state_d = S_DATA;
                        cnt_d   = BIT_LAST;
                        bit_d   = '0;
                    end
                end
            end
            S_DATA: begin
                if (sample) begin
                    shift_d = {rx_sync_q, shift_q[7:1]};
                    cnt_d   = BIT_LAST;
                    bit_d   = bit_q + 3'd1;
                    if (bit_q == 3'd7) begin
                        state_d = S_STOP;
                    end
                end
            end
            S_STOP: begin
                if (sample) begin
                    if (rx_sync_q) begin
                        valid_d = 1'b1;
                        state_d = S_IDLE;
                    end else begin
                        state_d = S_BREAK;           // framing error: no strobe
                    end
                end
            end
            S_BREAK: begin
                if (rx_sync_q) begin
                    state_d = S_IDLE;
                end
            end
            default: begin
                state_d = S_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_meta_q <= 1'b1;
            rx_sync_q <= 1'b1;
            state_q   <= S_IDLE;
            cnt_q     <= '0;
            bit_q     <= '0;
            shift_q   <= '0;
            valid_q   <= 1'b0;
        end else begin
            rx_meta_q <= rx_i;
            rx_sync_q <= rx_meta_q;
            state_q   <= state_d;
            cnt_q     <= cnt_d;
            bit_q     <= bit_d;
            shift_q   <= shift_d;
            valid_q   <= valid_d;
        end
    end

    assign rx_data  = shift_q;
    assign rx_valid = valid_q;
endmodule
