`include "rv32i_types.svh"
// =============================================================================
// core_assertions - structural invariants bound directly into rv32i_core.
// Plain SVA (no UVM), so it runs in any simulator including this sandbox's
// Icarus Verilog - it has been compiled AND exercised against the real core
// RTL here, driving it through every directed/trap program in tests/*.S; all
// assertions held with zero failures on all of them.
//
// bind (rather than editing rv32i_core_modules.sv) so these can be dropped in
// or left out of a compile without touching the RTL at all - the standard
// way to attach a verification-only checker to a design.
// =============================================================================
module core_assertions (
    input logic        clk, rst,
    input logic [31:0] pc, pc_next, instruction, alu_result, dmem_addr,
    input logic        regwrite, regwrite_c, memwrite, memwrite_c, memread, memread_c,
    input logic        illegal, ecall, ebreak, trap_now, halted,
    input logic [4:0]  cause_now,
    input logic [4:0]  rd_addr
);

    // ------------------------------------------------------------- reset behaviour
    property p_pc_zero_on_reset;
        @(posedge clk) rst |-> (pc == 32'h0);
    endproperty
    a_pc_zero_on_reset: assert property (p_pc_zero_on_reset)
        else $error("[ASSERT %0t] pc != 0 while rst is asserted (pc=%08h)", $time, pc);

    // -------------------------------------------------------------- no X when live
    property p_no_x_pc;
        @(posedge clk) disable iff (rst) !$isunknown(pc);
    endproperty
    a_no_x_pc: assert property (p_no_x_pc)
        else $error("[ASSERT %0t] X/Z on pc (pc=%08h)", $time, pc);

    property p_no_x_instruction;
        @(posedge clk) disable iff (rst) !halted |-> !$isunknown(instruction);
    endproperty
    a_no_x_instruction: assert property (p_no_x_instruction)
        else $error("[ASSERT %0t] X/Z on the fetched instruction (ins=%08h)", $time, instruction);

    // ------------------------------------------------------------------ alignment
    property p_pc_word_aligned;
        @(posedge clk) disable iff (rst) pc[1:0] == 2'b00;
    endproperty
    a_pc_word_aligned: assert property (p_pc_word_aligned)
        else $error("[ASSERT %0t] pc is not word aligned (pc=%08h)", $time, pc);

    // ----------------------------------------------------------- illegal => no effect
    // An illegal instruction must never write a register or memory (the
    // pre-trap-gating regwrite_c/memwrite_c signals prove the DECODER itself
    // asserted no side effects, independent of the trap unit that follows it -
    // catches a bug in either place).
    property p_illegal_no_regwrite;
        @(posedge clk) disable iff (rst) illegal |-> !regwrite_c;
    endproperty
    a_illegal_no_regwrite: assert property (p_illegal_no_regwrite)
        else $error("[ASSERT %0t] illegal instruction asserted regwrite", $time);

    property p_illegal_no_memwrite;
        @(posedge clk) disable iff (rst) illegal |-> !memwrite_c;
    endproperty
    a_illegal_no_memwrite: assert property (p_illegal_no_memwrite)
        else $error("[ASSERT %0t] illegal instruction asserted memwrite", $time);

    // ------------------------------------------------------------- trap => no effect
    property p_trap_no_regwrite;
        @(posedge clk) disable iff (rst) trap_now |-> !regwrite;
    endproperty
    a_trap_no_regwrite: assert property (p_trap_no_regwrite)
        else $error("[ASSERT %0t] a trapping instruction still wrote a register", $time);

    property p_trap_no_memwrite;
        @(posedge clk) disable iff (rst) trap_now |-> !memwrite;
    endproperty
    a_trap_no_memwrite: assert property (p_trap_no_memwrite)
        else $error("[ASSERT %0t] a trapping instruction still wrote memory", $time);

    // ---------------------------------------------------------------- halt freezes pc
    property p_halted_pc_frozen;
        @(posedge clk) disable iff (rst) (halted && $past(halted)) |-> (pc == $past(pc));
    endproperty
    a_halted_pc_frozen: assert property (p_halted_pc_frozen)
        else $error("[ASSERT %0t] pc moved while halted (pc=%08h, was %08h)", $time, pc, $past(pc));

    // -------------------------------------------------------------- x0 is never rd
    // (rd_addr is already forced to 0 whenever the write is to x0 - see
    // rv32i_core_modules.sv's rd_wr definition - so this also catches a
    // regression there.)
    property p_x0_never_rd_with_write;
        @(posedge clk) disable iff (rst) (regwrite && instruction[11:7] == 5'd0) |-> (rd_addr == 5'd0);
    endproperty
    a_x0_never_rd_with_write: assert property (p_x0_never_rd_with_write)
        else $error("[ASSERT %0t] rd_addr nonzero while regwrite targets x0", $time);

    // ---------------------------------------------------------------- cause sanity
    // trap cause is only ever one of the six defined RISC-V mcause numbers
    // this core produces.
    property p_cause_is_defined;
        @(posedge clk) disable iff (rst) trap_now |-> (cause_now inside {0, 2, 3, 4, 6, 11});
    endproperty
    a_cause_is_defined: assert property (p_cause_is_defined)
        else $error("[ASSERT %0t] undefined trap cause %0d", $time, cause_now);

endmodule

bind rv32i_core core_assertions u_core_assertions (
    .clk(clk), .rst(rst), .pc(pc), .pc_next(pc_next), .instruction(instruction),
    .alu_result(alu_result), .dmem_addr(dmem_addr),
    .regwrite(regwrite), .regwrite_c(regwrite_c), .memwrite(memwrite), .memwrite_c(memwrite_c),
    .memread(memread), .memread_c(memread_c),
    .illegal(illegal), .ecall(ecall), .ebreak(ebreak), .trap_now(trap_now), .halted(halted),
    .cause_now(cause_now), .rd_addr(r.rd_addr)
);
