// =============================================================================
// core_pkg - UVM-1.2 passive checking environment for the full RV32I core.
//
// The core's "stimulus" is the program sitting in instruction memory
// (loaded by $readmemh at time 0, via +HEX=/+DHEX=, same as every other
// testbench in this project) - not something a UVM driver produces, so this
// environment is intentionally PASSIVE: a monitor taps the retire trace
// (rvfi), a reference-model scoreboard checks every field of every retired
// instruction, and a coverage collector samples instruction-level bins.
// Program generation stays external (scripts/gen_random.py, riscv-dv, or a
// human-written .S), exactly as it already does in tb/rv32i_tb.sv.
//
// rv32i_reference_model below is the same instruction-set model as
// tb/rv32i_iss.sv, ported from a module (with a `step` task) into a plain
// SystemVerilog class (with a `step` function) so it can live inside a UVM
// scoreboard without any hierarchical-reference trick between a class and a
// module instance.
//
// NOTE ON VERIFICATION STATUS: same caveat as vec_pkg.sv - this needs a real
// UVM-1.2 library to compile, and this container has neither QuestaSim/
// ModelSim nor network access to get one, so it hasn't been compiled here.
// rvfi_if (uvm/core/rvfi_if.sv) and the core's bind-based assertions
// (uvm/assertions/core_assertions.sv) are plain SV and were compiled/run
// against the real core RTL elsewhere.
//
// What's new in this pass (closing functional coverage toward 100%): more
// cg_insn coverpoints - rs2 corner operands, rs1==rs2, rd==x0, branch taken/
// not-taken, JAL/JALR forward/backward, and load/store byte offset - plus
// ignore_bins on cx_op_f3 (LUI/AUIPC/JAL have no real funct3 field, so that
// row is excluded rather than left permanently partial) and a new
// cx_branch_taken cross. See uvm/README.md for the full list and how the
// existing directed .S programs already exercise most of the new bins.
// =============================================================================
`include "rv32i_types.svh"

package core_pkg;
    import uvm_pkg::*;
    import rvfi_pkg::*;   // rvfi_t as a real type - see rtl/rvfi_pkg.sv header
                           // comment for why a package can't just `include
                           // rv32i_types.svh for this like a module/interface can.
    `include "uvm_macros.svh"

    // ---------------------------------------------------------------- core_rvfi_txn
    // Pure analysis transaction (never driven through a sequencer), so it
    // extends uvm_object rather than uvm_sequence_item. Field-for-field copy
    // of rvfi_t (rv32i_types.svh) plus a retire-order cycle count for
    // readable log messages.
    class core_rvfi_txn extends uvm_object;
        bit [63:0] order;
        bit [31:0] insn;
        bit        trap;
        bit [4:0]  rs1_addr, rs2_addr, rd_addr;
        bit [31:0] rs1_rdata, rs2_rdata, rd_wdata;
        bit [31:0] pc_rdata, pc_wdata;
        bit [31:0] mem_addr;
        bit [3:0]  mem_rmask, mem_wmask;
        bit [31:0] mem_rdata, mem_wdata;
        bit [4:0]  cause;

        `uvm_object_utils(core_rvfi_txn)

        function new(string name = "core_rvfi_txn");
            super.new(name);
        endfunction

        function void from_rvfi(rvfi_t r);
            order     = r.order;
            insn      = r.insn;
            trap      = r.trap;
            rs1_addr  = r.rs1_addr;  rs2_addr = r.rs2_addr;  rd_addr = r.rd_addr;
            rs1_rdata = r.rs1_rdata; rs2_rdata = r.rs2_rdata; rd_wdata = r.rd_wdata;
            pc_rdata  = r.pc_rdata;  pc_wdata = r.pc_wdata;
            mem_addr  = r.mem_addr;
            mem_rmask = r.mem_rmask; mem_wmask = r.mem_wmask;
            mem_rdata = r.mem_rdata; mem_wdata = r.mem_wdata;
            cause     = r.cause;
        endfunction

        function string convert2string();
            return $sformatf("#%0d pc=%08h insn=%08h%s", order, pc_rdata, insn,
                             trap ? $sformatf(" TRAP cause=%0d", cause) : "");
        endfunction
    endclass

    // ------------------------------------------------------------------- core_monitor
    class core_monitor extends uvm_monitor;
        `uvm_component_utils(core_monitor)

        virtual rvfi_if.MONITOR vif;
        uvm_analysis_port #(core_rvfi_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual rvfi_if.MONITOR)::get(this, "", "vif", vif))
                `uvm_fatal("CORE_MON", "no vif set for core_monitor")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (!vif.rst && vif.rvfi.valid) begin
                    core_rvfi_txn t = core_rvfi_txn::type_id::create("t");
                    t.from_rvfi(vif.rvfi);
                    ap.write(t);
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------- core_agent
    // Always passive: there is nothing to drive, the CPU fetches from memory
    // on its own. Kept as an "agent" purely for the standard env shape/reuse
    // (identical pattern to vec_agent, just with is_active hard-wired off).
    class core_agent extends uvm_component;
        `uvm_component_utils(core_agent)

        core_monitor monitor;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = core_monitor::type_id::create("monitor", this);
        endfunction
    endclass

    // ============================================================================
    //                    behavioural RV32I reference model (a class)
    // ============================================================================
    // Same decode/execute/trap logic as tb/rv32i_iss.sv, restated as class
    // methods over class-member memories instead of a module with a task.
    // `step()` executes exactly the ONE instruction currently at m_pc and
    // returns the expected core_rvfi_txn for it - call it once per DUT
    // retire, in lockstep (see core_scoreboard below), exactly the way
    // rv32i_tb.sv drove rv32i_iss.
    class rv32i_reference_model;
        localparam int IMEM_BYTES = 65536;
        localparam int DMEM_WORDS = 16384;

        bit [7:0]  imem [0:IMEM_BYTES-1];
        bit [31:0] dmem [0:DMEM_WORDS-1];
        bit [31:0] x    [0:31];
        bit [31:0] m_pc;
        bit        m_halted;
        longint    m_retired;

        function new(string hexfile = "./ins_little_endian.hex", string dhexfile = "");
            for (int i = 0; i < IMEM_BYTES; i++) imem[i] = 8'h00;
            for (int i = 0; i < DMEM_WORDS; i++) dmem[i] = 32'd0;
            for (int i = 0; i < 32; i++)         x[i]    = 32'd0;
            m_pc = 0; m_halted = 0; m_retired = 0;
            $readmemh(hexfile, imem);
            if (dhexfile != "") $readmemh(dhexfile, dmem);
        endfunction

        function bit [31:0] pc();       return m_pc;     endfunction
        function bit        halted();   return m_halted; endfunction

        function bit [31:0] fetch(bit [31:0] a);
            bit [15:0] b = a[15:0];
            fetch = {imem[b+3], imem[b+2], imem[b+1], imem[b]};
        endfunction

        // Runs one instruction, returns its expected retire record. If the
        // model is already halted this returns an all-zero/trap-repeat
        // record - callers should stop calling step() once halted() is 1.
        //
        // dut_t (optional): the DUT's own retire record for THIS same
        // instruction, if the caller already has it (core_scoreboard does -
        // see write_core below). Needed for loads/stores that touch an
        // address outside the modeled 64KB SRAM (e.g. the vector
        // coprocessor's memory-mapped window at 0x4000_0000): this model
        // only simulates SRAM, not the coprocessor's internal registers, so
        // it can't independently predict what a load from there returns -
        // that's exactly what vec_scoreboard checks separately, against its
        // own behavioural model of the coprocessor. Without dut_t, an MMIO
        // load would alias into dmem[] using only address bits [15:2] and
        // return actual (wrong) SRAM content instead; with dut_t, the
        // DUT's own observed mem_rdata is adopted as ground truth for that
        // one load, so every later instruction that depends on the value
        // (typically the destination register) stays in lockstep. Comparing
        // rd_wdata/mem_rdata for that specific instruction is then trivially
        // true (dut supplied its own expected value) - real checking for
        // that data still happens, just in vec_scoreboard instead.
        function core_rvfi_txn step(core_rvfi_txn dut_t = null);
            core_rvfi_txn t = core_rvfi_txn::type_id::create("exp");
            bit [31:0] insn, rs1v, rs2v, imm_i, imm_s, imm_b, imm_u, imm_j;
            bit [31:0] npc, res, addr, tgt, word;
            bit [6:0]  opc, f7;
            bit [2:0]  f3;
            bit [4:0]  rd, rs1, rs2;
            bit signed [7:0]  sb8;
            bit signed [15:0] sh16;
            bit [7:0]  ub8;
            bit [15:0] uh16;
            bit        wr_rd, ill, take, u1, u2;
            bit [4:0]  cause;
            bit        trapped;
            int        sh;

            insn = fetch(m_pc);
            opc = insn[6:0];  f3 = insn[14:12];  f7 = insn[31:25];
            rd  = insn[11:7]; rs1 = insn[19:15]; rs2 = insn[24:20];
            imm_i = {{20{insn[31]}}, insn[31:20]};
            imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
            imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
            imm_u = {insn[31:12], 12'd0};
            imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

            t.order = m_retired; t.insn = insn; t.pc_rdata = m_pc; t.pc_wdata = m_pc;
            t.rs1_addr = 0; t.rs2_addr = 0; t.rs1_rdata = 0; t.rs2_rdata = 0;
            t.rd_addr = 0;  t.rd_wdata = 0;
            t.mem_addr = 0; t.mem_rmask = 0; t.mem_wmask = 0; t.mem_rdata = 0; t.mem_wdata = 0;
            t.trap = 0; t.cause = 0;

            rs1v = x[rs1]; rs2v = x[rs2];
            npc = m_pc + 4; wr_rd = 0; res = 0; ill = 0; cause = 0; u1 = 0; u2 = 0; trapped = 0;

            if (m_halted) return t;

            if (insn[1:0] != 2'b11) ill = 1;
            else case (opc)
                7'b0110111: begin res = imm_u;      wr_rd = 1; end
                7'b0010111: begin res = m_pc + imm_u; wr_rd = 1; end

                7'b1101111: begin
                    tgt = m_pc + imm_j;
                    if (tgt[1:0] != 0) begin trapped = 1; cause = 0; end
                    else begin res = m_pc + 4; wr_rd = 1; npc = tgt; end
                end

                7'b1100111: begin
                    if (f3 != 0) ill = 1;
                    else begin
                        u1 = 1;
                        tgt = (rs1v + imm_i) & 32'hFFFF_FFFE;
                        if (tgt[1:0] != 0) begin trapped = 1; cause = 0; end
                        else begin res = m_pc + 4; wr_rd = 1; npc = tgt; end
                    end
                end

                7'b1100011: begin
                    u1 = 1; u2 = 1;
                    case (f3)
                        3'b000: take = (rs1v == rs2v);
                        3'b001: take = (rs1v != rs2v);
                        3'b100: take = ($signed(rs1v) <  $signed(rs2v));
                        3'b101: take = ($signed(rs1v) >= $signed(rs2v));
                        3'b110: take = (rs1v <  rs2v);
                        3'b111: take = (rs1v >= rs2v);
                        default: begin take = 0; ill = 1; end
                    endcase
                    if (!ill && take) begin
                        tgt = m_pc + imm_b;
                        if (tgt[1:0] != 0) begin trapped = 1; cause = 0; end
                        else npc = tgt;
                    end
                end

                7'b0000011: begin
                    u1 = 1;
                    addr = rs1v + imm_i;
                    if (addr[31:16] == 16'h0000) begin
                        word = dmem[addr[15:2]];
                    end
                    else if (dut_t != null) begin
                        // unmodeled MMIO region (coprocessor window, etc.) -
                        // absorb the DUT's own read instead of guessing
                        word = dut_t.mem_rdata;
                    end
                    else begin
                        word = 32'd0;      // no DUT reference available - documented "unmapped reads 0"
                    end
                    case (f3)
                        3'b000: begin sb8 = word >> (8*addr[1:0]);  res = sb8; t.mem_rmask = 4'b0001 << addr[1:0]; end
                        3'b001: begin
                            sh16 = word >> (16*addr[1]); res = sh16;
                            t.mem_rmask = 4'b0011 << (2*addr[1]);
                            if (addr[0]) begin trapped = 1; cause = 4; end
                        end
                        3'b010: begin
                            res = word; t.mem_rmask = 4'b1111;
                            if (addr[1:0] != 0) begin trapped = 1; cause = 4; end
                        end
                        3'b100: begin ub8 = word >> (8*addr[1:0]); res = {24'd0, ub8}; t.mem_rmask = 4'b0001 << addr[1:0]; end
                        3'b101: begin
                            uh16 = word >> (16*addr[1]); res = {16'd0, uh16};
                            t.mem_rmask = 4'b0011 << (2*addr[1]);
                            if (addr[0]) begin trapped = 1; cause = 4; end
                        end
                        default: ill = 1;
                    endcase
                    if (!ill) begin t.mem_addr = {addr[31:2], 2'b00}; t.mem_rdata = word; wr_rd = 1; end
                end

                7'b0100011: begin
                    u1 = 1; u2 = 1;
                    addr = rs1v + imm_s;
                    if (addr[31:16] == 16'h0000) word = dmem[addr[15:2]];
                    else                         word = 32'd0;   // MMIO: read-modify-write base doesn't apply; f3=010 (word) fully overwrites word below anyway
                    case (f3)
                        3'b000: begin
                            t.mem_wmask = 4'b0001 << addr[1:0]; t.mem_wdata = {4{rs2v[7:0]}};
                            word[8*addr[1:0] +: 8] = rs2v[7:0];
                        end
                        3'b001: begin
                            t.mem_wmask = 4'b0011 << (2*addr[1]); t.mem_wdata = {2{rs2v[15:0]}};
                            word[16*addr[1] +: 16] = rs2v[15:0];
                            if (addr[0]) begin trapped = 1; cause = 6; end
                        end
                        3'b010: begin
                            t.mem_wmask = 4'b1111; t.mem_wdata = rs2v; word = rs2v;
                            if (addr[1:0] != 0) begin trapped = 1; cause = 6; end
                        end
                        default: ill = 1;
                    endcase
                    if (!ill) t.mem_addr = {addr[31:2], 2'b00};
                end

                7'b0010011: begin
                    u1 = 1; wr_rd = 1; sh = imm_i[4:0];
                    case (f3)
                        3'b000: res = rs1v + imm_i;
                        3'b010: res = ($signed(rs1v) < $signed(imm_i)) ? 1 : 0;
                        3'b011: res = (rs1v < imm_i) ? 1 : 0;
                        3'b100: res = rs1v ^ imm_i;
                        3'b110: res = rs1v | imm_i;
                        3'b111: res = rs1v & imm_i;
                        3'b001: if (f7 == 7'b0000000) res = rs1v << sh; else ill = 1;
                        3'b101: begin
                            if      (f7 == 7'b0000000) res = rs1v >> sh;
                            else if (f7 == 7'b0100000) res = $signed(rs1v) >>> sh;
                            else ill = 1;
                        end
                    endcase
                end

                7'b0110011: begin
                    u1 = 1; u2 = 1; wr_rd = 1; sh = rs2v[4:0];
                    if (f7 == 7'b0000000) begin
                        case (f3)
                            3'b000: res = rs1v + rs2v;
                            3'b001: res = rs1v << sh;
                            3'b010: res = ($signed(rs1v) < $signed(rs2v)) ? 1 : 0;
                            3'b011: res = (rs1v < rs2v) ? 1 : 0;
                            3'b100: res = rs1v ^ rs2v;
                            3'b101: res = rs1v >> sh;
                            3'b110: res = rs1v | rs2v;
                            3'b111: res = rs1v & rs2v;
                        endcase
                    end
                    else if (f7 == 7'b0100000 && f3 == 3'b000) res = rs1v - rs2v;
                    else if (f7 == 7'b0100000 && f3 == 3'b101) res = $signed(rs1v) >>> sh;
                    else ill = 1;
                end

                7'b0001111: if (f3 != 0) ill = 1;

                7'b1110011: begin
                    if      (insn == 32'h0000_0073) begin trapped = 1; cause = 11; end
                    else if (insn == 32'h0010_0073) begin trapped = 1; cause = 3;  end
                    else ill = 1;
                end

                default: ill = 1;
            endcase

            if (ill) begin trapped = 1; cause = 2; end

            if (trapped) begin
                m_halted = 1;
                t.trap = 1; t.cause = cause;
                t.pc_wdata = m_pc;
                if (ill) begin u1 = 0; u2 = 0; end
                t.rs1_addr = u1 ? rs1 : 0; t.rs1_rdata = u1 ? rs1v : 0;
                t.rs2_addr = u2 ? rs2 : 0; t.rs2_rdata = u2 ? rs2v : 0;
                t.mem_addr = 0; t.mem_rmask = 0; t.mem_wmask = 0; t.mem_rdata = 0; t.mem_wdata = 0;
            end
            else begin
                if (opc == 7'b0100011 && addr[31:16] == 16'h0000) dmem[addr[15:2]] = word;
                if (wr_rd && rd != 0) begin x[rd] = res; t.rd_addr = rd; t.rd_wdata = res; end
                t.rs1_addr = u1 ? rs1 : 0; t.rs1_rdata = u1 ? rs1v : 0;
                t.rs2_addr = u2 ? rs2 : 0; t.rs2_rdata = u2 ? rs2v : 0;
                m_pc = npc;
                t.pc_wdata = npc;
                m_retired++;
            end

            return t;
        endfunction
    endclass

    // -------------------------------------------------------------- core_scoreboard
    `uvm_analysis_imp_decl(_core)

    class core_scoreboard extends uvm_component;
        `uvm_component_utils(core_scoreboard)

        uvm_analysis_imp_core #(core_rvfi_txn, core_scoreboard) core_export;
        rv32i_reference_model model;

        int unsigned checks, errors, retired;
        int cause_seen = -1;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            core_export = new("core_export", this);
        endfunction

        function void build_phase(uvm_phase phase);
            string hexfile = "./ins_little_endian.hex";
            string dhexfile = "";
            super.build_phase(phase);
            void'($value$plusargs("HEX=%s", hexfile));
            void'($value$plusargs("DHEX=%s", dhexfile));
            model = new(hexfile, dhexfile);
        endfunction

        function void sb_check(bit cond, string field, bit [63:0] got, bit [63:0] exp);
            checks++;
            if (!cond) begin
                errors++;
                `uvm_error("CORE_SB", $sformatf("retire #%0d %s: dut=0x%0h model=0x%0h", retired, field, got, exp))
            end
        endfunction

        function bit [31:0] bmask(bit [3:0] m);
            bmask = {{8{m[3]}}, {8{m[2]}}, {8{m[1]}}, {8{m[0]}}};
        endfunction

        function void write_core(core_rvfi_txn dut_t);
            core_rvfi_txn exp_t = model.step(dut_t);

            sb_check(dut_t.order === exp_t.order, "order", dut_t.order, exp_t.order);
            sb_check(dut_t.insn === exp_t.insn, "insn", dut_t.insn, exp_t.insn);
            sb_check(dut_t.pc_rdata === exp_t.pc_rdata, "pc_rdata", dut_t.pc_rdata, exp_t.pc_rdata);
            sb_check(dut_t.pc_wdata === exp_t.pc_wdata, "pc_wdata", dut_t.pc_wdata, exp_t.pc_wdata);
            sb_check(dut_t.trap === exp_t.trap, "trap", dut_t.trap, exp_t.trap);
            if (exp_t.trap) sb_check(dut_t.cause === exp_t.cause, "cause", dut_t.cause, exp_t.cause);
            sb_check(dut_t.rs1_addr === exp_t.rs1_addr, "rs1_addr", dut_t.rs1_addr, exp_t.rs1_addr);
            sb_check(dut_t.rs2_addr === exp_t.rs2_addr, "rs2_addr", dut_t.rs2_addr, exp_t.rs2_addr);
            sb_check(dut_t.rs1_rdata === exp_t.rs1_rdata, "rs1_rdata", dut_t.rs1_rdata, exp_t.rs1_rdata);
            sb_check(dut_t.rs2_rdata === exp_t.rs2_rdata, "rs2_rdata", dut_t.rs2_rdata, exp_t.rs2_rdata);
            sb_check(dut_t.rd_addr === exp_t.rd_addr, "rd_addr", dut_t.rd_addr, exp_t.rd_addr);
            sb_check(dut_t.rd_wdata === exp_t.rd_wdata, "rd_wdata", dut_t.rd_wdata, exp_t.rd_wdata);
            sb_check(dut_t.mem_addr === exp_t.mem_addr, "mem_addr", dut_t.mem_addr, exp_t.mem_addr);
            sb_check(dut_t.mem_rmask === exp_t.mem_rmask, "mem_rmask", dut_t.mem_rmask, exp_t.mem_rmask);
            sb_check(dut_t.mem_wmask === exp_t.mem_wmask, "mem_wmask", dut_t.mem_wmask, exp_t.mem_wmask);
            sb_check((dut_t.mem_rdata & bmask(exp_t.mem_rmask)) === (exp_t.mem_rdata & bmask(exp_t.mem_rmask)), "mem_rdata", dut_t.mem_rdata, exp_t.mem_rdata);
            sb_check((dut_t.mem_wdata & bmask(exp_t.mem_wmask)) === (exp_t.mem_wdata & bmask(exp_t.mem_wmask)), "mem_wdata", dut_t.mem_wdata, exp_t.mem_wdata);

            if (dut_t.trap) cause_seen = dut_t.cause;
            retired++;
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("CORE_SB", $sformatf("retired=%0d checks=%0d errors=%0d final_cause=%0d",
                     retired, checks, errors, cause_seen), errors ? UVM_LOW : UVM_MEDIUM)
        endfunction
    endclass

    // ---------------------------------------------------------------- core_coverage
    class core_coverage extends uvm_component;
        `uvm_component_utils(core_coverage)

        uvm_analysis_imp_core #(core_rvfi_txn, core_coverage) core_export;
        local core_rvfi_txn m_t;

        covergroup cg_insn;
            option.per_instance = 1;
            cp_opcode: coverpoint m_t.insn[6:0] {
                bins lui    = {7'b0110111}; bins auipc = {7'b0010111};
                bins jal    = {7'b1101111}; bins jalr  = {7'b1100111};
                bins branch = {7'b1100011}; bins load  = {7'b0000011};
                bins store  = {7'b0100011}; bins opimm = {7'b0010011};
                bins op     = {7'b0110011}; bins fence = {7'b0001111};
                bins system = {7'b1110011};
                bins other  = default;
            }
            cp_funct3: coverpoint m_t.insn[14:12];
            cp_alu_operand: coverpoint m_t.rs1_rdata {
                bins zero = {32'h0};  bins minus1 = {32'hFFFFFFFF};
                bins max  = {32'h7FFFFFFF}; bins min = {32'h80000000};
                bins other = default;
            }
            cp_rs2_operand: coverpoint m_t.rs2_rdata iff (m_t.insn[6:0] == 7'b0110011) {
                bins zero = {32'h0};  bins minus1 = {32'hFFFFFFFF};
                bins max  = {32'h7FFFFFFF}; bins min = {32'h80000000};
                bins other = default;
            }
            cp_rd_eq_rs1: coverpoint (m_t.rd_addr == m_t.rs1_addr && m_t.rd_addr != 0);
            cp_rs1_eq_rs2: coverpoint (m_t.rs1_addr == m_t.rs2_addr) iff (m_t.insn[6:0] inside {7'b0110011, 7'b1100011});
            cp_rd_x0: coverpoint (m_t.rd_addr == 5'd0);
            // taken vs not-taken, sampled only on branch opcodes
            cp_branch_taken: coverpoint (m_t.pc_wdata != m_t.pc_rdata + 32'd4) iff (m_t.insn[6:0] == 7'b1100011 && !m_t.trap);
            // jump direction (forward vs backward target), JAL/JALR only
            cp_jump_dir: coverpoint (m_t.pc_wdata > m_t.pc_rdata) iff (m_t.insn[6:0] inside {7'b1101111, 7'b1100111} && !m_t.trap);
            // byte offset within the word for every load/store, all 4 phases
            cp_mem_off: coverpoint m_t.mem_addr[1:0] iff (m_t.insn[6:0] inside {7'b0000011, 7'b0100011});
            cp_trap: coverpoint m_t.trap;
            cp_cause: coverpoint m_t.cause iff (m_t.trap) { bins c[] = {0, 2, 3, 4, 6, 11}; }
            // opcode x funct3: LUI/AUIPC/JAL have no funct3 field (those bits
            // are immediate bits, not a real select) so those rows are
            // excluded rather than left as permanently-partial cross cells.
            cx_op_f3: cross cp_opcode, cp_funct3 {
                ignore_bins no_f3_field = binsof(cp_opcode.lui) || binsof(cp_opcode.auipc) || binsof(cp_opcode.jal);
            }
            // branch funct3 (the 6 real branch types) x taken/not-taken;
            // funct3=010/011 have no branch encoding in base RV32I (beq=000,
            // bne=001, blt=100, bge=101, bltu=110, bgeu=111 are the only six
            // real branch opcode/funct3 combos) - a branch with funct3=010/011
            // traps via the illegal-instruction path before pc_wdata vs.
            // pc_rdata is ever evaluated (the coverpoint's own `!m_t.trap`
            // guard filters it out), so those two cells can never be sampled
            // and are excluded rather than left permanently at zero.
            cx_branch_taken: cross cp_funct3, cp_branch_taken {
                ignore_bins reserved_f3 = binsof(cp_funct3) intersect {3'b010, 3'b011};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            core_export = new("core_export", this);
            cg_insn = new();
        endfunction

        function void write_core(core_rvfi_txn t);
            m_t = t;
            cg_insn.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("CORE_COV", $sformatf("functional coverage = %0.1f%%", cg_insn.get_coverage()), UVM_LOW)
        endfunction
    endclass

    // -------------------------------------------------------------------- core_env
    class core_env extends uvm_env;
        `uvm_component_utils(core_env)

        core_agent      agent;
        core_scoreboard sb;
        core_coverage   cov;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = core_agent::type_id::create("agent", this);
            sb    = core_scoreboard::type_id::create("sb", this);
            cov   = core_coverage::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.monitor.ap.connect(sb.core_export);
            agent.monitor.ap.connect(cov.core_export);
        endfunction
    endclass

    // ------------------------------------------------------------------------- test
    // A single test: wait for the DUT to halt (trap) or time out, then report.
    // Which PROGRAM runs is decided entirely outside UVM, by +HEX=/+DHEX= at
    // $readmemh time (both the DUT's ins_mem and this scoreboard's reference
    // model load the same file) - see the class comment at the top of this
    // package for why that split is intentional.
    class core_base_test extends uvm_test;
        `uvm_component_utils(core_base_test)

        core_env env;
        virtual rvfi_if.MONITOR vif;
        int max_cycles = 200000;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = core_env::type_id::create("env", this);
            if (!uvm_config_db#(virtual rvfi_if.MONITOR)::get(this, "", "vif", vif))
                `uvm_fatal("CORE_TEST", "no vif set - did the tb top call uvm_config_db#(virtual rvfi_if.MONITOR)::set(...)?")
            void'($value$plusargs("MAXCYC=%d", max_cycles));
        endfunction

        task run_phase(uvm_phase phase);
            int cyc = 0;
            bit halted = 0;
            phase.raise_objection(this);
            while (!halted && cyc < max_cycles) begin
                @(negedge vif.clk);
                cyc++;
                if (!vif.rst && vif.rvfi.valid && vif.rvfi.trap) halted = 1;
            end
            repeat (2) @(posedge vif.clk);
            if (!halted) `uvm_error("CORE_TEST", $sformatf("TIMEOUT after %0d cycles", cyc))
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            if (env.sb.errors == 0)
                `uvm_info("CORE_TEST", "*** TEST PASSED ***", UVM_NONE)
            else
                `uvm_error("CORE_TEST", $sformatf("*** TEST FAILED *** (%0d errors)", env.sb.errors))
        endfunction
    endclass

endpackage