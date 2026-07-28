# Root Makefile — ucie_rdi_to_pcie6_pipe7
# UCIe 1.0 RDI <-> PCIe 6.x / PIPE 7.1 MAC-facing bridge IP (Gen5 + Gen6).
# `make` (no target) prints the grouped target list below. Verilator is the OSS gate;
# the PyUVM-on-Cocotb tier (`make cocotb`) and the VCS/UVM tier (`make uvm`) sit above it.

.PHONY: all check ci clean cocotb cocotb_icarus coverage coverage_merge coverage_summary docs_check docs_pdf formal report report_check \
        gtkwave help lint nl1 quick regress regress_all regress_cov regress_nl1 repo_status \
        sim simv smoke test uvm uvm_compile uvm_pdf uvm_run verilator verilator_assn \
        verilator_cov verilator_ctrl verilator_debug verilator_framing verilator_framing_gb verilator_deframer_ovf verilator_deframer_gb_ovf verilator_timeout verilator_burst verilator_bridge_w160 verilator_bridge_cov verilator_rate_dp verilator_rdi verilator_cdc verilator_gen6 verilator_integ \
        verilator_msgbus verilator_nl1 vivado wave waves xsim questa

VERILATOR ?= $(shell command -v verilator_bin 2>/dev/null || command -v verilator 2>/dev/null)
VERILATOR_ROOT := $(shell if [ -n "$(VERILATOR)" ]; then realpath "$$(dirname "$(VERILATOR)")/../share/verilator"; fi)
VERILATOR_INC := $(VERILATOR_ROOT)/include
VERILATOR_CPP_CORE = $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_vcd_c.cpp \
	$(VERILATOR_INC)/verilated_threads.cpp

# ---- Integrated bridge (item 20): full composition presenting the real PIPE MAC signal set ----
BRIDGE_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_msgbus_master.sv \
             src/pipe7_regfile.sv src/pipe7_rdi_ingress.sv src/pipe7_cdc_elastic_buf.sv \
             src/pipe7_tx_framer_gb.sv src/pipe7_rx_deframer_gb.sv src/pipe7_gen6_datapath.sv \
             src/pipe7_mac_datapath_ra.sv src/pipe7_rx_burst_fifo.sv \
             src/pipe7_rdi_egress.sv src/ucie_rdi_to_pipe7_mac_bridge.sv
