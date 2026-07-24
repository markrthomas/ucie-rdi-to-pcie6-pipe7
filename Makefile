# Root Makefile — ucie_rdi_to_pcie6_pipe7
# UCIe 1.0 RDI <-> PCIe 6.x / PIPE 7.1 MAC-facing bridge IP (Gen5 + Gen6).
# `make` (no target) prints the grouped target list below. Verilator is the OSS gate;
# the PyUVM-on-Cocotb tier (`make cocotb`) and the VCS/UVM tier (`make uvm`) sit above it.

.PHONY: all check ci clean cocotb coverage coverage_summary docs_check docs_pdf formal \
        gtkwave help lint nl1 quick regress regress_all regress_cov regress_nl1 repo_status \
        sim simv smoke test uvm uvm_compile uvm_pdf uvm_run verilator verilator_assn \
        verilator_cov verilator_ctrl verilator_debug verilator_framing verilator_gen6 \
        verilator_msgbus verilator_nl1 vivado wave waves xsim questa

VERILATOR ?= $(shell command -v verilator_bin 2>/dev/null || command -v verilator 2>/dev/null)
VERILATOR_ROOT := $(shell if [ -n "$(VERILATOR)" ]; then realpath "$$(dirname "$(VERILATOR)")/../share/verilator"; fi)
VERILATOR_INC := $(VERILATOR_ROOT)/include
VERILATOR_CPP_CORE = $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_vcd_c.cpp \
	$(VERILATOR_INC)/verilated_threads.cpp

# ---- Datapath-only pass-through smoke (item 1) ----
VERILOG_RTL = src/pipe7_pkg.sv src/pipe7_cdc_elastic_buf.sv src/ucie_rdi_to_pipe7_mac_bridge.sv
VERILOG_FILES = $(VERILOG_RTL) test/tb_pipe7_mac_bridge.sv
TOP_MODULE = tb_pipe7_mac_bridge
TOP_SIMV = sim_top
VERILOG_SIMV = test/sim_top.sv $(VERILOG_RTL)
VERILATOR_DIR = obj_dir
COV_DIR = obj_dir_cov
NL1_TOP = tb_pipe7_mac_bridge_nl1
NL1_DIR = obj_dir_nl1
NL1_FILES = $(VERILOG_RTL) test/tb_pipe7_mac_bridge_nl1.sv
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
# Item 6: Gen6 (Rate=5) wide raw datapath + PAM4, composed with the ctrl FSM.
GEN6_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_gen6_datapath.sv
GEN6_FILES = $(GEN6_RTL) test/pipe7_phy_responder_stub.sv test/tb_pipe7_gen6.sv
GEN6_TOP = tb_pipe7_gen6
GEN6_DIR = obj_dir_gen6
# Item 7: PIPE MAC protocol assertions (SVA) against a good control+framing scenario.
ASSN_MOD = test/pipe7_mac_bridge_assertions.sv
ASSN_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_tx_framer.sv src/pipe7_rx_deframer.sv
ASSN_FILES = $(ASSN_RTL) $(ASSN_MOD) test/pipe7_phy_responder_stub.sv test/tb_pipe7_assertions.sv
ASSN_TOP = tb_pipe7_assertions
ASSN_DIR = obj_dir_assn
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
	@echo "  make verilator_gen6    Gen6 (Rate=5) raw wide datapath + L0p + PAM4"
	@echo "  make verilator_assn    PIPE protocol SVA assertions (Verilator --assert)"
	@echo ""
	@echo "Waveforms (GTKWave):"
	@echo "  make waves   [WAVE_TB=framing|ctrl|msgbus|gen6|assn]"
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
regress: lint verilator verilator_ctrl verilator_msgbus verilator_framing verilator_gen6 verilator_assn

# Full local confidence run (heavier than CI's first gate).
ci: regress regress_cov regress_nl1 coverage_summary docs_check

regress_cov: lint verilator_cov
regress_nl1: lint verilator_nl1

# ============================ Verilator smokes ============================
verilator:
	@echo "========== Compiling with Verilator =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	$(VERILATOR) --trace -cc $(VERILOG_FILES) --top-module $(TOP_MODULE) -Wno-INFINITELOOP -Wno-STMTDLY -Wno-WIDTH -Wno-UNUSEDSIGNAL
	cd $(VERILATOR_DIR) && make -f V$(TOP_MODULE).mk
	cd $(VERILATOR_DIR) && g++ -o $(TOP_MODULE) ../sim_main.cpp V$(TOP_MODULE)__ALL.a \
		-I. -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP_CORE) -pthread -lm
	@echo "Running Verilator simulation..."
	./$(VERILATOR_DIR)/$(TOP_MODULE)

# NUM_LANES=1 parameter sanity (obj_dir_nl1/, sim_main_nl1.cpp).
verilator_nl1:
	@echo "========== Verilator NUM_LANES=1 smoke =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(NL1_DIR)
	$(VERILATOR) --trace -cc $(NL1_FILES) --top-module $(NL1_TOP) \
		-Wno-INFINITELOOP -Wno-STMTDLY -Wno-WIDTH -Wno-UNUSEDSIGNAL --Mdir $(NL1_DIR)
	cd $(NL1_DIR) && make -f V$(NL1_TOP).mk
	cd $(NL1_DIR) && g++ -o $(NL1_TOP) ../sim_main_nl1.cpp V$(NL1_TOP)__ALL.a \
		-I. -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP_CORE) -pthread -lm
	@echo "Running Verilator NL1 simulation..."
	cd $(NL1_DIR) && ./$(NL1_TOP)

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

