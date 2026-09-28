`include "vec_defs.svh"
// =============================================================================
// vec_coproc - memory-mapped SIMD vector coprocessor (2 KB window)
//
//  Programming model (software = plain lw/sw from the RV32I core):
//    1. write operand vectors into the vector-register window
//    2. write OP, VSEL, VL
//    3. write CTRL.START = 1
//    4. poll STATUS until DONE (or ERR) is set
//    5. read result vector from the window, or RESULT for reductions
//
//  Timing: START -> BUSY for exactly 1 clock (EXEC state) -> DONE.
//  While BUSY, writes to OP/VSEL/VL/window are ignored and a second START is
//  ignored (so an operation can never be corrupted mid-flight).
//  START with an illegal op or VL outside 1..LANES: no execution, no writes,
//  ERR=1 and DONE=1 on the next cycle.
//
//  Bus: combinational read (rdata valid in the same cycle as addr), write is
//  sampled on the rising clock edge when sel & we. Word accesses only.
// =============================================================================
module vec_coproc #(
    parameter int LANES = 4,
    parameter int NVREG = 8,
    parameter int DW    = 32
)(
    input  logic        clk,
    input  logic        rst,          // async, active high (same as the core)

    input  logic        sel,          // address decoder hit
    input  logic        we,           // write strobe (raw memwrite)
    input  logic [10:0] addr,         // byte offset inside the window
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);

    localparam int VRW = $clog2(NVREG);
    localparam int LNW = $clog2(LANES);
    localparam int VLW = $clog2(LANES+1);
    localparam int WIN_WORDS = NVREG * LANES;
    localparam int WIN_BASE_W = 32'(`VREG_WINDOW) >> 2;          // word index of window base (64)

    // ------------------------------------------------ programmer-visible state
    logic [31:0]    op_r;             // full width so an out-of-range value can't alias a legal op
    logic [31:0]    vl_r;             // same for VL
    logic [VRW-1:0] vd_r, vs1_r, vs2_r;
    logic [DW-1:0]  result_r;
    logic           busy, done, err;  // busy also *is* the FSM state (0 = IDLE, 1 = EXEC)

    // ------------------------------------------------------------ bus decode
    wire [8:0]  waddr    = addr[10:2];
    wire [31:0] waddr32  = {23'd0, waddr};
    wire        wr       = sel & we;
    wire        wr_cfg   = wr & ~busy;                       // config / window writes locked while BUSY
    wire        in_win   = (waddr32 >= WIN_BASE_W) && (waddr32 < WIN_BASE_W + WIN_WORDS);
    wire [8:0]  win_idx  = waddr - 9'(WIN_BASE_W);          // only [LNW+VRW-1:0] is used

    wire start = wr & (addr == `VREG_CTRL) & wdata[0] & ~busy;
    wire clr   = wr & (addr == `VREG_CTRL) & wdata[1];

    // ---------------------------------------------------------- legality check
    wire op_ok = (op_r <= {28'd0, `VOP_MAX});
    wire vl_ok = (vl_r != 32'd0) && (vl_r <= LANES);

    // -------------------------------------------------- config regs + FSM + flags
    logic           alu_is_red;
    logic [DW-1:0]  alu_red;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            op_r     <= '0;
            vl_r     <= '0;
            vd_r     <= '0;
            vs1_r    <= '0;
            vs2_r    <= '0;
            result_r <= '0;
            busy     <= 1'b0;
            done     <= 1'b0;
            err      <= 1'b0;
        end
        else begin
            // configuration writes (ignored while busy)
            if (wr_cfg) begin
                if (addr == `VREG_OP)   op_r <= wdata;
                if (addr == `VREG_VL)   vl_r <= wdata;
                if (addr == `VREG_VSEL) begin
                    vd_r  <= wdata[0 +: VRW];
                    vs1_r <= wdata[3 +: VRW];
                    vs2_r <= wdata[6 +: VRW];
                end
            end

            // status clear (START below has priority, EXEC completion has the last word)
            if (clr) begin
                done <= 1'b0;
                err  <= 1'b0;
            end

            if (start) begin
                done <= 1'b0;
                err  <= 1'b0;
                if (op_ok && vl_ok) begin
                    busy <= 1'b1;               // -> EXEC
                end
                else begin
                    done <= 1'b1;               // rejected: report error, do nothing
                    err  <= 1'b1;
                end
            end
            else if (busy) begin                // EXEC: the ALU result is written this edge
                busy <= 1'b0;
                done <= 1'b1;
                if (alu_is_red)
                    result_r <= alu_red;
            end
        end
    end

    // ------------------------------------------------------------ datapath
    logic [LANES*DW-1:0] vs1_data, vs2_data, alu_y;
    logic [DW-1:0]       cpu_vrdata;
    logic [LANES-1:0]    lane_en;

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_en
            assign lane_en[l] = (vl_r > l);      // lanes below VL are active
        end
    endgenerate

    vec_regfile #(.NVREG(NVREG), .LANES(LANES), .DW(DW)) u_vrf (
        .clk       (clk),
        .rst       (rst),
        .cpu_we    (wr_cfg & in_win),
        .cpu_vreg  (win_idx[LNW +: VRW]),
        .cpu_lane  (win_idx[0 +: LNW]),
        .cpu_wdata (wdata),
        .cpu_rdata (cpu_vrdata),
        .rs1       (vs1_r),
        .rs2       (vs2_r),
        .rd1       (vs1_data),
        .rd2       (vs2_data),
        .alu_we    (busy & ~alu_is_red),         // EXEC cycle, element-wise ops only
        .rd        (vd_r),
        .lane_en   (lane_en),
        .wdata     (alu_y)
    );

    vec_alu #(.LANES(LANES), .DW(DW)) u_alu (
        .op     (op_r[3:0]),                     // only reaches the ALU after op_ok passed
        .vl     (vl_r[VLW-1:0]),
        .a      (vs1_data),
        .b      (vs2_data),
        .y      (alu_y),
        .red    (alu_red),
        .is_red (alu_is_red)
    );

    // ------------------------------------------------------------ read mux
    always_comb begin
        rdata = 32'd0;
        if (in_win) begin
            rdata = cpu_vrdata;
        end
        else begin
            case (addr)
                `VREG_OP:     rdata = op_r;
                `VREG_VL:     rdata = vl_r;
                `VREG_VSEL:   begin
                                  rdata[0 +: VRW] = vd_r;
                                  rdata[3 +: VRW] = vs1_r;
                                  rdata[6 +: VRW] = vs2_r;
                              end
                `VREG_STATUS: rdata = {29'd0, err, done, busy};
                `VREG_RESULT: rdata = result_r;
                default:      rdata = 32'd0;     // CTRL reads 0, unmapped reads 0
            endcase
        end
    end

endmodule
