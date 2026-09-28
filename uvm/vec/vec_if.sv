// =============================================================================
// vec_if - pin-level interface for the vec_coproc memory-mapped register bus.
//
// Used two ways:
//   * standalone vec_coproc testing: the UVM driver actively drives sel/we/
//     addr/wdata every clock and samples rdata (modport DRIVER).
//   * inside riscv_soc_top: only ever a MONITOR tap (modport MONITOR) - the
//     CPU is the real driver of these signals, vec_agent is built passive
//     (see vec_pkg.sv) so no driver/sequencer are ever connected to it there.
//
// No clocking block: the bus is a single-cycle protocol (drive for exactly
// one clock, no setup/hold subtlety), so plain @(posedge clk) procedural
// driving in the driver is simpler and more portable than a clocking block.
// =============================================================================
interface vec_if (
    input logic clk,
    input logic rst
);
    logic        sel;
    logic        we;
    logic [10:0] addr;
    logic [31:0] wdata;
    logic [31:0] rdata;

    // inject_reset: an extra, test-controlled reset source. The tb top ORs
    // this into the DUT's actual reset (see vec_coproc_uvm_tb.sv) so a UVM
    // test can pulse a reset in the MIDDLE of an in-flight command (T9/T11 -
    // "reset while BUSY" timing) without touching the power-on reset
    // generator. Defaults low so every other test is unaffected.
    logic inject_reset = 1'b0;

    modport DRIVER    (input clk, rst, output sel, we, addr, wdata, input rdata);
    modport MONITOR   (input clk, rst, sel, we, addr, wdata, rdata);
    modport RESETTER  (input clk, output inject_reset);
endinterface
