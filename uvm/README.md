# UVM Environment: RV32I Core + Vector Coprocessor SoC

Three UVM-1.2 environments (QuestaSim/ModelSim), plus bound SVA assertions.

| Environment | DUT | Top | Tests |
|---|---|---|---|
| Coprocessor | `vec_coproc` | `vec_coproc_uvm_tb` | `vec_smoke_test`, `vec_random_test`, `vec_sweep_test`, `vec_negative_test`, `vec_reset_mid_op_test`, `vec_cov_test` (all-in-one) |
| Core (passive) | `sgle_cyc_processor` | `rv32i_core_uvm_tb` | `core_base_test` (one run per `hex/*.hex`) |
| Full SoC | `riscv_soc_top` | `riscv_soc_uvm_tb` | `soc_base_test` |

- **Coprocessor:** active agent (sequencer, driver, monitor), event-driven scoreboard, and coverage (`cg_cmd`, `cg_recover`). Random stimulus uses `vec_cmd_txn::randomize()` with `dist` and implication constraints.
- **Core:** passive monitor on the `rvfi` port plus a reference-model scoreboard. The program in instruction memory (`+HEX=`) is the stimulus.
- **SoC:** reuses both environments, with the coprocessor agent in passive mode tapping the internal bus.

## Run the full UVM regression

From the repository root in the QuestaSim console:

```tcl
cd <path/to/repo>
do uvm/run_uvm_modelsim.do
```

This compiles with coverage, runs `vec_cov_test`, `core_base_test` for every program in `hex/manifest.txt`, and `soc_base_test`. It then merges the results into `uvm/coverage/merged_uvm.ucdb` and `uvm/coverage/overall_uvm_coverage.txt`. Functional coverage prints in the transcript; search for `CORE_COV` and `VEC_COV`.

The script shows two ways to get the UVM library: the built-in `-uvm` switch, or compiling your own UVM-1.2 source tree. Use whichever matches your install.

## Run a single test

```tcl
vsim -c work.vec_coproc_uvm_tb +UVM_TESTNAME=vec_cov_test +N_CMDS=400 -do "run -all; quit"
vsim -c work.rv32i_core_uvm_tb +UVM_TESTNAME=core_base_test +HEX=hex/t_ctrl.hex -do "run -all; quit"
vsim -c work.riscv_soc_uvm_tb  +UVM_TESTNAME=soc_base_test  +HEX=soc/ins_little_endian.hex -do "run -all; quit"
```

Optional plusargs: `+N_CMDS=<n>` (random sequence length), `+MAXCYC=<n>` (timeout), `+DHEX=<file>` (preload data memory).

## Assertions

`uvm/assertions/core_assertions.sv` and `uvm/assertions/vec_assertions.sv` are plain SVA with no UVM dependency. They are `bind`-inserted into `rv32i_core` and `vec_coproc`, so they check automatically in any test once compiled with the RTL:

```tcl
vlog -sv +incdir+rtl rtl/*.sv tb/*.sv uvm/assertions/*.sv
vsim -c work.rv32i_tb +HEX=hex/t_ctrl.hex -do "run -all; quit"
vsim -c work.vec_coproc_tb -do "run -all; quit"
```

A violation prints an assertion error with the failing assertion name and time. No assertion messages means all assertions held. In the GUI, view them with `add wave -r /*` and the Assertions window.

The assertions also run in every UVM test above.
