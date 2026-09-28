`include "rv32i_types.svh"
// =============================================================================
// Full RV32I single-cycle core (all 40 base instructions)
//
//   LUI AUIPC | JAL JALR | BEQ BNE BLT BGE BLTU BGEU | LB LH LW LBU LHU | SB SH SW
//   ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI | ADD SUB SLL SLT SLTU XOR SRL SRA OR AND
//   FENCE (no-op) | ECALL EBREAK (trap)
//
// Same module / instance names as your original design wherever they still make sense:
//   pc_counter1 (pc_top) cu3 (control_unit) reg_file4 immdata5 alu_mux6 alu7 mux_ressult9
//
// Policy decisions (no CSRs / trap handler in base RV32I, so the core HALTS on a trap):
//   * illegal instruction, ECALL, EBREAK, misaligned load/store, misaligned jump target
//     -> the instruction retires once with trap = 1 and NO side effects, PC freezes,
//        the core reports halted until reset.
//   * ECALL therefore doubles as a clean "end of test" for programs.
//   * FENCE is a no-op. FENCE.I (Zifencei) and CSR instructions are illegal here.
//   * data accesses must be naturally aligned.
// =============================================================================

// ------------------------------------------------------------------ ALU
module alu(
    input  logic [31:0] RD1, srcb,
    input  logic [3:0]  ALUControl,
    output logic [31:0] alu_result,
    output logic        zero
);
    always_comb
        case (ALUControl)
            `RV_ALU_ADD:  alu_result = RD1 + srcb;
            `RV_ALU_SUB:  alu_result = RD1 - srcb;
            `RV_ALU_AND:  alu_result = RD1 & srcb;
            `RV_ALU_OR:   alu_result = RD1 | srcb;
            `RV_ALU_XOR:  alu_result = RD1 ^ srcb;
            `RV_ALU_SLT:  alu_result = ($signed(RD1) < $signed(srcb)) ? 32'd1 : 32'd0;
            `RV_ALU_SLTU: alu_result = (RD1 < srcb)                   ? 32'd1 : 32'd0;
            `RV_ALU_SLL:  alu_result = RD1 << srcb[4:0];
            `RV_ALU_SRL:  alu_result = RD1 >> srcb[4:0];
            `RV_ALU_SRA:  alu_result = $signed(RD1) >>> srcb[4:0];
            default:      alu_result = 32'd0;
        endcase

    assign zero = (alu_result == 32'd0);
endmodule

// MUX for the ALU second operand (RD2 or immediate)
module alu_mux(
    input  logic [31:0] RD2,
    input  logic [31:0] imm,
    input  logic        alu_src,      // 0 -> RD2, 1 -> imm
    output logic [31:0] srcb
);
    assign srcb = (alu_src) ? imm : RD2;
endmodule

// Branch comparator (replaces "SUB and look at zero": needed for BLT/BGE/BLTU/BGEU)
module branch_cmp(
    input  logic [31:0] a, b,
    output logic        eq, lt, ltu
);
    assign eq  = (a == b);
    assign lt  = ($signed(a) < $signed(b));
    assign ltu = (a < b);
endmodule

// ------------------------------------------------------------ main decoder
// Decodes opcode (+ funct fields where the encoding has reserved combinations) and
// flags every undefined encoding as `illegal`. An illegal instruction has all
// side-effect controls forced to 0.
module main_decoder (
    input  logic [31:0] ins,
    output logic [2:0]  imm_src,
    output logic [1:0]  alu_op,        // 00 add | 01 sub | 10 by funct3/funct7
    output logic [2:0]  result_src,
    output logic        regwrite, alu_src, memwrite, memread,
    output logic        branch, jump, jalr,
    output logic        uses_rs1, uses_rs2,
    output logic        ecall, ebreak, illegal
);
    logic [6:0] opcode, f7;
    logic [2:0] f3;
    assign opcode = ins[6:0];
    assign f3     = ins[14:12];
    assign f7     = ins[31:25];

    always_comb begin
        // default = a NOP with no side effects
        regwrite = 1'b0;  imm_src = `RV_IMM_I;  alu_src = 1'b0;  memwrite = 1'b0;  memread = 1'b0;
        result_src = `RV_RES_ALU;  branch = 1'b0;  jump = 1'b0;  jalr = 1'b0;  alu_op = 2'b00;
        uses_rs1 = 1'b0;  uses_rs2 = 1'b0;  ecall = 1'b0;  ebreak = 1'b0;  illegal = 1'b0;

        if (ins[1:0] != 2'b11) begin
            illegal = 1'b1;                                  // not a 32-bit instruction
        end
        else begin
            case (opcode)
                7'b0110111: begin                            // LUI
                    regwrite = 1'b1;  imm_src = `RV_IMM_U;  result_src = `RV_RES_IMM;
                end
                7'b0010111: begin                            // AUIPC
                    regwrite = 1'b1;  imm_src = `RV_IMM_U;  result_src = `RV_RES_PCIMM;
                end
                7'b1101111: begin                            // JAL
                    regwrite = 1'b1;  imm_src = `RV_IMM_J;  result_src = `RV_RES_PC4;  jump = 1'b1;
                end
                7'b1100111: begin                            // JALR
                    if (f3 == 3'b000) begin
                        regwrite = 1'b1;  imm_src = `RV_IMM_I;  alu_src = 1'b1;  alu_op = 2'b00;
                        result_src = `RV_RES_PC4;  jalr = 1'b1;  uses_rs1 = 1'b1;
                    end
                    else illegal = 1'b1;
                end
                7'b1100011: begin                            // BRANCH
                    case (f3)
                        3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: begin
                            imm_src = `RV_IMM_B;  branch = 1'b1;  uses_rs1 = 1'b1;  uses_rs2 = 1'b1;
                        end
                        default: illegal = 1'b1;
                    endcase
                end
                7'b0000011: begin                            // LOAD
                    case (f3)
                        3'b000, 3'b001, 3'b010, 3'b100, 3'b101: begin
                            regwrite = 1'b1;  imm_src = `RV_IMM_I;  alu_src = 1'b1;  alu_op = 2'b00;
                            result_src = `RV_RES_MEM;  memread = 1'b1;  uses_rs1 = 1'b1;
                        end
                        default: illegal = 1'b1;
                    endcase
                end
                7'b0100011: begin                            // STORE
                    case (f3)
                        3'b000, 3'b001, 3'b010: begin
                            imm_src = `RV_IMM_S;  alu_src = 1'b1;  alu_op = 2'b00;
                            memwrite = 1'b1;  uses_rs1 = 1'b1;  uses_rs2 = 1'b1;
                        end
                        default: illegal = 1'b1;
                    endcase
                end
                7'b0010011: begin                            // OP-IMM
                    regwrite = 1'b1;  imm_src = `RV_IMM_I;  alu_src = 1'b1;  alu_op = 2'b10;  uses_rs1 = 1'b1;
                    if (f3 == 3'b001 && f7 != 7'b0000000)                         illegal = 1'b1;  // SLLI
                    if (f3 == 3'b101 && f7 != 7'b0000000 && f7 != 7'b0100000)    illegal = 1'b1;  // SRLI/SRAI
                end
                7'b0110011: begin                            // OP
                    regwrite = 1'b1;  alu_op = 2'b10;  uses_rs1 = 1'b1;  uses_rs2 = 1'b1;
                    if (!(f7 == 7'b0000000 ||
                         (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101)))) illegal = 1'b1;
                end
                7'b0001111: begin                            // MISC-MEM: FENCE = no-op
                    if (f3 != 3'b000) illegal = 1'b1;        // FENCE.I is Zifencei, not base RV32I
                end
                7'b1110011: begin                            // SYSTEM
                    if      (ins == 32'h0000_0073) ecall  = 1'b1;
                    else if (ins == 32'h0010_0073) ebreak = 1'b1;
                    else                           illegal = 1'b1;   // CSR instructions
                end
                default: illegal = 1'b1;
            endcase
        end

        if (illegal) begin                                   // no side effects, ever
            regwrite = 1'b0;  memwrite = 1'b0;  memread = 1'b0;
            branch = 1'b0;  jump = 1'b0;  jalr = 1'b0;
            uses_rs1 = 1'b0;  uses_rs2 = 1'b0;
        end
    end
endmodule

// ------------------------------------------------------------- ALU decoder
module alu_decoder (
    input  logic [1:0]  alu_op,
    input  logic [31:0] ins,
    output logic [3:0]  ALUControl
);
    logic [6:0] opcode;
    logic [2:0] funct3;
    assign opcode = ins[6:0];
    assign funct3 = ins[14:12];

    always_comb
        case (alu_op)
            2'b00:   ALUControl = `RV_ALU_ADD;                 // load / store / jalr address
            2'b01:   ALUControl = `RV_ALU_SUB;
            default: begin                                      // R-type and OP-IMM
                case (funct3)
                    3'b000: ALUControl = (opcode[5] & ins[30]) ? `RV_ALU_SUB : `RV_ALU_ADD;  // sub only for R-type
                    3'b001: ALUControl = `RV_ALU_SLL;
                    3'b010: ALUControl = `RV_ALU_SLT;
                    3'b011: ALUControl = `RV_ALU_SLTU;
                    3'b100: ALUControl = `RV_ALU_XOR;
                    3'b101: ALUControl = ins[30] ? `RV_ALU_SRA : `RV_ALU_SRL;
                    3'b110: ALUControl = `RV_ALU_OR;
                    3'b111: ALUControl = `RV_ALU_AND;
                endcase
            end
        endcase
endmodule

// ------------------------------------------------------------- control unit
module control_unit (
    input  logic [31:0] ins,
    input  logic        br_eq, br_lt, br_ltu,        // from branch_cmp
    output logic [3:0]  ALUControl,
    output logic [2:0]  imm_src, result_src,
    output logic        regwrite, alu_src, memwrite, memread,
    output logic        branch, jump, jalr,
    output logic [1:0]  pc_src,
    output logic        uses_rs1, uses_rs2,
    output logic        ecall, ebreak, illegal
);
    logic [1:0] alu_op;
    logic       cond, branch_taken;

    main_decoder MAIN_DEC (
        .ins(ins), .imm_src(imm_src), .alu_op(alu_op), .result_src(result_src),
        .regwrite(regwrite), .alu_src(alu_src), .memwrite(memwrite), .memread(memread),
        .branch(branch), .jump(jump), .jalr(jalr), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2),
        .ecall(ecall), .ebreak(ebreak), .illegal(illegal)
    );

    alu_decoder ALU_DEC (.alu_op(alu_op), .ins(ins), .ALUControl(ALUControl));

    // branch condition from funct3
    always_comb
        case (ins[14:12])
            3'b000:  cond =  br_eq;     // BEQ
            3'b001:  cond = ~br_eq;     // BNE
            3'b100:  cond =  br_lt;     // BLT
            3'b101:  cond = ~br_lt;     // BGE
            3'b110:  cond =  br_ltu;    // BLTU
            3'b111:  cond = ~br_ltu;    // BGEU
            default: cond = 1'b0;
        endcase

    assign branch_taken = branch & cond;
    assign pc_src = jalr                    ? `RV_PC_JALR :
                    (jump | branch_taken)   ? `RV_PC_TGT  :
                                              `RV_PC_NEXT;
endmodule

// ---------------------------------------------------------------- trap unit
// Everything that stops the core. Misalignment: RV32I without the C extension needs
// 4-byte aligned jump targets; natural alignment for halfword / word data.
module trap_unit(
    input  logic        illegal, ecall, ebreak,
    input  logic        memread, memwrite,           // controls BEFORE trap gating
    input  logic [2:0]  funct3,
    input  logic [1:0]  addr_lsb,                    // data address [1:0]
    input  logic [1:0]  pc_src,
    input  logic [1:0]  next_pc_lsb,                 // pc_next[1:0]
    output logic        trap,
    output logic [4:0]  cause
);
    logic mis_data, fetch_mis, load_mis, store_mis;

    assign mis_data  = ((funct3[1:0] == 2'b01) &  addr_lsb[0]) |
                       ((funct3[1:0] == 2'b10) & (addr_lsb != 2'b00));
    assign load_mis  = memread  & mis_data;
    assign store_mis = memwrite & mis_data;
    assign fetch_mis = (pc_src != `RV_PC_NEXT) & (next_pc_lsb != 2'b00);

    assign trap = illegal | ecall | ebreak | fetch_mis | load_mis | store_mis;

    always_comb begin
        if      (illegal)   cause = `RV_CAUSE_ILLEGAL;
        else if (ecall)     cause = `RV_CAUSE_ECALL;
        else if (ebreak)    cause = `RV_CAUSE_EBREAK;
        else if (fetch_mis) cause = `RV_CAUSE_FETCH_MISALIGNED;
        else if (load_mis)  cause = `RV_CAUSE_LOAD_MISALIGNED;
        else                cause = `RV_CAUSE_STORE_MISALIGNED;
    end
endmodule

// ------------------------------------------------------ immediate extractor
module imm_data(
    input  logic [31:0] ins,
    input  logic [2:0]  imm_src,
    output logic [31:0] imm
);
    always_comb
        case (imm_src)
            `RV_IMM_I: imm = {{20{ins[31]}}, ins[31:20]};
            `RV_IMM_S: imm = {{20{ins[31]}}, ins[31:25], ins[11:7]};
            `RV_IMM_B: imm = {{19{ins[31]}}, ins[31], ins[7], ins[30:25], ins[11:8], 1'b0};
            `RV_IMM_J: imm = {{11{ins[31]}}, ins[31], ins[19:12], ins[20], ins[30:21], 1'b0};
            `RV_IMM_U: imm = {ins[31:12], 12'b0};
            default:   imm = 32'd0;
        endcase
endmodule

// -------------------------------------------------------- load / store units
// Memory is a word-organised bus. Loads pick the byte / halfword out of the word and
// sign- or zero-extend; stores replicate the data into the right lane + byte enables.
module load_unit(
    input  logic [31:0] rdata,          // aligned word from the bus
    input  logic [1:0]  addr_lsb,
    input  logic [2:0]  funct3,
    output logic [31:0] result,
    output logic [3:0]  rmask
);
    logic [7:0]  b;
    logic [15:0] h;
    always_comb
        case (addr_lsb)
            2'd0:    b = rdata[7:0];
            2'd1:    b = rdata[15:8];
            2'd2:    b = rdata[23:16];
            default: b = rdata[31:24];
        endcase
    assign h = addr_lsb[1] ? rdata[31:16] : rdata[15:0];

    always_comb begin
        case (funct3)
            3'b000:  begin result = {{24{b[7]}},  b};  rmask = 4'b0001 << addr_lsb;              end // LB
            3'b001:  begin result = {{16{h[15]}}, h};  rmask = addr_lsb[1] ? 4'b1100 : 4'b0011;  end // LH
            3'b100:  begin result = {24'd0, b};        rmask = 4'b0001 << addr_lsb;              end // LBU
            3'b101:  begin result = {16'd0, h};        rmask = addr_lsb[1] ? 4'b1100 : 4'b0011;  end // LHU
            default: begin result = rdata;             rmask = 4'b1111;                          end // LW
        endcase
    end
endmodule

module store_unit(
    input  logic [31:0] wdata,          // rs2
    input  logic [1:0]  addr_lsb,
    input  logic [1:0]  size,           // funct3[1:0]: 00 byte, 01 half, 10 word
    output logic [31:0] bus_wdata,
    output logic [3:0]  be
);
    always_comb
        case (size)
            2'b00:   begin bus_wdata = {4{wdata[7:0]}};   be = 4'b0001 << addr_lsb;              end
            2'b01:   begin bus_wdata = {2{wdata[15:0]}};  be = addr_lsb[1] ? 4'b1100 : 4'b0011; end
            default: begin bus_wdata = wdata;             be = 4'b1111;                         end
        endcase
endmodule

// --------------------------------------------------- write-back result mux
module wb_mux(
    input  logic [31:0] alu_result, load_data, pcplus_4, imm, pc_target,
    input  logic [2:0]  result_src,
    output logic [31:0] WD
);
    always_comb
        case (result_src)
            `RV_RES_ALU:   WD = alu_result;
            `RV_RES_MEM:   WD = load_data;
            `RV_RES_PC4:   WD = pcplus_4;
            `RV_RES_IMM:   WD = imm;          // LUI
            `RV_RES_PCIMM: WD = pc_target;    // AUIPC (pc + imm)
            default:       WD = 32'd0;
        endcase
endmodule

// ---------------------------------------------------------------- PC logic
module program_counter(
    input  logic        clk, rst, en,
    input  logic [31:0] pc_next,
    output logic [31:0] pc
);
    always_ff @(posedge clk or posedge rst) begin
        if (rst)     pc <= 32'h0000_0000;
        else if (en) pc <= pc_next;
    end
endmodule

module alu_pc(
    input  logic [31:0] pc,
    output logic [31:0] pcplus_4
);
    assign pcplus_4 = pc + 32'd4;
endmodule

module alu_pc_target(
    input  logic [31:0] pc, imm,
    output logic [31:0] pc_target
);
    assign pc_target = pc + imm;
endmodule

module pc_src_mux(
    input  logic [31:0] pcplus_4, pc_target, jalr_target,
    input  logic [1:0]  pc_src,
    output logic [31:0] pc_next
);
    always_comb
        case (pc_src)
            `RV_PC_TGT:  pc_next = pc_target;
            `RV_PC_JALR: pc_next = {jalr_target[31:1], 1'b0};   // JALR clears bit 0
            default:     pc_next = pcplus_4;
        endcase
endmodule

module pc_top(
    input  logic        clk, rst, en,
    input  logic [1:0]  pc_src,
    input  logic [31:0] imm,
    input  logic [31:0] jalr_target,        // rs1 + imm from the ALU
    output logic [31:0] pc, pcplus_4, pc_next, pc_target
);
    program_counter pc_current (.clk(clk), .rst(rst), .en(en), .pc_next(pc_next), .pc(pc));
    alu_pc          pc_adder_4 (.pc(pc), .pcplus_4(pcplus_4));
    alu_pc_target   pc_target_alu (.pc(pc), .imm(imm), .pc_target(pc_target));
    pc_src_mux      pc_mux (.pcplus_4(pcplus_4), .pc_target(pc_target), .jalr_target(jalr_target),
                            .pc_src(pc_src), .pc_next(pc_next));
endmodule

// ------------------------------------------------------------ register file
module register_file(
    input  logic        clk, regwrite,
    input  logic [31:0] instruction,
    input  logic [31:0] WD_reg,
    output logic [31:0] RD1, RD2
);
    logic [4:0] A1, A2, A3;
    assign A1 = instruction[19:15];
    assign A2 = instruction[24:20];
    assign A3 = instruction[11:7];

    logic [31:0] regfile [31:0];

    integer i;
    initial for (i = 0; i < 32; i = i + 1) regfile[i] = 32'd0;      // simulation only

    // plain `always` (not always_ff): the array is also written by the initial block above
    always @(posedge clk)
        if (regwrite && A3 != 5'd0)                                // x0 is never written
            regfile[A3] <= WD_reg;

    assign RD1 = (A1 != 5'd0) ? regfile[A1] : 32'd0;
    assign RD2 = (A2 != 5'd0) ? regfile[A2] : 32'd0;
endmodule

// =============================================================================
// rv32i_core - the CPU without memories.  Clean instruction bus + data bus so it
// can sit in front of any memory / bus fabric (and a UVM environment later).
//
//   imem_addr  -> imem_rdata          : instruction fetch (combinational memory)
//   dmem_addr / dmem_wdata / dmem_be  : store  (byte enables, already lane aligned)
//   dmem_we / dmem_re / dmem_rdata    : dmem_rdata is the ALIGNED WORD at dmem_addr
// =============================================================================
module rv32i_core(
    input  logic        clk, rst,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,
    output logic        dmem_we, dmem_re,
    input  logic [31:0] dmem_rdata,

    output logic        trap,           // this cycle's instruction traps (first cycle only)
    output logic        halted,         // core stopped after a trap; cleared by reset
    output logic [4:0]  trap_cause,
    output logic [`RV_RVFI_W-1:0] rvfi      // retire trace, layout = rvfi_t (rv32i_types.svh)
);
    // ------------------------------------------------------------ signals
    rvfi_t       r;                     // the trace record, built below
    logic        zero, br_eq, br_lt, br_ltu;
    logic        regwrite, regwrite_c, alu_src, memwrite, memwrite_c, memread, memread_c;
    logic        branch, jump, jalr, uses_rs1, uses_rs2, ecall, ebreak, illegal;
    logic [1:0]  pc_src;
    logic [2:0]  imm_src, result_src;
    logic [3:0]  ALUControl;
    logic [31:0] pc, pc_next, pcplus_4, pc_target, instruction;
    logic [31:0] alu_result, W_Data, RD1, RD2, imm, srcb, RD, load_data, store_wd;
    logic [3:0]  store_be, load_rmask;
    logic        trap_now;
    logic [4:0]  cause_now;
    logic [63:0] order;

    assign instruction = imem_rdata;
    assign imem_addr   = pc;
    assign RD          = dmem_rdata;

    // trap => the instruction has no architectural effect and the PC freezes
    assign regwrite = regwrite_c & ~trap_now;
    assign memwrite = memwrite_c & ~trap_now;
    assign memread  = memread_c  & ~trap_now;

    // ------------------------------------------------------------- PC
    pc_top pc_counter1 (
        .clk(clk), .rst(rst), .en(~trap_now), .pc_src(pc_src), .imm(imm),
        .jalr_target(alu_result), .pc(pc), .pcplus_4(pcplus_4), .pc_next(pc_next), .pc_target(pc_target)
    );

    // ------------------------------------------------------------ control
    control_unit cu3 (
        .ins(instruction), .br_eq(br_eq), .br_lt(br_lt), .br_ltu(br_ltu),
        .ALUControl(ALUControl), .imm_src(imm_src), .result_src(result_src),
        .regwrite(regwrite_c), .alu_src(alu_src), .memwrite(memwrite_c), .memread(memread_c),
        .branch(branch), .jump(jump), .jalr(jalr), .pc_src(pc_src),
        .uses_rs1(uses_rs1), .uses_rs2(uses_rs2),
        .ecall(ecall), .ebreak(ebreak), .illegal(illegal)
    );

    trap_unit trap_unit1 (
        .illegal(illegal), .ecall(ecall), .ebreak(ebreak),
        .memread(memread_c), .memwrite(memwrite_c), .funct3(instruction[14:12]),
        .addr_lsb(alu_result[1:0]), .pc_src(pc_src), .next_pc_lsb(pc_next[1:0]),
        .trap(trap_now), .cause(cause_now)
    );

    // ---------------------------------------------------------- datapath
    register_file reg_file4 (
        .clk(clk), .regwrite(regwrite), .instruction(instruction),
        .WD_reg(W_Data), .RD1(RD1), .RD2(RD2)
    );

    imm_data immdata5 (.ins(instruction), .imm_src(imm_src), .imm(imm));

    alu_mux alu_mux6 (.RD2(RD2), .imm(imm), .alu_src(alu_src), .srcb(srcb));

    alu alu7 (.RD1(RD1), .srcb(srcb), .ALUControl(ALUControl), .alu_result(alu_result), .zero(zero));

    branch_cmp bcmp (.a(RD1), .b(RD2), .eq(br_eq), .lt(br_lt), .ltu(br_ltu));

    store_unit store_unit1 (
        .wdata(RD2), .addr_lsb(alu_result[1:0]), .size(instruction[13:12]),
        .bus_wdata(store_wd), .be(store_be)
    );

    load_unit load_unit1 (
        .rdata(RD), .addr_lsb(alu_result[1:0]), .funct3(instruction[14:12]),
        .result(load_data), .rmask(load_rmask)
    );

    wb_mux mux_ressult9 (
        .alu_result(alu_result), .load_data(load_data), .pcplus_4(pcplus_4), .imm(imm),
        .pc_target(pc_target), .result_src(result_src), .WD(W_Data)
    );

    // ------------------------------------------------------------ data bus
    assign dmem_addr  = alu_result;
    assign dmem_wdata = store_wd;
    assign dmem_be    = store_be & {4{memwrite}};
    assign dmem_we    = memwrite;
    assign dmem_re    = memread;

    // ------------------------------------------------------- halt + order
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            halted <= 1'b0;
            order  <= 64'd0;
        end
        else begin
            if (trap_now) halted <= 1'b1;
            if (r.valid) order <= order + 64'd1;
        end
    end

    assign trap       = trap_now & ~halted;
    assign trap_cause = cause_now;

    // ---------------------------------------------------------- retire trace
    logic       rd_wr;
    assign rd_wr = regwrite && (instruction[11:7] != 5'd0);

    always_comb begin
        r.valid     = ~rst & ~halted;
        r.order     = order;
        r.insn      = instruction;
        r.trap      = trap_now;
        r.halt      = trap_now;
        r.intr      = 1'b0;
        r.mode      = 2'd3;
        r.ixl       = 2'd1;
        r.rs1_addr  = uses_rs1 ? instruction[19:15] : 5'd0;
        r.rs2_addr  = uses_rs2 ? instruction[24:20] : 5'd0;
        r.rs1_rdata = uses_rs1 ? RD1 : 32'd0;
        r.rs2_rdata = uses_rs2 ? RD2 : 32'd0;
        r.rd_addr   = rd_wr ? instruction[11:7] : 5'd0;
        r.rd_wdata  = rd_wr ? W_Data : 32'd0;
        r.pc_rdata  = pc;
        r.pc_wdata  = trap_now ? pc : pc_next;
        r.mem_addr  = (memread || memwrite) ? {alu_result[31:2], 2'b00} : 32'd0;
        r.mem_rmask = memread  ? load_rmask : 4'd0;
        r.mem_wmask = memwrite ? store_be   : 4'd0;
        r.mem_rdata = memread  ? RD         : 32'd0;
        r.mem_wdata = memwrite ? store_wd   : 32'd0;
        r.cause     = trap_now ? cause_now  : 5'd0;
    end

    assign rvfi = r;
endmodule
