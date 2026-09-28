// =============================================================================
// vec_regfile - NVREG vector registers, each LANES x DW bits (default 8 x 4 x 32)
//
//  Port A (CPU / bus): one 32-bit element at a time  -> memory-mapped window
//  Port B (vector ALU): two full-vector reads + one masked full-vector write
//
//  ALU write has priority over the CPU write. Per-lane write enables let a
//  short vector (VL < LANES) leave the upper lanes of vd untouched.
//  Async active-high reset clears everything to 0 (deterministic sim, and the
//  "reset" test in the testbench can check it). NVREG and LANES: powers of 2.
// =============================================================================
module vec_regfile #(
    parameter int NVREG = 8,
    parameter int LANES = 4,
    parameter int DW    = 32
)(
    input  logic                       clk,
    input  logic                       rst,

    // CPU / bus element port
    input  logic                       cpu_we,
    input  logic [$clog2(NVREG)-1:0]   cpu_vreg,
    input  logic [$clog2(LANES)-1:0]   cpu_lane,
    input  logic [DW-1:0]              cpu_wdata,
    output logic [DW-1:0]              cpu_rdata,

    // ALU read ports
    input  logic [$clog2(NVREG)-1:0]   rs1, rs2,
    output logic [LANES*DW-1:0]        rd1, rd2,

    // ALU write port
    input  logic                       alu_we,
    input  logic [$clog2(NVREG)-1:0]   rd,
    input  logic [LANES-1:0]           lane_en,
    input  logic [LANES*DW-1:0]        wdata
);

    logic [LANES*DW-1:0] vr [0:NVREG-1];

    integer r, l;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (r = 0; r < NVREG; r = r + 1)
                vr[r] <= '0;
        end
        else if (alu_we) begin
            for (l = 0; l < LANES; l = l + 1)
                if (lane_en[l])
                    vr[rd][l*DW +: DW] <= wdata[l*DW +: DW];
        end
        else if (cpu_we) begin
            vr[cpu_vreg][cpu_lane*DW +: DW] <= cpu_wdata;
        end
    end

    assign rd1       = vr[rs1];
    assign rd2       = vr[rs2];
    assign cpu_rdata = vr[cpu_vreg][cpu_lane*DW +: DW];

endmodule