VERILOG_RTL = $(BRIDGE_RTL)
BRIDGE_STUBS = test/pipe7_phy_responder_stub.sv test/pipe7_msgbus_responder_stub.sv
# Item 36: passive perf monitor bound into the bridge (emits a [PERF] line). DV-only.
PERF_FILES = test/pipe7_perf_monitor.sv test/pipe7_perf_bind.sv
VERILOG_FILES = $(BRIDGE_RTL) $(BRIDGE_STUBS) $(PERF_FILES) test/pipe7_mac_bridge_assertions.sv test/tb_pipe7_mac_bridge.sv
TOP_MODULE = tb_pipe7_mac_bridge
TOP_SIMV = sim_top
VERILOG_SIMV = test/sim_top.sv $(VERILOG_RTL)
VERILATOR_DIR = obj_dir
COV_DIR = obj_dir_cov
NL1_TOP = tb_pipe7_mac_bridge_nl1
NL1_DIR = obj_dir_nl1
NL1_FILES = $(BRIDGE_RTL) $(BRIDGE_STUBS) test/tb_pipe7_mac_bridge_nl1.sv
# Item 2: PIPE MAC interface contract (define-guarded elaboration wrapper for lint).
MAC_IF = test/uvm/pipe7_mac_if.sv
# Item 3: PowerDown/Rate/Width control FSM (PhyStatus-gated) + responder stub.
CTRL_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv
CTRL_FILES = $(CTRL_RTL) test/pipe7_phy_responder_stub.sv test/tb_pipe7_ctrl_fsm.sv
CTRL_TOP = tb_pipe7_ctrl_fsm
CTRL_DIR = obj_dir_ctrl
# Item 4: message-bus master + MAC-side regfile + PHY responder stub.
MSGBUS_RTL = src/pipe7_pkg.sv src/pipe7_msgbus_master.sv src/pipe7_regfile.sv
MSGBUS_FILES = $(MSGBUS_RTL) test/pipe7_msgbus_responder_stub.sv test/tb_pipe7_msgbus.sv
MSGBUS_TOP = tb_pipe7_msgbus
MSGBUS_DIR = obj_dir_msgbus
# Item 5: Gen5 128b/130b TX framer + RX deframer (MAC-owned) loopback.
FRAMING_RTL = src/pipe7_pkg.sv src/pipe7_tx_framer.sv src/pipe7_rx_deframer.sv
FRAMING_FILES = $(FRAMING_RTL) test/tb_pipe7_framing.sv
FRAMING_TOP = tb_pipe7_framing
FRAMING_DIR = obj_dir_framing
# Item 16: full-width gearbox framer/deframer (up to 2 blocks/PCLK) for the full width set.
FRAMING_GB_RTL = src/pipe7_pkg.sv src/pipe7_tx_framer_gb.sv src/pipe7_rx_deframer_gb.sv
FRAMING_GB_FILES = $(FRAMING_GB_RTL) test/tb_pipe7_framing_gb.sv
FRAMING_GB_TOP = tb_pipe7_framing_gb
FRAMING_GB_DIR = obj_dir_framing_gb
# Item 27: RX deframer accumulator overflow guard -- directed garbage + recovery.
DEFRAMER_OVF_RTL = src/pipe7_pkg.sv src/pipe7_rx_deframer.sv
DEFRAMER_OVF_FILES = $(DEFRAMER_OVF_RTL) test/tb_pipe7_deframer_ovf.sv
DEFRAMER_OVF_TOP = tb_pipe7_deframer_ovf
DEFRAMER_OVF_DIR = obj_dir_deframer_ovf
# Item 41: gearbox RX deframer garbage/recovery (flush + slip paths).
DEFRAMER_GB_OVF_RTL = src/pipe7_pkg.sv src/pipe7_rx_deframer_gb.sv
DEFRAMER_GB_OVF_FILES = $(DEFRAMER_GB_OVF_RTL) test/tb_pipe7_deframer_gb_ovf.sv
DEFRAMER_GB_OVF_TOP = tb_pipe7_deframer_gb_ovf
DEFRAMER_GB_OVF_DIR = obj_dir_deframer_gb_ovf
# Item 28: control/msgbus completion watchdogs -- hung-PHY timeout -> error + recovery.
TIMEOUT_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_msgbus_master.sv
TIMEOUT_FILES = $(TIMEOUT_RTL) test/tb_pipe7_timeout.sv
TIMEOUT_TOP = tb_pipe7_timeout
TIMEOUT_DIR = obj_dir_timeout
# Item 29: RX burst-absorption skid FIFO unit test.
BURST_RTL = src/pipe7_rx_burst_fifo.sv
BURST_FILES = $(BURST_RTL) test/tb_pipe7_rx_burst_fifo.sv
BURST_TOP = tb_pipe7_rx_burst_fifo
BURST_DIR = obj_dir_burst
# Item 29: integrated bridge at PIPE_WIDTH=160 (gearbox + burst-FIFO fold).
W160_FILES = $(BRIDGE_RTL) $(BRIDGE_STUBS) $(PERF_FILES) test/tb_pipe7_mac_bridge_w160.sv
W160_TOP = tb_pipe7_mac_bridge_w160
W160_DIR = obj_dir_w160
# Item 42: bridge error-path coverage (sync_error on misaligned RX, rx_overflow on sink stall).
BRIDGE_COV_FILES = $(BRIDGE_RTL) $(BRIDGE_STUBS) test/tb_pipe7_mac_bridge_cov.sv
BRIDGE_COV_TOP = tb_pipe7_mac_bridge_cov
BRIDGE_COV_DIR = obj_dir_bridge_cov
# Item 6: Gen6 (Rate=5) wide raw datapath + PAM4, composed with the ctrl FSM.
GEN6_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_gen6_datapath.sv
GEN6_FILES = $(GEN6_RTL) test/pipe7_phy_responder_stub.sv test/tb_pipe7_gen6.sv
GEN6_TOP = tb_pipe7_gen6
GEN6_DIR = obj_dir_gen6
# Item 17: rate-aware MAC datapath (Gen5 gearbox / Gen6 raw mux) + TxElecIdle gating, assertions bound.
RATE_DP_RTL = src/pipe7_pkg.sv src/pipe7_tx_framer_gb.sv src/pipe7_rx_deframer_gb.sv src/pipe7_gen6_datapath.sv src/pipe7_mac_datapath_ra.sv
RATE_DP_FILES = $(RATE_DP_RTL) test/pipe7_mac_bridge_assertions.sv test/tb_pipe7_rate_dp.sv
RATE_DP_TOP = tb_pipe7_rate_dp
RATE_DP_DIR = obj_dir_rate_dp
# Item 18: UCIe RDI ingress/egress + credit flow-control round-trip.
RDI_RTL = src/pipe7_pkg.sv src/pipe7_rdi_ingress.sv src/pipe7_rdi_egress.sv
RDI_FILES = $(RDI_RTL) test/tb_pipe7_rdi.sv
RDI_TOP = tb_pipe7_rdi
RDI_DIR = obj_dir_rdi
# Item 19: RDI<->PCLK CDC of the block-payload stream.
CDC_RTL = src/pipe7_pkg.sv src/pipe7_cdc_elastic_buf.sv
CDC_FILES = $(CDC_RTL) test/tb_pipe7_cdc.sv
CDC_TOP = tb_pipe7_cdc
CDC_DIR = obj_dir_cdc
# Item 7: PIPE MAC protocol assertions (SVA) against a good control+framing scenario.
ASSN_MOD = test/pipe7_mac_bridge_assertions.sv
ASSN_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_tx_framer.sv src/pipe7_rx_deframer.sv
ASSN_FILES = $(ASSN_RTL) $(ASSN_MOD) test/pipe7_phy_responder_stub.sv test/tb_pipe7_assertions.sv
ASSN_TOP = tb_pipe7_assertions
ASSN_DIR = obj_dir_assn
# Item 15: integrated TxElecIdle-gated datapath (framer/deframer) + control FSM + PHY responder,
# with the item-7 assertions bound. Self-clocking smoke via `verilator --binary --timing --assert`.
INTEG_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_tx_framer.sv src/pipe7_rx_deframer.sv src/pipe7_mac_datapath.sv
INTEG_FILES = $(INTEG_RTL) test/pipe7_mac_bridge_assertions.sv test/pipe7_phy_responder_stub.sv test/tb_pipe7_integ.sv
INTEG_TOP = tb_pipe7_integ
INTEG_DIR = obj_dir_integ
UVM_MAKE = $(MAKE) -C test/uvm -f Makefile.vcs

