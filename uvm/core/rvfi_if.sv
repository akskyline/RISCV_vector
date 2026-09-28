// =============================================================================
// rvfi_if - interface tapping the core's retire trace.
//
// The DUT's `rvfi` port is a flat [`RV_RVFI_W-1:0] vector, not the rvfi_t
// struct itself (struct-typed ports were deliberately avoided in the RTL -
// see rv32i_core_modules.sv - because a struct port broke across separate
// compilation units in ModelSim earlier in this project). This interface
// takes the same flat vector and reconstructs the struct on this side only,
// for convenience in the monitor.
// =============================================================================
`include "rv32i_types.svh"

interface rvfi_if (
    input logic clk,
    input logic rst
);
    logic [`RV_RVFI_W-1:0] rvfi_bus;
    rvfi_t                 rvfi;

    assign rvfi = rvfi_bus;

    modport MONITOR (input clk, rst, rvfi_bus, rvfi);
endinterface
