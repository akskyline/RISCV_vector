# RV32I SoC with Vector/SIMD Coprocessor

A single-cycle RV32I RISC-V core integrated with a custom memory-mapped
4-lane vector/SIMD coprocessor: RTL design, functional verification (two
complementary testbench styles), and an RTL-to-GDSII physical design flow.

## Project Overview

The design has two halves communicating through a memory-mapped bus:

- **RV32I core** (`rv32i_core`, wrapped as `sgle_cyc_processor` with local
  memories for simulation, or as `riscv_soc_top` with the coprocessor
  attached) — a synthesizable single-cycle implementation of the full
  RV32I base integer instruction set, with trap/exception detection
  (illegal instruction, ECALL, EBREAK, misaligned load/store, misaligned
  fetch) and an RVFI-style retire-trace output for verification.
- **Vector/SIMD coprocessor** (`vec_coproc`) — a memory-mapped accelerator
  with 8 vector registers of 4 lanes each, supporting ADD / MUL / SLT /
  SEQ / REDSUM / REDMAX through a small control/status/window register
  interface. Ordinary CPU load/store instructions to its address range
  become coprocessor register accesses — no special instructions needed.

The project covers three phases, each documented separately:

1. **Functional verification** (`tb/`, `layered_tb/`) — see below.
2. **Synthesis, equivalence checking, place-and-route, and static timing
   analysis** (`constraints/`, `synthesis/`, `Equivalence_checking/`,
   `physical_design/`, `STA/`) — the full RTL-to-GDSII flow, documented
   step-by-step in **`GUIDE.md`**, targeting a 45 nm standard-cell library.
3. **This README** ties both together with compile/run instructions and
   the current, evidence-checked status of each.

## Directory Structure

| Path | Contents |
|---|---|
| `rtl/` | Synthesizable design source (core, memories, SoC top, vector coprocessor) and shared `.svh` headers |
| `rtl_pd/` | Synthesis-only replacements for the simulation memories (see note below) |
| `tb/` | Lockstep ISS reference model + directed/integration testbenches + post-synthesis equivalence-sim check |
| `layered_tb/` | Generator/driver/monitor/scoreboard layered testbenches (CPU, vector coprocessor, SoC) |
| `tests/`, `hex/`, `soc/` | Assembly test sources, assembled hex images, and the SoC-level vector-add program |
| `scripts/` | Assembler, program generators, mutation tester, GNU-`as`/Unicorn cross-checkers, regression `.do` script, and PD result-collection script |
| `constraints/` | Timing constraints (`riscv_soc_top.sdc`) |
| `synthesis/` | Genus synthesis script, output netlist/SDC/SDF, and QoR/area/power/timing reports |
| `Equivalence_checking/` | Conformal LEC dofiles and logs (RTL-vs-gate, and optional gate-vs-post-route) |
| `physical_design/` | Innovus (Stylus) floorplan/power/PnR scripts, MMMC view, outputs, and reports |
| `STA/` | Independent Tempus signoff timing script and reports |
| `lib/`, `lef/`, `captable/`, `QRC_Tech/` | **Empty placeholders** — see "Licensed PDK Files," below |
| `docs/screenshots/` | Transcript/waveform screenshots from confirmed passing layered-testbench runs |
| `final_submission/` | Reserved for the final GDS/deliverables once the PD flow completes |

> **Why `rtl_pd/` exists:** `rtl/rv32i_memories.sv` is a simulation model —
> 64 KB arrays loaded with `$readmemh`, which synthesis tools ignore.
> `rtl_pd/pd_imem_rom.sv` and `pd_data_mem_flops.sv` replace only those two
> modules (same names/ports, so `riscv_soc_top.sv` reads unchanged) with a
> synthesizable ROM and a flip-flop-based data memory. Both were verified in
> simulation against the original memories with an identical retire trace.
> `alt_180nm_sram/pd_data_mem.sv` is an alternative using real SRAM macros,
> for a 180 nm kit — see `GUIDE.md`'s last section for when to use it.

## Licensed PDK Files

`lib/`, `lef/`, `captable/`, and `QRC_Tech/` are **intentionally empty** in
this repository except for a `README.txt` in each — they hold licensed
foundry/EDA-vendor standard-cell and technology data (`gsclib045`/`gpdk045`)
that cannot be redistributed publicly. To run anything past RTL simulation
(synthesis, LEC, place-and-route, STA), copy these files in yourself from
your own licensed source, exactly as `GUIDE.md`'s Step 0 describes. Everyone
reviewing this repository can inspect all RTL, testbenches, scripts,
constraints, and the already-generated reports/logs without needing these
files — they're only required to *re-run* the PD stages from scratch.

## Required Tools / Environment

**Simulation / functional verification:**
- ModelSim / QuestaSim supporting IEEE 1800-2012 class-based testbenches
  (developed and verified against Intel FPGA Starter Edition vlog/vsim
  2020.1; newer QuestaSim releases work as well).
- Python 3 — only needed for `scripts/` (assembling new programs, random
  generation, mutation testing, cross-checks); `hex/` already contains
  pre-assembled images, so it's not required just to run the RTL sim.

**Physical design** (see `GUIDE.md` for full detail):
- Cadence Genus (synthesis), Conformal LEC (equivalence checking),
  Innovus/Stylus (place-and-route), Tempus (signoff STA) — versions as
  used in the provided logs: Genus 25.1-class, Conformal LEC 25.1,
  Innovus (Stylus), Tempus 25.1.