# ---- Waveform build (opt-in tracing of any self-clocking TB) ----
# Pick the TB with WAVE_TB; each maps to its existing file list / top and an optional
# per-TB extra arg. TBs dump when built with +define+ENABLE_WAVES (--trace); the VCD path
# is passed at run time via +wavefile so the Makefile owns the output location.
WAVE_TB   ?= framing
WAVE_DIR   = obj_dir_waves
WAVE_VCD   = waves/$(WAVE_TB).vcd
WAVE_GTKW  = waves/$(WAVE_TB).gtkw
WAVE_EXTRA =
ifeq ($(WAVE_TB),ctrl)
    WAVE_FILES = $(CTRL_FILES)
    WAVE_TOP   = $(CTRL_TOP)
else ifeq ($(WAVE_TB),msgbus)
    WAVE_FILES = $(MSGBUS_FILES)
    WAVE_TOP   = $(MSGBUS_TOP)
else ifeq ($(WAVE_TB),gen6)
    WAVE_FILES = $(GEN6_FILES)
    WAVE_TOP   = $(GEN6_TOP)
else ifeq ($(WAVE_TB),assn)
    WAVE_FILES = $(ASSN_FILES)
    WAVE_TOP   = $(ASSN_TOP)
    WAVE_EXTRA = --assert
else ifeq ($(WAVE_TB),integ)
    WAVE_FILES = $(INTEG_FILES)
    WAVE_TOP   = $(INTEG_TOP)
    WAVE_EXTRA = --assert
else
    WAVE_FILES = $(FRAMING_FILES)
    WAVE_TOP   = $(FRAMING_TOP)
endif

# Default target: print the grouped help (advanced-repo convention).
.DEFAULT_GOAL := help

# ============================ Help ============================
help:
	@echo "ucie_rdi_to_pcie6_pipe7 — make targets   (default: help)"
	@echo ""
	@echo "Build & regression:"
	@echo "  make regress           lint + all Verilator smokes (release gate; CI runs this)"
	@echo "  make ci                regress + coverage + NL1 + docs_check (full local run)"
	@echo "  make verilator         build+run the datapath smoke (alias: sim, smoke)"
	@echo "  make lint              Verilator -Wall lint of every RTL module + TB (alias: quick)"
	@echo ""
	@echo "Per-block smokes (self-clocking, --binary --timing):"
	@echo "  make verilator_ctrl    PowerDown/Rate/Width control FSM (PhyStatus-gated)"
	@echo "  make verilator_msgbus  M2P/P2M message-bus master + regfile"
	@echo "  make verilator_framing Gen5 128b/130b TX framer -> RX deframer round-trip"
	@echo "  make verilator_framing_gb  full-width gearbox (up to 2 blocks/PCLK; W160 + W80)"
	@echo "  make verilator_gen6    Gen6 (Rate=5) raw wide datapath + L0p + PAM4"
	@echo "  make verilator_assn    PIPE protocol SVA assertions (Verilator --assert)"
	@echo "  make verilator_rate_dp rate-aware datapath: Gen5 gearbox / Gen6 raw mux + EI gating"
	@echo "  make verilator_rdi     UCIe RDI ingress/egress + credit flow-control round-trip"
	@echo "  make verilator_cdc     RDI<->PCLK CDC of the block-payload stream (dual-clock)"
	@echo "  make verilator_integ   integrated EI-gated datapath + control + assertions bound"
	@echo ""
	@echo "Waveforms (GTKWave):"
	@echo "  make waves   [WAVE_TB=framing|ctrl|msgbus|gen6|assn|integ]"
	@echo "                         build+run the TB with --trace -> waves/<tb>.vcd"
	@echo "  make gtkwave [WAVE_TB=...]"
	@echo "                         waves, then open GTKWave with the waves/<tb>.gtkw layout"
	@echo "  make wave              open GTKWave on the datapath VCD (obj_dir/dump.vcd)"
	@echo ""
	@echo "Coverage & parameter smokes:"
	@echo "  make coverage          Verilator line coverage -> coverage.info (alias: regress_cov)"
	@echo "  make coverage_summary  print the per-file line-coverage table"
	@echo "  make nl1               NUM_LANES=1 parameter smoke (alias: regress_nl1)"
	@echo ""
	@echo "Cross-checks & UVM:"
	@echo "  make cocotb [COCOTB_SIM=verilator|icarus]"
	@echo "  make cocotb_icarus     # independent-engine cross-check (Icarus): bridge + gen6_rx"
	@echo "                         Tier 1b PyUVM-on-Cocotb cross-checks (datapath+ctrl+msgbus)"
	@echo "  make uvm               VCS/UVM compile+run (test/uvm; not in OSS CI)"
	@echo "  make uvm_compile | uvm_run | uvm_pdf"
	@echo ""
	@echo "Formal, docs, vendor sims, utility:"
	@echo "  make formal            SymbiYosys CDC/FSM proofs (verification/formal)"
	@echo "  make docs_check        required-docs + stale-claim gate"
	@echo "  make simv | questa | xsim | vivado    vendor simulator flows"
	@echo "  make repo_status       git status --short"
	@echo "  make clean             remove all build artifacts"
	@echo ""
	@echo "  Variables: WAVE_TB (waveform TB), COCOTB_SIM, VERILATOR"

