# UVM environment - RV32I core + vector coprocessor SoC

Three separate UVM environments, sharing components where the design allows it:

| Environment | DUT | Top testbench | Test names |
|---|---|---|---|
| Coprocessor only | `vec_coproc` | `uvm/vec/vec_coproc_uvm_tb.sv` | `vec_smoke_test`, `vec_random_test`, `vec_sweep_test`, `vec_negative_test`, `vec_reset_mid_op_test`, `vec_cov_test` (all-in-one) |
| Core only | `sgle_cyc_processor` | `uvm/core/rv32i_core_uvm_tb.sv` | `core_base_test` (run once per `hex/*.hex` program via `+HEX=`) |
| Full SoC | `riscv_soc_top` | `uvm/soc/riscv_soc_uvm_tb.sv` | `soc_base_test` |

### Coprocessor sequences and coverage-closure strategy

| Sequence | Purpose |
|---|---|
| `vec_directed_seq` | T1/T3-T8/T10 directed scenarios ported from `tb/vec_coproc_tb.sv` |
| `vec_corner_sweep_seq` | exhaustively drives every `{op(0-15), vl(0-7)}` cell (128 commands) so the illegal-op, illegal-VL and op×VL cross bins close deterministically, not by random luck |
| `vec_negative_access_seq` | T2/T10: write-only/read-only register misuse, out-of-window bus accesses |
| `vec_random_seq` | constrained-random via `vec_cmd_txn::randomize()` (see below) - weighted `dist` on op/VL, corner-biased operand words, forced-aliasing knobs |
| `vec_reset_mid_op_test` | T9/T11: asserts reset (via the new `vec_if.inject_reset` / `RESETTER` modport) while a command is in flight, then checks clean recovery |
| `vec_cov_test` | runs all of the above back-to-back in one `vsim` invocation - the one to use for a coverage-closure run |

`vec_cmd_txn` (in `uvm/vec/vec_pkg.sv`) is a proper randomizable UVM object -
`rand` fields for `op`/`vd`/`vs1`/`vs2`/`vl`/operand words, `dist`-weighted
constraints, and aliasing forced through implication constraints
(`force_alias_vd_vs1 -> vd == vs1`, etc.). Sequences call
`txn.randomize()` (and, for the sweep, `txn.randomize() with { op == ...; vl
== ...; }` to pin two fields while leaving the rest constrained-random) -
this is the actual UVM `randomize()` machinery, not hand-rolled
`$urandom_range` picking.

