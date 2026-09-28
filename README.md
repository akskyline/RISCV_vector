# RV32I Single-Cycle Core with Memory-Mapped Vector Coprocessor

A single-cycle **RV32I** RISC-V core with a Harvard memory system, extended with a **memory-mapped vector coprocessor** (`vec_coproc`) on a simple SoC bus. The project includes two verification tracks, both targeting **QuestaSim / ModelSim**:

- **Classic track**: SystemVerilog lockstep testbench against a reference ISS, a Python assembler and regression flow, and code coverage.
- **UVM track**: a UVM-1.2 environment with agents, sequences, scoreboards, SVA assertions, and functional and code coverage.

---

## Table of Contents

1. [Features](#features)
2. [Architecture](#architecture)
3. [Directory Structure](#directory-structure)
4. [Requirements](#requirements)
5. [Quick Start (QuestaSim)](#quick-start-questasim)
6. [Running the Tests](#running-the-tests)
7. [Plusargs](#plusargs)
8. [Expected Output](#expected-output)
9. [Coprocessor Register Map](#coprocessor-register-map)
10. [Core Policies and Trap Behavior](#core-policies-and-trap-behavior)
11. [Retire Trace (RVFI-style)](#retire-trace-rvfi-style)
12. [Verification Summary](#verification-summary)
13. [Documentation](#documentation)

---

## Features

- Full **RV32I base ISA**, single cycle, with byte-enabled Harvard memories.
- **8 x 4-lane, 32-bit vector coprocessor** driven purely through memory-mapped registers. No custom instruction encodings were added to the core.
- **SoC top level** with address decode: SRAM, coprocessor window, and unmapped-region handling.
- **RVFI-style retire trace** for lockstep checking against a reference model.
- Classic and UVM verification, with coverage merge scripts for QuestaSim.

## Architecture

```
            +-------------------------------------------------+
            |                  riscv_soc_top                  |
            |                                                 |
 ins_mem -->|  +-----------+      +-----------------------+   |
 (Harvard)  |  | rv32i_core|----->|     address decode    |   |
            |  +-----------+      +----+-------------+----+   |
            |                          |             |        |
            |                     +----v----+   +----v-----+  |
            |                     | data_mem|   | vec_coproc| |
            |                     |  (SRAM) |   | (MMIO)    | |
            |                     +---------+   +----------+  |
            +-------------------------------------------------+
```

| Block | Description |
|---|---|
| `rv32i_core` | Full RV32I single-cycle core |
| `ins_mem` / `data_mem` | Byte-enabled Harvard memories, both starting at address 0 |
| `sgle_cyc_processor` | Core plus memories (standalone, no coprocessor) |
| `riscv_soc_top` | Core plus memories plus address decode plus `vec_coproc` |
| `vec_coproc` | Vector unit (`vec_alu`, `vec_regfile`, control registers) |

**SoC memory map**

| Range | Target | Notes |
|---|---|---|
| `0x0000_0000` - `0x0000_FFFF` | Data SRAM | Byte, halfword and word access |
| `0x4000_0000` (2 KB window) | Vector coprocessor | Word writes only; sub-word stores are ignored, loads extract bytes/halfwords |
| Everything else | Unmapped | Reads return 0, writes are ignored, no trap |

## Directory Structure

| Path | Contents |
|---|---|
| `rtl/` | RTL source: `rv32i_types.svh` (constants, retire-trace struct), `rv32i_core_modules.sv` (core and submodules), `rv32i_memories.sv` (`ins_mem`, `data_mem`), `sgle_cyc_processor.sv` (core-only top), `riscv_soc_top.sv` (SoC top), `vec_*.sv` / `vec_defs.svh` (vector coprocessor), `rvfi_pkg.sv` |
| `tb/` | Classic testbenches: `rv32i_iss.sv` (reference model), `rv32i_tb.sv` (core lockstep), `riscv_soc_tb.sv` (SoC integration), `vec_coproc_tb.sv` (coprocessor unit test, T1-T12) |
| `uvm/` | UVM environment: `uvm/vec/` (coprocessor agent, scoreboard, coverage, sequences, tests), `uvm/core/` (core passive monitor, scoreboard, coverage), `uvm/soc/` (SoC env reusing both), `uvm/assertions/` (SVA), `uvm/README.md`, `uvm/run_uvm_modelsim.do` |
| `tests/`, `hex/` | Directed test sources (`tests/*.S`), assembled programs (`hex/*.hex`), and `hex/manifest.txt` (test name to expected trap cause) |
| `soc/` | SoC test program: `soc_prog.S` and `ins_little_endian.hex` |
| `scripts/` | `rv32_asm.py` (assembler), `check_asm_vs_gnu.py`, `gen_random.py` / `gen_random_hex.py` (random program generators and their constraints), `regress.py` (regression runner), `xcheck_unicorn.py`, `mutation_test.py`, `run_modelsim.do`, `run_coverage_modelsim.do`, `coverage_exclusions.do` |
| `coverage/` | Classic-track coverage output: one `.ucdb` per test, `merged.ucdb`, `overall_coverage.txt` |
| `uvm/coverage/` | UVM-track coverage output: one `.ucdb` per test, `merged_uvm.ucdb`, `overall_uvm_coverage.txt` |
| `docs/VERIFICATION.md` | Full verification report |

## Requirements

- **QuestaSim or ModelSim** (developed and run with QuestaSim-64 2024.1). The UVM track needs a **UVM-1.2** class library, either the simulator's bundled `-uvm` switch or a UVM-1.2 source tree passed to `vlog`. Both options are provided (commented) in `uvm/run_uvm_modelsim.do`.
- **Python 3** for the assembler, random generators, and regression runner. No third-party packages are needed, except `pip install unicorn` for the optional QEMU cross-check (`scripts/xcheck_unicorn.py`).

> This project is pre-synthesis RTL plus functional verification. There are no SDC/XDC timing constraints. The only "constraints" are verification constraints: weighted instruction-mix and operand constraints in `scripts/gen_random.py`, and the `rand`/`dist` blocks on `vec_cmd_txn` in `uvm/vec/vec_pkg.sv`.

## Quick Start (QuestaSim)

Clone the repository, then start QuestaSim from the repository root (or `cd` there inside the Questa console):

```tcl
cd <path/to/repo>
```

### 1. Compile everything

```tcl
vdel -lib work -all
vlib work
vlog -sv +incdir+rtl rtl/*.sv tb/*.sv
```

Expected: `Errors: 0, Warnings: 0`. The top-level modules are `riscv_soc_tb`, `rv32i_tb`, and `vec_coproc_tb`.

### 2. Run the core lockstep testbench (GUI, with waveforms)

```tcl
vsim -voptargs=+acc work.rv32i_tb +HEX=hex/t_ctrl.hex
add wave -r /*
run -all
```

Swap `hex/t_ctrl.hex` for any other program in `hex/`.

### 3. Run the SoC integration test (batch)

```tcl
vsim -c work.riscv_soc_tb +HEX=soc/ins_little_endian.hex -do "run -all; quit"
```

### 4. Run the coprocessor unit test

```tcl
vsim -c work.vec_coproc_tb -do "run -all; quit"
```

## Running the Tests

**Classic track, full regression (QuestaSim)**

```tcl
do scripts/run_modelsim.do
```

**Classic track, full regression with coverage**

```tcl
do scripts/run_coverage_modelsim.do
```

This merges every `hex/*.hex` program, the coprocessor unit test, and the SoC test into `coverage/merged.ucdb` and `coverage/overall_coverage.txt`. Re-running regenerates both from scratch.

**Classic track from the command line (Python runner)**

```bash
python3 scripts/regress.py --sim modelsim --random 50
```

`--random 50` adds 50 freshly generated random programs. Add `--xcheck` to cross-check against the Unicorn (QEMU) RV32 emulator.

**Mutation test** (checks that the checkers are strict enough)

```bash
python3 scripts/mutation_test.py
```

**UVM track, full regression with functional and code coverage**

```tcl
cd <path/to/repo>
do uvm/run_uvm_modelsim.do
```

Reports land in `uvm/coverage/` (`merged_uvm.ucdb`, `overall_uvm_coverage.txt`). To run a single UVM test, for example `vec_cov_test` or `core_base_test` on one program, see `uvm/README.md`. In general:

```tcl
vsim -c work.<top> +UVM_TESTNAME=<test> +N_CMDS=400 -do "run -all; quit"
```

**Assemble your own program**

```bash
python3 scripts/rv32_asm.py <input.S> <output.hex>
```

## Plusargs

| Plusarg | Applies to | Purpose |
|---|---|---|
| `+HEX=<file>` | Both | Instruction memory image |
| `+DHEX=<file>` | Both | Data memory initialization |
| `+QUIET` | Both | Suppress per-instruction output |
| `+STOP_PC=<hex>` | Both | Stop when the PC reaches this address |
| `+EXPECT_CAUSE=<n>` | Both | Expected trap cause at halt |
| `+MAXCYC=<n>` | Both | Cycle limit |
| `+COV` | Both | Enable coverage collection |
| `+VCD` | Both | Dump a VCD waveform |
| `+UVM_TESTNAME=<test>` | UVM | Select the UVM test |
| `+N_CMDS=<n>` | UVM | Coprocessor random-sequence length (default 400) |

## Expected Output

A passing SoC integration run ends with a scoreboard summary like this:

```
=== how the program ended ===
[PASS] core halted                                = 0x00000001 (1)
[PASS] trap cause = ECALL (clean end of test)     = 0x0000000b (11)
...
=============================================
 checks run : 42
 errors     : 0
 TEST PASSED
=============================================
```

The test program (`soc/soc_prog.S`) exercises:

1. Loading two vectors into the coprocessor window over the bus.
2. `VADD` with STATUS polling, and reading back the result lanes.
3. `VREDSUM` (110 for the example data).
4. An illegal coprocessor opcode (STATUS = DONE|ERR = 6).
5. Sub-word accesses to the coprocessor (stores ignored, loads extract bytes and halfwords).
6. Word, byte and halfword traffic to the data SRAM.
7. An unmapped-address access (reads 0, write ignored, no trap), then `ecall` to end.

The `[BUS]`, `[VEC]` and `[SRAM]` lines in the transcript trace each bus transaction and coprocessor operation with timestamps.

## Coprocessor Register Map

Base address `0x4000_0000` (built in software with `lui x10, 0x40000`).

| Offset | Register | Description |
|---|---|---|
| `0x000` | CTRL | Bit 0 = START |
| `0x004` | OP | Operation code (`0` = VADD, `4` = VREDSUM, others per `vec_defs.svh`; invalid codes set ERR) |
| `0x008` | VSEL | `vd` in bits [2:0], `vs1` in bits [5:3], `vs2` in bits [8:6] |
| `0x00C` | VL | Vector length (lanes) |
| `0x010` | STATUS | Bit 0 = BUSY, bit 1 = DONE, bit 2 = ERR |
| `0x014` | RESULT | Result of reduction operations |
| `0x100 + r*16 + l*4` | Vector window | Vector register `r` (0-7), lane `l` (0-3) |

Example: `VSEL = 139` selects `vd=3 | vs1=1<<3 | vs2=2<<6`.

## Core Policies and Trap Behavior

The core implements base RV32I only, with no CSRs, so a trap **halts the core**:

- **Traps**: illegal instruction, ECALL, EBREAK, misaligned load, misaligned store, misaligned jump or taken-branch target.
- The trapping instruction retires **once** with `trap=1` and no side effects. The PC freezes and `halted` stays high until reset.
- **Cause numbers** follow RISC-V `mcause`: `0` fetch misaligned, `2` illegal, `3` EBREAK, `4` load misaligned, `6` store misaligned, `11` ECALL.
- ECALL is the normal end of a program.
- `FENCE` is a no-op. `FENCE.I`, CSR instructions, `mul`, and compressed encodings are illegal.
- Instruction and data memories are separate (Harvard); both start at address 0.

## Retire Trace (RVFI-style)

The core emits one record per retired instruction on the `rvfi` port (see `rvfi_t` in `rvfi_pkg.sv`), valid in the cycle the instruction executes. Sample on the rising clock edge.

- `mem_addr` is word aligned.
- `mem_rmask` / `mem_wmask` indicate which bytes were read or written.
- An extra `cause` field carries the trap cause.

## Verification Summary

**Classic track**

- Lockstep comparison against the reference ISS on every instruction (all trace fields), plus final registers, PC, and data memory.
- Every directed and trap program, plus 200+ random programs, also cross-checked against the Unicorn (QEMU) emulator.
- Assembler checked byte-for-byte against GNU `as` (`scripts/check_asm_vs_gnu.py`).
- Mutation test: 33 injected RTL bugs, all detected.
- 40/40 RV32I instructions executed, all 6 trap causes hit, and a not-taken misaligned branch confirmed not to trap.
- SoC integration test: 42 self-checks passing.

**UVM track**

- Coprocessor agent with constrained-random sequences (`vec_cmd_txn`), scoreboard, and functional coverage.
- Passive core monitor, scoreboard, and coverage.
- SoC environment reusing both, plus SVA assertions in `uvm/assertions/`.
- Pass/fail and coverage numbers are produced by `do uvm/run_uvm_modelsim.do`. See `docs/VERIFICATION.md` (sections 6.2 and 6.3) for what to look for in the transcript.

## Documentation

- [`docs/VERIFICATION.md`](docs/VERIFICATION.md): full verification report (strategy, testbench architecture, test scenarios, assertions, UVM architecture, results).
- [`uvm/README.md`](uvm/README.md): UVM environment architecture and per-test run commands.
