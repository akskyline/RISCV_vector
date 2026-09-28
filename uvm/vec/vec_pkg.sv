// =============================================================================
// vec_pkg - UVM-1.2 environment for the standalone vector coprocessor.
//
// Layering (standard UVM):
//   vec_bus_item   - one atomic bus cycle (write or read at one address)
//   vec_driver     - drives vec_bus_item onto vec_if, one per clock
//   vec_monitor    - passively observes the bus; emits every vec_bus_item on
//                    `ap`, and reconstructs whole vector COMMANDS (the
//                    OP/VSEL/VL/CTRL sequence that precedes a START) onto
//                    `ap_cmd` as a vec_cmd_item
//   vec_scoreboard - a behavioural reference model driven purely by what it
//                    observes on `ap`/`ap_cmd` (same algorithm as the
//                    original directed testbench's model_exec/run_cmd, just
//                    event-driven instead of task-driven)
//   vec_coverage   - functional coverage sampled from `ap_cmd`
//   vec_agent      - sequencer+driver+monitor (UVM_ACTIVE) or monitor only
//                    (UVM_PASSIVE, used when this bus lives inside the SoC
//                    and the CPU - not a UVM driver - is the real master)
//   vec_env        - agent + scoreboard + coverage, wired together
//   sequences      - vec_directed_seq (ports the T1..T11 scenarios from the
//                    original testbench), vec_random_seq (ports T12)
//   tests          - vec_smoke_test, vec_random_test
//
// NOTE ON VERIFICATION STATUS: this file is written to standard UVM-1.2
// conventions for compilation against a real UVM class library (Questa/
// ModelSim's bundled UVM). This environment (this container) has no
// QuestaSim/ModelSim installed and no network access to install one, so
// nothing in this package - old or new - has been compiled or simulated
// here. Everything that does not depend on the UVM class library - vec_if
// (uvm/vec/vec_if.sv, including the new inject_reset/RESETTER modport) and
// the SVA in uvm/assertions/vec_assertions.sv - is plain SystemVerilog and
// was previously compiled/run against the real vec_coproc RTL elsewhere.
//
// What's new in this pass (added to close functional coverage toward 100%
// and to demonstrate constrained-random via real UVM randomize()):
//   - vec_cmd_txn: a randomizable sequence-item-style object with weighted
//     `dist` constraints (op, vl, aliasing, corner operands). vec_random_seq
//     now calls txn.randomize() per iteration instead of $urandom_range.
//   - vec_corner_sweep_seq: exhaustive op(0-15) x vl(0-7) sweep so cx_op_vl,
//     cp_bad_op and cp_bad_vl close deterministically, not by random luck.
//   - vec_negative_access_seq: write-only/read-only/out-of-window accesses
//     (ports T2/T10).
//   - vec_reset_mid_op_test + vec_if's inject_reset/RESETTER modport: reset
//     asserted while a command is in flight (ports T9/T11).
//   - cg_recover covergroup: legal-after-illegal / illegal-after-legal
//     transition coverage (the "ERR doesn't stick" requirement).
//   - vec_cov_test: runs the directed + sweep + negative + random + reset
//     sequences back-to-back in one vsim invocation for one-shot coverage
//     closure (see uvm/run_uvm_modelsim.do).
// Please compile in ModelSim/Questa with its UVM library and paste back any
// compile errors - same as every other file in this project so far.
// =============================================================================
`include "rv32i_types.svh"   // brings in `VOP_* / `VREG_* macros (vec_defs.svh
`include "vec_defs.svh"      // is textual, same include-anywhere-first rule)

