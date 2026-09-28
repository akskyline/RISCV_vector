`include "vec_defs.svh"
// =============================================================================
// vec_alu - SIMD execution unit
//
//  * LANES identical 32-bit lanes work on LANES elements in the SAME cycle
//    (that is the "SIMD" part: one command -> many data elements).
//  * Element-wise ops (ADD/MUL/SLT/SEQ) produce y[] ; lanes >= vl are still
//    computed here but are NOT written back (masked by the register file).
//  * Reduction ops (REDSUM/REDMAX) fold the first `vl` elements of `a` into
//    one scalar `red`.
//  * Purely combinational. Element data is signed for SLT / REDMAX.
// =============================================================================
module vec_alu #(
    parameter int LANES = 4,
    parameter int DW    = 32
)(
    input  logic [3:0]                 op,
    input  logic [$clog2(LANES+1)-1:0] vl,      // active elements, 1..LANES
    input  logic [LANES*DW-1:0]        a,       // vs1 (all lanes, flat)
    input  logic [LANES*DW-1:0]        b,       // vs2
    output logic [LANES*DW-1:0]        y,       // element-wise result
    output logic [DW-1:0]              red,     // reduction result
    output logic                       is_red   // 1 -> result is `red`, not `y`
);

    // ---------------------------------------------------------- SIMD lanes
    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_lane
            logic [DW-1:0] ai, bi, yi;
            assign ai = a[l*DW +: DW];
            assign bi = b[l*DW +: DW];

            always_comb begin
                case (op)
                    `VOP_ADD: yi = ai + bi;
                    `VOP_MUL: yi = ai * bi;                                   // low DW bits
                    `VOP_SLT: yi = ($signed(ai) < $signed(bi)) ? {{(DW-1){1'b0}}, 1'b1} : '0;
                    `VOP_SEQ: yi = (ai == bi)                  ? {{(DW-1){1'b0}}, 1'b1} : '0;
                    default:  yi = '0;
                endcase
            end

            assign y[l*DW +: DW] = yi;
        end
    endgenerate

    // ----------------------------------------------------------- reduction
    logic [DW-1:0] sum, mx;
    integer k;

    always_comb begin
        sum = '0;
        mx  = a[DW-1:0];                       // element 0 is always active (vl >= 1)
        for (k = 0; k < LANES; k = k + 1) begin
            if (k < vl) begin
                sum = sum + a[k*DW +: DW];
                if ($signed(a[k*DW +: DW]) > $signed(mx))
                    mx = a[k*DW +: DW];
            end
        end
    end

    assign is_red = (op == `VOP_REDSUM) || (op == `VOP_REDMAX);
    assign red    = (op == `VOP_REDMAX) ? mx : sum;

endmodule