# Verilator with coverage: separate build dir so normal obj_dir stays unchanged.
verilator_cov:
	@echo "========== Verilator with coverage =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(COV_DIR)
	$(VERILATOR) --coverage --trace -cc $(VERILOG_FILES) --top-module $(TOP_MODULE) \
		-Wno-INFINITELOOP -Wno-STMTDLY -Wno-WIDTH -Wno-UNUSEDSIGNAL --Mdir $(COV_DIR)
	cd $(COV_DIR) && make -f V$(TOP_MODULE).mk
	cd $(COV_DIR) && g++ -DVM_COVERAGE=1 -o $(TOP_MODULE) ../sim_main.cpp V$(TOP_MODULE)__ALL.a \
		-I. -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP_CORE) $(VERILATOR_INC)/verilated_cov.cpp -pthread -lm
	@echo "Running Verilator simulation (coverage)..."
	cd $(COV_DIR) && ./$(TOP_MODULE)
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
	@awk 'BEGIN{lines=0;hit=0} /^DA:/ {split($$0,a,":"); split(a[2],b,","); lines++; if (b[2] > 0) hit++} END{printf "Line coverage: %d/%d = %.2f%%\n", hit, lines, (lines?100*hit/lines:0)}' coverage.info
	@awk 'function flush(){if(file != ""){printf "  %-55s %4d/%-4d %6.2f%%\n", file, hit, lines, (lines?100*hit/lines:0)}} /^SF:/ {flush(); file=substr($$0,4); lines=0; hit=0} /^DA:/ {split($$0,a,":"); split(a[2],b,","); lines++; if (b[2] > 0) hit++} END{flush()}' coverage.info

# Same as verilator with debug-friendly C++ flags.
verilator_debug:
	@echo "========== Compiling with Verilator (debug) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	$(VERILATOR) --trace -cc $(VERILOG_FILES) --top-module $(TOP_MODULE) -Wno-INFINITELOOP -Wno-STMTDLY -Wno-WIDTH -Wno-UNUSEDSIGNAL
	cd $(VERILATOR_DIR) && make -f V$(TOP_MODULE).mk
	cd $(VERILATOR_DIR) && g++ -g -O0 -o $(TOP_MODULE) ../sim_main.cpp V$(TOP_MODULE)__ALL.a \
		-I. -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP_CORE) -pthread -lm
	@echo "Running Verilator simulation..."
	./$(VERILATOR_DIR)/$(TOP_MODULE)

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

# Legacy: open GTKWave on the datapath smoke's VCD (from sim_main.cpp).
wave:
	@echo "Opening GTKWave on $(VERILATOR_DIR)/dump.vcd..."
	gtkwave $(VERILATOR_DIR)/dump.vcd &

# ============================ Lint ============================
lint:
	@if [ -z "$(VERILATOR)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	$(VERILATOR) --lint-only -Wall -Isrc --top-module ucie_rdi_to_pipe7_mac_bridge $(VERILOG_RTL)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN --top-module $(TOP_MODULE) $(VERILOG_FILES)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN --top-module $(NL1_TOP) $(NL1_FILES)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-DECLFILENAME \
		+define+PIPE7_MAC_IF_LINT --top-module pipe7_mac_if_lint_top $(MAC_IF)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_ctrl_fsm $(CTRL_RTL)
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_msgbus_master src/pipe7_pkg.sv src/pipe7_msgbus_master.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_regfile src/pipe7_pkg.sv src/pipe7_regfile.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_tx_framer src/pipe7_pkg.sv src/pipe7_tx_framer.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_rx_deframer src/pipe7_pkg.sv src/pipe7_rx_deframer.sv
	$(VERILATOR) --lint-only -Wall -Isrc -Wno-UNUSEDPARAM --top-module pipe7_gen6_datapath src/pipe7_pkg.sv src/pipe7_gen6_datapath.sv
	$(VERILATOR) --lint-only -Wall --assert -Isrc -Wno-UNUSEDPARAM --top-module pipe7_mac_bridge_assertions src/pipe7_pkg.sv $(ASSN_MOD)

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

uvm_compile:
	$(UVM_MAKE) compile

uvm_run:
	$(UVM_MAKE) run

uvm: uvm_compile uvm_run

uvm_pdf docs_pdf:
	$(UVM_MAKE) pdf

# ============================ Formal ============================
# SymbiYosys formal proofs in verification/formal/ (CDC buffer + FSM invariants).
formal:
	@if command -v sby >/dev/null 2>&1; then \
		$(MAKE) -C $(CURDIR)/verification/formal; \
	else \
		echo "[FORMAL] sby not found; install SymbiYosys (OSS CAD Suite) to run formal"; \
		echo "         Properties are in verification/formal/fifo_cdc_props.sv"; \
		exit 0; \
	fi

# ============================ Docs ============================
docs_check:
	@echo "========== Checking documentation links and stale claims =========="
	@test -f README.md
	@test -f docs/architecture.md
	@test -f docs/interface_spec.md
	@test -f docs/verification_plan.md
	@test -f docs/uvm_verification.md
	@! grep -R "| \*\*Line Coverage\*\* | 100%" README.md docs >/dev/null
	@! grep -R "mirrors the coverage of the original SystemVerilog testbench" README.md docs >/dev/null
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
	rm -rf $(VERILATOR_DIR) $(COV_DIR) $(NL1_DIR) $(CTRL_DIR) $(MSGBUS_DIR) $(FRAMING_DIR) $(GEN6_DIR) $(ASSN_DIR) $(WAVE_DIR)
	rm -f coverage.info
	rm -f waves/*.vcd
	rm -rf csrc simv simv.daidir DVEdir coverage.db *.vcd *.wdb *.fsdb
	rm -rf xsim.dir transcript xsim_*.log
	rm -rf work *.ucdb
	@echo "Clean complete"
