# Tier 1b -- PyUVM-on-Cocotb cross-check (closure-plan items 13-14).
# Runs the PyUVM (UVM 1.2 in Python) env against the RTL via cocotb on an open-source
# simulator, so unlike the VCS/UVM tier this actually executes in OSS CI.
#
#   make                     # default: datapath cross-check (item 13), SIM=verilator
#   make MODULE=test_ctrl_plane   # control-plane cross-check (item 14)
#   make MODULE=test_msgbus       # message-bus cross-check (item 14)
#   make SIM=icarus ...           # alternate simulator
#   make all_tests                # run all three sequentially
#
# Requires: cocotb + pyuvm (+ cocotb-coverage) -- see requirements.txt -- and verilator or
# iverilog on PATH.

SIM           ?= verilator
TOPLEVEL_LANG ?= verilog
MODULE        ?= test_datapath

ROOT := $(shell cd ../.. && pwd)
SRC  := $(ROOT)/src
HDL  := $(ROOT)/test/cocotb/hdl

# Per-test DUT sources + top. Each test drives a thin wrapper over the relevant RTL.
TB := $(ROOT)/test
ifeq ($(MODULE),test_ctrl_plane)
    VERILOG_SOURCES = $(SRC)/pipe7_pkg.sv $(SRC)/pipe7_mac_ctrl_fsm.sv $(HDL)/pipe7_ctrl_top.sv
    TOPLEVEL = pipe7_ctrl_top
else ifeq ($(MODULE),test_msgbus)
    VERILOG_SOURCES = $(SRC)/pipe7_pkg.sv $(SRC)/pipe7_msgbus_master.sv $(SRC)/pipe7_regfile.sv $(HDL)/pipe7_msgbus_top.sv
    TOPLEVEL = pipe7_msgbus_top
else ifeq ($(MODULE),test_bridge)
    VERILOG_SOURCES = $(SRC)/pipe7_pkg.sv $(SRC)/pipe7_mac_ctrl_fsm.sv $(SRC)/pipe7_msgbus_master.sv \
        $(SRC)/pipe7_regfile.sv $(SRC)/pipe7_rdi_ingress.sv $(SRC)/pipe7_cdc_elastic_buf.sv \
        $(SRC)/pipe7_tx_framer_gb.sv $(SRC)/pipe7_rx_deframer_gb.sv $(SRC)/pipe7_gen6_datapath.sv \
        $(SRC)/pipe7_mac_datapath_ra.sv $(SRC)/pipe7_rx_burst_fifo.sv \
        $(SRC)/pipe7_rdi_egress.sv $(SRC)/ucie_rdi_to_pipe7_mac_bridge.sv \
        $(TB)/pipe7_phy_responder_stub.sv $(TB)/pipe7_msgbus_responder_stub.sv \
        $(HDL)/pipe7_bridge_top.sv
    TOPLEVEL = pipe7_bridge_top
else ifeq ($(MODULE),test_fcov)
    # Phase G functional-coverage driver -- same integrated bridge DUT as test_bridge.
    VERILOG_SOURCES = $(SRC)/pipe7_pkg.sv $(SRC)/pipe7_mac_ctrl_fsm.sv $(SRC)/pipe7_msgbus_master.sv \
        $(SRC)/pipe7_regfile.sv $(SRC)/pipe7_rdi_ingress.sv $(SRC)/pipe7_cdc_elastic_buf.sv \
        $(SRC)/pipe7_tx_framer_gb.sv $(SRC)/pipe7_rx_deframer_gb.sv $(SRC)/pipe7_gen6_datapath.sv \
        $(SRC)/pipe7_mac_datapath_ra.sv $(SRC)/pipe7_rx_burst_fifo.sv \
        $(SRC)/pipe7_rdi_egress.sv $(SRC)/ucie_rdi_to_pipe7_mac_bridge.sv \
        $(TB)/pipe7_phy_responder_stub.sv $(TB)/pipe7_msgbus_responder_stub.sv \
        $(HDL)/pipe7_bridge_top.sv
    TOPLEVEL = pipe7_bridge_top
else ifeq ($(MODULE),test_gen6_rx)
    VERILOG_SOURCES = $(SRC)/pipe7_pkg.sv $(SRC)/pipe7_tx_framer_gb.sv $(SRC)/pipe7_rx_deframer_gb.sv \
        $(SRC)/pipe7_gen6_datapath.sv $(SRC)/pipe7_mac_datapath_ra.sv $(HDL)/pipe7_gen6_rx_top.sv
    TOPLEVEL = pipe7_gen6_rx_top
else
    VERILOG_SOURCES = $(SRC)/pipe7_pkg.sv $(SRC)/pipe7_tx_framer.sv $(SRC)/pipe7_rx_deframer.sv $(HDL)/pipe7_framing_top.sv
    TOPLEVEL = pipe7_framing_top
endif

# Make our Python packages (models/, agents/, seq_lib/) importable by the test module.
export PYTHONPATH := $(ROOT)/test/cocotb:$(PYTHONPATH)
# Phase G: where test_fcov writes its functional-coverage report (must reach the sim subprocess).
export FCOV_OUT

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-UNUSEDPARAM -Wno-fatal
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

.DEFAULT_GOAL := sim

# Each test drives a different TOPLEVEL, so sim_build must be cleaned between them.
.PHONY: datapath ctrl_plane msgbus bridge gen6_rx fcov all_tests
datapath:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_datapath
ctrl_plane:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_ctrl_plane
msgbus:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_msgbus
bridge:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_bridge
gen6_rx:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_gen6_rx
fcov:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_fcov
all_tests:
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_datapath
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_ctrl_plane
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_msgbus
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_bridge
	rm -rf sim_build results.xml && $(MAKE) MODULE=test_gen6_rx