# ============================ Workflow aliases ============================
all: verilator
quick: lint
check: regress
smoke: verilator
test: regress
nl1: regress_nl1
sim: verilator                 # DV_STANDARDS: sim = Verilator OSS sim
coverage: regress_cov          # alias for Verilator line coverage
regress_all: ci

# ============================ Gates ============================
# Release regression (lint + every Verilator smoke); CI runs this.
regress: lint verilator verilator_ctrl verilator_msgbus verilator_framing verilator_framing_gb verilator_deframer_ovf verilator_deframer_gb_ovf verilator_timeout verilator_burst verilator_bridge_w160 verilator_bridge_cov verilator_rate_dp verilator_rdi verilator_cdc verilator_gen6 verilator_assn verilator_integ

# Full local confidence run (heavier than CI's first gate).
ci: regress regress_cov regress_nl1 coverage_summary docs_check

regress_cov: lint verilator_cov
regress_nl1: lint verilator_nl1

# ============================ Verilator smokes ============================
verilator:
	@echo "========== Integrated bridge smoke (Verilator --binary --timing --assert) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(VERILATOR_DIR)
	$(VERILATOR) --binary --timing --assert -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(TOP_MODULE) --Mdir $(VERILATOR_DIR) -o bridge_sim $(VERILOG_FILES)
	@echo "Running integrated bridge smoke..."
	./$(VERILATOR_DIR)/bridge_sim

# Reduced-config parameter sanity (obj_dir_nl1/).
verilator_nl1:
	@echo "========== Integrated bridge reduced-config smoke =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(NL1_DIR)
	$(VERILATOR) --binary --timing -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(NL1_TOP) --Mdir $(NL1_DIR) -o nl1_sim $(NL1_FILES)
	@echo "Running reduced-config bridge smoke..."
	./$(NL1_DIR)/nl1_sim

# Item 3: control-plane smoke -- PhyStatus-gated PowerDown/Rate/Width FSM.
verilator_ctrl:
	@echo "========== Verilator control-plane smoke (PhyStatus-gated FSM) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(CTRL_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(CTRL_TOP) --Mdir $(CTRL_DIR) -o ctrl_sim $(CTRL_FILES)
	@echo "Running Verilator control-plane smoke..."
	./$(CTRL_DIR)/ctrl_sim

# Item 4: message-bus smoke -- M2P/P2M framing round-trip through master + regfile.
verilator_msgbus:
	@echo "========== Verilator message-bus smoke (M2P/P2M framing) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(MSGBUS_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(MSGBUS_TOP) --Mdir $(MSGBUS_DIR) -o msgbus_sim $(MSGBUS_FILES)
	@echo "Running Verilator message-bus smoke..."
	./$(MSGBUS_DIR)/msgbus_sim

# Item 5: Gen5 128b/130b framing smoke -- TX framer -> RX deframer loopback.
verilator_framing:
	@echo "========== Verilator framing smoke (Gen5 128b/130b round-trip) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(FRAMING_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(FRAMING_TOP) --Mdir $(FRAMING_DIR) -o framing_sim $(FRAMING_FILES)
	@echo "Running Verilator framing smoke..."
	./$(FRAMING_DIR)/framing_sim

# Item 42: bridge error-path coverage smoke (sync_error + rx_overflow).
verilator_bridge_cov:
	@echo "========== Verilator bridge error-path coverage smoke (item 42) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator"; exit 1; fi
	rm -rf $(BRIDGE_COV_DIR)
	$(VERILATOR) --binary --timing -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH --top-module $(BRIDGE_COV_TOP) --Mdir $(BRIDGE_COV_DIR) -o bcov_sim $(BRIDGE_COV_FILES)
	@echo "Running..."
	./$(BRIDGE_COV_DIR)/bcov_sim

# Item 29: integrated bridge at width 160 -- validates the gearbox + burst-FIFO fold end-to-end.
verilator_bridge_w160:
	@echo "========== Verilator integrated bridge @ PIPE_WIDTH=160 (item 29) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator"; exit 1; fi
	rm -rf $(W160_DIR)
	$(VERILATOR) --binary --timing --assert -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH --top-module $(W160_TOP) --Mdir $(W160_DIR) -o w160_sim $(W160_FILES)
	@echo "Running Verilator width-160 bridge smoke..."
	./$(W160_DIR)/w160_sim

# Item 29: RX burst-FIFO unit test -- 0/1/2-per-cycle push vs 1/cycle drain; order + overflow.
verilator_burst:
	@echo "========== Verilator RX burst-FIFO unit test (item 29) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator"; exit 1; fi
	rm -rf $(BURST_DIR)
	$(VERILATOR) --binary --timing -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH --top-module $(BURST_TOP) --Mdir $(BURST_DIR) -o burst_sim $(BURST_FILES)
	@echo "Running Verilator burst-FIFO unit test..."
	./$(BURST_DIR)/burst_sim