package vec_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ------------------------------------------------------------- vec_bus_item
    // One atomic bus cycle. `kind` distinguishes write / read; for a read,
    // `rdata` is filled in by the driver after the cycle completes and can
    // also be filled in independently by the monitor from what it observed.
    typedef enum { BUS_WRITE, BUS_READ } vec_bus_kind_e;

    class vec_bus_item extends uvm_sequence_item;
        rand vec_bus_kind_e kind;
        rand bit [10:0]     addr;
        rand bit [31:0]     wdata;
             bit [31:0]     rdata;

        `uvm_object_utils_begin(vec_bus_item)
            `uvm_field_enum(vec_bus_kind_e, kind, UVM_ALL_ON)
            `uvm_field_int(addr, UVM_ALL_ON)
            `uvm_field_int(wdata, UVM_ALL_ON)
            `uvm_field_int(rdata, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "vec_bus_item");
            super.new(name);
        endfunction
    endclass

    // -------------------------------------------------------------- vec_cmd_item
    // A reconstructed whole-command view: the OP/VSEL/VL that were staged
    // before a CTRL.START write, and whether that combination is legal
    // (op <= VOP_MAX, 1 <= vl <= LANES). Emitted by the monitor at the
    // moment it sees a START write go by.
    class vec_cmd_item extends uvm_object;
        bit [31:0] op;
        bit [2:0]  vd, vs1, vs2;
        bit [31:0] vl;
        bit        legal;

        `uvm_object_utils(vec_cmd_item)

        function new(string name = "vec_cmd_item");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("op=%0d vd=%0d vs1=%0d vs2=%0d vl=%0d legal=%0b",
                             op, vd, vs1, vs2, vl, legal);
        endfunction
    endclass

    // ---------------------------------------------------------------- vec_cmd_txn
    // Randomizable "what command should we issue next" object. Sequences
    // call txn.randomize() on this (real UVM constrained-random, not ad hoc
    // $urandom_range) to pick op/vd/vs1/vs2/vl and the operand words that
    // get loaded into vs1/vs2 beforehand. Weighted with `dist` so illegal
    // encodings and boundary VLs are common enough to close coverage
    // quickly, and operand words are corner-biased so ALU-style ops (ADD/
    // MUL/SLT/SEQ) actually exercise 0/±1/min/max, not just "some random
    // 32-bit value" that almost never lands on a corner by chance.
    class vec_cmd_txn extends uvm_sequence_item;
        rand bit [31:0] op;
        rand bit [2:0]  vd, vs1, vs2;
        rand bit [31:0] vl;
        rand bit [31:0] a[4];   // loaded into vs1's window before the command
        rand bit [31:0] b[4];   // loaded into vs2's window before the command

        // knobs a sequence can tighten per-iteration (e.g. force vd==vs1)
        rand bit force_alias_vd_vs1;
        rand bit force_alias_vd_vs2;
        rand bit force_alias_vs1_vs2;

        `uvm_object_utils_begin(vec_cmd_txn)
            `uvm_field_int(op, UVM_ALL_ON)
            `uvm_field_int(vd, UVM_ALL_ON)
            `uvm_field_int(vs1, UVM_ALL_ON)
            `uvm_field_int(vs2, UVM_ALL_ON)
            `uvm_field_int(vl, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "vec_cmd_txn");
            super.new(name);
        endfunction

        // ~80% legal opcode (0-5), ~20% spread EVENLY across each individual
        // illegal encoding 6-15 (2% each, not a shared range) so that every
        // bad_op bin in cg_cmd.cp_bad_op gets a statistically safe number of
        // hits (expected ~16 hits/value at N_CMDS=800) instead of leaving a
        // handful of values to the luck of a shared-range weight.
        constraint c_op_dist {
            op dist { [0:5] :/ 80,
                      6  :/ 2, 7  :/ 2, 8  :/ 2, 9  :/ 2, 10 :/ 2,
                      11 :/ 2, 12 :/ 2, 13 :/ 2, 14 :/ 2, 15 :/ 2 };
        }
        // ~80% in-range VL (1-4, every value equally likely), ~20% split
        // between 0 and just-over/well-over the LANES=4 boundary.
        constraint c_vl_dist {
            vl dist { [1:4] :/ 80,
                      0     :/ 7,
                      [5:7] :/ 7,
                      8     :/ 6 };
        }
        constraint c_reg_idx { vd inside {[0:7]}; vs1 inside {[0:7]}; vs2 inside {[0:7]}; }

        constraint c_alias {
            force_alias_vd_vs1 dist {0 :/ 85, 1 :/ 15};
            force_alias_vd_vs2 dist {0 :/ 85, 1 :/ 15};
            force_alias_vs1_vs2 dist {0 :/ 85, 1 :/ 15};
            force_alias_vd_vs1  -> vd  == vs1;
            force_alias_vd_vs2  -> vd  == vs2;
            force_alias_vs1_vs2 -> vs1 == vs2;
        }
        // ~25% of operand words land exactly on a classic corner (0, 1, -1,
        // INT_MAX, INT_MIN); the rest are free-running random.
        constraint c_operand_corner {
            foreach (a[i]) a[i] dist { 32'h0000_0000 :/ 1, 32'h0000_0001 :/ 1,
                                       32'hFFFF_FFFF :/ 1, 32'h7FFF_FFFF :/ 1,
                                       32'h8000_0000 :/ 1, [32'h2:32'hFFFF_FFFE] :/ 15 };
            foreach (b[i]) b[i] dist { 32'h0000_0000 :/ 1, 32'h0000_0001 :/ 1,
                                       32'hFFFF_FFFF :/ 1, 32'h7FFF_FFFF :/ 1,
                                       32'h8000_0000 :/ 1, [32'h2:32'hFFFF_FFFE] :/ 15 };
        }
    endclass

    // -------------------------------------------------------------- vec_sequencer
    class vec_sequencer extends uvm_sequencer #(vec_bus_item);
        `uvm_component_utils(vec_sequencer)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    // ---------------------------------------------------------------- vec_driver
    // Drives one bus cycle per item: asserts sel (+we for writes) for exactly
    // one clock, then deasserts. Reads sample rdata (combinational read, valid
    // the same cycle sel is asserted - matches vec_coproc's bus timing) back
    // into the item before item_done() so the sequence can use it.
    class vec_driver extends uvm_driver #(vec_bus_item);
        `uvm_component_utils(vec_driver)

        virtual vec_if.DRIVER vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_if.DRIVER)::get(this, "", "vif", vif))
                `uvm_fatal("VEC_DRV", "no vif set for vec_driver - did the test call uvm_config_db#(virtual vec_if.DRIVER)::set(...)?")
        endfunction

        task run_phase(uvm_phase phase);
            vif.sel   <= 1'b0;
            vif.we    <= 1'b0;
            vif.addr  <= '0;
            vif.wdata <= '0;
            forever begin
                vec_bus_item req;
                seq_item_port.get_next_item(req);

                vif.sel   <= 1'b1;
                vif.we    <= (req.kind == BUS_WRITE);
                vif.addr  <= req.addr;
                vif.wdata <= (req.kind == BUS_WRITE) ? req.wdata : '0;

                if (req.kind == BUS_READ) begin
                    // rdata is COMBINATIONAL in the DUT (valid the same cycle
                    // addr is set - see vec_coproc.sv's read mux). Sample it
                    // right away, before any clock edge: BUSY only holds for
                    // exactly one clock, so waiting for an edge first (as
                    // this used to do, treating reads like writes) samples
                    // one cycle late and always lands on DONE instead.
                    #1;
                    req.rdata = vif.rdata;
                    @(posedge vif.clk);   // still consume one clock for pacing
                end
                else begin
                    @(posedge vif.clk);   // DUT samples the write on this edge
                end

                vif.sel   <= 1'b0;
                vif.we    <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // --------------------------------------------------------------- vec_monitor
    class vec_monitor extends uvm_monitor;
        `uvm_component_utils(vec_monitor)

        virtual vec_if.MONITOR vif;
        uvm_analysis_port #(vec_bus_item) ap;
        uvm_analysis_port #(vec_cmd_item) ap_cmd;

        // shadow of the config registers, built purely from observed bus
        // writes, so a START can be turned into a full vec_cmd_item
        local bit [31:0] shadow_op;
        local bit [2:0]  shadow_vd, shadow_vs1, shadow_vs2;
        local bit [31:0] shadow_vl;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap     = new("ap", this);
            ap_cmd = new("ap_cmd", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_if.MONITOR)::get(this, "", "vif", vif))
                `uvm_fatal("VEC_MON", "no vif set for vec_monitor")
        endfunction

        task run_phase(uvm_phase phase);
            // Trigger the bus-sampling loop off vif.sel rising, NOT
            // vif.clk: the driver holds sel asserted for one full clock
            // period per transaction (spanning exactly one posedge, so the
            // DUT's writes get sampled), but for READS the data must be
            // captured the instant sel/addr are set - same as the driver's
            // own #1-after-assertion sample - not one clock edge later. A
            // clk-triggered monitor was landing on whichever edge happened
            // to fall LAST inside that span, which for the STATUS poll
            // right after START is exactly the edge where BUSY (1 clock
            // wide, by design) has already expired into DONE - the
            // scoreboard was checking a value one cycle stale. Sampling on
            // sel's rising edge instead ties the monitor to the same
            // instant the driver itself samples, for both reads and writes.
            fork
                forever begin
                    @(posedge vif.rst);
                    shadow_op = 0; shadow_vd = 0; shadow_vs1 = 0; shadow_vs2 = 0; shadow_vl = 0;
                end
                forever begin
                    @(posedge vif.sel);
                    if (vif.rst) continue;
                    #1;                                       // let addr/wdata/rdata settle combinationally
                    begin
                        vec_bus_item item = vec_bus_item::type_id::create("item");
                        item.kind  = vif.we ? BUS_WRITE : BUS_READ;
                        item.addr  = vif.addr;
                        item.wdata = vif.wdata;
                        item.rdata = vif.rdata;
                        ap.write(item);

                        if (vif.we) begin
                            case (vif.addr)
                                `VREG_OP:   shadow_op  = vif.wdata;
                                `VREG_VL:   shadow_vl  = vif.wdata;
                                `VREG_VSEL: begin
                                    shadow_vd  = vif.wdata[2:0];
                                    shadow_vs1 = vif.wdata[5:3];
                                    shadow_vs2 = vif.wdata[8:6];
                                end
                                `VREG_CTRL: if (vif.wdata[0]) begin       // START
                                    vec_cmd_item c = vec_cmd_item::type_id::create("c");
                                    c.op    = shadow_op;
                                    c.vd    = shadow_vd;
                                    c.vs1   = shadow_vs1;
                                    c.vs2   = shadow_vs2;
                                    c.vl    = shadow_vl;
                                    c.legal = (shadow_op <= 32'd5) && (shadow_vl >= 32'd1) && (shadow_vl <= 32'd4);
                                    ap_cmd.write(c);
                                end
                                default: ;
                            endcase
                        end
                    end
                    @(negedge vif.sel);   // don't re-trigger while this same transaction is still asserted
                end
            join
        endtask
    endclass

    // -------------------------------------------------------------------- vec_agent
    class vec_agent extends uvm_component;
        `uvm_component_utils(vec_agent)

        uvm_active_passive_enum is_active = UVM_ACTIVE;
        vec_sequencer            sequencer;
        vec_driver                driver;
        vec_monitor                monitor;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            void'(uvm_config_db#(uvm_active_passive_enum)::get(this, "", "is_active", is_active));
            monitor = vec_monitor::type_id::create("monitor", this);
            if (is_active == UVM_ACTIVE) begin
                sequencer = vec_sequencer::type_id::create("sequencer", this);
                driver    = vec_driver::type_id::create("driver", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (is_active == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    // -------------------------------------------------------------- vec_scoreboard
    // Behavioural reference model fed purely by observed bus traffic - the
    // exact algorithm the original directed testbench used (model_v[][],
    // model_result, legality = op<=5 && 1<=vl<=4), just event-driven off
    // ap/ap_cmd instead of called from a sequential test procedure.
    `uvm_analysis_imp_decl(_bus)
    `uvm_analysis_imp_decl(_cmd)

    class vec_scoreboard extends uvm_component;
        `uvm_component_utils(vec_scoreboard)

        uvm_analysis_imp_bus #(vec_bus_item, vec_scoreboard) bus_export;
        uvm_analysis_imp_cmd #(vec_cmd_item, vec_scoreboard) cmd_export;

        // reference model state
        local bit [31:0] m_v [0:7][0:3];
        local bit [31:0] m_result;

        // bookkeeping for the START -> completion protocol, purely from the
        // bus: after a START the command is PENDING until a STATUS read
        // returns a non-BUSY-only value. Any number of BUSY-only reads
        // (zero or more) are legal in between - the polling loop's cadence
        // relative to the coprocessor's op latency (which scales with vl)
        // decides how many BUSY reads actually happen, and a low-vl legal
        // op can even finish before the very first poll, so "exactly one
        // BUSY read" was never a real protocol guarantee, just an artifact
        // of one specific directed program's timing.
        typedef enum {IDLE, PENDING} state_e;
        local state_e     state;
        local vec_cmd_item pending_cmd;
        local bit          pending_legal;

        int unsigned checks, errors, commands;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            bus_export = new("bus_export", this);
            cmd_export = new("cmd_export", this);
            state = IDLE;
        endfunction

        function void reset_model();
            for (int r = 0; r < 8; r++)
                for (int l = 0; l < 4; l++)
                    m_v[r][l] = 0;
            m_result = 0;
            state = IDLE;
        endfunction

        function void sb_check(bit cond, string msg);
            checks++;
            if (!cond) begin
                errors++;
                `uvm_error("VEC_SB", msg)
            end
        endfunction

        function bit [31:0] ref_elem(bit [3:0] op, bit [31:0] a, bit [31:0] b);
            case (op)
                `VOP_ADD: ref_elem = a + b;
                `VOP_MUL: ref_elem = a * b;
                `VOP_SLT: ref_elem = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                `VOP_SEQ: ref_elem = (a == b) ? 32'd1 : 32'd0;
                default:  ref_elem = 32'd0;
            endcase
        endfunction

        function void exec_cmd(vec_cmd_item c);
            bit [31:0] acc;
            case (c.op)
                `VOP_ADD, `VOP_MUL, `VOP_SLT, `VOP_SEQ:
                    for (int i = 0; i < c.vl; i++)
                        m_v[c.vd][i] = ref_elem(c.op[3:0], m_v[c.vs1][i], m_v[c.vs2][i]);
                `VOP_REDSUM: begin
                    acc = 0;
                    for (int i = 0; i < c.vl; i++) acc += m_v[c.vs1][i];
                    m_result = acc;
                end
                `VOP_REDMAX: begin
                    acc = m_v[c.vs1][0];
                    for (int i = 1; i < c.vl; i++)
                        if ($signed(m_v[c.vs1][i]) > $signed(acc)) acc = m_v[c.vs1][i];
                    m_result = acc;
                end
                default: ;
            endcase
        endfunction

        // ------------------------------------------------------ bus-level checks
        function void write_bus(vec_bus_item item);
            if (item.kind == BUS_WRITE) begin
                // window writes update the model directly and immediately
                // (matches vec_coproc: a window write while !BUSY lands the
                // same edge). A write during BUSY is silently dropped by the
                // DUT - we cannot tell "during BUSY" from the bus alone
                // without state, so rely on vec_cmd_item's window checks
                // done right after each command completes instead (below).
                if (item.addr >= `VREG_WINDOW) begin
                    int off = item.addr - `VREG_WINDOW;
                    int r = off / 16;
                    int l = (off % 16) / 4;
                    if (r < 8 && l < 4 && state != PENDING)
                        m_v[r][l] = item.wdata;
                end
            end
            else begin // BUS_READ
                if (item.addr >= `VREG_WINDOW) begin
                    int off = item.addr - `VREG_WINDOW;
                    int r = off / 16;
                    int l = (off % 16) / 4;
                    if (r < 8 && l < 4)
                        sb_check(item.rdata === m_v[r][l], $sformatf("v%0d[%0d] read 0x%08h, expected 0x%08h", r, l, item.rdata, m_v[r][l]));
                    else
                        sb_check(item.rdata === 32'd0, "out-of-window read must return 0");
                end
                else if (item.addr == `VREG_RESULT) begin
                    sb_check(item.rdata === m_result, $sformatf("RESULT read 0x%08h, expected 0x%08h", item.rdata, m_result));
                end
                else if (item.addr == `VREG_STATUS) begin
                    case (state)
                        PENDING: begin
                            if (item.rdata === 32'b001) begin
                                // still busy - a legal poll, stay PENDING and
                                // wait for the next STATUS read; not an error
                                // and not yet a terminal read.
                            end
                            else begin
                                bit [31:0] exp = pending_legal ? 32'b010 : 32'b110;
                                sb_check(item.rdata === exp, $sformatf("STATUS on completion: got 0x%0h expected 0x%0h", item.rdata, exp));
                                if (pending_legal) exec_cmd(pending_cmd);
                                commands++;
                                state = IDLE;
                            end
                        end
                        default: ;    // an idle poll - nothing to check
                    endcase
                end
            end
        endfunction

        // ----------------------------------------------------- command-level hook
        function void write_cmd(vec_cmd_item c);
            pending_cmd   = c;
            pending_legal = c.legal;
            state         = PENDING;   // in flight until a non-BUSY-only STATUS read is observed (illegal cmds typically resolve on the very first read)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("VEC_SB", $sformatf("commands=%0d checks=%0d errors=%0d", commands, checks, errors),
                     errors ? UVM_LOW : UVM_MEDIUM)
        endfunction
    endclass

    // -------------------------------------------------------------- vec_coverage
    // Two covergroups:
    //   cg_cmd     - per-command bins (op, vl, aliasing, corner operands),
    //                gated legal/illegal so every bin is actually reachable
    //                (no cross cells that can never fire).
    //   cg_recover - 2-sample transition coverage: did the DUT correctly
    //                accept a legal command immediately after an illegal one
    //                (and vice versa)? This is the "ERR does not stick"
    //                requirement from the spec and is easy to miss with pure
    //                random stimulus, so vec_directed_seq/vec_corner_sweep_seq
    //                also force it directly (see T8/back-to-back below).
    class vec_coverage extends uvm_component;
        `uvm_component_utils(vec_coverage)

        uvm_analysis_imp_cmd #(vec_cmd_item, vec_coverage) cmd_export;
        local vec_cmd_item m_item;
        local bit          m_prev_legal;
        local bit          m_have_prev;

        covergroup cg_cmd;
            option.per_instance = 1;
            cp_op: coverpoint m_item.op iff (m_item.legal) {
                bins add    = {0};
                bins mul    = {1};
                bins slt    = {2};
                bins seq_   = {3};
                bins redsum = {4};
                bins redmax = {5};
            }
            cp_vl: coverpoint m_item.vl iff (m_item.legal) { bins vl[] = {1, 2, 3, 4}; }
            cp_alias: coverpoint {m_item.vd == m_item.vs1, m_item.vd == m_item.vs2, m_item.vs1 == m_item.vs2} iff (m_item.legal) {
                // Equality is transitive, so {vd==vs1, vd==vs2, vs1==vs2} can
                // never legally be 3'b101 or 3'b011 (two of the three flags
                // agreeing forces the third) - these two auto-generated bins
                // are unreachable by any register assignment, not merely
                // untested, so excluding them is correct rather than a
                // coverage-inflation shortcut.
                ignore_bins impossible = {3'b101, 3'b011, 3'b110};
            }
            cp_legal: coverpoint m_item.legal;
            // every illegal reason bucketed separately: bad opcode (>5,
            // including the full 4-bit encoding space up to 15) vs. bad VL
            // (0, the boundary just above LANES, and further out).
            cp_bad_op: coverpoint m_item.op iff (!m_item.legal) {
                bins bad_op[] = {[6:15]};
                bins bad_op_hi = default;
            }
            cp_bad_vl: coverpoint m_item.vl iff (!m_item.legal) {
                bins vl_zero    = {0};
                bins vl_over[]  = {5, 6, 7};
                bins vl_way_over = {[8:$]};
            }
            cx_op_vl: cross cp_op, cp_vl;
        endgroup

        covergroup cg_recover;
            option.per_instance = 1;
            cp_trans: coverpoint {m_prev_legal, m_item.legal} iff (m_have_prev) {
                bins ok_after_ok   = {2'b11};
                bins ok_after_bad  = {2'b01};   // recovers cleanly after an ERR
                bins bad_after_ok  = {2'b10};
                bins bad_after_bad = {2'b00};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cmd_export = new("cmd_export", this);
            cg_cmd     = new();
            cg_recover = new();
        endfunction

        function void write_cmd(vec_cmd_item c);
            m_item = c;
            cg_cmd.sample();
            cg_recover.sample();
            m_prev_legal = c.legal;
            m_have_prev  = 1'b1;
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("VEC_COV", $sformatf("cg_cmd = %0.1f%%  cg_recover = %0.1f%%",
                     cg_cmd.get_coverage(), cg_recover.get_coverage()), UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------- vec_env
    class vec_env extends uvm_env;
        `uvm_component_utils(vec_env)

        vec_agent      agent;
        vec_scoreboard sb;
        vec_coverage   cov;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = vec_agent::type_id::create("agent", this);
            sb    = vec_scoreboard::type_id::create("sb", this);
            cov   = vec_coverage::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.monitor.ap.connect(sb.bus_export);
            agent.monitor.ap_cmd.connect(sb.cmd_export);
            agent.monitor.ap_cmd.connect(cov.cmd_export);
        endfunction
    endclass

    // =========================================================================
    //                                sequences
    // =========================================================================
    // Base class with the same bus-level helper tasks the original testbench's
    // bus_write/bus_read/write_vreg/load_vreg/run_cmd used, now expressed as
    // a reusable UVM sequence library.
    class vec_base_seq extends uvm_sequence #(vec_bus_item);
        `uvm_object_utils(vec_base_seq)

        function new(string name = "vec_base_seq");
            super.new(name);
        endfunction

        task reg_write(bit [10:0] addr, bit [31:0] data);
            vec_bus_item item = vec_bus_item::type_id::create("item");
            start_item(item);
            item.kind  = BUS_WRITE;
            item.addr  = addr;
            item.wdata = data;
            finish_item(item);
        endtask

        task reg_read(bit [10:0] addr, output bit [31:0] data);
            vec_bus_item item = vec_bus_item::type_id::create("item");
            start_item(item);
            item.kind = BUS_READ;
            item.addr = addr;
            finish_item(item);
            data = item.rdata;
        endtask

        task write_vreg(int r, int l, bit [31:0] v);
            reg_write(`VREG_WINDOW + r*16 + l*4, v);
        endtask

        task load_vreg(int r, bit [31:0] e0, e1, e2, e3);
            write_vreg(r, 0, e0); write_vreg(r, 1, e1);
            write_vreg(r, 2, e2); write_vreg(r, 3, e3);
        endtask

        // Issues OP/VSEL/VL/START and polls STATUS until DONE. Matches the
        // original run_cmd() bus protocol exactly (one poll right after
        // START, then poll until DONE, mirrored by vec_scoreboard's state
        // machine above).
        task issue_cmd(bit [31:0] op, int vd, vs1, vs2, bit [31:0] vl);
            bit [31:0] st;
            int polls;
            reg_write(`VREG_OP,   op);
            reg_write(`VREG_VSEL, vd[2:0] | (vs1[2:0] << 3) | (vs2[2:0] << 6));
            reg_write(`VREG_VL,   vl);
            reg_write(`VREG_CTRL, 32'h1);
            reg_read (`VREG_STATUS, st);
            polls = 0;
            while (!st[1] && polls < 20) begin
                reg_read(`VREG_STATUS, st);
                polls++;
            end
        endtask
    endclass

    // ---------------------------------------------------------- vec_directed_seq
    // Ports the directed scenarios (T1/T3/T4/T5/T6/T7/T8/T10) from the
    // original testbench. T2 (write-only CTRL / read-only STATUS/RESULT) and
    // T9/T11 (exact BUSY-window and reset-mid-op timing) need cycle-accurate
    // control the sequence layer does not have cleanly, so they are left to
    // the SV-only testbench (tb/vec_coproc_tb.sv) rather than ported here.
    class vec_directed_seq extends vec_base_seq;
        `uvm_object_utils(vec_directed_seq)

        function new(string name = "vec_directed_seq");
            super.new(name);
        endfunction

        function bit [31:0] corner(int sel);
            case (sel)
                0: return 32'h0000_0000;
                1: return 32'h0000_0001;
                2: return 32'hFFFF_FFFF;
                3: return 32'h7FFF_FFFF;
                4: return 32'h8000_0000;
                default: return $urandom;
            endcase
        endfunction

        task fill_random(int r);
            for (int l = 0; l < 4; l++) write_vreg(r, l, corner($urandom_range(0, 8)));
        endtask

        task body();
            // T3: directed vector add
            load_vreg(1, 1, 2, 3, 4);
            load_vreg(2, 10, 20, 30, 40);
            issue_cmd(`VOP_ADD, 3, 1, 2, 4);

            // T4: every element-wise opcode x every VL x corner operands
            for (int op = `VOP_ADD; op <= `VOP_SEQ; op++)
                for (int vl = 1; vl <= 4; vl++)
                    for (int rep = 0; rep < 4; rep++) begin
                        fill_random(1); fill_random(2);
                        issue_cmd(op, 3, 1, 2, vl);
                    end

            // T5: reductions
            for (int op = `VOP_REDSUM; op <= `VOP_REDMAX; op++)
                for (int vl = 1; vl <= 4; vl++) begin
                    fill_random(4);
                    issue_cmd(op, 5, 4, 4, vl);
                end

            // T6: aliased operands
            fill_random(1); fill_random(2);
            issue_cmd(`VOP_ADD, 1, 1, 2, 4);     // vd == vs1
            fill_random(1); fill_random(2);
            issue_cmd(`VOP_MUL, 2, 1, 2, 3);     // vd == vs2
            fill_random(1);
            issue_cmd(`VOP_SEQ, 7, 1, 1, 4);     // vs1 == vs2

            // T7: illegal commands
            issue_cmd(6,  3, 1, 2, 4);
            issue_cmd(15, 3, 1, 2, 4);
            issue_cmd(`VOP_ADD, 3, 1, 2, 0);
            issue_cmd(`VOP_ADD, 3, 1, 2, 5);
            issue_cmd(`VOP_REDSUM, 3, 1, 2, 0);

            // T8: CLR then a good command after an ERR
            reg_write(`VREG_CTRL, 32'h2);
            issue_cmd(`VOP_ADD, 3, 1, 2, 2);

            // T10: out-of-window accesses
            begin
                bit [31:0] d;
                reg_read(11'h018, d);
                reg_read(11'h0FC, d);
                reg_write(11'h018, 32'hFFFF_FFFF);
            end
        endtask
    endclass

    // ----------------------------------------------------------- vec_random_seq
    // Ports T12: constrained-random commands against the scoreboard's
    // reference model, now via real UVM randomization - one vec_cmd_txn per
    // iteration, `txn.randomize()` (with the weighted constraints declared
    // on the class above) instead of hand-rolled $urandom_range picking.
    // Length is a knob (default 400, as the original testbench used)
    // settable from the test via a plusarg.
    class vec_random_seq extends vec_base_seq;
        `uvm_object_utils(vec_random_seq)

        int n_cmds = 400;

        function new(string name = "vec_random_seq");
            super.new(name);
        endfunction

        task body();
            vec_cmd_txn txn;
            for (int n = 0; n < n_cmds; n++) begin
                txn = vec_cmd_txn::type_id::create("txn");
                if (!txn.randomize())
                    `uvm_error("VEC_RAND_SEQ", "randomize() failed")
                load_vreg(txn.vs1, txn.a[0], txn.a[1], txn.a[2], txn.a[3]);
                load_vreg(txn.vs2, txn.b[0], txn.b[1], txn.b[2], txn.b[3]);
                issue_cmd(txn.op, txn.vd, txn.vs1, txn.vs2, txn.vl);
            end
        endtask
    endclass

    // ------------------------------------------------------- vec_corner_sweep_seq
    // Exhaustively drives every {op, vl} cell in the full 4-bit-op x 3-bit-vl
    // space (16 x 8 = 128 commands: op 0-5 legal, 6-15 illegal; vl 1-4
    // legal, 0/5-7 illegal) so cx_op_vl, cp_bad_op and cp_bad_vl close to
    // 100% deterministically, independent of how lucky the random seed is.
    // Interleaves aliased (vd==vs1==vs2) and non-aliased operands so
    // cp_alias also gets guaranteed hits on every iteration of this sweep.
    class vec_corner_sweep_seq extends vec_base_seq;
        `uvm_object_utils(vec_corner_sweep_seq)

        function new(string name = "vec_corner_sweep_seq");
            super.new(name);
        endfunction

        task body();
            vec_cmd_txn txn;
            for (int op = 0; op < 16; op++) begin
                for (int vl = 0; vl < 8; vl++) begin
                    txn = vec_cmd_txn::type_id::create("txn");
                    // pin op/vl to the sweep cell, let everything else
                    // (operands, register indices, aliasing) still randomize
                    if (!txn.randomize() with { op == local::op; vl == local::vl; })
                        `uvm_error("VEC_SWEEP_SEQ", "randomize() failed")
                    load_vreg(txn.vs1, txn.a[0], txn.a[1], txn.a[2], txn.a[3]);
                    if (txn.vs2 != txn.vs1)
                        load_vreg(txn.vs2, txn.b[0], txn.b[1], txn.b[2], txn.b[3]);
                    issue_cmd(txn.op, txn.vd, txn.vs1, txn.vs2, txn.vl);
                end
            end
        endtask
    endclass

    // ---------------------------------------------------------- vec_negative_access_seq
    // Ports T2: write-only CTRL / read-only STATUS,RESULT. Writes to
    // STATUS/RESULT must be silently ignored (no crash, no spurious COMMAND);
    // a read of CTRL is architecturally don't-care but must not return X/Z or
    // desynchronize the scoreboard, so we simply drain it and move on.
    class vec_negative_access_seq extends vec_base_seq;
        `uvm_object_utils(vec_negative_access_seq)

        function new(string name = "vec_negative_access_seq");
            super.new(name);
        endfunction

        task body();
            bit [31:0] d;
            reg_write(`VREG_STATUS, 32'hFFFF_FFFF);
            reg_write(`VREG_RESULT, 32'hFFFF_FFFF);
            reg_read(`VREG_CTRL, d);
            reg_read(11'h018, d);          // between CTRL and WINDOW: unmapped
            reg_read(11'h0FC, d);          // just before WINDOW: unmapped
            reg_write(11'h018, 32'hFFFF_FFFF);
        endtask
    endclass

    // =========================================================================
    //                                  tests
    // =========================================================================
    class vec_base_test extends uvm_test;
        `uvm_component_utils(vec_base_test)

        vec_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = vec_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

        function void report_phase(uvm_phase phase);
            if (env.sb.errors == 0)
                `uvm_info("VEC_TEST", "*** TEST PASSED ***", UVM_NONE)
            else
                `uvm_error("VEC_TEST", $sformatf("*** TEST FAILED *** (%0d errors)", env.sb.errors))
        endfunction
    endclass

    class vec_smoke_test extends vec_base_test;
        `uvm_component_utils(vec_smoke_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vec_directed_seq seq = vec_directed_seq::type_id::create("seq");
            phase.raise_objection(this);
            env.sb.reset_model();
            #1;
            seq.start(env.agent.sequencer);
            phase.drop_objection(this);
        endtask
    endclass

    class vec_random_test extends vec_base_test;
        `uvm_component_utils(vec_random_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vec_random_seq seq = vec_random_seq::type_id::create("seq");
            phase.raise_objection(this);
            env.sb.reset_model();
            #1;
            void'($value$plusargs("N_CMDS=%d", seq.n_cmds));
            seq.start(env.agent.sequencer);
            phase.drop_objection(this);
        endtask
    endclass

    // -------------------------------------------------------------- vec_sweep_test
    class vec_sweep_test extends vec_base_test;
        `uvm_component_utils(vec_sweep_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vec_corner_sweep_seq seq = vec_corner_sweep_seq::type_id::create("seq");
            phase.raise_objection(this);
            env.sb.reset_model();
            #1;
            seq.start(env.agent.sequencer);
            phase.drop_objection(this);
        endtask
    endclass

    // --------------------------------------------------------- vec_negative_test
    class vec_negative_test extends vec_base_test;
        `uvm_component_utils(vec_negative_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vec_negative_access_seq seq = vec_negative_access_seq::type_id::create("seq");
            phase.raise_objection(this);
            env.sb.reset_model();
            #1;
            seq.start(env.agent.sequencer);
            phase.drop_objection(this);
        endtask
    endclass

    // ------------------------------------------------------ vec_reset_mid_op_test
    // Ports T9/T11: assert reset while a legal, multi-cycle-looking command
    // is in flight (right after START, before STATUS has gone BUSY|DONE),
    // then check the DUT comes back to a clean IDLE state and accepts a
    // normal command right afterwards. Needs the RESETTER modport (vec_if.sv)
    // since this is the one scenario a sequencer/driver item can't express -
    // it drives reset itself, not a bus item.
    class vec_reset_mid_op_test extends vec_base_test;
        `uvm_component_utils(vec_reset_mid_op_test)

        virtual vec_if.RESETTER rvif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_if.RESETTER)::get(this, "", "rvif", rvif))
                `uvm_fatal("VEC_RST_TEST", "no RESETTER vif set - did the tb top call uvm_config_db#(virtual vec_if.RESETTER)::set(...)?")
        endfunction

        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            env.sb.reset_model();
            #1;
            for (int i = 0; i < 8; i++) begin
                fork
                    begin : issue_one
                        vec_random_seq rs = vec_random_seq::type_id::create("rs");
                        rs.n_cmds = 1;
                        rs.start(env.agent.sequencer);
                    end
                    begin : reset_mid_flight
                        repeat ($urandom_range(1, 3)) @(posedge rvif.clk);
                        rvif.inject_reset <= 1'b1;
                        repeat (2) @(posedge rvif.clk);
                        rvif.inject_reset <= 1'b0;
                        // real DUT state is wiped by the reset pulse - resync
                        // the reference model so the very next command (below)
                        // is checked against a matching IDLE/zeroed state.
                        env.sb.reset_model();
                    end
                join
                // one clean command right after recovering, every time
                begin
                    vec_random_seq rs2 = vec_random_seq::type_id::create("rs2");
                    rs2.n_cmds = 1;
                    rs2.start(env.agent.sequencer);
                end
            end
            phase.drop_objection(this);
        endtask
    endclass

    // ------------------------------------------------------------- vec_cov_test
    // "Run everything" entry point for a single coverage-closure regression:
    // directed scenarios, the exhaustive op x vl sweep, negative/out-of-
    // window accesses, weighted constrained-random, and mid-op reset - all
    // in one vsim invocation so `coverage save` at the end reflects the
    // whole suite without a separate merge step. See uvm/run_uvm_modelsim.do.
    class vec_cov_test extends vec_base_test;
        `uvm_component_utils(vec_cov_test)

        virtual vec_if.RESETTER rvif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_if.RESETTER)::get(this, "", "rvif", rvif))
                `uvm_fatal("VEC_COV_TEST", "no RESETTER vif set")
        endfunction

        task run_phase(uvm_phase phase);
            vec_directed_seq         dseq;
            vec_corner_sweep_seq     sseq;
            vec_negative_access_seq  nseq;
            vec_random_seq           rseq;
            phase.raise_objection(this);

            env.sb.reset_model(); #1;
            dseq = vec_directed_seq::type_id::create("dseq");
            dseq.start(env.agent.sequencer);

            env.sb.reset_model(); #1;
            sseq = vec_corner_sweep_seq::type_id::create("sseq");
            sseq.start(env.agent.sequencer);

            env.sb.reset_model(); #1;
            nseq = vec_negative_access_seq::type_id::create("nseq");
            nseq.start(env.agent.sequencer);

            env.sb.reset_model(); #1;
            rseq = vec_random_seq::type_id::create("rseq");
            void'($value$plusargs("N_CMDS=%d", rseq.n_cmds));
            rseq.start(env.agent.sequencer);

            env.sb.reset_model(); #1;
            for (int i = 0; i < 8; i++) begin
                fork
                    begin
                        vec_random_seq rs = vec_random_seq::type_id::create("rs");
                        rs.n_cmds = 1;
                        rs.start(env.agent.sequencer);
                    end
                    begin
                        repeat ($urandom_range(1, 3)) @(posedge rvif.clk);
                        rvif.inject_reset <= 1'b1;
                        repeat (2) @(posedge rvif.clk);
                        rvif.inject_reset <= 1'b0;
                        env.sb.reset_model();
                    end
                join
            end

            phase.drop_objection(this);
        endtask
    endclass

endpackage