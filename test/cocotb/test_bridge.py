"""Tier 1b INTEGRATED-bridge cross-check (closure-plan item 23).

A PyUVM uvm_test driving the real ucie_rdi_to_pipe7_mac_bridge (pipe7_bridge_top wrapper, with
a PHY loopback + responder stubs) via cocotb. It exercises the full UCIe RDI credit-based flit
round-trip -- flit -> block reassembly -> Gen5 128b/130b framing -> PHY loopback -> deframing ->
block -> flit -- and cross-checks it three ways against independent Python models:

  1. round-trip identity   : recovered flits == driven flits (data/sob/is_os), in order.
  2. Python-deframe vs DUT : deframe_stream of the DUT's own TxData == the driven blocks (decode).
  3. DUT-framer vs Python  : the DUT's TxData word stream == frame_stream of the driven blocks
                             (encode; bit-exact over the captured overlap).

Dual-clock (pclk + rdi_clk); the bridge owns the RDI<->PCLK CDC. Runs on Verilator/Icarus.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from pyuvm import uvm_test
import pyuvm

from models import framing_model as fm
from models import rdi_model as rm

PIPE_WIDTH = 80
RDI_WIDTH  = 64
CREDITS    = 8
N_BLOCKS   = 24     # real blocks to check
FLUSH      = 6      # trailing filler blocks flush the last real block through the framer


@pyuvm.test()
class BridgeTest(uvm_test):
    def build_phase(self):
        pass

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top

        # Golden block stream (seeded, reproducible) + trailing filler blocks.
        import random
        rng = random.Random(0xC0FFEE)
        blocks = [(rng.getrandbits(128), bool(rng.getrandbits(1)))
                  for _ in range(N_BLOCKS + FLUSH)]
        driven_flits = rm.blocks_to_flits(blocks, RDI_WIDTH)

        # Clocks + reset.
        cocotb.start_soon(Clock(dut.pclk, 10, units="ns").start())
        cocotb.start_soon(Clock(dut.rdi_clk, 14, units="ns").start())
        self._init_inputs(dut)
        dut.reset_n.value = 0
        for _ in range(6):
            await FallingEdge(dut.pclk)
        dut.reset_n.value = 1

        recovered = []
        stream = []
        cocotb.start_soon(self._rx_sink(dut, recovered))
        cocotb.start_soon(self._tx_stream_mon(dut, stream))
        await self._rdi_source(dut, driven_flits)

        # Drain: let the last blocks propagate through the CDC + deframer + egress.
        fpb = 128 // RDI_WIDTH
        for _ in range(400):
            await FallingEdge(dut.rdi_clk)
            if len(recovered) >= (N_BLOCKS + FLUSH) * fpb:
                break

        self._check(driven_flits, recovered, stream, blocks)
        self.drop_objection()

    # ---- stimulus / capture ----
    def _init_inputs(self, dut):
        dut.rdi_tx_valid.value = 0
        dut.rdi_tx_data.value = 0
        dut.rdi_tx_sob.value = 0
        dut.rdi_tx_is_os.value = 0
        dut.rdi_rx_crd.value = 0
        dut.req_valid.value = 0
        dut.req_kind.value = 0
        dut.req_power_down.value = 0
        dut.req_rate.value = 4          # RATE_GEN5
        dut.req_width.value = 3         # W_160
        dut.req_rxwidth.value = 3
        dut.mb_req_valid.value = 0
        dut.mb_req_write.value = 0
        dut.mb_req_committed.value = 0
        dut.mb_req_addr.value = 0
        dut.mb_req_wdata.value = 0

    async def _rdi_source(self, dut, flits):
        """Credit-gated flit source: drive a flit only while a credit is held; fold returned
        credits (rdi_tx_crd, 0..2/cycle) back into the budget -- mirrors the SV smoke source."""
        avail = CREDITS
        i = 0
        while i < len(flits):
            await FallingEdge(dut.rdi_clk)
            avail += int(dut.rdi_tx_crd.value)
            if avail > 0:
                data, sob, is_os = flits[i]
                dut.rdi_tx_data.value = data
                dut.rdi_tx_sob.value = int(sob)
                dut.rdi_tx_is_os.value = int(is_os)
                dut.rdi_tx_valid.value = 1
                avail -= 1
                i += 1
            else:
                dut.rdi_tx_valid.value = 0
        await FallingEdge(dut.rdi_clk)
        dut.rdi_tx_valid.value = 0

    async def _rx_sink(self, dut, recovered):
        """Return one credit per recovered flit and capture the recovered stream."""
        while True:
            await FallingEdge(dut.rdi_clk)
            if int(dut.reset_n.value) != 1:
                dut.rdi_rx_crd.value = 0
                continue
            v = int(dut.rdi_rx_valid.value)
            dut.rdi_rx_crd.value = v
            if v == 1:
                recovered.append((int(dut.rdi_rx_data.value),
                                  bool(int(dut.rdi_rx_sob.value)),
                                  bool(int(dut.rdi_rx_is_os.value))))

    async def _tx_stream_mon(self, dut, stream):
        """Capture each valid PIPE TxData word (pclk domain) for the framer cross-check."""
        while True:
            await FallingEdge(dut.pclk)
            if int(dut.reset_n.value) == 1 and int(dut.tx_data_valid.value) == 1:
                stream.append(int(dut.tx_data.value))

    # ---- 3-way cross-check ----
    def _check(self, driven_flits, recovered, stream, blocks):
        errors = []
        fpb = 128 // RDI_WIDTH
        ncheck = N_BLOCKS * fpb

        # 1. round-trip identity (first N blocks worth of flits).
        if recovered[:ncheck] != driven_flits[:ncheck]:
            n = min(len(recovered), ncheck)
            first = next((i for i in range(n) if recovered[i] != driven_flits[i]), n)
            errors.append(f"round-trip mismatch: {len(recovered)} recovered flits; "
                          f"first diff at flit #{first}")
        rec_blocks = rm.flits_to_blocks(recovered, RDI_WIDTH)
        if rec_blocks[:N_BLOCKS] != blocks[:N_BLOCKS]:
            errors.append("recovered blocks != golden blocks (reassembly)")

        # 2. independent Python deframe of the DUT's own TxData stream == driven blocks.
        model_out = fm.deframe_stream(stream, PIPE_WIDTH, len(blocks))
        model_blocks = [(d, o) for (d, o, _s) in model_out]
        if model_blocks[:N_BLOCKS] != blocks[:N_BLOCKS]:
            errors.append(f"python-deframe(DUT stream)[:N] != golden ({len(model_blocks)} blocks)")
        for (_d, _o, s) in model_out:
            if not fm.sync_is_legal(s):
                errors.append(f"illegal sync header 0b{s:02b} in DUT stream")
                break

        # 3. DUT framer stream == independent Python framer (bit-exact over the overlap).
        model_stream = fm.frame_stream(blocks, PIPE_WIDTH)
        k = min(len(stream), len(model_stream))
        if k == 0:
            errors.append("no TxData words captured")
        elif stream[:k] != model_stream[:k]:
            first = next((i for i in range(k) if stream[i] != model_stream[i]), k)
            errors.append(f"framer/model stream mismatch: first diff at word #{first} "
                          f"(DUT {len(stream)} vs model {len(model_stream)} words)")

        self.logger.info(f"[SB] driven_flits={len(driven_flits)} recovered={len(recovered)} "
                         f"stream_words={len(stream)} model_words={len(model_stream)}")
        assert not errors, "integrated-bridge cross-check failed:\n  " + "\n  ".join(errors)
        self.logger.info("[SB] integrated-bridge cross-check PASS (3-way agreement)")
