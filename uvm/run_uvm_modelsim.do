# UVM regression + coverage for ModelSim/Questa. Needs a real UVM-1.2 library
# on the search path - either compiled from source (set UVM_HOME to its src/
# dir below) or via your ModelSim's built-in -uvm switch (see the two vlog
# variants below; comment out whichever you don't use).
#
#   cd uvm_2 ; do uvm/run_uvm_modelsim.do
#
# This container has no QuestaSim/ModelSim and no network access to get one,
# so this script has not been run here - the vlog/vsim commands below are the
# standard recipe, but your installation's exact UVM path may differ. Please
# paste back whatever vlog reports on the first attempt and I'll fix it, same
# as every other file in this project so far.
#
# Runs, in order: the vector coprocessor's directed / exhaustive-sweep /
# negative-access / weighted-random / mid-op-reset suite (vec_cov_test, one
# vsim invocation covers all of it), the RV32I core lockstep scoreboard
# against EVERY program in hex/manifest.txt, and the full SoC test. RTL is
# compiled with -cover so `coverage save` at the end of each run captures
# code coverage; the UVM covergroups (cg_insn/cg_cmd/cg_recover) report their
# own functional-coverage percentage straight to the transcript via
# `uvm_info` in each package's report_phase - grep the transcript for
# "_COV" to see all of them together.
#
# Output: uvm/coverage/*.ucdb (one per run), uvm/coverage/merged_uvm.ucdb
# (everything merged) and uvm/coverage/overall_uvm_coverage.txt (the report).

quit -sim
if {[file exists work]} { vdel -lib work -all }
vlib work
file mkdir uvm/coverage

# ---- option A: ModelSim/Questa ships UVM and understands -uvm directly
# vlog -mfcu -uvm -sv -cover bcestf +incdir+rtl +incdir+uvm/vec +incdir+uvm/core rtl/rvfi_pkg.sv rtl/*.sv \
#      uvm/vec/vec_if.sv uvm/vec/vec_pkg.sv uvm/vec/vec_coproc_uvm_tb.sv \
#      uvm/core/rvfi_if.sv uvm/core/core_pkg.sv uvm/core/rv32i_core_uvm_tb.sv \
#      uvm/soc/soc_pkg.sv uvm/soc/riscv_soc_uvm_tb.sv

# ---- option B: compile a real UVM-1.2 source tree yourself and point at it
# set UVM_HOME /path/to/uvm-1.2/src
# vlog -sv +incdir+$UVM_HOME $UVM_HOME/uvm_pkg.sv
#
# rtl/rvfi_pkg.sv MUST be compiled before uvm/core/core_pkg.sv (which imports
# it) - listed first below for that reason. Two separate reasons the file
# list looks the way it does:
#   1) core_pkg.sv is a *package*. Modules/interfaces automatically see
#      $unit-scope declarations (so rv32i_core_modules.sv and rvfi_if.sv see
#      rvfi_t fine just from `include "rv32i_types.svh"), but a package does
#      NOT get that automatically - it only sees its own declarations plus
#      whatever it explicitly imports. rtl/rvfi_pkg.sv exists purely to give
#      core_pkg.sv something to `import rvfi_pkg::*;` for (see its header
#      comment for why this is safe: identical packed-struct layouts are
#      equivalent types per the LRM regardless of declaring scope).
#   2) rv32i_types.svh/vec_defs.svh are `include headers (not packages) with
#      an `ifndef guard, and Questa's default is a SEPARATE compilation unit
#      per file - without -mfcu, only the first file in this list to
#      `include such a header actually gets its content (the guard macro
#      persists across the whole file list even though per-file $unit scopes
#      don't share declarations without -mfcu).
vlog -mfcu -sv -cover bcestf +incdir+rtl +incdir+uvm/vec +incdir+uvm/core rtl/rvfi_pkg.sv rtl/*.sv \
     uvm/vec/vec_if.sv uvm/vec/vec_pkg.sv uvm/vec/vec_coproc_uvm_tb.sv \
     uvm/core/rvfi_if.sv uvm/core/core_pkg.sv uvm/core/rv32i_core_uvm_tb.sv \
     uvm/soc/soc_pkg.sv uvm/soc/riscv_soc_uvm_tb.sv

set ucdbs {}

echo "=========== vector coprocessor: full closure suite (directed + sweep + negative + random + reset) ==========="
vsim -onfinish stop -c -coverage work.vec_coproc_uvm_tb +UVM_TESTNAME=vec_cov_test +N_CMDS=800
do scripts/coverage_exclusions.do
run -all
coverage save uvm/coverage/vec_cov_test.ucdb
quit -sim
lappend ucdbs uvm/coverage/vec_cov_test.ucdb

echo "=========== RV32I core: UVM lockstep scoreboard, every hex/*.hex program ==========="
set fd [open hex/manifest.txt r]
set lines [split [read $fd] "\n"]
close $fd
foreach line $lines {
    if {$line eq ""} continue
    lassign $line name cause
    vsim -onfinish stop -c -coverage work.rv32i_core_uvm_tb +UVM_TESTNAME=core_base_test +HEX=hex/$name.hex
    do scripts/coverage_exclusions.do
    run -all
    coverage save uvm/coverage/core_$name.ucdb
    quit -sim
    lappend ucdbs uvm/coverage/core_$name.ucdb
}

echo "=========== full SoC: UVM lockstep + coprocessor bus checking ==========="
vsim -onfinish stop -c -coverage work.riscv_soc_uvm_tb +UVM_TESTNAME=soc_base_test +HEX=soc/ins_little_endian.hex
do scripts/coverage_exclusions.do
run -all
coverage save uvm/coverage/soc_base_test.ucdb
quit -sim
lappend ucdbs uvm/coverage/soc_base_test.ucdb

# ---- merge every UVM run into one code-coverage database, then report on it
eval vcover merge uvm/coverage/merged_uvm.ucdb $ucdbs
vcover report uvm/coverage/merged_uvm.ucdb -details -output uvm/coverage/overall_uvm_coverage.txt
vcover report uvm/coverage/merged_uvm.ucdb -summary
echo "==== merged [llength $ucdbs] UVM runs -> uvm/coverage/merged_uvm.ucdb ===="
echo "==== full code-coverage report: uvm/coverage/overall_uvm_coverage.txt ===="
echo "==== functional coverage (cg_insn / cg_cmd / cg_recover %): grep the transcript above for _COV ===="
echo "==== check the transcript for TEST PASSED / TEST FAILED and any UVM_ERROR ===="
