// =============================================================================
// rv32i_core_uvm_tb - top module for the core-only UVM environment (no
// vector coprocessor). DUT = sgle_cyc_processor (core + its own memories).
//
// ModelSim/Questa (with a real UVM-1.2 library on the search path):
//   vlib work
//   vlog -sv +incdir+rtl +incdir+uvm/core rtl/rv32i_core_modules.sv rtl/rv32i_memories.sv \
//        rtl/sgle_cyc_processor.sv uvm/core/rvfi_if.sv uvm/core/core_pkg.sv uvm/core/rv32i_core_uvm_tb.sv
//   vsim -c work.rv32i_core_uvm_tb +UVM_TESTNAME=core_base_test +HEX=hex/t_ctrl.hex -do "run -all; quit"
//
// This module and rvfi_if.sv have been compiled and elaborated against the
// real core RTL here (Icarus Verilog) - the rvfi wiring is confirmed
// correct. run_test() needs the real UVM class library (see core_pkg.sv);
// please share ModelSim's vlog/vsim output.
// =============================================================================
// Note: this file deliberately does NOT `include "rv32i_types.svh" - it never
// references rvfi_t or `RV_RVFI_W directly (it only wires vif.rvfi_bus, a plain
// vector, and imports core_pkg which already owns its own copy of the struct).
// Also including it here would create a second, independent copy of the same
// typedef alongside the one core_pkg.sv carries in - Questa (unlike Icarus/
// Verilator) treats that as a hard "multiply defined" error once this file
// imports core_pkg::*.
module rv32i_core_uvm_tb;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import core_pkg::*;

    logic clk = 1'b0;
    logic rst;
    logic trap, halted;
    logic [4:0] trap_cause;

    always #5 clk = ~clk;

    rvfi_if vif (.clk(clk), .rst(rst));

    sgle_cyc_processor dut (
        .clk       (vif.clk),
        .rst       (vif.rst),
        .trap      (trap),
        .halted    (halted),
        .trap_cause(trap_cause),
        .rvfi      (vif.rvfi_bus)
    );

    initial begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;
    end

    initial begin
        uvm_config_db#(virtual rvfi_if.MONITOR)::set(null, "*", "vif", vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("rv32i_core_uvm.vcd");
            $dumpvars(0, rv32i_core_uvm_tb);
        end
    end
endmodule
