`timescale 1ns/1ps
`include "rv32i_types.svh"
// =============================================================================
// riscv_soc_tb - integration test: the full RV32I core runs soc/soc_prog.S and drives the
// vector coprocessor with ordinary loads / stores (base 0x4000_0000 built with lui).
//
// Checks the core's registers, the coprocessor's internal state, the address decode
// (SRAM vs coprocessor vs unmapped) and the sub-word access policy (coprocessor is word-only).
//
// Run from a folder containing ins_little_endian.hex built from soc/soc_prog.S,
// or pass  +HEX=<file>.
// =============================================================================
module riscv_soc_tb;

    localparam time CLK_PERIOD = 10;

    logic clk = 0, rst = 1;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic       trap, halted;
    logic [4:0] trap_cause;
    logic [`RV_RVFI_W-1:0] rvfi;

    riscv_soc_top dut (.clk(clk), .rst(rst), .trap(trap), .halted(halted),
                       .trap_cause(trap_cause), .rvfi(rvfi));

    integer errors = 0, checks = 0;

    task automatic check_eq(input logic [31:0] got, input logic [31:0] exp, input string msg);
        begin
            checks = checks + 1;
            if (got === exp) $display("[PASS] %-52s = 0x%08h (%0d)", msg, got, got);
            else begin
                errors = errors + 1;
                $display("[FAIL] %-52s = 0x%08h, expected 0x%08h", msg, got, exp);
            end
        end
    endtask

    // ------------------------------------------- bus trace of coprocessor accesses
    integer cp_wr_all = 0, cp_wr_word = 0, sram_wr = 0;
    logic [31:0] sram_a [0:7];
    logic [31:0] sram_d [0:7];

    always @(posedge clk) begin
        if (!rst && !halted) begin
            if (dut.cp_sel && dut.dmem_we) begin
                cp_wr_all = cp_wr_all + 1;
                if (dut.dmem_be == 4'b1111) begin
                    cp_wr_word = cp_wr_word + 1;
                    $display("[BUS %0t] pc=%03h  CPU -> COPROC  write off=0x%03h data=0x%08h",
                             $time, dut.u_core.pc[11:0], dut.dmem_addr[10:0], dut.dmem_wdata);
                end
                else
                    $display("[BUS %0t] pc=%03h  CPU -> COPROC  SUB-WORD write off=0x%03h be=%b  (ignored by the coprocessor)",
                             $time, dut.u_core.pc[11:0], dut.dmem_addr[10:0], dut.dmem_be);
            end
            else if (dut.cp_sel && dut.dmem_re)
                $display("[BUS %0t] pc=%03h  CPU <- COPROC  read  off=0x%03h data=0x%08h",
                         $time, dut.u_core.pc[11:0], dut.dmem_addr[10:0], dut.RD_cp);
            if (dut.data_mem8.memwrite) begin
                if (sram_wr < 8) begin sram_a[sram_wr] = dut.data_mem8.A; sram_d[sram_wr] = dut.data_mem8.WD; end
                sram_wr = sram_wr + 1;
                $display("[SRAM %0t] pc=%03h write addr=0x%08h be=%b data=0x%08h",
                         $time, dut.u_core.pc[11:0], dut.data_mem8.A, dut.data_mem8.be, dut.data_mem8.WD);
            end
        end
    end

    // completion of a coprocessor command
    logic busy_q = 0, done_q = 0;
    always @(posedge clk) begin
        busy_q <= dut.u_vec.busy;
        done_q <= dut.u_vec.done;
        if (dut.u_vec.busy && !busy_q) $display("[VEC %0t] EXEC start  op=%0d vd=v%0d vs1=v%0d vs2=v%0d vl=%0d",
                                                $time, dut.u_vec.op_r, dut.u_vec.vd_r, dut.u_vec.vs1_r,
                                                dut.u_vec.vs2_r, dut.u_vec.vl_r);
        if (dut.u_vec.done && !done_q) $display("[VEC %0t] DONE       err=%b result=0x%08h",
                                                $time, dut.u_vec.err, dut.u_vec.result_r);
    end

    // ---------------------------------------------------------------- main
    integer cyc = 0;
    initial begin
        $timeformat(-9, 0, " ns", 8);
        if ($test$plusargs("VCD")) begin $dumpfile("riscv_soc.vcd"); $dumpvars(0, riscv_soc_tb); end

        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;

        while (!halted && cyc < 3000) begin @(negedge clk); cyc = cyc + 1; end
        repeat (2) @(posedge clk);
        if (!halted) begin
            errors = errors + 1;
            $display("[FAIL] TIMEOUT - program never reached its ECALL, pc=0x%08h", dut.u_core.pc);
        end

        $display("\n=== how the program ended ===");
        check_eq(halted,      1,  "core halted");
        check_eq(trap_cause, 11,  "trap cause = ECALL (clean end of test)");

        $display("\n=== core register results ===");
        check_eq(dut.u_core.reg_file4.regfile[10], 32'h4000_0000, "x10 coprocessor base (lui 0x40000)");
        check_eq(dut.u_core.reg_file4.regfile[4],  32'd11,  "x4  v3[0] read back over the bus (1+10)");
        check_eq(dut.u_core.reg_file4.regfile[5],  32'd22,  "x5  v3[1] (2+20)");
        check_eq(dut.u_core.reg_file4.regfile[6],  32'd33,  "x6  v3[2] (3+30)");
        check_eq(dut.u_core.reg_file4.regfile[7],  32'd44,  "x7  v3[3] (4+40)");
        check_eq(dut.u_core.reg_file4.regfile[2],  32'd2,   "x2  last STATUS poll = DONE");
        check_eq(dut.u_core.reg_file4.regfile[8],  32'd110, "x8  REDSUM(v3) = 11+22+33+44");
        check_eq(dut.u_core.reg_file4.regfile[9],  32'd6,   "x9  STATUS after illegal op = DONE|ERR");
        check_eq(dut.u_core.reg_file4.regfile[13], 32'd1,   "x13 v1[0] survived an ignored sb");
        check_eq(dut.u_core.reg_file4.regfile[16], 32'd2,   "x16 v1[1] survived an ignored sh");
        check_eq(dut.u_core.reg_file4.regfile[14], 32'd6,   "x14 lbu STATUS byte 0");
        check_eq(dut.u_core.reg_file4.regfile[15], 32'd0,   "x15 lbu STATUS byte 1");
        check_eq(dut.u_core.reg_file4.regfile[17], 32'd6,   "x17 lh  STATUS low halfword");
        check_eq(dut.u_core.reg_file4.regfile[11], 32'd55,  "x11 add of two results");
        check_eq(dut.u_core.reg_file4.regfile[12], 32'd55,  "x12 SRAM word store/load round trip");
        check_eq(dut.u_core.reg_file4.regfile[23], 32'h56,  "x23 SRAM lbu of byte 1 of 0x12345678");
        check_eq(dut.u_core.reg_file4.regfile[24], 32'h1234,"x24 SRAM lh of the upper half");
        check_eq(dut.u_core.reg_file4.regfile[25], 32'h5534_5678, "x25 SRAM after sb into byte 3");
        check_eq(dut.u_core.reg_file4.regfile[21], 32'd0,   "x21 unmapped read returns 0");

        $display("\n=== coprocessor internal state ===");
        check_eq(dut.u_vec.u_vrf.vr[1][31:0],    32'd1,  "v1[0]");
        check_eq(dut.u_vec.u_vrf.vr[1][63:32],   32'd2,  "v1[1]");
        check_eq(dut.u_vec.u_vrf.vr[1][127:96],  32'd4,  "v1[3]");
        check_eq(dut.u_vec.u_vrf.vr[2][31:0],    32'd10, "v2[0]");
        check_eq(dut.u_vec.u_vrf.vr[2][127:96],  32'd40, "v2[3]");
        check_eq(dut.u_vec.u_vrf.vr[3][31:0],    32'd11, "v3[0]");
        check_eq(dut.u_vec.u_vrf.vr[3][63:32],   32'd22, "v3[1]");
        check_eq(dut.u_vec.u_vrf.vr[3][95:64],   32'd33, "v3[2]");
        check_eq(dut.u_vec.u_vrf.vr[3][127:96],  32'd44, "v3[3]");
        check_eq(dut.u_vec.result_r, 32'd110, "RESULT register");
        check_eq({29'd0, dut.u_vec.err, dut.u_vec.done, dut.u_vec.busy}, 32'b110, "STATUS = ERR|DONE|!BUSY");

        $display("\n=== address decode ===");
        check_eq(cp_wr_all,  19, "stores aimed at the coprocessor (17 word + sb + sh)");
        check_eq(cp_wr_word, 17, "of which word stores accepted");
        check_eq(sram_wr,     3, "stores that reached the data SRAM (sw, sw, sb; NOT the unmapped sw)");
        check_eq(sram_a[0], 32'h0000_0000, "SRAM store #1 address");
        check_eq(sram_d[0], 32'd55,        "SRAM store #1 data");
        check_eq(sram_a[1], 32'h0000_0100, "SRAM store #2 address");
        check_eq(sram_d[1], 32'h1234_5678, "SRAM store #2 data");
        check_eq(sram_a[2], 32'h0000_0103, "SRAM store #3 (sb) byte address on the bus");
        check_eq(sram_d[2], 32'h5555_5555, "SRAM store #3 (sb) data replicated into every lane");
        check_eq(dut.u_vec.u_vrf.vr[0][31:0], 32'd0, "coprocessor v0[0] untouched by SRAM stores");

        $display("\n=============================================");
        $display(" checks run : %0d", checks);
        $display(" errors     : %0d", errors);
        if (errors == 0) $display(" TEST PASSED");
        else             $display(" TEST FAILED");
        $display("=============================================\n");
        $finish;
    end
endmodule
