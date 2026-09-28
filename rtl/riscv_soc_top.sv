`include "rv32i_types.svh"
// =============================================================================
// riscv_soc_top - full RV32I core + memories + memory-mapped vector coprocessor
//
//     0x0000_0000 - 0x0000_FFFF   data SRAM        (64 KB)
//     0x4000_0000 - 0x4000_07FF   vec_coproc       (2 KB register window)   [COPROC_BASE]
//     anything else               unmapped: reads 0, writes ignored
//
// Coprocessor accesses are WORD only: sw is accepted, sb/sh are ignored (loads of any
// size just read the word and the core's load unit extracts the bytes).
// Software builds the base address with:   lui x10, 0x40000
// =============================================================================
module riscv_soc_top #(
    parameter logic [31:0] COPROC_BASE = 32'h4000_0000       // 2 KB aligned
)(
    input  logic       clk, rst,
    output logic       trap, halted,
    output logic [4:0] trap_cause,
    output logic [`RV_RVFI_W-1:0] rvfi
);
    logic [31:0] imem_addr, instruction;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata, RD_dmem, RD_cp;
    logic [3:0]  dmem_be;
    logic        dmem_we, dmem_re;
    logic        cp_sel, sram_sel;

    rv32i_core u_core (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(instruction),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
        .trap(trap), .halted(halted), .trap_cause(trap_cause), .rvfi(rvfi)
    );

    ins_mem ins_mem2 (.addr(imem_addr), .instruction(instruction));

    // ---- data-bus address decode
    assign cp_sel   = (dmem_addr[31:11] == COPROC_BASE[31:11]);
    assign sram_sel = (dmem_addr[31:16] == 16'h0000);

    data_mem data_mem8 (
        .clk(clk), .memwrite(dmem_we & sram_sel), .be(dmem_be),
        .A(dmem_addr), .WD(dmem_wdata), .RD(RD_dmem)
    );

    vec_coproc u_vec (
        .clk(clk), .rst(rst),
        .sel(cp_sel), .we(dmem_we & (dmem_be == 4'b1111)),
        .addr(dmem_addr[10:0]), .wdata(dmem_wdata), .rdata(RD_cp)
    );

    assign dmem_rdata = cp_sel ? RD_cp : (sram_sel ? RD_dmem : 32'd0);
endmodule
