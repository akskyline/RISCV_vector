`timescale 1ns/1ps
`include "vec_defs.svh"
// =============================================================================
// vec_coproc_tb - directed + constrained-random, self-checking testbench
//
// The testbench plays the CPU: it drives the memory-mapped bus of the
// coprocessor and compares EVERYTHING it reads back against a behavioural
// reference model (m_v[][], m_result) that is updated in parallel.
//
// Covers (matches the "Basic Verification" bullet of the brief):
//   * reset values, reset in the middle of an operation
//   * every opcode x every vector length 1..LANES x corner + random operands
//   * masked lanes (lanes >= VL must keep their old value)
//   * in-place / aliased operands (vd==vs1, vs1==vs2, vd==vs2)
//   * invalid opcode, invalid VL (incl. values that would alias when truncated)
//   * BUSY / DONE / ERR status protocol, config lock while BUSY, double START
//   * unmapped / out-of-window accesses
//   * 400 random commands (a few % illegal) against the model
// =============================================================================
module vec_coproc_tb;

    localparam int LANES = 4;
    localparam int NVREG = 8;
    localparam time CLK_PERIOD = 10;

    logic        clk, rst;
    logic        sel, we;
    logic [10:0] addr;
    logic [31:0] wdata, rdata;

    vec_coproc #(.LANES(LANES), .NVREG(NVREG)) dut (
        .clk(clk), .rst(rst), .sel(sel), .we(we),
        .addr(addr), .wdata(wdata), .rdata(rdata)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------ bookkeeping
    bit test_done = 0;    // set at the end so the watchdog stays quiet if the sim is resumed after $finish
    int errors = 0;
    int checks = 0;
    bit verbose = 1;

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("[FAIL %0t] %s", $time, msg);
        end
        else if (verbose) $display("[PASS] %s", msg);
    endtask

    task automatic check_eq(input logic [31:0] got, input logic [31:0] exp, input string msg);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("[FAIL %0t] %s : got 0x%08h expected 0x%08h", $time, msg, got, exp);
        end
    endtask

    // ---------------------------------------------------------- bus primitives
    // Tasks are called right after a falling clock edge; the DUT samples on the
    // next rising edge; each access takes exactly one clock.
    task automatic bus_write(input logic [10:0] a, input logic [31:0] d);
        begin
            sel = 1; we = 1; addr = a; wdata = d;
            @(negedge clk);
            sel = 0; we = 0; addr = '0; wdata = '0;
        end
    endtask

    task automatic bus_read(input logic [10:0] a, output logic [31:0] d);
        begin
            sel = 1; we = 0; addr = a;
            #1 d = rdata;                       // combinational read
            @(negedge clk);
            sel = 0; addr = '0;
        end
    endtask

    // ------------------------------------------------------- reference model
    logic [31:0] m_v [0:NVREG-1][0:LANES-1];
    logic [31:0] m_result;

    function automatic logic [31:0] ref_elem(input logic [3:0] op, input logic [31:0] a, input logic [31:0] b);
        case (op)
            `VOP_ADD: ref_elem = a + b;
            `VOP_MUL: ref_elem = a * b;
            `VOP_SLT: ref_elem = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            `VOP_SEQ: ref_elem = (a == b) ? 32'd1 : 32'd0;
            default:  ref_elem = 32'd0;
        endcase
    endfunction

    task automatic model_reset();
        for (int r = 0; r < NVREG; r++)
            for (int l = 0; l < LANES; l++)
                m_v[r][l] = 32'd0;
        m_result = 32'd0;
    endtask

    task automatic model_exec(input int op, input int vd, input int vs1, input int vs2, input int vl);
        logic [31:0] acc;
        begin
            case (op)
                `VOP_ADD, `VOP_MUL, `VOP_SLT, `VOP_SEQ:
                    for (int i = 0; i < vl; i++)
                        m_v[vd][i] = ref_elem(op[3:0], m_v[vs1][i], m_v[vs2][i]);
                `VOP_REDSUM: begin
                    acc = 32'd0;
                    for (int i = 0; i < vl; i++) acc = acc + m_v[vs1][i];
                    m_result = acc;
                end
                `VOP_REDMAX: begin
                    acc = m_v[vs1][0];
                    for (int i = 1; i < vl; i++)
                        if ($signed(m_v[vs1][i]) > $signed(acc)) acc = m_v[vs1][i];
                    m_result = acc;
                end
                default: ;
            endcase
        end
    endtask

    // ------------------------------------------------------ vector reg helpers
    function automatic logic [10:0] vaddr(input int r, input int l);
        vaddr = `VREG_WINDOW + r*(LANES*4) + l*4;
    endfunction

    task automatic write_vreg(input int r, input int l, input logic [31:0] v);
        begin
            bus_write(vaddr(r, l), v);
            m_v[r][l] = v;
        end
    endtask

    task automatic load_vreg(input int r, input logic [31:0] e0, e1, e2, e3);
        begin
            write_vreg(r, 0, e0); write_vreg(r, 1, e1);
            write_vreg(r, 2, e2); write_vreg(r, 3, e3);
        end
    endtask

    task automatic check_all_vregs(input string tag);
        logic [31:0] d;
        begin
            for (int r = 0; r < NVREG; r++)
                for (int l = 0; l < LANES; l++) begin
                    bus_read(vaddr(r, l), d);
                    check_eq(d, m_v[r][l], $sformatf("%s: v%0d[%0d]", tag, r, l));
                end
        end
    endtask

    task automatic check_result(input string tag);
        logic [31:0] d;
        begin
            bus_read(`VREG_RESULT, d);
            check_eq(d, m_result, {tag, ": RESULT"});
        end
    endtask

    // -------------------------------------------------------- coverage counters
    int cov_op [0:15];
    int cov_vl [0:LANES];
    int cov_illegal = 0;
    int cmd_count   = 0;

    // ----------------------------------------------------------- run a command
    function automatic string op_name(input logic [31:0] op);
        case (op)
            `VOP_ADD:    op_name = "VADD";
            `VOP_MUL:    op_name = "VMUL";
            `VOP_SLT:    op_name = "VSLT";
            `VOP_SEQ:    op_name = "VSEQ";
            `VOP_REDSUM: op_name = "VREDSUM";
            `VOP_REDMAX: op_name = "VREDMAX";
            default:     op_name = "ILLEGAL";
        endcase
    endfunction

    task automatic run_cmd(input logic [31:0] op, input int vd, input int vs1, input int vs2,
                           input logic [31:0] vl);
        logic [31:0] st;
        bit          legal;
        int          polls;
        begin
            legal = (op <= 32'd5) && (vl >= 32'd1) && (vl <= LANES);
            cmd_count++;
            bus_write(`VREG_OP,   op);
            bus_write(`VREG_VSEL, 32'(vd) | (32'(vs1) << 3) | (32'(vs2) << 6));
            bus_write(`VREG_VL,   vl);
            bus_write(`VREG_CTRL, 32'h1);                 // START
            bus_read (`VREG_STATUS, st);                  // first cycle after START

            if (legal) begin
                if (verbose)
                    $display("[CMD ] %-8s v%0d <- v%0d,v%0d  vl=%0d", op_name(op), vd, vs1, vs2, vl);
                check_eq(st, 32'b001, "status right after START must be BUSY only");
                polls = 0;
                do begin
                    bus_read(`VREG_STATUS, st);
                    polls++;
                end while (!st[1] && polls < 20);
                check_eq(st, 32'b010, "status after completion must be DONE only");
                model_exec(op, vd, vs1, vs2, vl);
                cov_op[op[3:0]]++;
                cov_vl[vl[3:0]]++;
            end
            else begin
                if (verbose)
                    $display("[CMD ] %-8s (illegal: op=0x%0h vl=%0d) -> expect ERR", op_name(op), op, vl);
                check_eq(st, 32'b110, "illegal command: DONE+ERR immediately, no BUSY");
                cov_illegal++;
            end
        end
    endtask

    // -------------------------------------------------------- value generators
    function automatic logic [31:0] corner_or_rand();
        int sel_i;
        begin
            sel_i = $urandom % 12;
            case (sel_i)
                0:  corner_or_rand = 32'h0000_0000;
                1:  corner_or_rand = 32'h0000_0001;
                2:  corner_or_rand = 32'hFFFF_FFFF;   // -1
                3:  corner_or_rand = 32'h7FFF_FFFF;   // INT_MAX
                4:  corner_or_rand = 32'h8000_0000;   // INT_MIN
                5:  corner_or_rand = 32'h0000_FFFF;
                6:  corner_or_rand = 32'hFFFF_0000;
                default: corner_or_rand = $urandom;
            endcase
        end
    endfunction

    task automatic fill_random(input int r);
        for (int l = 0; l < LANES; l++) write_vreg(r, l, corner_or_rand());
    endtask

    // =========================================================================
    //                               main test
    // =========================================================================
    logic [31:0] d;

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $dumpfile("vec_coproc.vcd");
        $dumpvars(0, vec_coproc_tb);

        for (int i = 0; i < 16; i++)     cov_op[i] = 0;
        for (int i = 0; i <= LANES; i++) cov_vl[i] = 0;

        sel = 0; we = 0; addr = '0; wdata = '0; rst = 1;
        model_reset();
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // ------------------------------------------------------------------
        $display("\n=== T1: reset values ===");
        bus_read(`VREG_STATUS, d); check_eq(d, 32'd0, "STATUS after reset");
        bus_read(`VREG_OP,     d); check_eq(d, 32'd0, "OP after reset");
        bus_read(`VREG_VSEL,   d); check_eq(d, 32'd0, "VSEL after reset");
        bus_read(`VREG_VL,     d); check_eq(d, 32'd0, "VL after reset");
        bus_read(`VREG_RESULT, d); check_eq(d, 32'd0, "RESULT after reset");
        check_all_vregs("after reset");

        // ------------------------------------------------------------------
        $display("\n=== T2: register read-back / write-only CTRL ===");
        bus_write(`VREG_OP, 32'd2);                 bus_read(`VREG_OP, d);   check_eq(d, 32'd2, "OP readback");
        bus_write(`VREG_VL, 32'd3);                 bus_read(`VREG_VL, d);   check_eq(d, 32'd3, "VL readback");
        bus_write(`VREG_VSEL, 32'b111_010_101);     bus_read(`VREG_VSEL, d); check_eq(d, 32'b111_010_101, "VSEL readback");
        bus_read(`VREG_CTRL, d);                    check_eq(d, 32'd0, "CTRL always reads 0");
        bus_write(`VREG_STATUS, 32'hFFFF_FFFF);     bus_read(`VREG_STATUS, d); check_eq(d, 32'd0, "STATUS is read-only");
        bus_write(`VREG_RESULT, 32'hFFFF_FFFF);     bus_read(`VREG_RESULT, d); check_eq(d, 32'd0, "RESULT is read-only");

        // ------------------------------------------------------------------
        $display("\n=== T3: directed vector add (basic bring-up) ===");
        load_vreg(1, 1, 2, 3, 4);
        load_vreg(2, 10, 20, 30, 40);
        run_cmd(`VOP_ADD, 3, 1, 2, 4);
        check_all_vregs("T3");
        bus_read(vaddr(3, 0), d); check_eq(d, 11, "v3[0] = 1+10");
        bus_read(vaddr(3, 3), d); check_eq(d, 44, "v3[3] = 4+40");

        // ------------------------------------------------------------------
        $display("\n=== T4: every element-wise opcode x every VL x corner operands ===");
        verbose = 0;
        for (int op = `VOP_ADD; op <= `VOP_SEQ; op++)
            for (int vl = 1; vl <= LANES; vl++)
                for (int rep = 0; rep < 6; rep++) begin
                    fill_random(1); fill_random(2);
                    write_vreg(3, 0, 32'hDEAD_BEE0); write_vreg(3, 1, 32'hDEAD_BEE1);   // sentinels in vd
                    write_vreg(3, 2, 32'hDEAD_BEE2); write_vreg(3, 3, 32'hDEAD_BEE3);
                    run_cmd(op, 3, 1, 2, vl);
                    check_all_vregs($sformatf("T4 %s vl=%0d", op_name(op), vl));  // also proves lanes >= VL untouched
                end
        verbose = 1;
        $display("[INFO] T4 done, errors so far = %0d", errors);

        // ------------------------------------------------------------------
        $display("\n=== T5: reductions (sum / signed max), VL 1..LANES ===");
        verbose = 0;
        for (int op = `VOP_REDSUM; op <= `VOP_REDMAX; op++)
            for (int vl = 1; vl <= LANES; vl++)
                for (int rep = 0; rep < 6; rep++) begin
                    fill_random(4);
                    write_vreg(5, 0, 32'h1234_5670); write_vreg(5, 1, 32'h1234_5671);
                    run_cmd(op, 5, 4, 4, vl);
                    check_result($sformatf("T5 %s vl=%0d", op_name(op), vl));
                    check_all_vregs($sformatf("T5 %s vl=%0d (vd must be untouched)", op_name(op), vl));
                end
        verbose = 1;
        load_vreg(6, 32'hFFFF_FFFB, 32'd3, 32'hFFFF_FFFE, 32'd1);      // -5, 3, -2, 1
        run_cmd(`VOP_REDMAX, 0, 6, 6, 4);   check_eq(m_result, 32'd3, "model sanity: max(-5,3,-2,1)=3"); check_result("T5 signed max");
        load_vreg(6, 32'hFFFF_FFFB, 32'hFFFF_FFFE, 32'hFFFF_FFFF, 32'hFFFF_FFF0);   // all negative
        run_cmd(`VOP_REDMAX, 0, 6, 6, 4);   check_result("T5 signed max, all negative");
        run_cmd(`VOP_REDSUM, 0, 6, 6, 4);   check_result("T5 sum wraps mod 2^32 correctly");

        // ------------------------------------------------------------------
        $display("\n=== T6: aliased operands (vd==vs1, vs1==vs2, vd==vs2) ===");
        fill_random(1); fill_random(2);
        run_cmd(`VOP_ADD, 1, 1, 2, 4);  check_all_vregs("T6 vd==vs1");
        fill_random(1); fill_random(2);
        run_cmd(`VOP_MUL, 2, 1, 2, 3);  check_all_vregs("T6 vd==vs2");
        fill_random(1);
        run_cmd(`VOP_SEQ, 7, 1, 1, 4);  check_all_vregs("T6 vs1==vs2 (SEQ must be all ones)");
        bus_read(vaddr(7, 0), d); check_eq(d, 1, "v7[0]==1 for x==x");

        // ------------------------------------------------------------------
        $display("\n=== T7: illegal commands must not execute or write anything ===");
        fill_random(1); fill_random(2); fill_random(3);
        run_cmd(32'd6,        3, 1, 2, 4);  check_all_vregs("T7 op=6");
        run_cmd(32'd15,       3, 1, 2, 4);  check_all_vregs("T7 op=15");
        run_cmd(32'h0000_0010, 3, 1, 2, 4); check_all_vregs("T7 op=0x10 must not alias to VADD");
        run_cmd(32'h0000_0100, 3, 1, 2, 4); check_all_vregs("T7 op=0x100 must not alias to VADD");
        run_cmd(32'hFFFF_FFFF, 3, 1, 2, 4); check_all_vregs("T7 op=0xFFFFFFFF");
        run_cmd(`VOP_ADD, 3, 1, 2, 0);      check_all_vregs("T7 VL=0");
        run_cmd(`VOP_ADD, 3, 1, 2, 5);      check_all_vregs("T7 VL=5 (> LANES)");
        run_cmd(`VOP_ADD, 3, 1, 2, 8);      check_all_vregs("T7 VL=8");
        run_cmd(`VOP_ADD, 3, 1, 2, 32'h0000_0102); check_all_vregs("T7 VL=0x102 must not alias to 2");
        run_cmd(`VOP_REDSUM, 3, 1, 2, 0);   check_result("T7 RESULT untouched by illegal reduction");
        bus_read(`VREG_STATUS, d); check_eq(d, 32'b110, "ERR and DONE stay set");

        // ------------------------------------------------------------------
        $display("\n=== T8: status flags: CLR, and a good START clears old ERR/DONE ===");
        bus_write(`VREG_CTRL, 32'h2);                              // CLR
        bus_read(`VREG_STATUS, d); check_eq(d, 32'd0, "CLR clears DONE and ERR");
        run_cmd(`VOP_ADD, 3, 1, 2, 2);                             // legal
        bus_read(`VREG_STATUS, d); check_eq(d, 32'b010, "legal command leaves DONE only (ERR from before is gone)");
        check_all_vregs("T8");

        // ------------------------------------------------------------------
        // BUSY lasts exactly one clock, so only ONE bus access can land inside it.
        // Each scenario therefore spends that single slot on a different access.
        $display("\n=== T9: things that must be ignored while BUSY ===");
        // (a) a second START during BUSY. If it were accepted the in-place add
        //     (vd == vs1) would run twice and v1 would be wrong.
        fill_random(1); fill_random(2);
        bus_write(`VREG_OP,   `VOP_ADD);
        bus_write(`VREG_VSEL, 32'd1 | (32'd1 << 3) | (32'd2 << 6));   // v1 <- v1 + v2 (in place)
        bus_write(`VREG_VL,   32'd4);
        bus_write(`VREG_CTRL, 32'h1);                                 // START  -> BUSY
        bus_write(`VREG_CTRL, 32'h1);                                 // 2nd START lands in the BUSY cycle -> ignored
        model_exec(`VOP_ADD, 1, 1, 2, 4);
        bus_read(`VREG_STATUS, d);  check_eq(d, 32'b010, "(a) exactly one completion, no ERR");
        check_all_vregs("T9a in-place add executed exactly once");

        // (b) a config write during BUSY
        fill_random(1); fill_random(2);
        bus_write(`VREG_CTRL, 32'h1);
        bus_write(`VREG_VL,   32'd1);                                 // lands in the BUSY cycle -> ignored
        model_exec(`VOP_ADD, 1, 1, 2, 4);                             // still VL=4, same command as before
        bus_read(`VREG_VL, d);      check_eq(d, 32'd4, "(b) VL write during BUSY was ignored");
        check_all_vregs("T9b operation used the old VL");

        // (c) a vector-window write during BUSY (to a register the ALU is not writing)
        fill_random(1); fill_random(2);
        write_vreg(5, 0, 32'h5555_0000);
        bus_write(`VREG_CTRL, 32'h1);
        bus_write(vaddr(5, 0), 32'hBAD0_BAD0);                        // lands in the BUSY cycle -> ignored
        model_exec(`VOP_ADD, 1, 1, 2, 4);
        check_all_vregs("T9c window write during BUSY was ignored");

        // ------------------------------------------------------------------
        $display("\n=== T10: out-of-window / unmapped accesses ===");
        bus_read(11'h018, d);                       check_eq(d, 32'd0, "unmapped register reads 0");
        bus_read(11'h0FC, d);                       check_eq(d, 32'd0, "gap before the window reads 0");
        bus_read(vaddr(NVREG, 0), d);               check_eq(d, 32'd0, "first word past the window reads 0");
        bus_write(vaddr(NVREG, 0), 32'hFFFF_FFFF);  // must not alias into any vreg
        bus_write(11'h7FC, 32'hFFFF_FFFF);
        bus_write(11'h018, 32'hFFFF_FFFF);
        check_all_vregs("T10 no aliasing from stray writes");

        // ------------------------------------------------------------------
        $display("\n=== T11: reset in the middle of an operation ===");
        fill_random(1); fill_random(2);
        bus_write(`VREG_OP,   `VOP_MUL);
        bus_write(`VREG_VSEL, 32'd3 | (32'd1 << 3) | (32'd2 << 6));
        bus_write(`VREG_VL,   32'd4);
        bus_write(`VREG_CTRL, 32'h1);               // now BUSY
        #1 rst = 1;                                 // asynchronous reset before the EXEC edge
        #1 bus_read(`VREG_STATUS, d);
        check_eq(d, 32'd0, "STATUS cleared by mid-operation reset");
        @(negedge clk); rst = 0;
        model_reset();
        check_all_vregs("T11 everything zero, no half-finished write");
        bus_read(`VREG_OP, d); check_eq(d, 32'd0, "OP cleared by reset");
        bus_read(`VREG_VL, d); check_eq(d, 32'd0, "VL cleared by reset");
        bus_read(`VREG_RESULT, d); check_eq(d, 32'd0, "RESULT cleared by reset");
        load_vreg(1, 5, 6, 7, 8); load_vreg(2, 1, 1, 1, 1);
        run_cmd(`VOP_ADD, 3, 1, 2, 4);              // still works after reset
        check_all_vregs("T11 operational after reset");

        // ------------------------------------------------------------------
        $display("\n=== T12: 400 constrained-random commands vs. reference model ===");
        verbose = 0;
        for (int n = 0; n < 400; n++) begin
            int op, vd, vs1, vs2, vl;
            if ($urandom % 3 == 0) fill_random($urandom % NVREG);
            if ($urandom % 3 == 0) fill_random($urandom % NVREG);
            op  = ($urandom % 20 == 0) ? (6 + $urandom % 10) : ($urandom % 6);   // ~5 % illegal opcodes
            vl  = ($urandom % 20 == 0) ? (($urandom % 2) ? 0 : LANES + 1 + $urandom % 4) : (1 + $urandom % LANES);
            vd  = $urandom % NVREG;  vs1 = $urandom % NVREG;  vs2 = $urandom % NVREG;
            run_cmd(op, vd, vs1, vs2, vl);
            if (n % 20 == 19) begin
                check_all_vregs($sformatf("T12 after cmd %0d", n));
                check_result($sformatf("T12 after cmd %0d", n));
            end
        end
        check_all_vregs("T12 final");
        check_result("T12 final");
        verbose = 1;

        // ------------------------------------------------------------------
        $display("\n=== functional coverage (commands actually executed) ===");
        $display("  opcode : ADD=%0d MUL=%0d SLT=%0d SEQ=%0d REDSUM=%0d REDMAX=%0d  | illegal rejected=%0d",
                 cov_op[0], cov_op[1], cov_op[2], cov_op[3], cov_op[4], cov_op[5], cov_illegal);
        $display("  VL     : 1=%0d 2=%0d 3=%0d 4=%0d", cov_vl[1], cov_vl[2], cov_vl[3], cov_vl[4]);
        for (int i = 0; i <= 5; i++) check(cov_op[i] > 0, $sformatf("coverage: opcode %0d exercised", i));
        for (int i = 1; i <= LANES; i++) check(cov_vl[i] > 0, $sformatf("coverage: VL=%0d exercised", i));

        test_done = 1;
        $display("\n=============================================");
        $display(" commands issued : %0d", cmd_count);
        $display(" checks run      : %0d", checks);
        $display(" errors          : %0d", errors);
        if (errors == 0) $display(" TEST PASSED");
        else             $display(" TEST FAILED");
        $display("=============================================\n");
        $finish;
    end

    // watchdog
    initial begin
        #(CLK_PERIOD * 400000);
        if (!test_done) begin
            $display("[FAIL] TIMEOUT");
            $display(" TEST FAILED");
            $finish;
        end
    end

endmodule
