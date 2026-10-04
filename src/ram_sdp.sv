// ram_sdp -- simple dual-port RAM, one clock: synchronous write, registered read (data one clock
// after the address). Not reset: the user must not depend on a word it has not written.
// A read and a write of the same address in the same cycle: the write takes effect, the value
// read that cycle is not defined; ma_engine never uses it. DECISIONS D20.
module ram_sdp #(
    parameter int unsigned AW = 5,  // address bits
    parameter int unsigned DW = 1   // data bits
) (
    input  logic          clk,
    input  logic          we,       // write enable
    input  logic [AW-1:0] wa,       // write address
    input  logic [DW-1:0] wd,       // write data
    input  logic [AW-1:0] ra,       // read address
    output logic [DW-1:0] rd        // mem[ra] of the previous clock
);
    // Synthesis attribute (DECISIONS D20): without it GowinSynthesis V1.9.11.03 builds a RAM this
    // small from RAM16 shadow RAM plus LUTs, which count as logic; block RAM does not (D19).
    logic [DW-1:0] mem [2**AW] /* synthesis syn_ramstyle = "block_ram" */;

    always_ff @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
endmodule
