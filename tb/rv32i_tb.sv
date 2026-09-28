`timescale 1ns/1ps
`include "rv32i_types.svh"
// =============================================================================
// rv32i_tb - lockstep testbench for the full RV32I core.
//
//   Every instruction the DUT retires (rvfi.valid) is executed by the reference model
//   (rv32i_iss) and EVERY field of the retire record is compared:
//     pc before / after, instruction word, rs1/rs2 addresses + values, rd address + value,
//     memory address / byte masks / read + write data, trap + cause, retire order.
//   At the end the 32 registers, the PC and the whole data memory are compared too.
//
//   Program:  +HEX=<file>   (default ./ins_little_endian.hex)     data init: +DHEX=<file>
//   Options:  +QUIET        no per-instruction trace
//             +STOP_PC=<hex> end the test when the PC reaches this value (for programs that end
//                            in a `jal x0,0` loop instead of ECALL)
//             +MAXCYC=<n>   timeout in cycles (default 200000)
//             +COV          print instruction-coverage counts (COV name count)
//             +EXPECT_CAUSE=<n>  the test must end with this trap cause
//   Machine-readable result lines for scripts:  FINAL / REG / MEM / RESULT
// =============================================================================
module rv32i_tb;

    localparam time CLK_PERIOD = 10;

    logic  clk = 0, rst = 1;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------- DUT + model
    logic       trap, halted;
    logic [4:0] trap_cause;
    logic [`RV_RVFI_W-1:0] rvfi_bus;
    rvfi_t      rvfi;
    assign rvfi = rvfi_bus;

    sgle_cyc_processor dut (.clk(clk), .rst(rst), .trap(trap), .halted(halted),
                            .trap_cause(trap_cause), .rvfi(rvfi_bus));
    rv32i_iss          iss ();

    // ---------------------------------------------------------------- options
    bit     quiet = 0, cov_en = 0, stop_en = 0, expect_en = 0;
    integer maxcyc = 200000;
    logic [31:0] stop_pc = 0;
    integer expect_cause = 0;

    // ------------------------------------------------------------ bookkeeping
    integer errors = 0;
    integer retired = 0;
    integer cyc = 0;
    integer cov [0:40];
    integer cause_seen = -1;
    bit     done = 0;
    integer k;

    // ------------------------------------------------- instruction classification
    // 0 lui 1 auipc 2 jal 3 jalr 4 beq 5 bne 6 blt 7 bge 8 bltu 9 bgeu 10 lb 11 lh 12 lw 13 lbu 14 lhu
    // 15 sb 16 sh 17 sw 18 addi 19 slti 20 sltiu 21 xori 22 ori 23 andi 24 slli 25 srli 26 srai
    // 27 add 28 sub 29 sll 30 slt 31 sltu 32 xor 33 srl 34 sra 35 or 36 and 37 fence 38 ecall 39 ebreak 40 illegal
    function automatic integer iclass(input logic [31:0] i);
        logic [6:0] op, f7;
        logic [2:0] f3;
        begin
            op = i[6:0];  f3 = i[14:12];  f7 = i[31:25];
            iclass = 40;
            if (i[1:0] == 2'b11)
                case (op)
                    7'b0110111: iclass = 0;
                    7'b0010111: iclass = 1;
                    7'b1101111: iclass = 2;
                    7'b1100111: if (f3 == 0) iclass = 3;
                    7'b1100011: case (f3) 0: iclass = 4; 1: iclass = 5; 4: iclass = 6; 5: iclass = 7; 6: iclass = 8; 7: iclass = 9; default: ; endcase
                    7'b0000011: case (f3) 0: iclass = 10; 1: iclass = 11; 2: iclass = 12; 4: iclass = 13; 5: iclass = 14; default: ; endcase
                    7'b0100011: case (f3) 0: iclass = 15; 1: iclass = 16; 2: iclass = 17; default: ; endcase
                    7'b0010011: case (f3)
                                    0: iclass = 18;  2: iclass = 19;  3: iclass = 20;  4: iclass = 21;  6: iclass = 22;  7: iclass = 23;
                                    1: if (f7 == 7'b0000000) iclass = 24;
                                    5: if (f7 == 7'b0000000) iclass = 25; else if (f7 == 7'b0100000) iclass = 26;
                                    default: ;
                                endcase
                    7'b0110011: if (f7 == 7'b0000000)
                                    case (f3) 0: iclass = 27; 1: iclass = 29; 2: iclass = 30; 3: iclass = 31; 4: iclass = 32; 5: iclass = 33; 6: iclass = 35; 7: iclass = 36; default: ; endcase
                                else if (f7 == 7'b0100000 && f3 == 0) iclass = 28;
                                else if (f7 == 7'b0100000 && f3 == 5) iclass = 34;
                    7'b0001111: if (f3 == 0) iclass = 37;
                    7'b1110011: if (i == 32'h00000073) iclass = 38; else if (i == 32'h00100073) iclass = 39;
                    default: ;
                endcase
        end
    endfunction

    task automatic iname(input integer c, output logic [8*8-1:0] s);
        begin
            case (c)
                0: s = "lui";    1: s = "auipc";  2: s = "jal";    3: s = "jalr";   4: s = "beq";    5: s = "bne";
                6: s = "blt";    7: s = "bge";    8: s = "bltu";   9: s = "bgeu";  10: s = "lb";    11: s = "lh";
               12: s = "lw";    13: s = "lbu";   14: s = "lhu";   15: s = "sb";    16: s = "sh";    17: s = "sw";
               18: s = "addi";  19: s = "slti";  20: s = "sltiu"; 21: s = "xori";  22: s = "ori";   23: s = "andi";
               24: s = "slli";  25: s = "srli";  26: s = "srai";  27: s = "add";   28: s = "sub";   29: s = "sll";
               30: s = "slt";   31: s = "sltu";  32: s = "xor";   33: s = "srl";   34: s = "sra";   35: s = "or";
               36: s = "and";   37: s = "fence"; 38: s = "ecall"; 39: s = "ebreak"; default: s = "illegal";
            endcase
        end
    endtask

    // ----------------------------------------------------------- disassembler
    localparam int TXT = 8*40;
    task automatic disasm(input logic [31:0] i, output logic [TXT-1:0] s);
        integer c;
        logic [8*8-1:0] nm;
        integer imm_i, imm_s, imm_b, imm_j;
        logic [4:0] rd, rs1, rs2;
        begin
            c = iclass(i);
            iname(c, nm);
            rd = i[11:7];  rs1 = i[19:15];  rs2 = i[24:20];
            imm_i = $signed(i[31:20]);
            imm_s = $signed({i[31:25], i[11:7]});
            imm_b = $signed({i[31], i[7], i[30:25], i[11:8], 1'b0});
            imm_j = $signed({i[31], i[19:12], i[20], i[30:21], 1'b0});
            if      (c == 0 || c == 1)   $sformat(s, "%0s x%0d,0x%0h", nm, rd, i[31:12]);
            else if (c == 2)             $sformat(s, "%0s x%0d,%0d", nm, rd, imm_j);
            else if (c == 3)             $sformat(s, "%0s x%0d,%0d(x%0d)", nm, rd, imm_i, rs1);
            else if (c >= 4  && c <= 9)  $sformat(s, "%0s x%0d,x%0d,%0d", nm, rs1, rs2, imm_b);
            else if (c >= 10 && c <= 14) $sformat(s, "%0s x%0d,%0d(x%0d)", nm, rd, imm_i, rs1);
            else if (c >= 15 && c <= 17) $sformat(s, "%0s x%0d,%0d(x%0d)", nm, rs2, imm_s, rs1);
            else if (c >= 24 && c <= 26) $sformat(s, "%0s x%0d,x%0d,%0d", nm, rd, rs1, rs2);
            else if (c >= 18 && c <= 23) $sformat(s, "%0s x%0d,x%0d,%0d", nm, rd, rs1, imm_i);
            else if (c >= 27 && c <= 36) $sformat(s, "%0s x%0d,x%0d,x%0d", nm, rd, rs1, rs2);
            else if (c >= 37 && c <= 39) $sformat(s, "%0s", nm);
            else                         $sformat(s, "illegal 0x%08h", i);
        end
    endtask

    // ------------------------------------------------------------ comparators
    function automatic logic [31:0] bmask(input logic [3:0] m);
        bmask = {{8{m[3]}}, {8{m[2]}}, {8{m[1]}}, {8{m[0]}}};
    endfunction

    task automatic cmp(input string what, input logic [63:0] got, input logic [63:0] exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("[FAIL %0t] retire #%0d: %s  dut=0x%0h  model=0x%0h", $time, retired, what, got, exp);
            end
        end
    endtask

    // ---------------------------------------------------- lockstep checker
    logic [TXT-1:0] dtxt;
    logic [8*40-1:0] eff, meff;
    integer e_before;

    always @(posedge clk) begin
        if (!rst && rvfi.valid) begin
            e_before = errors;
            iss.step;

            cmp("order",     rvfi.order,     retired);
            cmp("insn",      rvfi.insn,      iss.o_insn);
            cmp("pc_rdata",  rvfi.pc_rdata,  iss.o_pc_rdata);
            cmp("pc_wdata",  rvfi.pc_wdata,  iss.o_pc_wdata);
            cmp("trap",      rvfi.trap,      iss.o_trap);
            cmp("halt",      rvfi.halt,      iss.o_trap);
            if (iss.o_trap) cmp("cause", rvfi.cause, iss.o_cause);
            cmp("rs1_addr",  rvfi.rs1_addr,  iss.o_rs1_addr);
            cmp("rs2_addr",  rvfi.rs2_addr,  iss.o_rs2_addr);
            cmp("rs1_rdata", rvfi.rs1_rdata, iss.o_rs1_rdata);
            cmp("rs2_rdata", rvfi.rs2_rdata, iss.o_rs2_rdata);
            cmp("rd_addr",   rvfi.rd_addr,   iss.o_rd_addr);
            cmp("rd_wdata",  rvfi.rd_wdata,  iss.o_rd_wdata);
            cmp("mem_addr",  rvfi.mem_addr,  iss.o_mem_addr);
            cmp("mem_rmask", rvfi.mem_rmask, iss.o_rmask);
            cmp("mem_wmask", rvfi.mem_wmask, iss.o_wmask);
            cmp("mem_rdata", rvfi.mem_rdata & bmask(iss.o_rmask), iss.o_mem_rdata & bmask(iss.o_rmask));
            cmp("mem_wdata", rvfi.mem_wdata & bmask(iss.o_wmask), iss.o_mem_wdata & bmask(iss.o_wmask));
            if ($isunknown(rvfi)) begin
                errors = errors + 1;
                $display("[FAIL %0t] retire #%0d: X/Z somewhere in the retire record", $time, retired);
            end

            // instruction coverage
            if (rvfi.trap) begin
                cause_seen = rvfi.cause;
                if (cov_en) cov[iclass(rvfi.insn)] = cov[iclass(rvfi.insn)] + 1;
            end
            else
                cov[iclass(rvfi.insn)] = cov[iclass(rvfi.insn)] + 1;

            if (!quiet) begin
                disasm(rvfi.insn, dtxt);
                if (rvfi.trap)                $sformat(eff, "TRAP cause=%0d", rvfi.cause);
                else if (rvfi.rd_addr != 0)   $sformat(eff, "x%0d<=%08h", rvfi.rd_addr, rvfi.rd_wdata);
                else                          eff = "";
                if (rvfi.mem_wmask != 0)      $sformat(meff, "mem[%08h]/%b<=%08h", rvfi.mem_addr, rvfi.mem_wmask, rvfi.mem_wdata);
                else if (rvfi.mem_rmask != 0) $sformat(meff, "mem[%08h]/%b", rvfi.mem_addr, rvfi.mem_rmask);
                else                          meff = "";
                $display("[RET %4d] pc=%08h %08h %0s   %0s %0s", retired, rvfi.pc_rdata, rvfi.insn, dtxt, eff, meff);
            end
            if (errors != e_before && !quiet) $display("           ^^^^ mismatch on this instruction");

            retired = retired + 1;
        end
    end

    // ----------------------------------- always-on protocol / structural checks
    always @(posedge clk) if (!rst) begin
        if (dut.u_core.reg_file4.regfile[0] !== 32'd0) begin
            errors = errors + 1;  $display("[FAIL %0t] x0 was written", $time);
        end
        if (!halted && $isunknown(dut.u_core.pc)) begin
            errors = errors + 1;  $display("[FAIL %0t] PC is X/Z", $time);
        end
        if (!halted && dut.u_core.pc[1:0] != 2'b00) begin
            errors = errors + 1;  $display("[FAIL %0t] PC is not word aligned: %h", $time, dut.u_core.pc);
        end
    end

    // ------------------------------------------------------------------ main
    logic [63:0] tmp;
    integer ii;
    initial begin
        $timeformat(-9, 0, " ns", 8);
        if ($test$plusargs("QUIET")) quiet = 1;
        if ($test$plusargs("COV"))   cov_en = 1;
        if ($value$plusargs("MAXCYC=%d", maxcyc)) ;
        if ($value$plusargs("STOP_PC=%h", stop_pc)) stop_en = 1;
        if ($value$plusargs("EXPECT_CAUSE=%d", expect_cause)) expect_en = 1;
        for (k = 0; k <= 40; k = k + 1) cov[k] = 0;
        if ($test$plusargs("VCD")) begin
            $dumpfile("rv32i.vcd");
            $dumpvars(0, rv32i_tb);
        end

        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;

        while (!done && cyc < maxcyc) begin
            @(negedge clk);
            cyc = cyc + 1;
            if (halted) done = 1;
            else if (stop_en && dut.u_core.pc == stop_pc) done = 1;
        end
        if (!done) begin
            errors = errors + 1;
            $display("[FAIL] TIMEOUT after %0d cycles (pc=%08h) - program neither trapped nor reached STOP_PC", cyc, dut.u_core.pc);
        end
        repeat (2) @(posedge clk);

        // ---- final architectural state: registers, pc, data memory
        for (ii = 1; ii < 32; ii = ii + 1)
            if (dut.u_core.reg_file4.regfile[ii] !== iss.x[ii]) begin
                errors = errors + 1;
                $display("[FAIL] final x%0d: dut=%08h model=%08h", ii, dut.u_core.reg_file4.regfile[ii], iss.x[ii]);
            end
        if (dut.u_core.pc !== iss.pc) begin
            errors = errors + 1;
            $display("[FAIL] final pc: dut=%08h model=%08h", dut.u_core.pc, iss.pc);
        end
        if (stop_en == 0 && halted !== iss.halted) begin
            errors = errors + 1;
            $display("[FAIL] halted: dut=%b model=%b", halted, iss.halted);
        end
        for (ii = 0; ii < 16384; ii = ii + 1)
            if (dut.data_mem8.mem[ii] !== iss.dmem[ii]) begin
                errors = errors + 1;
                if (errors < 30) $display("[FAIL] final dmem[0x%04h]: dut=%08h model=%08h", ii*4, dut.data_mem8.mem[ii], iss.dmem[ii]);
            end
        if (expect_en && cause_seen != expect_cause) begin
            errors = errors + 1;
            $display("[FAIL] expected the program to end with trap cause %0d, saw %0d", expect_cause, cause_seen);
        end

        // ---- machine readable summary
        $display("FINAL pc=%08h halted=%b cause=%0d retired=%0d cycles=%0d", dut.u_core.pc, halted, cause_seen, retired, cyc);
        for (ii = 1; ii < 32; ii = ii + 1) $display("REG x%0d %08h", ii, dut.u_core.reg_file4.regfile[ii]);
        for (ii = 0; ii < 16384; ii = ii + 1)
            if (dut.data_mem8.mem[ii] !== 32'd0) $display("MEM %08h %08h", ii*4, dut.data_mem8.mem[ii]);
        if (cov_en)
            for (ii = 0; ii <= 40; ii = ii + 1) begin
                iname(ii, tmp[63:0]);
                $display("COV %0s %0d", tmp[63:0], cov[ii]);
            end
        if (errors == 0) $display("RESULT PASS retired=%0d", retired);
        else             $display("RESULT FAIL errors=%0d retired=%0d", errors, retired);
        $finish;
    end
endmodule
