
.PHONY: all check ci clean coverage coverage_summary docs_check docs_pdf formal help lint nl1 quick regress regress_all regress_cov regress_nl1 repo_status sim simv smoke test uvm uvm_compile uvm_pdf uvm_run verilator verilator_cov verilator_ctrl verilator_debug verilator_framing verilator_gen6 verilator_msgbus verilator_nl1 vivado wave xsim questa

VERILATOR ?= $(shell command -v verilator_bin 2>/dev/null || command -v verilator 2>/dev/null)
VERILATOR_ROOT := $(shell if [ -n "$(VERILATOR)" ]; then realpath "$$(dirname "$(VERILATOR)")/../share/verilator"; fi)
VERILATOR_INC := $(VERILATOR_ROOT)/include
VERILATOR_CPP_CORE = $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_vcd_c.cpp \
	$(VERILATOR_INC)/verilated_threads.cpp

# Item 1 (datapath-only pass-through) file lists. Framing/FSM/message-bus
# sources and the adapted scoreboard/assertions/UVM come in later items.
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
# Item 2: PIPE MAC interface contract. Linted via a define-guarded elaboration wrapper
# (clocking blocks are excluded under ifndef VERILATOR; consumed by the UVM tier).
MAC_IF = test/uvm/pipe7_mac_if.sv
# Item 3: PowerDown/Rate/Width control FSM (PhyStatus-gated) + PHY-responder stub + a
# self-clocking control-plane smoke, built with `verilator --binary --timing`.
CTRL_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv
CTRL_FILES = $(CTRL_RTL) test/pipe7_phy_responder_stub.sv test/tb_pipe7_ctrl_fsm.sv
CTRL_TOP = tb_pipe7_ctrl_fsm
CTRL_DIR = obj_dir_ctrl
# Item 4: message-bus master + MAC-side regfile + PHY message-bus responder stub, in a
# self-clocking M2P/P2M round-trip smoke, built with `verilator --binary --timing`.
MSGBUS_RTL = src/pipe7_pkg.sv src/pipe7_msgbus_master.sv src/pipe7_regfile.sv
MSGBUS_FILES = $(MSGBUS_RTL) test/pipe7_msgbus_responder_stub.sv test/tb_pipe7_msgbus.sv
MSGBUS_TOP = tb_pipe7_msgbus
MSGBUS_DIR = obj_dir_msgbus
# Item 5: Gen5 128b/130b TX framer + RX deframer (MAC-owned block coding) in a self-clocking
# loopback round-trip smoke, built with `verilator --binary --timing`.
FRAMING_RTL = src/pipe7_pkg.sv src/pipe7_tx_framer.sv src/pipe7_rx_deframer.sv
FRAMING_FILES = $(FRAMING_RTL) test/tb_pipe7_framing.sv
FRAMING_TOP = tb_pipe7_framing
FRAMING_DIR = obj_dir_framing
# Item 6: Gen6 (Rate=5) wide raw datapath (no 128b/130b sync header) + PAM4RestrictedLevels
# carry, composed with the item-3 ctrl FSM for Gen6 rate/L0p-width. Self-clocking smoke.
GEN6_RTL = src/pipe7_pkg.sv src/pipe7_mac_ctrl_fsm.sv src/pipe7_gen6_datapath.sv
GEN6_FILES = $(GEN6_RTL) test/pipe7_phy_responder_stub.sv test/tb_pipe7_gen6.sv
GEN6_TOP = tb_pipe7_gen6
GEN6_DIR = obj_dir_gen6
UVM_MAKE = $(MAKE) -C test/uvm -f Makefile.vcs

# Default target
all: verilator

# Repo workflow aliases
quick: lint

check: regress

smoke: verilator

test: regress

nl1: regress_nl1

# Standard DV gate aliases (consistent with other RTL repos).
# coverage: alias for regress_cov (Verilator line coverage).
coverage: regress_cov

