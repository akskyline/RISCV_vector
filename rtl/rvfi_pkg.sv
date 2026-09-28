// =============================================================================
// rvfi_pkg - the SAME rvfi_t struct as rtl/rv32i_types.svh, but declared
// inside a real package instead of at $unit scope via `include.
//
// Why this needs to exist as well as the .svh: modules and interfaces get
// AUTOMATIC visibility of $unit-scope declarations (so rv32i_core_modules.sv
// and uvm/core/rvfi_if.sv see rvfi_t fine just from `include "rv32i_types.svh"),
// but a `package` block does NOT automatically see $unit items - it only sees
// its own declarations plus whatever it explicitly imports. uvm/core/core_pkg.sv
// is a package and needs rvfi_t as a real type (for from_rvfi(rvfi_t r)), so it
// needs a package to `import`, not another `include of the .svh.
//
// This is a second declaration of the same struct, not a copy that can drift
// silently unnoticed: it's a `typedef struct packed`, and packed-struct types
// with identical field lists/order/widths are EQUIVALENT types per the LRM
// (6.22.2) regardless of which scope declared them - so a value of
// rv32i_types.svh's $unit-scope rvfi_t (e.g. uvm/core/rvfi_if.sv's `rvfi`
// signal) can be passed directly into a function expecting rvfi_pkg::rvfi_t
// with no cast needed. If you ever change the field list, change BOTH copies
// (rv32i_types.svh and this file) together, in lockstep.
// =============================================================================
package rvfi_pkg;
    typedef struct packed {
        logic        valid;
        logic [63:0] order;
        logic [31:0] insn;
        logic        trap;
        logic        halt;
        logic        intr;
        logic [1:0]  mode;
        logic [1:0]  ixl;
        logic [4:0]  rs1_addr;
        logic [4:0]  rs2_addr;
        logic [31:0] rs1_rdata;
        logic [31:0] rs2_rdata;
        logic [4:0]  rd_addr;
        logic [31:0] rd_wdata;
        logic [31:0] pc_rdata;
        logic [31:0] pc_wdata;
        logic [31:0] mem_addr;
        logic [3:0]  mem_rmask;
        logic [3:0]  mem_wmask;
        logic [31:0] mem_rdata;
        logic [31:0] mem_wdata;
        logic [4:0]  cause;
    } rvfi_t;
endpackage
