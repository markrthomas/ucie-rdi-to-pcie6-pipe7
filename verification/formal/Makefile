SBY ?= sby

# SymbiYosys formal proofs. Most are faithful plain-Verilog re-models of the RTL core (Yosys's
# built-in Verilog frontend cannot parse the SV package-import module headers); cdc_mc and
# deframer_rtl bind the REAL RTL via the yosys-slang frontend. BMC (safety) + cover (reachability).
#
#   fifo_cdc    — CDC elastic buffer: no overflow/underflow, flag consistency (ported, single-clock)
#   cdc_mc      — REAL CDC under INDEPENDENT clocks (multiclock, via slang): occupancy bounded (item 32)
#   credit_fc   — RDI egress credit flow control: no underflow / over-credit (item 18)
#   ingress_fc  — RDI ingress credit flow control: no FIFO overflow under a credit-honest sender (item 33)
#   gearbox     — Gen5 128b/130b TX gearbox: no over-accept / accumulator overflow (item 16)
#   dataphase   — rate-aware datapath control: TxElecIdle gating + rate-mux safety (item 17)
#   deframer    — Gen5 RX deframer accumulator overflow guard: fill bounded unconditionally (item 27)
#   deframer_rtl — SAME guard bound to the REAL pipe7_rx_deframer via yosys-slang (item 31)

PROOFS = fifo_cdc cdc_mc credit_fc ingress_fc gearbox dataphase deframer deframer_rtl

.PHONY: all bmc cover clean $(PROOFS)

all: $(PROOFS)

# Legacy aliases (the original CDC-only targets).
bmc:
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[FORMAL] sby not found; install SymbiYosys to run BMC"; exit 0; }
	$(SBY) -f fifo_cdc.sby bmc
cover:
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[FORMAL] sby not found; install SymbiYosys to run cover"; exit 0; }
	$(SBY) -f fifo_cdc.sby cover

$(PROOFS):
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[FORMAL] sby not found; install SymbiYosys to run $@"; exit 0; }
	$(SBY) -f $@.sby

clean:
	rm -rf fifo_cdc_bmc/ fifo_cdc_cover/ cdc_mc/ credit_fc_bmc/ credit_fc_cover/ ingress_fc_bmc/ ingress_fc_cover/ \
	       gearbox_bmc/ gearbox_cover/ dataphase_bmc/ dataphase_cover/ \
	       deframer_bmc/ deframer_cover/ deframer_rtl/
