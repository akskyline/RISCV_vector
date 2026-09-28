// =============================================================================
// vec_defs.svh - vector coprocessor opcodes and register map
// (plain `defines instead of a package: works in every synthesis front-end)
// =============================================================================
`ifndef VEC_DEFS_SVH
`define VEC_DEFS_SVH

// ---- OP register values ------------------------------------------------------
`define VOP_ADD     4'd0   // vd[i] = vs1[i] + vs2[i]                 (i < VL)
`define VOP_MUL     4'd1   // vd[i] = (vs1[i] * vs2[i])[31:0]         (i < VL)
`define VOP_SLT     4'd2   // vd[i] = signed(vs1[i]) < signed(vs2[i]) (i < VL)  -> 1 / 0
`define VOP_SEQ     4'd3   // vd[i] = (vs1[i] == vs2[i])              (i < VL)  -> 1 / 0
`define VOP_REDSUM  4'd4   // RESULT = sum of vs1[0..VL-1]
`define VOP_REDMAX  4'd5   // RESULT = signed max of vs1[0..VL-1]
`define VOP_MAX     4'd5   // highest legal opcode - anything larger is an error

// ---- register map: byte offsets inside the 2 KB coprocessor window -----------
`define VREG_CTRL    11'h000  // W : bit0 START (pulse), bit1 CLR (clear DONE/ERR)
`define VREG_OP      11'h004  // RW: operation code
`define VREG_VSEL    11'h008  // RW: [2:0] vd, [5:3] vs1, [8:6] vs2
`define VREG_VL      11'h00C  // RW: vector length, legal range 1..LANES
`define VREG_STATUS  11'h010  // R : bit0 BUSY, bit1 DONE, bit2 ERR
`define VREG_RESULT  11'h014  // R : scalar result of reduction ops
`define VREG_WINDOW  11'h100  // RW: vector register file, vreg r lane l at 0x100 + r*16 + l*4

`endif
