"""Phase G INDEPENDENT functional-coverage driver (items 44-45).

A single-process PyUVM test that drives the integrated bridge (pipe7_bridge_top) across the
rate / power / width / message-bus / RDI-credit space and scores FUNCTIONAL coverage via
cocotb_coverage (models/coverage_model.py). Run on the INDEPENDENT Icarus engine (`make fcov`),
this is a redundant cross-check to the Verilator line-coverage union: a different simulator, a
different testbench, a different coverage tool, and a different metric (functional vs line).

Item 44 establishes the model + this baseline driver (control/msgbus/RDI/datapath observation).
Item 45 adds the RX-inject + sink-stall knobs that reach the last error bins (sync_error=1,
rx_overflow=1) and promotes `make fcov` to a >=98% gate.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from pyuvm import uvm_test
import pyuvm

from models import coverage_model as cov
from models import rdi_model as rm

PIPE_WIDTH = 80
RDI_WIDTH  = 64
CREDITS    = 8

# control encodings (pipe7_pkg)
REQ_POWER, REQ_RATE, REQ_WIDTH = 0, 1, 2
PD_P0, PD_P0S, PD_P1, PD_P2 = 0, 1, 2, 3
RATE_GEN5, RATE_GEN6 = 4, 5
W_10, W_20, W_40, W_80, W_160 = 0, 1, 2, 3, 4


@pyuvm.test()
class FcovTest(uvm_test):
    def build_phase(self):
        pass

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        self.stall_sink = False
        self.fill_stop = True
        cocotb.start_soon(Clock(dut.pclk, 10, units="ns").start())
        cocotb.start_soon(Clock(dut.rdi_clk, 14, units="ns").start())
        self._init(dut)
        dut.reset_n.value = 0
        for _ in range(6):
            await FallingEdge(dut.pclk)
        dut.reset_n.value = 1
        for _ in range(3):
            await FallingEdge(dut.pclk)

        # Continuous observers for the datapath + RDI status bins.
        cocotb.start_soon(self._dp_mon(dut))
        cocotb.start_soon(self._rdi_mon(dut))

        self.logger.info("[FCOV] phase: ctrl sweep")
        await self._ctrl_sweep(dut)
        self.logger.info("[FCOV] phase: msgbus sweep")
        await self._mb_sweep(dut)
        # The control sweep leaves the datapath in Gen6; the Gen5 128b/130b flit round-trip is the
        # mode that reassembles flits and returns TX credits, so commit Gen5 (legal in P0) before
        # driving RDI traffic -- otherwise the credit-gated source starves. This is the concrete
        # bug the [[dv-avoid-silent-hangs]] discipline is meant to prevent.
        await self._ctrl_req(dut, REQ_RATE, rate=RATE_GEN5)
        self.logger.info("[FCOV] phase: rdi traffic (Gen5)")
        await self._rdi_traffic(dut)
        self.logger.info("[FCOV] phase: rx garbage inject (sync_error)")
        await self._inject_garbage(dut)
        self.logger.info("[FCOV] phase: sink stall (rx_overflow)")
        await self._sink_stall(dut)
        self.logger.info("[FCOV] phase: settle")

        for _ in range(40):
            await FallingEdge(dut.pclk)

        self._finish()
        self.drop_objection()

    # ---- init ----
    def _init(self, dut):
        for sig in ("rx_inject_en", "rx_inject_data", "rdi_tx_valid", "rdi_tx_data", "rdi_tx_sob",
                    "rdi_tx_is_os", "rdi_rx_crd", "req_valid", "req_kind", "req_power_down",
                    "mb_req_valid", "mb_req_write", "mb_req_committed", "mb_req_addr",
                    "mb_req_wdata"):
            getattr(dut, sig).value = 0
        dut.req_rate.value = RATE_GEN5
        dut.req_width.value = W_80
        dut.req_rxwidth.value = W_80

    # ---- observers ----
    async def _dp_mon(self, dut):
        while True:
            await FallingEdge(dut.pclk)
            if int(dut.reset_n.value) != 1:
                continue
            cov.sample_dp({
                "rate":       int(dut.rate.value),
                "locked":     int(dut.block_locked.value),
                "sync_err":   int(dut.sync_error.value),
                "data_phase": int(dut.in_data_phase.value),
                "tx_valid":   int(dut.tx_data_valid.value),
            })

    async def _rdi_mon(self, dut):
        while True:
            await FallingEdge(dut.rdi_clk)
            if int(dut.reset_n.value) != 1:
                continue
            cov.sample_rdi({
                "tx_crd":   int(dut.rdi_tx_crd.value),
                "rx_valid": int(dut.rdi_rx_valid.value),
                "is_os":    int(dut.rdi_rx_is_os.value),
                "sob":      int(dut.rdi_rx_sob.value),
                "overflow": int(dut.rx_overflow.value),
            })

    # ---- control-plane sweep (all kinds / power states / rates / widths + a reject) ----
    async def _ctrl_sweep(self, dut):
        # PowerDown to each state (always 'done').
        for pd in (PD_P0, PD_P0S, PD_P1, PD_P2):
            await self._ctrl_req(dut, REQ_POWER, pd=pd)
        # Back to P0 (legal for rate/width changes).
        await self._ctrl_req(dut, REQ_POWER, pd=PD_P0)
        # Rate: Gen5 then Gen6 (legal in P0).
        for rate in (RATE_GEN5, RATE_GEN6):
            await self._ctrl_req(dut, REQ_RATE, rate=rate)
        # Width: full SerDes set (legal in P0).
        for w in (W_10, W_20, W_40, W_80, W_160):
            await self._ctrl_req(dut, REQ_WIDTH, width=w)
        # Reject: a rate change from P2 is illegal (no change, req_error).
        await self._ctrl_req(dut, REQ_POWER, pd=PD_P2)
        await self._ctrl_req(dut, REQ_RATE, rate=RATE_GEN5)   # -> reject
        await self._ctrl_req(dut, REQ_POWER, pd=PD_P0)        # restore

    async def _ctrl_req(self, dut, kind, pd=PD_P0, rate=RATE_GEN5, width=W_80):
        await FallingEdge(dut.pclk)
        dut.req_kind.value = kind
        dut.req_power_down.value = pd
        dut.req_rate.value = rate
        dut.req_width.value = width
        dut.req_rxwidth.value = width
        dut.req_valid.value = 1
        await FallingEdge(dut.pclk)
        dut.req_valid.value = 0
        # busy=1 bin (request in flight).
        cov.sample_ctrl({"kind": kind, "outcome": "done", "pd": pd, "rate": rate,
                         "width": width, "busy": int(dut.busy.value)})
        outcome = "done"
        for _ in range(200):
            if int(dut.done.value) == 1:
                outcome = "done"
                break
            if int(dut.req_error.value) == 1:
                outcome = "reject"
                break
            await FallingEdge(dut.pclk)
        cov.sample_ctrl({"kind": kind, "outcome": outcome, "pd": pd, "rate": rate,
                         "width": width, "busy": int(dut.busy.value)})

    # ---- message-bus sweep (read / uncommitted write / committed write) ----
    async def _mb_sweep(self, dut):
        await self._mb_req(dut, write=0, committed=0, addr=0x010, wdata=0x00)  # read
        await self._mb_req(dut, write=1, committed=0, addr=0x011, wdata=0xA5)  # wr_unc
        await self._mb_req(dut, write=1, committed=1, addr=0x012, wdata=0x5A)  # wr_com

    async def _mb_req(self, dut, write, committed, addr, wdata):
        for _ in range(50):
            await FallingEdge(dut.pclk)
            if int(dut.mb_req_ready.value) == 1:
                break
        dut.mb_req_write.value = write
        dut.mb_req_committed.value = committed
        dut.mb_req_addr.value = addr
        dut.mb_req_wdata.value = wdata
        dut.mb_req_valid.value = 1
        await FallingEdge(dut.pclk)
        dut.mb_req_valid.value = 0
        is_read = 0
        for _ in range(300):
            if int(dut.mb_rsp_valid.value) == 1:
                is_read = int(dut.mb_rsp_is_read.value)
                break
            await FallingEdge(dut.pclk)
        op = "read" if not write else ("wr_com" if committed else "wr_unc")
        cov.sample_mb({"op": op, "is_read": is_read, "committed": committed})

    # ---- RDI traffic (credit round-trip; observe is_os/sob/tx_crd via _rdi_mon) ----
    async def _rdi_traffic(self, dut):
        rng = random.Random(0xF00D)
        n = 24
        blocks = [(rng.getrandbits(128), bool(rng.getrandbits(1))) for _ in range(n)]
        flits = rm.blocks_to_flits(blocks, RDI_WIDTH)
        cocotb.start_soon(self._rx_sink(dut))
        avail = CREDITS
        i = 0
        stall = 0                      # consecutive cycles with no credit and none held
        MAX_STALL = 64                 # fail-fast: a credit round-trip completes well within this
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
                stall = 0
            else:
                dut.rdi_tx_valid.value = 0
                stall += 1
                # Fail-fast rather than spin: if credits never return, the datapath is almost
                # certainly in the wrong mode -- surface it immediately instead of hanging.
                assert stall < MAX_STALL, (
                    f"RDI TX credit starved after {i}/{len(flits)} flits "
                    f"(rate={int(dut.rate.value)}, in_data_phase={int(dut.in_data_phase.value)}, "
                    f"block_locked={int(dut.block_locked.value)}) -- credits not returning")
        dut.rdi_tx_valid.value = 0
        # Bounded drain: stop as soon as the recovered stream goes idle.
        idle = 0
        for _ in range(300):
            await FallingEdge(dut.rdi_clk)
            idle = idle + 1 if int(dut.rdi_rx_valid.value) == 0 else 0
            if idle >= 20:
                break

    async def _rx_sink(self, dut):
        # Owns rdi_rx_crd for the whole run: returns a credit per recovered flit, except while
        # self.stall_sink is set (the overflow phase), when it holds credits at 0.
        while True:
            await FallingEdge(dut.rdi_clk)
            if int(dut.reset_n.value) != 1 or self.stall_sink:
                dut.rdi_rx_crd.value = 0
                continue
            dut.rdi_rx_crd.value = int(dut.rdi_rx_valid.value)

    # ---- error injection (reach the last status bins) ----
    async def _tx_filler(self, dut):
        """Keep TX flits flowing (credit-gated) so tx_data_valid -- and thus the deframer's
        rx_valid -- keeps pulsing. Runs until self.fill_stop."""
        rng = random.Random(0x1234)
        avail = CREDITS
        while not self.fill_stop:
            await FallingEdge(dut.rdi_clk)
            avail += int(dut.rdi_tx_crd.value)
            if avail > 0:
                dut.rdi_tx_data.value = rng.getrandbits(RDI_WIDTH)
                dut.rdi_tx_sob.value = rng.getrandbits(1)
                dut.rdi_tx_is_os.value = rng.getrandbits(1)
                dut.rdi_tx_valid.value = 1
                avail -= 1
            else:
                dut.rdi_tx_valid.value = 0
        dut.rdi_tx_valid.value = 0

    async def _inject_garbage(self, dut):
        """Drive misaligned RxData so the deframer loses sync -> sync_error=1. Garbage is only
        clocked into the deframer while tx_data_valid (=rx_valid) pulses, so keep TX flowing."""
        self.fill_stop = False
        cocotb.start_soon(self._tx_filler(dut))
        dut.rx_inject_en.value = 1
        seen = False
        for k in range(160):
            dut.rx_inject_data.value = (1 << PIPE_WIDTH) - 1 if (k & 1) else 0x3
            await FallingEdge(dut.pclk)
            if int(dut.sync_error.value) == 1:
                seen = True
                break
        dut.rx_inject_en.value = 0
        self.fill_stop = True
        # Let the deframer re-lock on the restored loopback.
        for _ in range(30):
            await FallingEdge(dut.pclk)
        assert seen, "sync_error never asserted under sustained garbage RX injection"

    async def _sink_stall(self, dut):
        """Stall the RX credit return while TX keeps flowing so the RX CDC fills -> rx_overflow=1."""
        rng = random.Random(0x5A5A)
        blocks = [(rng.getrandbits(128), bool(rng.getrandbits(1))) for _ in range(48)]
        flits = rm.blocks_to_flits(blocks, RDI_WIDTH)
        # Hold off the sink: _rx_sink keeps rdi_rx_crd at 0 while stall_sink is set.
        self.stall_sink = True
        seen = False
        i = 0
        avail = CREDITS
        for _ in range(600):
            await FallingEdge(dut.rdi_clk)
            avail += int(dut.rdi_tx_crd.value)
            if i < len(flits) and avail > 0:
                data, sob, is_os = flits[i]
                dut.rdi_tx_data.value = data
                dut.rdi_tx_sob.value = int(sob)
                dut.rdi_tx_is_os.value = int(is_os)
                dut.rdi_tx_valid.value = 1
                avail -= 1
                i += 1
            else:
                dut.rdi_tx_valid.value = 0
            if int(dut.rx_overflow.value) == 1:
                seen = True
                break
        dut.rdi_tx_valid.value = 0
        self.stall_sink = False
        assert seen, "rx_overflow never asserted under a stalled RX sink"

    # ---- report ----
    def _finish(self):
        hit, total, pct = cov.overall()
        out = os.environ.get("FCOV_OUT", "")
        if out:
            cov.dump(json_path=os.path.join(out, "fcov.json"),
                     txt_path=os.path.join(out, "fcov.txt"))
        miss = [n for (n, c, s, _p) in cov.per_point() if c < s]
        self.logger.info(f"[FCOV] bins={hit}/{total} = {pct:.1f}%  "
                         f"tool=cocotb_coverage engine=icarus")
        if miss:
            self.logger.info("[FCOV] not-yet-full points: " + ", ".join(miss))
