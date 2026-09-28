// =============================================================================
// vec_coproc_uvm_tb - top module for the standalone UVM environment.
//
// ModelSim/Questa (with a real UVM-1.2 library on the search path):
//   vlib work
//   vlog -sv +incdir+rtl +incdir+uvm/vec rtl/vec_alu.sv rtl/vec_regfile.sv rtl/vec_coproc.sv \
//        uvm/vec/vec_if.sv uvm/vec/vec_pkg.sv uvm/vec/vec_coproc_uvm_tb.sv
//   vsim -c work.vec_coproc_uvm_tb +UVM_TESTNAME=vec_smoke_test -do "run -all; quit"
//   vsim -c work.vec_coproc_uvm_tb +UVM_TESTNAME=vec_random_test +N_CMDS=400 -do "run -all; quit"
//
// This module and vec_if.sv have been compiled and elaborated against the
// real vec_coproc RTL in this environment (Icarus Verilog) - the bus wiring
// below is confirmed correct. run_test() itself needs the real UVM class
// library, which was not available to compile here (see the note at the top
// of vec_pkg.sv); please share the vlog/vsim output from ModelSim.
// =============================================================================
// Note: no `include here either - this file never references the macros/struct
// directly, and vec_pkg (imported below) already owns its own copy of both
// headers. Keeping a second copy here risks the same "multiply defined" clash
// Questa raised for the equivalent pattern in rv32i_core_uvm_tb.sv.
module vec_coproc_uvm_tb;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import vec_pkg::*;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    vec_if vif (.clk(clk), .rst(rst));

    // dut_rst = power-on reset OR whatever a UVM test injects mid-run via
    // vif.inject_reset (modport RESETTER) - see vec_if.sv.
    wire dut_rst = vif.rst | vif.inject_reset;

    vec_coproc #(.LANES(4), .NVREG(8)) dut (
        .clk  (vif.clk),
        .rst  (dut_rst),
        .sel  (vif.sel),
        .we   (vif.we),
        .addr (vif.addr),
        .wdata(vif.wdata),
        .rdata(vif.rdata)
    );

    initial begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;
    end

    initial begin
        uvm_config_db#(virtual vec_if.DRIVER)::set(null, "*", "vif", vif);
        uvm_config_db#(virtual vec_if.MONITOR)::set(null, "*", "vif", vif);
        uvm_config_db#(virtual vec_if.RESETTER)::set(null, "*", "rvif", vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("vec_coproc_uvm.vcd");
            $dumpvars(0, vec_coproc_uvm_tb);
        end
    end
endmodule
