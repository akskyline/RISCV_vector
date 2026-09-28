# RV32I Single-Cycle Core + Memory-Mapped Vector Coprocessor

A single-cycle RV32I RISC-V core with a Harvard memory system, extended with a memory-mapped vector
coprocessor (`vec_coproc`) on a simple SoC bus, plus two full verification tracks: a classic
SystemVerilog/Python testbench flow (works today in any simulator) and a UVM-1.2 environment (agents,
sequences, scoreboards, functional + code coverage) for ModelSim/Questa.

**Verification status, read first:** the classic track's results below are real numbers, reproduced in the
environment this repository was authored in (Icarus Verilog + Python). The UVM track (everything under
`uvm/`, except the two `*_if.sv` interfaces and the SVA assertions) is written to standard UVM-1.2
conventions but **has not been compiled or simulated by the author** — that environment has no
QuestaSim/ModelSim and no network access to obtain one. See `docs/VERIFICATION.md` and `uvm/README.md` for
the full, honest account, and please paste back the transcript from `do uvm/run_uvm_modelsim.do` the same
way every other file in this project has been debugged so far.

## Project overview

* **RTL** (`rtl/`): `rv32i_core` (full RV32I base ISA, single cycle) + `ins_mem`/`data_mem` (Harvard,
  byte-enabled) → `sgle_cyc_processor` (core + memories, standalone) or `riscv_soc_top` (core + memories +
  address decode + `vec_coproc`, the SoC). `vec_coproc` is an 8×4-lane, 32-bit vector unit driven purely
  through memory-mapped registers (OP/VSEL/VL/CTRL/STATUS/RESULT + a register-window), so the CPU is a
  regular bus master to it — no custom instruction encoding was added to the core.
* **No CSRs, base RV32I only**: illegal instruction / ECALL / EBREAK / misaligned load-store / misaligned
  jump-or-taken-branch all trap by halting the core (cause number = RISC-V `mcause` convention); FENCE is a
  no-op; FENCE.I, CSR ops, `mul`, and compressed encodings are illegal.
* **Two verification tracks** over the same RTL: a classic SV+Python flow (`tb/`, `scripts/`, works with
  Icarus Verilog or ModelSim) and a UVM-1.2 environment (`uvm/`, ModelSim/Questa only). See
  `docs/VERIFICATION.md` for the full verification report (strategy, testbench architecture, test
  scenarios, UVM architecture/agents/sequences/scoreboard/assertions/coverage, and results).

## Directory structure

| Path | Contents |
|---|---|
| `rtl/` | **RTL source**: `rv32i_types.svh` (constants + retire-trace struct), `rv32i_core_modules.sv` (the core + submodules), `rv32i_memories.sv` (`ins_mem`/`data_mem`), `sgle_cyc_processor.sv` (core-only top), `riscv_soc_top.sv` (SoC top), `vec_*.sv`/`vec_defs.svh` (vector coprocessor) |
| `tb/` | **Classic-track testbench files**: `rv32i_iss.sv` (reference-model ISS), `rv32i_tb.sv` (core lockstep), `riscv_soc_tb.sv` (SoC integration), `vec_coproc_tb.sv` (coprocessor unit test, T1-T12) |
| `uvm/` | **UVM environment**: `uvm/vec/` (coprocessor agent+scoreboard+coverage+sequences+tests), `uvm/core/` (core passive monitor+scoreboard+coverage), `uvm/soc/` (SoC env reusing both), `uvm/assertions/` (SVA, no UVM dependency), `uvm/README.md` (architecture + running instructions), `uvm/run_uvm_modelsim.do` (regression + coverage script) |
| `tests/`, `hex/` | **Test cases/sequences (classic track)**: `tests/*.S` assembly sources, `hex/*.hex` assembled programs + `hex/manifest.txt` (name → expected trap cause), `soc/soc_prog.S` + `soc/ins_little_endian.hex` for the SoC test |
| `scripts/` | **Scripts**: `rv32_asm.py` (assembler), `check_asm_vs_gnu.py` (cross-check vs GNU `as`), `gen_random.py`/`gen_random_hex.py` (random program generators — this is also where **constraints** on random-program generation live, e.g. instruction-mix weighting and operand corner-biasing; the UVM track's equivalent constraints are the `rand`/`dist` declarations in `uvm/vec/vec_pkg.sv`'s `vec_cmd_txn`), `regress.py` (regression runner + coverage summary), `xcheck_unicorn.py` (cross-check vs the Unicorn/QEMU RV32 emulator), `mutation_test.py` (injects deliberate RTL bugs to check the checkers), `run_modelsim.do`/`run_coverage_modelsim.do`/`coverage_exclusions.do` (ModelSim scripts for the classic track) |
| `coverage/` | **Coverage-related files/reports (classic track)**: one `.ucdb` per test + `merged.ucdb` + `overall_coverage.txt`, produced by `scripts/run_coverage_modelsim.do` |
| `uvm/coverage/` | Coverage-related files/reports (UVM track), produced by `uvm/run_uvm_modelsim.do`: one `.ucdb` per UVM test + `merged_uvm.ucdb` + `overall_uvm_coverage.txt` |
| `docs/VERIFICATION.md` | The full verification report: strategy, testbench architecture, test scenarios, assertions/scoreboard detail, UVM architecture/agents/sequences/coverage, and results (simulation, pass/fail, coverage) |
| `README.md` | This file |

