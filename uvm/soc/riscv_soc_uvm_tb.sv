// =============================================================================
// riscv_soc_uvm_tb - top module for the full-SoC UVM environment.
// DUT = riscv_soc_top (core + memories + memory-mapped vector coprocessor).
//
// ModelSim/Questa (with a real UVM-1.2 library on the search path):
//   vlib work
//   vlog -sv +incdir+rtl +incdir+uvm/core +incdir+uvm/vec \
//        rtl/rv32i_core_modules.sv rtl/rv32i_memories.sv rtl/vec_alu.sv rtl/vec_regfile.sv \
//        rtl/vec_coproc.sv rtl/riscv_soc_top.sv \
//        uvm/core/rvfi_if.sv uvm/core/core_pkg.sv uvm/vec/vec_if.sv uvm/vec/vec_pkg.sv \
//        uvm/soc/soc_pkg.sv uvm/soc/riscv_soc_uvm_tb.sv
//   vsim -c work.riscv_soc_uvm_tb +UVM_TESTNAME=soc_base_test +HEX=soc/ins_little_endian.hex -do "run -all; quit"
//
// vec_if here is a MONITOR-only tap into riscv_soc_top's internal
// cp_sel/dmem_we/dmem_be/dmem_addr/dmem_wdata/RD_cp nets (the CPU is the bus
// master, not a UVM driver - vec_env is built passive, see soc_pkg.sv). This
// wiring has been elaborated against the real riscv_soc_top RTL here
// (Icarus Verilog), confirmed byte-for-byte against rtl/riscv_soc_top.sv's
// own instantiation of vec_coproc. run_test() needs the real UVM class
// library (see soc_pkg.sv); please share ModelSim's vlog/vsim output.
// =============================================================================
// Note: no `include "rv32i_types.svh" here either, for the same reason as
// rv32i_core_uvm_tb.sv - this file only wires vif.rvfi_bus (a plain vector)
// and imports soc_pkg (which pulls in core_pkg, which already owns the struct).
module riscv_soc_uvm_tb;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import soc_pkg::*;

    logic clk = 1'b0;
    logic rst;
    logic trap, halted;
    logic [4:0] trap_cause;

    always #5 clk = ~clk;

    rvfi_if vif (.clk(clk), .rst(rst));

    riscv_soc_top dut (
        .clk       (vif.clk),
        .rst       (vif.rst),
        .trap      (trap),
        .halted    (halted),
        .trap_cause(trap_cause),
        .rvfi      (vif.rvfi_bus)
    );

    // passive coprocessor-bus tap - same signals/qualification as
    // rtl/riscv_soc_top.sv's own instantiation of vec_coproc (verified
    // against that file directly)
    vec_if vec_vif (.clk(clk), .rst(rst));
    assign vec_vif.sel   = dut.cp_sel;
    assign vec_vif.we    = dut.dmem_we & (dut.dmem_be == 4'b1111);
    assign vec_vif.addr  = dut.dmem_addr[10:0];
    assign vec_vif.wdata = dut.dmem_wdata;
    assign vec_vif.rdata = dut.RD_cp;

    initial begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;
    end

    initial begin
        uvm_config_db#(virtual rvfi_if.MONITOR)::set(null, "*", "vif", vif);
        uvm_config_db#(virtual vec_if.MONITOR)::set(null, "*", "vif", vec_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("riscv_soc_uvm.vcd");
            $dumpvars(0, riscv_soc_uvm_tb);
        end
    end
endmodule
