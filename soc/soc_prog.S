# ---------------------------------------------------------------------------
# SoC integration program (full RV32I core + memory-mapped vector coprocessor)
# Coprocessor window base = 0x4000_0000 (x10), built with lui - no more add tricks.
#   0x000 CTRL  0x004 OP  0x008 VSEL  0x00C VL  0x010 STATUS  0x014 RESULT
#   0x100 + r*16 + l*4 : vector register r, lane l
# ---------------------------------------------------------------------------
        lui  x10, 0x40000         # x10 = 0x4000_0000

        # v1 = {1,2,3,4}   (v1 at window offset 0x110)
        addi x1, x0, 1
        sw   x1, 0x110(x10)
        addi x1, x0, 2
        sw   x1, 0x114(x10)
        addi x1, x0, 3
        sw   x1, 0x118(x10)
        addi x1, x0, 4
        sw   x1, 0x11C(x10)
        # v2 = {10,20,30,40}  (v2 at 0x120)
        addi x1, x0, 10
        sw   x1, 0x120(x10)
        addi x1, x0, 20
        sw   x1, 0x124(x10)
        addi x1, x0, 30
        sw   x1, 0x128(x10)
        addi x1, x0, 40
        sw   x1, 0x12C(x10)

        # ---- VADD v3 = v1 + v2, VL = 4
        addi x1, x0, 0            # OP = VADD
        sw   x1, 0x004(x10)
        addi x1, x0, 139          # VSEL: vd=3 | vs1=1<<3 | vs2=2<<6
        sw   x1, 0x008(x10)
        addi x1, x0, 4            # VL = 4
        sw   x1, 0x00C(x10)
        addi x1, x0, 1            # CTRL.START
        sw   x1, 0x000(x10)
poll1:  lw   x2, 0x010(x10)       # poll STATUS
        andi x3, x2, 2            # DONE bit
        beq  x3, x0, poll1

        lw   x4, 0x130(x10)       # v3[0] = 11
        lw   x5, 0x134(x10)       # v3[1] = 22
        lw   x6, 0x138(x10)       # v3[2] = 33
        lw   x7, 0x13C(x10)       # v3[3] = 44

        # ---- VREDSUM of v3 (VL=4) -> RESULT = 110
        addi x1, x0, 4            # OP = VREDSUM
        sw   x1, 0x004(x10)
        addi x1, x0, 24           # VSEL: vs1 = 3<<3
        sw   x1, 0x008(x10)
        addi x1, x0, 1            # START
        sw   x1, 0x000(x10)
poll2:  lw   x2, 0x010(x10)
        andi x3, x2, 2
        beq  x3, x0, poll2
        lw   x8, 0x014(x10)       # x8 = 110

        # ---- illegal opcode -> ERR + DONE straight away
        addi x1, x0, 15
        sw   x1, 0x004(x10)
        addi x1, x0, 1
        sw   x1, 0x000(x10)
        lw   x9, 0x010(x10)       # x9 = 0b110 = 6

        # ---- sub-word accesses to the coprocessor: stores are IGNORED, loads extract bytes
        addi x1, x0, 0x55
        sb   x1, 0x110(x10)       # ignored (word access only)
        lw   x13, 0x110(x10)      # still 1
        sh   x1, 0x114(x10)       # ignored
        lw   x16, 0x114(x10)      # still 2
        lbu  x14, 0x010(x10)      # STATUS byte 0 = 6
        lbu  x15, 0x011(x10)      # STATUS byte 1 = 0
        lh   x17, 0x010(x10)      # STATUS low halfword = 6

        # ---- ordinary SRAM traffic next to the coprocessor (word, byte, halfword)
        add  x11, x4, x7          # 11 + 44 = 55
        sw   x11, 0(x0)
        lw   x12, 0(x0)           # 55
        lui  x22, 0x12345
        addi x22, x22, 0x678      # x22 = 0x12345678
        sw   x22, 0x100(x0)
        lbu  x23, 0x101(x0)       # 0x56
        lh   x24, 0x102(x0)       # 0x1234
        sb   x1, 0x103(x0)        # word becomes 0x55345678
        lw   x25, 0x100(x0)

        # ---- unmapped address: reads 0, writes ignored, no trap
        lui  x20, 0x80000
        lw   x21, 0(x20)          # 0
        sw   x1, 0(x20)
        ecall