## Required tools / environment

* A SystemVerilog simulator. The classic track has been run with **Icarus Verilog** (`iverilog`/`vvp`,
  `-g2012`) and is also ModelSim-compatible; the UVM track needs **ModelSim/Questa with a UVM-1.2 class
  library** (either the simulator's bundled `-uvm` switch, or a UVM-1.2 source tree you point `vlog` at —
  both options are in `uvm/run_uvm_modelsim.do`, commented, pick whichever matches your install).
* **Python 3** (no third-party packages required for the assembler/regression runner; `scripts/xcheck_unicorn.py`
  additionally needs `pip install unicorn` if you want the QEMU-engine cross-check).
* No physical/timing constraints are part of this project (it is pre-synthesis RTL + functional
  verification only — there is no SDC/XDC file); the only "constraints" here are the verification kind:
  weighted instruction-mix / operand constraints in `scripts/gen_random.py` (classic track) and the
  `rand`/`dist` constraint blocks on `vec_cmd_txn` in `uvm/vec/vec_pkg.sv` (UVM track).

## How to compile and run the simulation

**Classic track, Icarus Verilog** (core only):
```bash
iverilog -g2012 -I rtl -s rv32i_tb -o sim.vvp rtl/rv32i_core_modules.sv rtl/rv32i_memories.sv \
         rtl/sgle_cyc_processor.sv tb/rv32i_iss.sv tb/rv32i_tb.sv
vvp sim.vvp +HEX=hex/t_ctrl.hex +QUIET +COV
```

**Classic track, ModelSim** (everything, via the provided `.do` script):
```tcl
vdel -lib work -all
vlib work
vlog -sv +incdir+rtl rtl/*.sv tb/*.sv
vsim -voptargs=+acc work.rv32i_tb +HEX=hex/t_ctrl.hex        ;# then: add wave -r /* ; run -all
vsim -c work.riscv_soc_tb +HEX=soc/ins_little_endian.hex -do "run -all; quit"
do scripts/run_modelsim.do                                    ;# runs the whole classic-track regression
or 
do scripts/run_coverage_modelsim.do                           ;# runs the whole classic-track regression with coverage
```

**UVM track, ModelSim/Questa** (see `uvm/README.md` for full detail and per-test commands):
```tcl
cd uvm_2
do uvm/run_uvm_modelsim.do
```

Common plusargs (both tracks, where applicable): `+HEX=<file>` program, `+DHEX=<file>` data init, `+QUIET`,
`+STOP_PC=<hex>`, `+EXPECT_CAUSE=<n>`, `+MAXCYC=<n>`, `+COV`, `+VCD`. UVM-specific: `+UVM_TESTNAME=<test>`,
`+N_CMDS=<n>` (coprocessor random-sequence length, default 400).

