# Tier 1b -- PyUVM-on-Cocotb cross-check (closure-plan items 13-14).
# Runs the PyUVM (UVM 1.2 in Python) env against the RTL via cocotb on an open-source
# simulator, so unlike the VCS/UVM tier this actually executes in OSS CI.
#
#   make            # default: datapath cross-check (item 13), SIM=verilator
#   make SIM=icarus # alternate simulator
#   make datapath   # item 13: Gen5 128b/130b framing round-trip vs independent Python model
#
# Requires: cocotb + pyuvm (see requirements.txt), and verilator or iverilog on PATH.

SIM           ?= verilator
TOPLEVEL_LANG ?= verilog

ROOT := $(shell cd ../.. && pwd)
SRC  := $(ROOT)/src
HDL  := $(ROOT)/test/cocotb/hdl

# Shared RTL + the cocotb DUT wrapper.
VERILOG_SOURCES  = $(SRC)/pipe7_pkg.sv
VERILOG_SOURCES += $(SRC)/pipe7_tx_framer.sv
VERILOG_SOURCES += $(SRC)/pipe7_rx_deframer.sv
VERILOG_SOURCES += $(HDL)/pipe7_framing_top.sv

TOPLEVEL = pipe7_framing_top
MODULE  ?= test_datapath

# Make our Python packages (models/, agents/, seq_lib/) importable by the test module.
export PYTHONPATH := $(ROOT)/test/cocotb:$(PYTHONPATH)

# Verilator: our RTL is -Wall clean except the pkg's BUFFER_DEPTH (used by other modules);
# keep warnings non-fatal for the cocotb build and enable SystemVerilog assertions off.
ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-structs -Wno-UNUSEDPARAM -Wno-fatal
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# cocotb's `sim` target runs the MODULE test. Default to the datapath cross-check; override
# MODULE on the command line (e.g. `make MODULE=test_flow`) or use the alias below.
.DEFAULT_GOAL := sim

.PHONY: datapath
datapath: sim
