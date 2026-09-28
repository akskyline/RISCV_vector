// =============================================================================
// soc_pkg - full-SoC UVM environment: core_env (unchanged, from core_pkg)
// watching riscv_soc_top's rvfi port, plus a vec_env built PASSIVE (agent's
// is_active = UVM_PASSIVE) watching the coprocessor bus that lives INSIDE
// riscv_soc_top. The CPU is the real bus master there, not a UVM driver -
// this is exactly why vec_agent was built with an is_active switch in the
// first place: the same monitor/scoreboard/coverage classes are reused
// verbatim between the standalone coprocessor environment and this one.
//
// NOTE ON VERIFICATION STATUS: same caveat as vec_pkg.sv / core_pkg.sv -
// needs a real UVM-1.2 library, not available to compile here. The wiring
// in riscv_soc_uvm_tb.sv (which vec_if signals tap which riscv_soc_top
// internal nets) matches rtl/riscv_soc_top.sv exactly, cross-checked against
// the file directly.
// =============================================================================
package soc_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import core_pkg::*;
    import vec_pkg::*;

    class soc_env extends uvm_env;
        `uvm_component_utils(soc_env)

        core_env core;
        vec_env  vec;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            uvm_config_db#(uvm_active_passive_enum)::set(this, "vec.agent", "is_active", UVM_PASSIVE);
            core = core_env::type_id::create("core", this);
            vec  = vec_env::type_id::create("vec", this);
        endfunction
    endclass

    // Same wait-for-halt shape as core_base_test, plus a combined pass/fail
    // over both scoreboards (core lockstep + coprocessor bus checks) and
    // both coverage collectors in the final report.
    class soc_base_test extends uvm_test;
        `uvm_component_utils(soc_base_test)

        soc_env env;
        virtual rvfi_if.MONITOR vif;
        int max_cycles = 200000;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = soc_env::type_id::create("env", this);
            if (!uvm_config_db#(virtual rvfi_if.MONITOR)::get(this, "", "vif", vif))
                `uvm_fatal("SOC_TEST", "no vif set - did the tb top call uvm_config_db#(virtual rvfi_if.MONITOR)::set(...)?")
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
            if (!halted) `uvm_error("SOC_TEST", $sformatf("TIMEOUT after %0d cycles", cyc))
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            int total_errors = env.core.sb.errors + env.vec.sb.errors;
            `uvm_info("SOC_TEST", $sformatf("core: retired=%0d errors=%0d  |  coprocessor: commands=%0d errors=%0d",
                     env.core.sb.retired, env.core.sb.errors, env.vec.sb.commands, env.vec.sb.errors), UVM_LOW)
            if (total_errors == 0)
                `uvm_info("SOC_TEST", "*** TEST PASSED ***", UVM_NONE)
            else
                `uvm_error("SOC_TEST", $sformatf("*** TEST FAILED *** (%0d errors)", total_errors))
        endfunction
    endclass

endpackage
