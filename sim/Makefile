# cocotb + Verilator simulation for one HBM4 pseudo-channel slice.
#
# Runs at REDUCED geometry (-DFV_SMALL), the same configuration the formal
# proofs use, so a failure here and a failure there refer to the same design.
# See formal/SCALING.md for why the reduced geometry is shaped as it is.

SIM      ?= verilator
TOPLEVEL_LANG ?= verilog
TOPLEVEL ?= tb_pc_slice
MODULE   ?= test_slice

RTL := $(PWD)/../rtl
VERILOG_SOURCES := \
  $(RTL)/pkg/hbm4_pkg.sv $(RTL)/pkg/hbm4_timing_pkg.sv \
  $(wildcard $(RTL)/fabric/*.sv) $(wildcard $(RTL)/fe/*.sv) \
  $(wildcard $(RTL)/core/*.sv)  $(wildcard $(RTL)/dfi/*.sv) \
  $(wildcard $(RTL)/ras/*.sv)   $(wildcard $(RTL)/global/*.sv) \
  $(wildcard $(RTL)/slice/*.sv) \
  $(PWD)/tb_pc_slice.sv $(PWD)/tb_stack_top.sv $(PWD)/tb_sys_top.sv

# Per-toplevel build directory.  Sharing one directory between tb_pc_slice and
# tb_stack_top means the second run reuses the first ones compiled model and
# fails with "cannot find root handle" -- or worse, silently simulates the
# wrong top.
# GEOM=small (default) matches the formal proofs.  GEOM=full builds production
# geometry, which the efficiency measurement REQUIRES: TQ_DEPTH is 4 under
# FV_SMALL, so at most four transactions are ever in flight and the column bus
# cannot be saturated no matter how good the scheduler is.  Measuring efficiency
# there measures the testbench's credit limit, not the design.
GEOM ?= small
ifeq ($(GEOM),small)
  GEOM_DEF := -DFV_SMALL
else
  GEOM_DEF :=
endif
SIM_BUILD := sim_build_$(TOPLEVEL)_$(GEOM)

EXTRA_ARGS += --trace --trace-structs $(GEOM_DEF) -Wno-fatal

# Strict lint gate, run before simulating.
#
# EXTRA_ARGS carries -Wno-fatal because the cocotb/Verilator wrapper emits
# warnings that are not ours. The cost is that OUR mistakes stop being fatal too:
# a testbench that forgets a port compiles anyway, Verilator ties the input low,
# and the test passes while exercising a signal that is stuck at zero. That is
# how the missing req_data connections in tb_stack_top and tb_sys_top slid
# through -- the same silent-omission class as the unconnected modules and the
# unconnected DFI payloads before them.
#
# So lint the design and the testbench SEPARATELY, at -Wall, with warnings fatal.
.PHONY: lint
lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME $(GEOM_DEF) \
	  $(VERILOG_SOURCES) --top-module $(TOPLEVEL)

# The gate has to be wired, not just written. `lint` is the first target in
# this file, so until Rev 1.4 it was make's DEFAULT GOAL: a bare `make` linted
# and ran no tests at all, while every instruction in README.md said `make` --
# a run that reports success having tested nothing. Pin the goal to cocotb's
# `all` (which is `sim`), and hang the lint gate off `sim` so it cannot be
# skipped by accident.
.DEFAULT_GOAL := all
sim: lint

include $(shell cocotb-config --makefiles)/Makefile.sim
