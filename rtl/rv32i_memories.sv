// =============================================================================
// Behavioural memories (simulation models - swap for SRAM macros at physical design)
// =============================================================================

// Instruction memory: 64 KB, byte array, combinational read.
// Program file: "./ins_little_endian.hex" (one byte per line, little-endian),
// or any file given on the command line with   +HEX=<path>
module ins_mem #(parameter int BYTES = 65536) (
    input  logic [31:0] addr,
    output logic [31:0] instruction
);
    logic [7:0] mem [0:BYTES-1];
    logic [8*256-1:0] hexfile;
    integer i;

    initial begin
        for (i = 0; i < BYTES; i = i + 1) mem[i] = 8'h00;      // unloaded memory = 0x00000000 = illegal instruction
        hexfile = "./ins_little_endian.hex";
        if ($value$plusargs("HEX=%s", hexfile)) ;               // +HEX=... overrides the default
        $readmemh(hexfile, mem);
    end

    logic [15:0] a;
    assign a = {addr[15:2], 2'b00};                             // fetches are word aligned
    assign instruction = {mem[a + 16'd3], mem[a + 16'd2], mem[a + 16'd1], mem[a]};
endmodule

// Data memory: 64 KB, word organised, per-byte write enables, combinational read of the
// aligned word (the core's load unit does the byte / halfword select and extension).
// Optional initial contents: +DHEX=<path> (one 32-bit word per line, hex).
module data_mem #(parameter int WORDS = 16384) (
    input  logic        clk, memwrite,
    input  logic [3:0]  be,
    input  logic [31:0] A,          // byte address
    input  logic [31:0] WD,         // write word (lane aligned by the store unit)
    output logic [31:0] RD          // aligned word at A
);
    logic [31:0] mem [0:WORDS-1];
    logic [8*256-1:0] dhexfile;
    integer i;

    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
        if ($value$plusargs("DHEX=%s", dhexfile)) $readmemh(dhexfile, mem);
    end

    localparam int AW = $clog2(WORDS);
    logic [AW-1:0] idx;
    assign idx = A[AW+1:2];
    assign RD  = mem[idx];

    // plain `always` (not always_ff): the array is also written by the initial block above
    always @(posedge clk)
        if (memwrite) begin
            if (be[0]) mem[idx][7:0]   <= WD[7:0];
            if (be[1]) mem[idx][15:8]  <= WD[15:8];
            if (be[2]) mem[idx][23:16] <= WD[23:16];
            if (be[3]) mem[idx][31:24] <= WD[31:24];
        end
endmodule
