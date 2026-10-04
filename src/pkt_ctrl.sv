// pkt_ctrl -- the one control FSM. Owns the packet lifecycle end to end:
//   collect 8 bytes -> (clear on index 0) -> slot 1 -> slot 2 -> send 8 bytes.
// Contract: docs/ARCHITECTURE.md §3 (B1, B2, B3), §5. Owner: io.
module pkt_ctrl
    import gqh_pkg::*;
#(
    parameter int unsigned RX_TIMEOUT_CLKS = gqh_pkg::RX_TIMEOUT_CLKS  // 0 disables the timeout
) (
    input  logic       clk,           // system clock
    input  logic       rst,           // synchronous, active-high
    // B1: bytes from uart_rx
    input  logic [7:0] rx_data,       // byte on the rx_valid strobe
    input  logic       rx_valid,      // 1-cycle strobe; taken only while collecting a request
    // B2: command to ma_engine (valid/ready) and its result
    output logic       cmd_valid,     // held, with stable cmd_* fields, until cmd_ready
    input  logic       cmd_ready,     // engine accepts command this cycle
    output logic       cmd_clear,     // 1: clear all state of both items; other cmd_* fields ignored
    output item_sel_e  cmd_item_sel,  // which item's state this sample belongs to
    output logic       cmd_eval,      // 1: update + crossing; 0: warm-up sample, action NONE
    output price_t     cmd_price,     // selected slot's sample
    input  logic       act_valid,     // 1-cycle strobe, one per accepted non-clear command
    input  action_e    act,           // valid on the act_valid cycle only
    // B3: bytes to uart_tx (valid/ready)
    output logic [7:0] tx_data,       // stable while tx_valid = 1
    output logic       tx_valid,      // held until tx_ready
    input  logic       tx_ready       // UART accepts byte this cycle
);
    localparam int unsigned BYTE_W = $clog2(PKT_BYTES);
    localparam int unsigned TIMEOUT_W = (RX_TIMEOUT_CLKS > 1) ? $clog2(RX_TIMEOUT_CLKS) : 1;
    // D13/D19: specialize the deployed 2^20-clock timeout; other parameter values
    // retain their exact binary timing (including 0=disabled and 1).
    localparam logic TIMEOUT_LFSR = (RX_TIMEOUT_CLKS == (1 << 20));
    localparam logic [TIMEOUT_W-1:0] TIMEOUT_LAST = TIMEOUT_LFSR
        ? TIMEOUT_W'(20'h80000) : TIMEOUT_W'(RX_TIMEOUT_CLKS-1);

    typedef enum logic [2:0] {
        S_RX, S_CLEAR, S_CMD1, S_ACT1, S_CMD2, S_ACT2, S_TX
    } state_e;

    state_e state_q, state_d;
    req_t req_q, req_d;
    action_e action1_q, action1_d, action2_q, action2_d;
    logic [BYTE_W-1:0] byte_q, byte_d;
    logic [TIMEOUT_W-1:0] timeout_q, timeout_d;
    rsp_t rsp;

    // No response storage: the request and strobed actions remain fixed throughout S_TX.
    assign rsp = {req_q.index, req_q.item1, 6'b0, action1_q,
                  req_q.item2, 6'b0, action2_q, 16'b0};

    always_comb begin
        state_d = state_q;
        req_d = req_q;
        action1_d = action1_q;
        action2_d = action2_q;
        byte_d = byte_q;
        timeout_d = timeout_q;
        cmd_valid = 1'b0;
        cmd_clear = 1'b0;
        cmd_item_sel = SEL_A;
        cmd_eval = (req_q.index >= WARMUP_END);
        cmd_price = '0;
        tx_valid = 1'b0;
        tx_data = rsp[$bits(rsp_t)-1 - 8*byte_q -: 8];

        case (state_q)
            S_RX: begin
                if (rx_valid) begin
                    req_d = {req_q[$bits(req_t)-9:0], rx_data};
                    timeout_d = '0;
                    if (byte_q == BYTE_W'(PKT_BYTES-1)) begin
                        byte_d = '0;
                        // Test the completed request, including the eighth shifted byte.
                        state_d = (req_d.index == '0) ? S_CLEAR : S_CMD1;
                    end else begin
                        byte_d = byte_q + 1'b1;
                    end
                end else if ((RX_TIMEOUT_CLKS != 0) && (byte_q != '0)) begin
                    if (timeout_q == TIMEOUT_LAST) begin
                        byte_d = '0;
                        timeout_d = '0;
                    end else begin
                        if (TIMEOUT_LFSR) begin
                            // Left-shift XOR taps [19,16]: 2^20-1 nonzero states.
                            // Inject 1 from the zero seed, then stop at 0x80000:
                            // exactly 2^20 quiet clocks, including the expiry edge.
                            timeout_d = timeout_q << 1;
                            timeout_d[0] = (^(timeout_q & TIMEOUT_W'(20'h90000)))
                                           | (timeout_q == '0);
                        end else begin
                            timeout_d = timeout_q + 1'b1;
                        end
                    end
                end
            end
            S_CLEAR: begin
                cmd_valid = !rst;
                cmd_clear = 1'b1;
                if (cmd_ready) state_d = S_CMD1;
            end
            S_CMD1: begin
                cmd_valid = !rst;
                cmd_item_sel = (req_q.item1 == ITEM_B) ? SEL_B : SEL_A;
                cmd_price = req_q.price1;
                if (cmd_ready) state_d = S_ACT1;
            end
            S_ACT1: if (act_valid) begin
                action1_d = act;
                state_d = S_CMD2;
            end
            S_CMD2: begin
                cmd_valid = !rst;
                cmd_item_sel = (req_q.item2 == ITEM_B) ? SEL_B : SEL_A;
                cmd_price = req_q.price2;
                if (cmd_ready) state_d = S_ACT2;
            end
            S_ACT2: if (act_valid) begin
                action2_d = act;
                state_d = S_TX;
            end
            S_TX: begin
                tx_valid = !rst;
                if (tx_ready) begin
                    if (byte_q == BYTE_W'(PKT_BYTES-1)) begin
                        byte_d = '0;
                        state_d = S_RX;
                    end else begin
                        byte_d = byte_q + 1'b1;
                    end
                end
            end
            default: begin
                state_d = S_RX;
                byte_d = '0;
                timeout_d = '0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_RX;
            req_q <= '0;
            action1_q <= ACT_NONE;
            action2_q <= ACT_NONE;
            byte_q <= '0;
            timeout_q <= '0;
        end else begin
            state_q <= state_d;
            req_q <= req_d;
            action1_q <= action1_d;
            action2_q <= action2_d;
            byte_q <= byte_d;
            timeout_q <= timeout_d;
        end
    end
endmodule