# Item 28: completion-watchdog smoke -- ctrl FSM + msgbus master time out on a hung PHY, report
# an error, and recover; the normal path still completes. --binary --timing; $fatal on fail.
verilator_timeout:
	@echo "========== Verilator completion-watchdog smoke (item 28) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(TIMEOUT_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(TIMEOUT_TOP) --Mdir $(TIMEOUT_DIR) -o timeout_sim $(TIMEOUT_FILES)
	@echo "Running Verilator completion-watchdog smoke..."
	./$(TIMEOUT_DIR)/timeout_sim

# Item 41: gearbox RX deframer garbage/recovery smoke (flush + slip).
verilator_deframer_gb_ovf:
	@echo "========== Verilator gearbox deframer overflow-guard smoke (item 41) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator"; exit 1; fi
	rm -rf $(DEFRAMER_GB_OVF_DIR)
	$(VERILATOR) --binary --timing -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH --top-module $(DEFRAMER_GB_OVF_TOP) --Mdir $(DEFRAMER_GB_OVF_DIR) -o dgb_sim $(DEFRAMER_GB_OVF_FILES)
	@echo "Running..."
	./$(DEFRAMER_GB_OVF_DIR)/dgb_sim

# Item 27: RX deframer overflow-guard smoke -- sustained garbage stays bounded (rfill <= RACC_W,
# no spurious payload), then an aligned stream re-locks and recovers. --binary --timing; $fatal.
verilator_deframer_ovf:
	@echo "========== Verilator deframer overflow-guard smoke (item 27) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(DEFRAMER_OVF_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(DEFRAMER_OVF_TOP) --Mdir $(DEFRAMER_OVF_DIR) -o deframer_ovf_sim $(DEFRAMER_OVF_FILES)
	@echo "Running Verilator deframer overflow-guard smoke..."
	./$(DEFRAMER_OVF_DIR)/deframer_ovf_sim

# Item 16: full-width gearbox framing smoke -- framer_gb -> deframer_gb at W160 (2 blocks/PCLK)
# and W80. Self-clocking TB via --binary --timing; $fatal on mismatch.
verilator_framing_gb:
	@echo "========== Verilator full-width gearbox framing smoke (W160 + W80) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(FRAMING_GB_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(FRAMING_GB_TOP) --Mdir $(FRAMING_GB_DIR) -o framing_gb_sim $(FRAMING_GB_FILES)
	@echo "Running Verilator gearbox framing smoke..."
	./$(FRAMING_GB_DIR)/framing_gb_sim

# Item 17: rate-aware datapath smoke -- Gen5 gearbox data + rate switch to Gen6 raw data, with
# the item-7 assertions bound (TxElecIdle gating across the switch). --assert; $fatal on fail.
verilator_rate_dp:
	@echo "========== Verilator rate-aware datapath smoke (Gen5 gearbox + Gen6 raw) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(RATE_DP_DIR)
	$(VERILATOR) --binary --timing --assert -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(RATE_DP_TOP) --Mdir $(RATE_DP_DIR) -o rate_dp_sim $(RATE_DP_FILES)
	@echo "Running Verilator rate-aware datapath smoke..."
	./$(RATE_DP_DIR)/rate_dp_sim

# Item 18: RDI ingress/egress + credit flow-control round-trip. Self-clocking; $fatal on fail.
verilator_rdi:
	@echo "========== Verilator RDI credit flow-control smoke =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(RDI_DIR)
	$(VERILATOR) --binary --timing -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(RDI_TOP) --Mdir $(RDI_DIR) -o rdi_sim $(RDI_FILES)
	@echo "Running Verilator RDI smoke..."
	./$(RDI_DIR)/rdi_sim

# Item 19: RDI<->PCLK CDC of the block-payload stream (dual-clock + backpressure round-trip).
verilator_cdc:
	@echo "========== Verilator RDI<->PCLK CDC smoke (block payload) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(CDC_DIR)
	$(VERILATOR) --binary --timing -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(CDC_TOP) --Mdir $(CDC_DIR) -o cdc_sim $(CDC_FILES)
	@echo "Running Verilator CDC smoke..."
	./$(CDC_DIR)/cdc_sim

# Item 6: Gen6 datapath smoke -- Gen6 rate + L0p width via ctrl FSM, then wide round-trip.
verilator_gen6:
	@echo "========== Verilator Gen6 smoke (Rate=5 raw wide datapath + PAM4) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(GEN6_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(GEN6_TOP) --Mdir $(GEN6_DIR) -o gen6_sim $(GEN6_FILES)
	@echo "Running Verilator Gen6 smoke..."
	./$(GEN6_DIR)/gen6_sim

# Item 7: protocol-assertion smoke -- SVA checker (--assert), $fatal on violation.
verilator_assn:
	@echo "========== Verilator protocol-assertion smoke (SVA) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(ASSN_DIR)
	$(VERILATOR) --binary --timing --assert -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(ASSN_TOP) --Mdir $(ASSN_DIR) -o assn_sim $(ASSN_FILES)
	@echo "Running Verilator protocol-assertion smoke..."
	./$(ASSN_DIR)/assn_sim

