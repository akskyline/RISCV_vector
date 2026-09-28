`ifndef RV32I_TYPES_SVH
`define RV32I_TYPES_SVH
// =============================================================================
// rv32i_types.svh - constants and the retire-trace type shared by RTL and TBs.
// Textual include (not a package) so the compile order of your rtl/*.sv glob
// never matters.
// =============================================================================

// ---- ALUControl (4 bit) ------------------------------------------------------
`define RV_ALU_ADD   4'd0
`define RV_ALU_SUB   4'd1
`define RV_ALU_AND   4'd2
`define RV_ALU_OR    4'd3
`define RV_ALU_XOR   4'd4
`define RV_ALU_SLT   4'd5
`define RV_ALU_SLTU  4'd6
`define RV_ALU_SLL   4'd7
`define RV_ALU_SRL   4'd8
`define RV_ALU_SRA   4'd9

// ---- imm_src (3 bit) ---------------------------------------------------------
`define RV_IMM_I     3'd0
`define RV_IMM_S     3'd1
`define RV_IMM_B     3'd2
`define RV_IMM_J     3'd3
`define RV_IMM_U     3'd4

// ---- result_src (3 bit): what is written back to rd -----------------------------
`define RV_RES_ALU   3'd0     // ALU result
`define RV_RES_MEM   3'd1     // load data (after align / extend)
`define RV_RES_PC4   3'd2     // pc + 4      (jal / jalr link)
`define RV_RES_IMM   3'd3     // U immediate (lui)
`define RV_RES_PCIMM 3'd4     // pc + U imm  (auipc)

// ---- pc_src (2 bit) ------------------------------------------------------------
`define RV_PC_NEXT   2'd0     // pc + 4
`define RV_PC_TGT    2'd1     // pc + imm    (taken branch, jal)
`define RV_PC_JALR   2'd2     // (rs1 + imm) & ~1

// ---- trap causes: same numbers as the RISC-V mcause encoding -------------------
`define RV_CAUSE_FETCH_MISALIGNED 5'd0
`define RV_CAUSE_ILLEGAL          5'd2
`define RV_CAUSE_EBREAK           5'd3
`define RV_CAUSE_LOAD_MISALIGNED  5'd4
`define RV_CAUSE_STORE_MISALIGNED 5'd6
`define RV_CAUSE_ECALL            5'd11

// ---- retire trace (RVFI-style: RISC-V Formal Interface field names) ------------
// One record per retired instruction (declared as a packed struct so fields can be named; travels on ports as a vector). Because the core is single-cycle, the record
// is valid in the cycle the instruction executes: sample it on the rising clock edge.
//   * a trapping instruction retires once with trap=1 and NO architectural effect,
//     after which the core halts (valid stays 0 until reset)
//   * mem_addr is word aligned; rmask / wmask say which bytes of that word were
//     read / written; rdata / wdata are the raw bus words
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
    logic [4:0]  cause;          // extension: trap cause (mcause numbers) when trap = 1
} rvfi_t;

// Ports carry the trace as a plain vector of this width (module ports never use the struct type, so the
// design also compiles when every file is its own compilation unit); convert with  rvfi_t'(bus)  /  assignment.
`define RV_RVFI_W $bits(rvfi_t)

`endif
