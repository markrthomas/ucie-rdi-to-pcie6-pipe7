"""Tier 1b control-plane cross-check (closure-plan item 14).

Drives PowerDown/Rate/Width requests into pipe7_mac_ctrl_fsm (pipe7_ctrl_top) while an
INDEPENDENT PyUVM PhyStatusResponder answers the PhyStatus handshake, and cross-checks the
DUT's per-request outcome (done vs req_error) and resulting command state against an
independent Python legality model. Includes a cocotb-coverage parity check on the key bins.
Run: `make MODULE=test_ctrl_plane`.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from pyuvm import uvm_env, uvm_scoreboard, uvm_test, uvm_tlm_analysis_fifo, ConfigDB
import pyuvm
from cocotb_coverage.coverage import CoverPoint, coverage_db

from agents.ctrl_agent import CtrlAgent
from agents.phy_responder_agent import PhyStatusResponder
from seq_lib.pipe7_seq_lib import CtrlSeq
from models.ctrl_plane_model import CtrlModel


@CoverPoint("top.ctrl.kind", xf=lambda item, outcome, state: item.kind, bins=[0, 1, 2],
            bins_labels=["POWER", "RATE", "WIDTH"])
@CoverPoint("top.ctrl.outcome", xf=lambda item, outcome, state: outcome,
            bins=["done", "reject"])
@CoverPoint("top.ctrl.pd", xf=lambda item, outcome, state: state["pd"], bins=[0, 1, 2, 3],
            bins_labels=["P0", "P0s", "P1", "P2"])
@CoverPoint("top.ctrl.rate", xf=lambda item, outcome, state: state["rate"], bins=[4, 5],
            bins_labels=["Gen5", "Gen6"])
def _sample_ctrl(item, outcome, state):
    pass


class CtrlScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.fifo = uvm_tlm_analysis_fifo("fifo", self)
        self.errors = []
        self.n_done = 0
        self.n_reject = 0

    def check_phase(self):
        model = CtrlModel()
        i = 0
        while self.fifo.can_get():
            ok, (item, outcome, state) = self.fifo.try_get()
            if not ok:
                break
            exp_outcome, exp_state = model.predict(item.kind, item.pd, item.rate,
                                                   item.width, item.rxw)
            if outcome != exp_outcome:
                self.errors.append(f"req#{i} kind={item.kind}: outcome {outcome} != {exp_outcome}")
            elif outcome == "done" and state != exp_state:
                self.errors.append(f"req#{i}: state {state} != model {exp_state}")
            if outcome == "done":
                self.n_done += 1
            elif outcome == "reject":
                self.n_reject += 1
            _sample_ctrl(item, outcome, state)
            i += 1
        self.logger.info(f"[SB-CTRL] requests={i} done={self.n_done} reject={self.n_reject}")

        # Leaf scoreboard owns the pass/fail (pyuvm check_phase is top-down).
        if i == 0:
            self.errors.append("no control requests observed")
        if self.n_reject != 2:
            self.errors.append(f"expected 2 rejects, got {self.n_reject}")
        # cocotb-coverage parity: every key bin the SV/UVM covergroup counts must be hit.
        for name in ("top.ctrl.kind", "top.ctrl.outcome", "top.ctrl.pd", "top.ctrl.rate"):
            pct = coverage_db[name].cover_percentage
            if pct != 100.0:
                self.errors.append(f"coverage {name} = {pct}% (< 100; bin parity gap)")

        assert not self.errors, \
            "control-plane cross-check failed:\n  " + "\n  ".join(self.errors)

    def report_phase(self):
        if not self.errors:
            self.logger.info("[SB-CTRL] control-plane cross-check PASS (DUT == model)")


class CtrlEnv(uvm_env):
    def build_phase(self):
        self.agent = CtrlAgent("agent", self)
        self.responder = PhyStatusResponder("responder", self)
        self.sb = CtrlScoreboard("sb", self)

    def connect_phase(self):
        self.agent.driver.ap.connect(self.sb.fifo.analysis_export)


@pyuvm.test()
class CtrlPlaneTest(uvm_test):
    def build_phase(self):
        self.env = CtrlEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
        dut.reset_n.value = 0
        dut.req_valid.value = 0
        dut.req_kind.value = 0
        dut.req_power_down.value = 0
        dut.req_rate.value = 4
        dut.req_width.value = 4
        dut.req_rxwidth.value = 4
        for _ in range(5):
            await FallingEdge(dut.clk)
        dut.reset_n.value = 1
        for _ in range(3):
            await FallingEdge(dut.clk)

        seqr = ConfigDB().get(self, "", "CTRL_SEQR")
        await CtrlSeq("ctrl_seq").start(seqr)
        for _ in range(10):
            await FallingEdge(dut.clk)
        self.drop_objection()

    # Pass/fail assertions live in CtrlScoreboard.check_phase (leaf) -- see note in
    # test_datapath.py about pyuvm's top-down check_phase ordering.