# Item 15: integration smoke -- TxElecIdle-gated datapath + control FSM + PHY responder, with
# the item-7 assertions bound (proves P1 holds with real EI gating). --assert; $fatal on fail.
verilator_integ:
	@echo "========== Verilator integration smoke (EI-gated datapath + assertions) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(INTEG_DIR)
	$(VERILATOR) --binary --timing --assert -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(INTEG_TOP) --Mdir $(INTEG_DIR) -o integ_sim $(INTEG_FILES)
	@echo "Running Verilator integration smoke..."
	./$(INTEG_DIR)/integ_sim

# Verilator with coverage: separate build dir so normal obj_dir stays unchanged.
verilator_cov:
	@echo "========== Integrated bridge coverage (Verilator --binary --coverage) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(COV_DIR)
	$(VERILATOR) --binary --timing --assert --coverage -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(TOP_MODULE) --Mdir $(COV_DIR) -o cov_sim $(VERILOG_FILES)
	@echo "Running integrated bridge (coverage)..."
	cd $(COV_DIR) && ./cov_sim
	@echo "Coverage raw data: $(COV_DIR)/coverage.dat"
	@if command -v verilator_coverage >/dev/null 2>&1; then \
		cd $(COV_DIR) && verilator_coverage --write-info ../coverage.info coverage.dat && \
		echo "Wrote coverage.info (Verilator: merge/report per manual)"; \
	else \
		echo "Tip: verilator_coverage --write-info coverage.info $(COV_DIR)/coverage.dat"; \
	fi

coverage_summary:
	@if [ ! -f coverage.info ]; then \
		echo "coverage.info not found; run 'make regress_cov' first"; \
		exit 1; \
	fi
	@# DUT line coverage: count src/ (the design) only -- testbenches, stubs, the perf monitor,
	@# and the assertion module are verification code, not the DUT, so they are excluded.
	@awk 'BEGIN{lines=0;hit=0} /^SF:/{inc=($$0 ~ /:src\//)} inc&&/^DA:/ {split($$0,a,":"); split(a[2],b,","); lines++; if (b[2] > 0) hit++} END{printf "DUT line coverage (src/): %d/%d = %.2f%%\n", hit, lines, (lines?100*hit/lines:0)}' coverage.info
	@awk 'function flush(){if(file != ""){printf "  %-55s %4d/%-4d %6.2f%%\n", file, hit, lines, (lines?100*hit/lines:0)}} /^SF:/ {flush(); inc=($$0 ~ /:src\//); file=(inc?substr($$0,4):""); lines=0; hit=0} inc&&/^DA:/ {split($$0,a,":"); split(a[2],b,","); lines++; if (b[2] > 0) hit++} END{flush()}' coverage.info

# Item 40: union DUT line coverage across the whole smoke suite (builds each with --coverage and
# merges the per-smoke coverage.dat files). Produces coverage.info -> use with coverage_summary.
coverage_merge:
	@if [ -z "$(VERILATOR)" ]; then echo "ERROR: install verilator"; exit 1; fi
	@bash scripts/coverage_merge.sh

# Item 37: aggregate perf + coverage + smoke + formal + cocotb into report/{metrics.json,
# report.md,report.html}. Sub-steps tolerate failure (-) so the report always generates and
# reflects the actual state; the [PERF] lines come from the bridge/w160 smokes in regress.
REPORT_DIR = report
report:
	@echo "========== Metrics report (item 37) =========="
	@mkdir -p $(REPORT_DIR)/logs
	-@$(MAKE) --no-print-directory regress          > $(REPORT_DIR)/logs/regress.log 2>&1
	-@$(MAKE) --no-print-directory coverage_merge      > $(REPORT_DIR)/logs/coverage.log 2>&1
	-@$(MAKE) --no-print-directory formal            > $(REPORT_DIR)/logs/formal.log 2>&1
	-@$(MAKE) --no-print-directory -C test/cocotb SIM=verilator all_tests > $(REPORT_DIR)/logs/cocotb.log 2>&1
	@python3 scripts/gen_report.py --root $(CURDIR) --out $(CURDIR)/$(REPORT_DIR)

# Item 38: perf/quality threshold gate over report/metrics.json. Advisory / opt-in -- run after
# `make report`; NOT part of the required `ci` gate (a sim timing wobble must not red the build).
report_check:
	@python3 scripts/gen_report.py --check scripts/report_thresholds.json --out $(CURDIR)/$(REPORT_DIR)

# Debug build of the integrated bridge smoke with waveform tracing (VCD at obj_dir/bridge.vcd).
verilator_debug:
	@echo "========== Integrated bridge smoke (Verilator debug + trace) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(VERILATOR_DIR)
	$(VERILATOR) --binary --timing --assert --trace -Isrc -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		+define+ENABLE_WAVES --top-module $(TOP_MODULE) --Mdir $(VERILATOR_DIR) -o bridge_dbg $(VERILOG_FILES)
	./$(VERILATOR_DIR)/bridge_dbg +wavefile=$(VERILATOR_DIR)/bridge.vcd
	@echo "VCD: $(VERILATOR_DIR)/bridge.vcd"

