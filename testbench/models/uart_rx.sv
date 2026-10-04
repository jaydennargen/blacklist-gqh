// MODEL of uart_rx -- simulation only, never synthesized, NOT the RTL. It exists so the
// testbenches can be shown to pass on a design that follows docs/ARCHITECTURE.md §3 (B1), §5 and
// to fail on a broken one:  python tools/run.py sim uart --models [--plusargs "+MUT=<n>"]
// +MUT: 14 stop bit not checked   17 start bit not re-checked at mid-bit   18 data sampled at
//       the start of each bit instead of the middle
// Same ports as src/uart_rx.sv.
module uart_rx #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT
) (
    input  logic       clk,
    input  logic       rst,      // synchronous, active-high
    input  logic       rx_i,     // asynchronous pin; synchronized inside this module
    output logic [7:0] rx_data,  // valid on the rx_valid cycle only
    output logic       rx_valid  // 1-cycle strobe per good frame; no back-pressure
);
    typedef enum logic [1:0] {R_IDLE, R_START, R_DATA, R_STOP} state_e;

    int unsigned mut = 0;
    initial void'($value$plusargs("MUT=%d", mut));

    state_e      state_q;
    logic        sync1_q;
    logic        sync2_q;   // rx_i after the 2-flop synchronizer
    int unsigned tick_q;    // clock within the bit-time
    int unsigned bit_q;     // data bits sampled so far
    int unsigned half;      // clocks from the start edge to the first sample point

    assign half = (mut == 18) ? 2 : CLKS_PER_BIT / 2;

    always_ff @(posedge clk) begin
        sync1_q  <= rx_i;
        sync2_q  <= sync1_q;
        rx_valid <= 1'b0;
        if (rst) begin
            state_q <= R_IDLE;
            sync1_q <= 1'b1;
            sync2_q <= 1'b1;
        end else begin
            tick_q <= tick_q + 1;
            case (state_q)
                R_IDLE: begin
                    tick_q <= 0;
                    if (!sync2_q) state_q <= R_START;
                end
                R_START: if (tick_q == half - 1) begin
                    tick_q  <= 0;
                    bit_q   <= 0;
                    state_q <= (sync2_q && mut != 17) ? R_IDLE : R_DATA;
                end
                R_DATA: if (tick_q == CLKS_PER_BIT - 1) begin
                    tick_q  <= 0;
                    rx_data <= {sync2_q, rx_data[7:1]};
                    bit_q   <= bit_q + 1;
                    if (bit_q == 7) state_q <= R_STOP;
                end
                default: if (tick_q == CLKS_PER_BIT - 1) begin   // R_STOP
                    rx_valid <= sync2_q || (mut == 14);
                    state_q  <= R_IDLE;
                end
            endcase
        end
    end
endmodule
