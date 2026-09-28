`include "rv32i_types.svh"
// =============================================================================
// sgle_cyc_processor - your original top: core + instruction memory + data memory
// (same name and clk/rst ports as before; the trace / status ports are new outputs,
// leave them unconnected if you don't need them)
// =============================================================================
module sgle_cyc_processor(
    input  logic       clk, rst,
    output logic       trap, halted,
    output logic [4:0] trap_cause,
    output logic [`RV_RVFI_W-1:0] rvfi
);
    logic [31:0] imem_addr, instruction;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_be;
    logic        dmem_we, dmem_re;

    rv32i_core u_core (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(instruction),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
        .trap(trap), .halted(halted), .trap_cause(trap_cause), .rvfi(rvfi)
    );

    ins_mem ins_mem2 (.addr(imem_addr), .instruction(instruction));

    data_mem data_mem8 (
        .clk(clk), .memwrite(dmem_we), .be(dmem_be),
        .A(dmem_addr), .WD(dmem_wdata), .RD(dmem_rdata)
    );
endmodule