# ============================ Waveforms ============================
# waves: build the selected self-clocking TB with tracing (+define+ENABLE_WAVES arms the
# TB's $dumpvars) and run it, writing waves/<tb>.vcd. gtkwave then opens it with the saved
# waves/<tb>.gtkw signal layout. `wave` (singular) is the legacy datapath-smoke VCD viewer.
waves:
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	@mkdir -p waves
	rm -rf $(WAVE_DIR)
	$(VERILATOR) --binary --timing --trace $(WAVE_EXTRA) -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		+define+ENABLE_WAVES --top-module $(WAVE_TOP) --Mdir $(WAVE_DIR) -o wave_sim $(WAVE_FILES)
	@echo "Running $(WAVE_TOP) with tracing (WAVE_TB=$(WAVE_TB))..."
	./$(WAVE_DIR)/wave_sim +wavefile=$(WAVE_VCD)
	@echo "[WAVES] wrote $(WAVE_VCD)"

gtkwave: waves
	@if ! command -v gtkwave >/dev/null 2>&1; then \
		echo "[GTKWAVE] gtkwave not on PATH; VCD is at $(WAVE_VCD)"; exit 0; \
	fi; \
	if [ -f $(WAVE_GTKW) ]; then \
		echo "[GTKWAVE] opening $(WAVE_VCD) with layout $(WAVE_GTKW)"; \
		gtkwave $(WAVE_VCD) $(WAVE_GTKW) & \
	else \
		echo "[GTKWAVE] no saved layout $(WAVE_GTKW); opening $(WAVE_VCD)"; \
		gtkwave $(WAVE_VCD) & \
	fi

# Legacy: open GTKWave on the bridge debug VCD (make verilator_debug first).
wave:
	@echo "Opening GTKWave on $(VERILATOR_DIR)/dump.vcd..."
	gtkwave $(VERILATOR_DIR)/bridge.vcd &