- A licensed 45 nm standard-cell/technology kit (`gsclib045`/`gpdk045`) —
  see "Licensed PDK Files" above.

## How to Compile and Run the Simulation

### Layered testbenches (recommended starting point)

Each of the three layered testbenches is self-contained and must be
compiled in **its own separate library/session** (they intentionally share
identically-named helper functions/opcode constants, which would collide
if compiled together):

```tcl
:: CPU core
vlib work
vlog -sv +incdir+rtl rtl/*.sv layered_tb/tb_cpu_layered.sv
vsim -voptargs=+acc work.cpu_tb_top
add wave -r /*
run -all

:: Vector coprocessor
vlib work
vlog -sv +incdir+rtl rtl/*.sv layered_tb/tb_vec_layered.sv
vsim -voptargs=+acc work.vec_tb_top
add wave -r /*
run -all

:: Full SoC integration
vlib work
vlog -sv +incdir+rtl rtl/*.sv layered_tb/tb_soc_layered.sv
vsim -voptargs=+acc work.soc_tb_top
add wave -r /*
run -all
```

Run `vdel -lib work -all` + `vlib work` fresh between the three — a stale
`work/` library from the previous testbench can cause `vsim` to fail to
find the new top module.

### Original lockstep / directed testbenches

```tcl
vdel -lib work -all
vlib work
vlog -sv +incdir+rtl rtl/*.sv tb/*.sv

vsim -voptargs=+acc work.rv32i_tb +HEX=hex/t_alu.hex +QUIET
add wave -r /*
run -all

vsim -voptargs=+acc work.vec_coproc_tb
run -all

vsim -voptargs=+acc work.riscv_soc_tb +HEX=soc/ins_little_endian.hex
run -all
```

## How to Run the Tests

**Every directed/trap program at once** (loops over `hex/manifest.txt`,
checking each program's actual trap cause against its expected one):
```tcl
do scripts/run_modelsim.do
```

**A single directed/trap program by name:**
```tcl
vsim -c work.rv32i_tb +HEX=hex/trap_ecall.hex +EXPECT_CAUSE=11 -do "run -all; quit -sim"
```

**The layered testbenches** need no plusargs — each builds and loads its
own directed test programs internally; run the three `vsim` invocations
above under "Layered testbenches."

**Regenerating test programs** (optional, Python 3):
```bash
python3 scripts/rv32_asm.py tests/my_new_test.S hex/my_new_test.hex
python3 scripts/gen_random.py
python3 scripts/mutation_test.py
python3 scripts/check_asm_vs_gnu.py
python3 scripts/xcheck_unicorn.py
```

## How to Reproduce the Reported Results

### Functional verification (confirmed, screenshots in `docs/screenshots/`)

| Testbench | Command | Result |
|---|---|---|
| CPU core (layered) | `vsim -voptargs=+acc work.cpu_tb_top` → `run -all` | `PASS=14 FAIL=0` |
| Vector coprocessor (layered) | `vsim -voptargs=+acc work.vec_tb_top` → `run -all` | `PASS=14 FAIL=0` |
| Full SoC (layered) | `vsim -voptargs=+acc work.soc_tb_top` → `run -all` | `PASS=2 FAIL=0` |
| Full lockstep regression | `do scripts/run_modelsim.do` | Every `hex/manifest.txt` program reports `RESULT PASS` |

A harmless warning (`Failed to open readmem file "./ins_little_endian.hex"`)
appears at the start of every layered-testbench run — expected, since each
loads its own program directly into instruction memory rather than via the
default `$readmemh`.

### Physical design (see `GUIDE.md` for the full step-by-step walkthrough)

| Stage | Command | Status |
|---|---|---|
| Synthesis | `cd synthesis && genus -f genus_script.tcl` | Complete: 0 violating paths, worst slack +1.5 ns at 100 MHz (`reports/report_qor.rpt`), no unresolved references (`reports/check_design_unresolved.rpt`) |
| Equivalence checking (RTL vs. gate) | `cd Equivalence_checking && lec -XL -nogui -64 -dofile riscv_lec.do` | **Rerun to completion** — the provided log stops right after the `compare` command; confirm the final Equivalent/Non-equivalent point count before citing this as passed |
| Place-and-route | `cd physical_design && innovus -stylus -files runPnR.tcl` | Not yet run — `outputs/`/`reports/` are currently placeholders |
| Signoff STA | `cd STA && tempus -stylus -files tempus_script.tcl` | Not yet run — depends on place-and-route output |

Run `scripts/collect_results.sh` to gather the metrics into `GUIDE.md`'s
"Final Results Table" once all stages are complete.

## Accessibility for Evaluators

- The repository is public and self-contained for everything **except**
  the licensed PDK content (see "Licensed PDK Files"): an evaluator can
  clone it, read every RTL/testbench file, inspect all synthesis/LEC
  reports and logs as committed evidence, and view the verification
  screenshots in `docs/screenshots/` without installing anything.
- Reproducing the **simulation** results only requires ModelSim/QuestaSim
  (see "Required Tools/Environment") — no licensed PDK needed.
- Reproducing the **physical design** stages requires Cadence tools plus
  the evaluator's own access to a compatible standard-cell/technology kit,
  copied in per `GUIDE.md` Step 0 — this is an unavoidable constraint of
  any ASIC flow built on licensed foundry data, not a gap in this repo.
- `GUIDE.md` documents every PD step in enough detail (exact commands,
  expected answers, and why each value differs from the course's original
  lab) that an evaluator with tool/kit access can follow it directly.