# formal: SymbiYosys formal proofs in verification/formal/.
#         Checks wr_ready/wr_full polarity and output stability (rd_valid,
#         rd_data, rd_error held when rd_ready is low) for ucie_rdi_fifo_cdc.
#         Uses a plain-Verilog model (struct literals / 'return' unsupported by Yosys).
formal:
	@if command -v sby >/dev/null 2>&1; then \
		$(MAKE) -C $(CURDIR)/verification/formal; \
	else \
		echo "[FORMAL] sby not found; install SymbiYosys (OSS CAD Suite) to run formal"; \
		echo "         Properties are in verification/formal/fifo_cdc_props.sv"; \
		exit 0; \
	fi

# Full local confidence run. This is intentionally heavier than CI's first gate.
ci: regress regress_cov regress_nl1 coverage_summary docs_check

regress_all: ci

# Release regression (lint + Verilator datapath + control-plane + message-bus + framing + Gen6 smokes); CI runs this.
regress: lint verilator verilator_ctrl verilator_msgbus verilator_framing verilator_gen6

# Standard DV alias (DV_STANDARDS.md): sim = Verilator OSS sim.
sim: verilator

# Lint + Verilator with coverage (writes obj_dir_cov/coverage.dat; optional coverage.info).
regress_cov: lint verilator_cov

# NUM_LANES=1 compile + minimal smoke (lint includes nl1 TB pass).
regress_nl1: lint verilator_nl1

# Verilator Simulation
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

# Item 3: control-plane smoke -- PhyStatus-gated PowerDown/Rate/Width FSM against the
# non-UVM PHY-responder stub. Self-clocking TB via --binary --timing; $fatal on mismatch.
verilator_ctrl:
	@echo "========== Verilator control-plane smoke (PhyStatus-gated FSM) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(CTRL_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(CTRL_TOP) --Mdir $(CTRL_DIR) -o ctrl_sim $(CTRL_FILES)
	@echo "Running Verilator control-plane smoke..."
	./$(CTRL_DIR)/ctrl_sim

# Item 4: message-bus smoke -- M2P/P2M framing round-trip through the master + regfile against
# the non-UVM PHY message-bus responder stub. Self-clocking TB via --binary --timing.
verilator_msgbus:
	@echo "========== Verilator message-bus smoke (M2P/P2M framing) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(MSGBUS_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(MSGBUS_TOP) --Mdir $(MSGBUS_DIR) -o msgbus_sim $(MSGBUS_FILES)
	@echo "Running Verilator message-bus smoke..."
	./$(MSGBUS_DIR)/msgbus_sim

# Item 5: Gen5 128b/130b framing smoke -- TX framer -> RX deframer loopback round-trip.
# Self-clocking TB via --binary --timing; $fatal on mismatch.
verilator_framing:
	@echo "========== Verilator framing smoke (Gen5 128b/130b round-trip) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(FRAMING_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(FRAMING_TOP) --Mdir $(FRAMING_DIR) -o framing_sim $(FRAMING_FILES)
	@echo "Running Verilator framing smoke..."
	./$(FRAMING_DIR)/framing_sim

# Item 6: Gen6 datapath smoke -- Gen6 rate + L0p width via the ctrl FSM, then the raw wide
# datapath round-trip + PAM4RestrictedLevels carry. Self-clocking TB via --binary --timing.
verilator_gen6:
	@echo "========== Verilator Gen6 smoke (Rate=5 raw wide datapath + PAM4) =========="
	@if [ -z "$(VERILATOR)" ] || [ -z "$(VERILATOR_ROOT)" ]; then echo "ERROR: install verilator or ensure verilator_bin is on PATH"; exit 1; fi
	rm -rf $(GEN6_DIR)
	$(VERILATOR) --binary --timing -Isrc \
		-Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH \
		--top-module $(GEN6_TOP) --Mdir $(GEN6_DIR) -o gen6_sim $(GEN6_FILES)
	@echo "Running Verilator Gen6 smoke..."
	./$(GEN6_DIR)/gen6_sim

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

# Same as verilator with debug-friendly C++ flags
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

# View waveforms (GTKWave; VCD from sim_main.cpp)
wave:
	@echo "Opening GTKWave..."
	gtkwave $(VERILATOR_DIR)/dump.vcd &

