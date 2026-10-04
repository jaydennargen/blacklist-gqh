// MODEL of uart_tx -- simulation only, never synthesized, NOT the RTL. It exists so the
// testbenches can be shown to pass on a design that follows docs/ARCHITECTURE.md §3 (B3) and to
// fail on a broken one:  python tools/run.py sim uart --models [--plusargs "+MUT=<n>"]
// +MUT: 13 data bits sent MSB first   15 idle gap one bit-time short
// Same ports as src/uart_tx.sv.
module uart_tx #(
    parameter int unsigned CLKS_PER_BIT = gqh_pkg::CLKS_PER_BIT,
    parameter int unsigned GAP_BITS     = gqh_pkg::TX_GAP_BITS   // idle bit-times after the stop bit
) (
    input  logic       clk,
    input  logic       rst,       // synchronous, active-high
    input  logic [7:0] tx_data,   // sampled on the cycle tx_valid && tx_ready
    input  logic       tx_valid,
    output logic       tx_ready,  // 0 in reset and from the transfer until stop bit + gap have ended
    output logic       tx_o       // idle high
);
    localparam int unsigned FRAME_BITS = 10;  // start + 8 data + stop

    int unsigned mut = 0;
    initial void'($value$plusargs("MUT=%d", mut));

    logic                  busy_q;
    logic [FRAME_BITS-1:0] frame_q;   // bit 0 goes out first
    int unsigned           slot_q;    // bit-time within frame + gap
    int unsigned           tick_q;    // clock within the bit-time
    int unsigned           slots;     // bit-times one byte occupies

    function automatic logic [7:0] msb_first(input logic [7:0] d);
        for (int i = 0; i < 8; i++) msb_first[i] = d[7-i];
    endfunction

    assign slots    = FRAME_BITS + GAP_BITS - ((mut == 15) ? 1 : 0);
    assign tx_ready = !rst && !busy_q;
    assign tx_o     = (busy_q && slot_q < FRAME_BITS) ? frame_q[slot_q] : 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0;
        end else if (tx_valid && tx_ready) begin
            busy_q  <= 1'b1;
            frame_q <= {1'b1, (mut == 13) ? msb_first(tx_data) : tx_data, 1'b0};
            slot_q  <= 0;
            tick_q  <= 0;
        end else if (busy_q) begin
            if (tick_q != CLKS_PER_BIT - 1) begin
                tick_q <= tick_q + 1;
            end else begin
                tick_q <= 0;
                slot_q <= slot_q + 1;
                if (slot_q == slots - 1) busy_q <= 1'b0;
            end
        end
    end
endmodule
