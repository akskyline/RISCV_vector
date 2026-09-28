// =============================================================================
// rv32i_iss - behavioural RV32I instruction-set simulator (the "golden model")
//
// Deliberately written in a different style from the RTL (one big case on the opcode,
// blocking arithmetic, read-modify-write memory) so that a mistake is unlikely to be
// copied into both. It loads the same program / data files as the DUT
// (+HEX=... and +DHEX=..., default ./ins_little_endian.hex) and executes ONE instruction
// per call of  step;  filling the o_* record (same fields / meaning as the core's rvfi).
//
// Policy is identical to the core (see rv32i_core_modules.sv): illegal instruction,
// ECALL, EBREAK, misaligned load / store / jump target -> trap with NO side effects,
// after which the model is halted.
// =============================================================================
module rv32i_iss #(
    parameter int IMEM_BYTES = 65536,
    parameter int DMEM_WORDS = 16384
);
    // ---------------------------------------------------------------- state
    logic [7:0]  imem [0:IMEM_BYTES-1];
    logic [31:0] dmem [0:DMEM_WORDS-1];
    logic [31:0] x    [0:31];
    logic [31:0] pc;
    bit          halted;
    longint      retired;

    // ------------------------------------------- record of the last step()
    logic [31:0] o_insn, o_pc_rdata, o_pc_wdata, o_rs1_rdata, o_rs2_rdata, o_rd_wdata;
    logic [31:0] o_mem_addr, o_mem_rdata, o_mem_wdata;
    logic [4:0]  o_rs1_addr, o_rs2_addr, o_rd_addr, o_cause;
    logic [3:0]  o_rmask, o_wmask;
    logic        o_trap;

    logic [8*256-1:0] hexfile, dhexfile;
    integer i;

    initial begin
        for (i = 0; i < IMEM_BYTES; i = i + 1) imem[i] = 8'h00;
        for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'd0;
        for (i = 0; i < 32; i = i + 1)         x[i]    = 32'd0;
        pc = 32'd0;  halted = 1'b0;  retired = 0;
        hexfile = "./ins_little_endian.hex";
        if ($value$plusargs("HEX=%s", hexfile)) ;
        $readmemh(hexfile, imem);
        if ($value$plusargs("DHEX=%s", dhexfile)) $readmemh(dhexfile, dmem);
    end

    // ----------------------------------------------------------- helpers
    function automatic logic [31:0] fetch(input logic [31:0] a);
        logic [15:0] b;
        begin
            b = a[15:0];
            fetch = {imem[b + 16'd3], imem[b + 16'd2], imem[b + 16'd1], imem[b]};
        end
    endfunction

    // ------------------------------------------------------------- one instruction
    task step;
        logic [31:0] insn, rs1v, rs2v, imm_i, imm_s, imm_b, imm_u, imm_j;
        logic [31:0] npc, res, addr, tgt, word;
        logic [6:0]  opc, f7;
        logic [2:0]  f3;
        logic [4:0]  rd, rs1, rs2;
        logic signed [7:0]  sb8;
        logic signed [15:0] sh16;
        logic [7:0]  ub8;
        logic [15:0] uh16;
        bit          wr_rd, ill, take, u1, u2;
        logic [4:0]  cause;
        integer      sh;
        begin
            insn = fetch(pc);
            opc = insn[6:0];  f3 = insn[14:12];  f7 = insn[31:25];
            rd = insn[11:7];  rs1 = insn[19:15];  rs2 = insn[24:20];
            imm_i = {{20{insn[31]}}, insn[31:20]};
            imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
            imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
            imm_u = {insn[31:12], 12'd0};
            imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

            // defaults for the record
            o_insn = insn;  o_pc_rdata = pc;  o_pc_wdata = pc;
            o_rs1_addr = 0; o_rs2_addr = 0; o_rs1_rdata = 0; o_rs2_rdata = 0;
            o_rd_addr = 0;  o_rd_wdata = 0;
            o_mem_addr = 0; o_rmask = 0; o_wmask = 0; o_mem_rdata = 0; o_mem_wdata = 0;
            o_trap = 0;     o_cause = 0;

            rs1v = x[rs1];  rs2v = x[rs2];
            npc = pc + 32'd4;  wr_rd = 0;  res = 0;  ill = 0;  cause = 0;  u1 = 0;  u2 = 0;

            if (halted) begin
                // nothing to do
            end
            else begin
                if (insn[1:0] != 2'b11) ill = 1;
                else case (opc)
                    7'b0110111: begin res = imm_u;      wr_rd = 1; end                   // LUI
                    7'b0010111: begin res = pc + imm_u; wr_rd = 1; end                   // AUIPC

                    7'b1101111: begin                                                    // JAL
                        tgt = pc + imm_j;
                        if (tgt[1:0] != 0) begin o_trap = 1; o_cause = 0; end
                        else begin res = pc + 4; wr_rd = 1; npc = tgt; end
                    end

                    7'b1100111: begin                                                    // JALR
                        if (f3 != 0) ill = 1;
                        else begin
                            u1 = 1;
                            tgt = (rs1v + imm_i) & 32'hFFFF_FFFE;
                            if (tgt[1:0] != 0) begin o_trap = 1; o_cause = 0; end
                            else begin res = pc + 4; wr_rd = 1; npc = tgt; end
                        end
                    end

                    7'b1100011: begin                                                    // BRANCH
                        u1 = 1; u2 = 1;
                        case (f3)
                            3'b000: take = (rs1v == rs2v);
                            3'b001: take = (rs1v != rs2v);
                            3'b100: take = ($signed(rs1v) <  $signed(rs2v));
                            3'b101: take = ($signed(rs1v) >= $signed(rs2v));
                            3'b110: take = (rs1v <  rs2v);
                            3'b111: take = (rs1v >= rs2v);
                            default: begin take = 0; ill = 1; end
                        endcase
                        if (!ill && take) begin
                            tgt = pc + imm_b;
                            if (tgt[1:0] != 0) begin o_trap = 1; o_cause = 0; end
                            else npc = tgt;
                        end
                    end

                    7'b0000011: begin                                                    // LOAD
                        u1 = 1;
                        addr = rs1v + imm_i;
                        word = dmem[addr[15:2]];
                        case (f3)
                            3'b000: begin                                                 // LB
                                sb8 = word >> (8 * addr[1:0]);  res = sb8;
                                o_rmask = 4'b0001 << addr[1:0];
                            end
                            3'b001: begin                                                 // LH
                                sh16 = word >> (16 * addr[1]);  res = sh16;
                                o_rmask = 4'b0011 << (2 * addr[1]);
                                if (addr[0]) begin o_trap = 1; o_cause = 4; end
                            end
                            3'b010: begin                                                 // LW
                                res = word;  o_rmask = 4'b1111;
                                if (addr[1:0] != 0) begin o_trap = 1; o_cause = 4; end
                            end
                            3'b100: begin                                                 // LBU
                                ub8 = word >> (8 * addr[1:0]);  res = {24'd0, ub8};
                                o_rmask = 4'b0001 << addr[1:0];
                            end
                            3'b101: begin                                                 // LHU
                                uh16 = word >> (16 * addr[1]);  res = {16'd0, uh16};
                                o_rmask = 4'b0011 << (2 * addr[1]);
                                if (addr[0]) begin o_trap = 1; o_cause = 4; end
                            end
                            default: ill = 1;
                        endcase
                        if (!ill) begin
                            o_mem_addr = {addr[31:2], 2'b00};  o_mem_rdata = word;
                            wr_rd = 1;
                        end
                    end

                    7'b0100011: begin                                                    // STORE
                        u1 = 1; u2 = 1;
                        addr = rs1v + imm_s;
                        word = dmem[addr[15:2]];
                        case (f3)
                            3'b000: begin                                                 // SB
                                o_wmask = 4'b0001 << addr[1:0];
                                o_mem_wdata = {4{rs2v[7:0]}};
                                word[8*addr[1:0] +: 8] = rs2v[7:0];
                            end
                            3'b001: begin                                                 // SH
                                o_wmask = 4'b0011 << (2 * addr[1]);
                                o_mem_wdata = {2{rs2v[15:0]}};
                                word[16*addr[1] +: 16] = rs2v[15:0];
                                if (addr[0]) begin o_trap = 1; o_cause = 6; end
                            end
                            3'b010: begin                                                 // SW
                                o_wmask = 4'b1111;
                                o_mem_wdata = rs2v;
                                word = rs2v;
                                if (addr[1:0] != 0) begin o_trap = 1; o_cause = 6; end
                            end
                            default: ill = 1;
                        endcase
                        if (!ill) o_mem_addr = {addr[31:2], 2'b00};
                    end

                    7'b0010011: begin                                                    // OP-IMM
                        u1 = 1;  wr_rd = 1;
                        sh = imm_i[4:0];
                        case (f3)
                            3'b000: res = rs1v + imm_i;                                                     // ADDI
                            3'b010: res = ($signed(rs1v) < $signed(imm_i)) ? 1 : 0;                         // SLTI
                            3'b011: res = (rs1v < imm_i) ? 1 : 0;                                           // SLTIU
                            3'b100: res = rs1v ^ imm_i;                                                     // XORI
                            3'b110: res = rs1v | imm_i;                                                     // ORI
                            3'b111: res = rs1v & imm_i;                                                     // ANDI
                            3'b001: if (f7 == 7'b0000000) res = rs1v << sh; else ill = 1;                   // SLLI
                            3'b101: begin
                                if      (f7 == 7'b0000000) res = rs1v >> sh;                                // SRLI
                                else if (f7 == 7'b0100000) res = $signed(rs1v) >>> sh;                      // SRAI
                                else ill = 1;
                            end
                        endcase
                    end

                    7'b0110011: begin                                                    // OP
                        u1 = 1; u2 = 1;  wr_rd = 1;
                        sh = rs2v[4:0];
                        if (f7 == 7'b0000000) begin
                            case (f3)
                                3'b000: res = rs1v + rs2v;                                                   // ADD
                                3'b001: res = rs1v << sh;                                                    // SLL
                                3'b010: res = ($signed(rs1v) < $signed(rs2v)) ? 1 : 0;                       // SLT
                                3'b011: res = (rs1v < rs2v) ? 1 : 0;                                         // SLTU
                                3'b100: res = rs1v ^ rs2v;                                                   // XOR
                                3'b101: res = rs1v >> sh;                                                    // SRL
                                3'b110: res = rs1v | rs2v;                                                   // OR
                                3'b111: res = rs1v & rs2v;                                                   // AND
                            endcase
                        end
                        else if (f7 == 7'b0100000 && f3 == 3'b000) res = rs1v - rs2v;                       // SUB
                        else if (f7 == 7'b0100000 && f3 == 3'b101) res = $signed(rs1v) >>> sh;               // SRA
                        else ill = 1;
                    end

                    7'b0001111: begin                                                    // FENCE
                        if (f3 != 0) ill = 1;
                    end

                    7'b1110011: begin                                                    // SYSTEM
                        if      (insn == 32'h0000_0073) begin o_trap = 1; o_cause = 11; end   // ECALL
                        else if (insn == 32'h0010_0073) begin o_trap = 1; o_cause = 3;  end   // EBREAK
                        else ill = 1;
                    end

                    default: ill = 1;
                endcase

                if (ill) begin o_trap = 1; o_cause = 2; end

                // ---- commit (a trapping instruction changes nothing)
                if (o_trap) begin
                    halted = 1;
                    o_pc_wdata = pc;
                    // an illegal instruction reports no operands, the others report what they read
                    if (ill) begin u1 = 0; u2 = 0; end
                    o_rs1_addr = u1 ? rs1 : 0;   o_rs1_rdata = u1 ? rs1v : 0;
                    o_rs2_addr = u2 ? rs2 : 0;   o_rs2_rdata = u2 ? rs2v : 0;
                    o_rd_addr = 0;  o_rd_wdata = 0;  o_mem_addr = 0;  o_mem_rdata = 0;  o_mem_wdata = 0;
                    o_rmask = 0;    o_wmask = 0;
                end
                else begin
                    if (opc == 7'b0100011) dmem[addr[15:2]] = word;
                    if (wr_rd && rd != 0) begin x[rd] = res; o_rd_addr = rd; o_rd_wdata = res; end
                    o_rs1_addr = u1 ? rs1 : 0;   o_rs1_rdata = u1 ? rs1v : 0;
                    o_rs2_addr = u2 ? rs2 : 0;   o_rs2_rdata = u2 ? rs2v : 0;
                    pc = npc;
                    o_pc_wdata = npc;
                    retired = retired + 1;
                end
            end
        end
    endtask
endmodule