# VCS Simulation (requires Synopsys VCS)
simv:
	@echo "========== Compiling with VCS =========="
	vcs -sverilog -debug_all -cm line+tgl -top $(TOP_SIMV) $(VERILOG_SIMV)
	@echo "Running VCS simulation..."
	./simv -gui &

# Mentor ModelSim/QuestaSim
questa:
	@echo "========== Compiling with QuestaSim =========="
	vlog -sv $(VERILOG_SIMV)
	vsim -c $(TOP_SIMV) -do "run -all; quit"

# Cadence Xcelium
xsim:
	@echo "========== Compiling with Cadence Xcelium =========="
	xmvlog -sv $(VERILOG_SIMV)
	xmsim $(TOP_SIMV)

# Vivado Simulation (Xilinx)
vivado:
	@echo "========== Setting up Vivado Simulation =========="
	@echo "Note: Add files manually to Vivado project"
	@echo "Source files: $(VERILOG_FILES)"

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

uvm_compile:
	$(UVM_MAKE) compile

uvm_run:
	$(UVM_MAKE) run

uvm: uvm_compile uvm_run

uvm_pdf docs_pdf:
	$(UVM_MAKE) pdf

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

repo_status:
	@git status --short

# Clean up simulation artifacts
clean:
	@echo "========== Cleaning simulation files =========="
	rm -rf $(VERILATOR_DIR) $(COV_DIR) $(NL1_DIR) $(CTRL_DIR) $(MSGBUS_DIR) $(FRAMING_DIR) $(GEN6_DIR)
	rm -f coverage.info
	rm -rf csrc simv simv.daidir DVEdir coverage.db *.vcd *.wdb *.fsdb
	rm -rf xsim.dir transcript xsim_*.log
	rm -rf work *.ucdb
	@echo "Clean complete"

help:
	@echo "Available targets:"
	@echo "  make quick              - lint only"
	@echo "  make check              - alias for regress"
	@echo "  make test               - alias for regress"
	@echo "  make ci                 - regress + coverage + NL1 + docs check"
	@echo "  make regress             - lint + Verilator datapath + control-plane + message-bus smokes (release gate)"
	@echo "  make verilator_ctrl      - control-plane smoke: PhyStatus-gated FSM + PHY-responder stub"
	@echo "  make verilator_msgbus    - message-bus smoke: M2P/P2M framing master + regfile + responder stub"
	@echo "  make verilator_framing   - framing smoke: Gen5 128b/130b TX framer -> RX deframer round-trip"
	@echo "  make verilator_gen6      - Gen6 smoke: Rate=5 raw wide datapath + L0p width + PAM4 config"
	@echo "  make regress_cov         - lint + Verilator sim with coverage (+ coverage.info if tool present)"
	@echo "  make regress_nl1         - lint + NUM_LANES=1 Verilator smoke"
	@echo "  make regress_all         - alias for ci"
	@echo "  make coverage_summary    - summarize coverage.info"
	@echo "  make docs_check          - check required docs and stale claims"
	@echo "  make uvm                - VCS/UVM compile + run via test/uvm/Makefile.vcs"
	@echo "  make uvm_compile        - VCS/UVM compile only"
	@echo "  make uvm_run            - VCS/UVM run only"
	@echo "  make uvm_pdf            - build UVM README PDF via pandoc"
	@echo "  make repo_status        - git status --short"
	@echo "  make verilator_nl1       - NUM_LANES=1 build/run only (after lint)"
	@echo "  make verilator          - Compile and simulate with Verilator (default)"
	@echo "  make verilator_debug    - Verilator with g++ -g -O0"
	@echo "  make wave               - Open GTKWave on obj_dir/dump.vcd"
	@echo "  make lint               - Verilator -Wall (RTL + assertions + TB/scoreboard)"
	@echo "  make simv               - VCS"
	@echo "  make questa             - QuestaSim"
	@echo "  make xsim               - Xcelium"
	@echo "  make vivado             - Vivado hints"
	@echo "  make clean              - Remove build artifacts"
	@echo "  make help               - This message"

.DEFAULT_GOAL := all
