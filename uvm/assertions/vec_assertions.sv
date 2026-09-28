`include "rv32i_types.svh"
`include "vec_defs.svh"
// =============================================================================
// vec_assertions - structural invariants bound directly into vec_coproc.
// Plain SVA, no UVM - compiled and exercised here (Verilator) against the
// real vec_coproc RTL through tb/vec_coproc_tb.sv's full scenario list
// (reset, directed, every-opcode-x-every-VL, aliasing, illegal commands,
// BUSY-window checks, out-of-window, reset-mid-op, 400 random commands);
// all assertions held with zero failures.
// =============================================================================
module vec_assertions #(
    parameter int LANES = 4,
    parameter int NVREG = 8
)(
    input logic        clk, rst,
    input logic        busy, done, err,
    input logic        start, clr,
    input logic [31:0] op_r, vl_r,
    input logic         op_ok, vl_ok
);

    // ------------------------------------------------------------------ mutex
    property p_busy_done_mutex;
        @(posedge clk) disable iff (rst) !(busy && done);
    endproperty
    a_busy_done_mutex: assert property (p_busy_done_mutex)
        else $error("[ASSERT %0t] BUSY and DONE asserted together", $time);

    // ---------------------------------------------------------------- one-cycle
    // BUSY is asserted for exactly one clock: once high, it must be low the
    // very next cycle (the single-cycle EXEC state the FSM is built around).
    property p_busy_one_cycle;
        @(posedge clk) disable iff (rst) busy |=> !busy;
    endproperty
    a_busy_one_cycle: assert property (p_busy_one_cycle)
        else $error("[ASSERT %0t] BUSY held for more than one clock", $time);

    // ------------------------------------------------------------- err => done
    property p_err_implies_done;
        @(posedge clk) disable iff (rst) err |-> done;
    endproperty
    a_err_implies_done: assert property (p_err_implies_done)
        else $error("[ASSERT %0t] ERR asserted without DONE", $time);

    // ------------------------------------------------------- start legality gate
    // A START into an illegal command (bad op or bad VL) must never enter
    // BUSY the following cycle - it has to reject immediately (DONE|ERR).
    property p_illegal_start_no_busy;
        @(posedge clk) disable iff (rst) (start && !(op_ok && vl_ok)) |=> !busy;
    endproperty
    a_illegal_start_no_busy: assert property (p_illegal_start_no_busy)
        else $error("[ASSERT %0t] an illegal START entered BUSY", $time);

    property p_legal_start_busy;
        @(posedge clk) disable iff (rst) (start && op_ok && vl_ok) |=> busy;
    endproperty
    a_legal_start_busy: assert property (p_legal_start_busy)
        else $error("[ASSERT %0t] a legal START did not enter BUSY next cycle", $time);

    // -------------------------------------------------------------------- no X
    property p_no_x_status;
        @(posedge clk) disable iff (rst) !$isunknown({busy, done, err});
    endproperty
    a_no_x_status: assert property (p_no_x_status)
        else $error("[ASSERT %0t] X/Z on BUSY/DONE/ERR", $time);

endmodule

bind vec_coproc vec_assertions #(.LANES(LANES), .NVREG(NVREG)) u_vec_assertions (
    .clk(clk), .rst(rst), .busy(busy), .done(done), .err(err),
    .start(start), .clr(clr), .op_r(op_r), .vl_r(vl_r), .op_ok(op_ok), .vl_ok(vl_ok)
);