# ============================ Lint ============================
lint:
	@if [ -z "$(VERILATOR)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	$(VERILATOR) --lint-only -Wall -Isrc --top-module ucie_rdi_to_pipe7_mac_bridge $(VERILOG_RTL)
	$(VERILATOR) --lint-only -Wall --assert -Isrc -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module $(TOP_MODULE) $(VERILOG_FILES)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module $(NL1_TOP) $(NL1_FILES)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-DECLFILENAME \
		+define+PIPE7_MAC_IF_LINT --top-module pipe7_mac_if_lint_top $(MAC_IF)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_ctrl_fsm $(CTRL_RTL)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_msgbus_master src/pipe7_pkg.sv src/pipe7_msgbus_master.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_regfile src/pipe7_pkg.sv src/pipe7_regfile.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_tx_framer src/pipe7_pkg.sv src/pipe7_tx_framer.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_rx_deframer src/pipe7_pkg.sv src/pipe7_rx_deframer.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_tx_framer_gb src/pipe7_pkg.sv src/pipe7_tx_framer_gb.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_rx_deframer_gb src/pipe7_pkg.sv src/pipe7_rx_deframer_gb.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_datapath_ra src/pipe7_pkg.sv src/pipe7_tx_framer_gb.sv src/pipe7_rx_deframer_gb.sv src/pipe7_gen6_datapath.sv src/pipe7_mac_datapath_ra.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_rdi_ingress src/pipe7_pkg.sv src/pipe7_rdi_ingress.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_rdi_egress src/pipe7_pkg.sv src/pipe7_rdi_egress.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_gen6_datapath src/pipe7_pkg.sv src/pipe7_gen6_datapath.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_datapath src/pipe7_pkg.sv src/pipe7_tx_framer.sv src/pipe7_rx_deframer.sv src/pipe7_mac_datapath.sv
	$(VERILATOR) --lint-only -Wall --assert -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_bridge_assertions src/pipe7_pkg.sv $(ASSN_MOD)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_dut $(BRIDGE_RTL) test/uvm/pipe7_mac_dut.sv

# ============================ Cross-checks & UVM ============================
# Tier 1b: PyUVM-on-Cocotb cross-check (closure-plan items 13-14). Runs the PyUVM env against
# the RTL via cocotb on an OSS simulator -- actually executes here (unlike the VCS/UVM tier).
COCOTB_SIM ?= verilator
cocotb:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[COCOTB] cocotb not found; pip install -r test/cocotb/requirements.txt to run Tier 1b"; \
		exit 0; \
	fi
	$(MAKE) -C test/cocotb SIM=$(COCOTB_SIM) all_tests

# Phase G (item 43): run the cocotb env on the INDEPENDENT Icarus Verilog engine as a redundant
# cross-check to the Verilator gate. The ICARUS_BIN_DIR shim points cocotb's embedded Python at the
# system cocotb interpreter (see scripts/gen_cocotb_icarus_bin.sh for why oss-cad-suite needs it).
ICARUS_BIN_DIR := $(CURDIR)/test/cocotb/.icarus_bin
cocotb_icarus:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[COCOTB] cocotb not found; pip install -r test/cocotb/requirements.txt to run Tier 1b"; \
		exit 0; \
	fi
	@bash scripts/gen_cocotb_icarus_bin.sh $(ICARUS_BIN_DIR)
	$(MAKE) -C test/cocotb SIM=icarus ICARUS_BIN_DIR=$(ICARUS_BIN_DIR) bridge
	$(MAKE) -C test/cocotb SIM=icarus ICARUS_BIN_DIR=$(ICARUS_BIN_DIR) gen6_rx
	@echo "[COCOTB ICARUS] bridge + gen6_rx PASS on Icarus Verilog (independent engine)"

uvm_compile:
	$(UVM_MAKE) compile

uvm_run:
	$(UVM_MAKE) run

uvm: uvm_compile uvm_run

uvm_pdf docs_pdf:
	$(UVM_MAKE) pdf

# ============================ Formal ============================
# SymbiYosys formal proofs in verification/formal/ (CDC buffer + credit FC + gearbox + data-phase).
formal:
	@if command -v sby >/dev/null 2>&1; then \
		$(MAKE) -C $(CURDIR)/verification/formal; \
	else \
		echo "[FORMAL] sby not found; install SymbiYosys (OSS CAD Suite) to run formal"; \
		echo "         Proofs: verification/formal/{fifo_cdc,credit_fc,gearbox,dataphase}_props.sv"; \
		exit 0; \
	fi

# ============================ Docs ============================
DOCS_FINAL = docs/architecture.md docs/uvm_verification.md docs/verification_plan.md
docs_check:
	@echo "========== Checking documentation links and stale claims =========="
	@test -f README.md
	@test -f docs/architecture.md
	@test -f docs/interface_spec.md
	@test -f docs/verification_plan.md
	@test -f docs/uvm_verification.md
	@! grep -R "| \*\*Line Coverage\*\* | 100%" README.md docs >/dev/null
	@! grep -R "mirrors the coverage of the original SystemVerilog testbench" README.md docs >/dev/null
	@# Item 12 sign-off: the finalized docs must describe THIS project, not the predecessor.
	@if grep -REn "ucie_rdi_pcie_pkg|pipe_rx_agent|pcie_pipe_if" $(DOCS_FINAL) >/dev/null; then \
		echo "docs_check: stale predecessor UVM reference in $(DOCS_FINAL)"; exit 1; fi
	@grep -q "pipe7_mac_pkg" docs/uvm_verification.md || { echo "docs_check: uvm_verification.md must describe pipe7_mac_pkg"; exit 1; }
	@grep -qi "coverage" docs/verification_plan.md || { echo "docs_check: verification_plan.md must record the coverage baseline"; exit 1; }
	@# Item 25 sign-off: the docs must describe the INTEGRATED IP + all-tier verification.
	@grep -q "651/662" docs/verification_plan.md || { echo "docs_check: verification_plan.md must record the DUT coverage baseline (651/662)"; exit 1; }
	@grep -q "## Performance / KPIs" docs/verification_plan.md || { echo "docs_check: verification_plan.md must have a Performance / KPIs section (item 39)"; exit 1; }
	@grep -q '```mermaid' docs/architecture.md || { echo "docs_check: architecture.md must include mermaid block diagrams (item 39)"; exit 1; }
	@grep -qi "integrated" docs/architecture.md || { echo "docs_check: architecture.md must describe the integrated bridge top"; exit 1; }
	@grep -qi "credit_fc\|gearbox\|dataphase" docs/verification_plan.md || { echo "docs_check: verification_plan.md must record the formal proofs"; exit 1; }
	@grep -q "pipe7_rdi_ingress\|pipe7_rdi_egress" docs/architecture.md || { echo "docs_check: architecture.md must describe the credit-based RDI front end"; exit 1; }
	@echo "Documentation check passed"

# ============================ Vendor simulators ============================
simv:
	@echo "========== Compiling with VCS =========="
	vcs -sverilog -debug_all -cm line+tgl -top $(TOP_SIMV) $(VERILOG_SIMV)
	@echo "Running VCS simulation..."
	./simv -gui &

questa:
	@echo "========== Compiling with QuestaSim =========="
	vlog -sv $(VERILOG_SIMV)
	vsim -c $(TOP_SIMV) -do "run -all; quit"

xsim:
	@echo "========== Compiling with Cadence Xcelium =========="
	xmvlog -sv $(VERILOG_SIMV)
	xmsim $(TOP_SIMV)

vivado:
	@echo "========== Setting up Vivado Simulation =========="
	@echo "Note: Add files manually to Vivado project"
	@echo "Source files: $(VERILOG_FILES)"

# ============================ Utility ============================
repo_status:
	@git status --short

clean:
	@echo "========== Cleaning simulation files =========="
	rm -rf $(VERILATOR_DIR) $(COV_DIR) $(NL1_DIR) $(CTRL_DIR) $(MSGBUS_DIR) $(FRAMING_DIR) $(FRAMING_GB_DIR) $(DEFRAMER_OVF_DIR) $(DEFRAMER_GB_OVF_DIR) $(TIMEOUT_DIR) $(BURST_DIR) $(W160_DIR) $(BRIDGE_COV_DIR) $(RATE_DP_DIR) $(RDI_DIR) $(CDC_DIR) $(GEN6_DIR) $(ASSN_DIR) $(INTEG_DIR) $(WAVE_DIR)
	rm -rf obj_dir_covmerge
	rm -f coverage.info
	rm -rf $(REPORT_DIR)
	rm -f waves/*.vcd
	rm -rf csrc simv simv.daidir DVEdir coverage.db *.vcd *.wdb *.fsdb
	rm -rf xsim.dir transcript xsim_*.log
	rm -rf work *.ucdb
	@echo "Clean complete"
