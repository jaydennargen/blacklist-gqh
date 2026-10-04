// b1_sva -- B1 (uart_rx -> pkt_ctrl) checks on the uart_rx side, bound into every uart_rx.
// Contract: docs/ARCHITECTURE.md §3 (B1); assertion list §7. Simulation only.
// The pkt_ctrl side of B1 (which strobes are taken) is in pkt_ctrl_sva.sv.
`include "gqh_sva.svh"

module b1_sva (
    input logic       clk,
    input logic       rst,       // synchronous, active-high
    input logic [7:0] rx_data,   // valid on the rx_valid cycle only
    input logic       rx_valid   // 1-cycle strobe per good frame
);
    // ---- protocol
    // Checked from the second cycle of rst: a registered output needs one clock of synchronous
    // reset before it reads 0.
    a_valid_low_in_rst: assert property (@(posedge clk) rst ##1 rst |-> !rx_valid)
        else $error("a_valid_low_in_rst: rx_valid=1 while rst");
    `GQH_COVER(c_valid_low_in_rst, rst ##1 rst)

    a_rx_strobe_1cycle: assert property (@(posedge clk) disable iff (rst) rx_valid |=> !rx_valid)
        else $error("a_rx_strobe_1cycle: rx_valid high for two cycles");
    a_rx_data_known: assert property (@(posedge clk) disable iff (rst) rx_valid |-> !$isunknown(rx_data))
        else $error("a_rx_data_known: rx_data has X/Z on the rx_valid cycle");
    `GQH_COVER(c_rx_strobe, !rst && rx_valid)

    final begin
        if ($test$plusargs("REQUIRE_COVERS")) begin
            `GQH_COVER_REQUIRED(c_valid_low_in_rst)
            `GQH_COVER_REQUIRED(c_rx_strobe)
        end
    end
endmodule

// The bind sits in a module because Questa does not elaborate a bind at file scope (vlog-2650).
// tools/run.py loads b1_bind as an extra top when the test instantiates uart_rx.
module b1_bind;
    bind uart_rx b1_sva u_b1_sva (.*);
endmodule