Functional coverage (`uvm/vec/vec_pkg.sv`, class `vec_coverage`) now has two
covergroups: `cg_cmd` (op, VL, aliasing, and - separately gated - illegal-op /
illegal-VL bins so every bin is actually reachable) and `cg_recover`
(legal-after-illegal / illegal-after-legal transition coverage, i.e. "an ERR
does not stick"). `uvm/core/core_pkg.sv`'s `cg_insn` gained rs2 corner
operands, `rs1==rs2`, `rd==x0`, branch taken/not-taken, JAL/JALR direction,
and load/store byte-offset coverpoints, plus `ignore_bins` on the op×funct3
cross for the three opcodes (LUI/AUIPC/JAL) that have no real funct3 field -
without that exclusion those cross cells can never be hit and coverage would
be capped below 100% for a reason that has nothing to do with test quality.

## Architecture

**Vector coprocessor (`uvm/vec/`)** is a conventional *active* UVM agent: a
sequencer/driver pair actively drives the register bus one cycle at a time
(`vec_bus_item`), a monitor observes every bus cycle and also reconstructs
whole commands (op/vd/vs1/vs2/vl) the moment a START goes by, a scoreboard
runs the same reference-model algorithm the original `tb/vec_coproc_tb.sv`
used but event-driven off the monitor instead of called from a sequential
test, and a covergroup samples op × VL × operand-aliasing. `vec_directed_seq`
and `vec_random_seq` port the T1-T12 scenarios from that original testbench
into reusable UVM sequences.

**Core (`uvm/core/`)** is deliberately *passive*: the core's stimulus is
whatever program sits in instruction memory (`+HEX=`), not something a UVM
driver produces, so there is a monitor tapping the `rvfi` retire-trace port
and a scoreboard, but no driver. The scoreboard's reference model
(`rv32i_reference_model`) is the same algorithm as `tb/rv32i_iss.sv`, ported
from a module+task into a plain class so it can live inside a UVM component.

**SoC (`uvm/soc/`)** reuses both environments unmodified: `core_env` watches
`riscv_soc_top`'s `rvfi` port exactly as before, and `vec_env` is instantiated
a second time with `is_active` forced to `UVM_PASSIVE` (via `uvm_config_db`)
so only its monitor is built - it taps the coprocessor bus *inside* the SoC,
where the CPU (not a UVM driver) is the real bus master. This is the payoff
of giving `vec_agent` an active/passive switch in the first place.

**Assertions (`uvm/assertions/`)** are plain SVA, `bind`-inserted into
`rv32i_core` and `vec_coproc` - no UVM dependency at all, so they run in any
simulator and were exercised directly here.

## Verification status - please read before compiling

Everything in this environment that depends on the **real UVM-1.2 class
library** (every file under `uvm/vec/`, `uvm/core/`, `uvm/soc/` except the
two `*_if.sv` interfaces) has **not** been compiled or run in this sandbox.
I checked directly: neither Icarus Verilog nor Verilator here can run real
UVM - Icarus's SystemVerilog class support does not extend to dynamic
arrays/queues of class handles, which UVM's analysis ports and sequencer
queues rely on throughout (confirmed with a minimal test case), and
Verilator's build for a UVM-class-heavy design did not complete in a
reasonable time here. So this code is written to standard UVM-1.2
conventions from experience, not verified end-to-end by simulation, unlike
literally every other file delivered earlier in this project.

What **has** been compiled and run against the real RTL here, with results
confirmed correct:
- `uvm/vec/vec_if.sv` and `uvm/core/rvfi_if.sv` - elaborated against
  `vec_coproc` and `sgle_cyc_processor` directly; signal names and widths
  checked against a live simulation.
- The SoC-level passive tap in `uvm/soc/riscv_soc_uvm_tb.sv` (which
  `riscv_soc_top` internal nets feed `vec_if`) - elaborated against
  `riscv_soc_top` and cross-checked byte-for-byte against
  `rtl/riscv_soc_top.sv`'s own instantiation of `vec_coproc`.
- `uvm/assertions/core_assertions.sv` and `uvm/assertions/vec_assertions.sv` -
  compiled with Verilator (`--assert`) bound into the real core and the real
  coprocessor, run through every directed/trap program and the full T1-T12
  coprocessor scenario suite: **zero assertion failures**. I then injected
  two deliberate RTL bugs (illegal instructions leaking a register write;
  an illegal vector command entering BUSY) and confirmed the relevant
  assertion fires immediately and correctly on each. (One caveat found in
  the process: `a_x0_never_rd_with_write` only re-checks `rd_addr` derivation
  inside `rv32i_core`, not the register file's internal write array, so it
  would not catch an `x0`-writable bug in `register_file` itself - that class
  of bug is instead caught by `tb/rv32i_tb.sv`'s lockstep scoreboard, which
  already covers it.)

**Please compile `uvm/run_uvm_modelsim.do` in ModelSim and paste back
whatever `vlog` reports.** Given how many small ModelSim-specific fixes the
rest of this project needed (`always_ff` with two drivers, struct-typed
ports across compilation units, `$readmemh` paths), I expect the UVM files
will need at least a few similarly small corrections on first compile - that
is completely normal for code that size going into a tool for the first
time. We'll fix them the same way we fixed everything else.

## Running

```tcl
cd uvm_2
do uvm/run_uvm_modelsim.do
```
compiles everything with `-cover bcestf`, then runs `vec_cov_test` (the
coprocessor's full closure suite), `core_base_test` once per program in
`hex/manifest.txt`, and `soc_base_test` - saving a `.ucdb` per run and
merging them into `uvm/coverage/merged_uvm.ucdb` /
`uvm/coverage/overall_uvm_coverage.txt` at the end (code coverage). Each
package's `report_phase` also prints its own functional-coverage percentage
straight to the transcript - grep for `_COV` (`CORE_COV`, `VEC_COV`) to see
`cg_insn` / `cg_cmd` / `cg_recover` together in one place.

Individual tests, if you want to run just one:
```tcl
vsim -c work.vec_coproc_uvm_tb    +UVM_TESTNAME=vec_cov_test          +N_CMDS=400 -do "run -all; quit"
vsim -c work.vec_coproc_uvm_tb    +UVM_TESTNAME=vec_smoke_test        -do "run -all; quit"
vsim -c work.vec_coproc_uvm_tb    +UVM_TESTNAME=vec_random_test       +N_CMDS=400 -do "run -all; quit"
vsim -c work.vec_coproc_uvm_tb    +UVM_TESTNAME=vec_sweep_test        -do "run -all; quit"
vsim -c work.vec_coproc_uvm_tb    +UVM_TESTNAME=vec_negative_test     -do "run -all; quit"
vsim -c work.vec_coproc_uvm_tb    +UVM_TESTNAME=vec_reset_mid_op_test -do "run -all; quit"
vsim -c work.rv32i_core_uvm_tb    +UVM_TESTNAME=core_base_test        +HEX=hex/t_ctrl.hex -do "run -all; quit"
vsim -c work.riscv_soc_uvm_tb     +UVM_TESTNAME=soc_base_test         +HEX=soc/ins_little_endian.hex -do "run -all; quit"
```
Any `hex/*.hex` program works with `core_base_test`/`soc_base_test`.
`+MAXCYC=<n>` sets the timeout; `+DHEX=<file>` preloads data memory for both
the DUT and the reference model, same as `tb/rv32i_tb.sv`.

The `uvm/run_uvm_modelsim.do` file also shows the two ways to bring in a real
UVM library (ModelSim's built-in `-uvm` switch, or compiling a UVM-1.2
source tree yourself) - use whichever matches your installation.

## A note on "near 100%" coverage

This project's functional coverage is built so that **every declared bin is
reachable** (illegal opcodes/VLs, corner operands, aliasing, branch
direction, ERR-recovery, reset-mid-op) and the sequences above are
specifically designed to hit every one of them: `vec_corner_sweep_seq` hits
every `{op, vl}` cell exhaustively rather than hoping randomization gets
there, and `ignore_bins` remove the cross cells that are architecturally
impossible (e.g. LUI has no funct3 field) so they don't cap the percentage
for reasons unrelated to test quality. That said, an actual coverage number
can only come from running these files through Questa/ModelSim - this
container cannot compile or simulate SystemVerilog UVM (no EDA tool, no
network access to install one; see the caveat above and in each package's
header comment). After `do uvm/run_uvm_modelsim.do`, paste back
`uvm/coverage/overall_uvm_coverage.txt` and the `_COV` lines from the
transcript and any remaining gaps can be closed with one more targeted
sequence or `.S` program, the same iterative way the rest of this project's
verification was built.
