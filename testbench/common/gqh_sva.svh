// gqh_sva.svh -- cover bookkeeping shared by the bind files in testbench/common/.
// Every assertion has a cover of its trigger (docs/ARCHITECTURE.md §7). A cover that never hits
// means its assertion never evaluated, so a test run with +REQUIRE_COVERS turns it into an error.
`ifndef GQH_SVA_SVH
`define GQH_SVA_SVH

// Named cover with a hit counter. Expects `clk` in scope. Wrap sequences containing commas in ().
`define GQH_COVER(name, seq) \
    int unsigned name``_hits = 0; \
    name: cover property (@(posedge clk) seq) name``_hits++;

// Use inside a final block: reports a cover that never hit.
`define GQH_COVER_REQUIRED(name) \
    if (name``_hits == 0) $error("COVER_ZERO %m.%s", `"name`");

`endif