## How to run the tests

* **Everything, classic track, Icarus**: `python3 scripts/regress.py --random 50 --xcheck`
  (assembles every `tests/*.S`, runs the lockstep testbench, reports PASS/FAIL + an instruction-coverage
  summary, cross-checks against Unicorn; `--random 50` adds 50 freshly generated random programs).
* **Everything, classic track, ModelSim**: `python3 scripts/regress.py --sim modelsim --random 50`, or
  `do scripts/run_modelsim.do` directly from ModelSim.
* **Mutation test** (checks that the checkers are strict enough): `python3 scripts/mutation_test.py`.
* **Everything, UVM track**: `do uvm/run_uvm_modelsim.do` from ModelSim/Questa (see `uvm/README.md` for
  running one test at a time, e.g. just `vec_cov_test` or just `core_base_test` on one program).

## How to reproduce the reported results

* **Classic-track pass/fail + instruction coverage**: `python3 scripts/regress.py --random 50 --xcheck`
  reproduces the "40/40 instructions, all 6 trap causes, 200+ random programs, Unicorn cross-check" numbers
  in `docs/VERIFICATION.md` §6.1.
* **Classic-track code coverage**: `do scripts/run_coverage_modelsim.do` from ModelSim — merges every
  `hex/*.hex` program + the coprocessor unit test + the SoC test into `coverage/merged.ucdb` /
  `coverage/overall_coverage.txt` (already present in this repo from a prior run; re-running regenerates
  them from scratch).
* **Mutation-test result** ("33/33 injected bugs detected"): `python3 scripts/mutation_test.py`.
* **UVM pass/fail + functional + code coverage**: `do uvm/run_uvm_modelsim.do` — see
  `docs/VERIFICATION.md` §6.2/§6.3 for exactly what to look for in the transcript and where the report files
  land (`uvm/coverage/overall_uvm_coverage.txt`). This has not been run by the author; the numbers in that
  section are placeholders describing how to obtain them, not fabricated results.

## Policies (no CSRs in base RV32I, so the core halts on a trap)
* trap = illegal instruction, ECALL, EBREAK, misaligned load / store, misaligned jump / taken-branch target.
  The instruction retires ONCE with `trap=1` and no side effect, the PC freezes, `halted` goes high until reset.
  Cause numbers = RISC-V `mcause` (0 fetch misaligned, 2 illegal, 3 ebreak, 4 load, 6 store, 11 ecall).
* ECALL is therefore the normal "end of program". FENCE = no-op. FENCE.I, CSR instructions, `mul`, compressed
  encodings are illegal (base RV32I only).
* Memories are separate (Harvard): instruction memory and data memory both start at address 0.
* SoC map: SRAM 0x0000_0000-0xFFFF, coprocessor 0x4000_0000 (2 KB, word access only), everything else unmapped
  (reads 0, writes ignored).

## Retire trace (`rvfi` port, RVFI-style field names, see `rvfi_t`)
One record per retired instruction, valid in the cycle it executes: sample on the rising clock edge.
`mem_addr` is word aligned; `mem_rmask`/`mem_wmask` say which bytes were read/written. Extra field `cause`.

## Verification done (classic track — reproduced numbers)
* Lockstep vs the reference model on every instruction (all trace fields) + final registers, PC, data memory.
* Every directed/trap program, over 200 random programs, all also cross-checked against the Unicorn (QEMU)
  emulator.
* Assembler cross-checked byte-for-byte against GNU `as` (`scripts/check_asm_vs_gnu.py`).
* 33 injected RTL bugs (mutation test, `scripts/mutation_test.py`) — all detected.
* 40/40 RV32I instructions executed; all 6 trap causes; misaligned-not-taken branch does not trap.

See `docs/VERIFICATION.md` for the full verification report (strategy, architecture, scenarios, UVM
details, and results) and `uvm/README.md` for the UVM environment specifically.
