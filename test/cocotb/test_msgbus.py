"""Tier 1b message-bus cross-check (closure-plan item 14).

Drives register read/write transactions into pipe7_msgbus_master (pipe7_msgbus_top) while an
INDEPENDENT PyUVM MsgbusResponder decodes the M2P framing and answers on P2M. The scoreboard
cross-checks: (a) the responder-decoded transaction matches the driven request AND the
independently-encoded M2P bytes (framing); (b) the DUT's rsp_rdata for reads matches the
register model; (c) a committed-write -> read round-trip returns the written value. Includes a
cocotb-coverage parity check. Run: `make MODULE=test_msgbus`.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from pyuvm import uvm_env, uvm_scoreboard, uvm_test, uvm_tlm_analysis_fifo, ConfigDB
import pyuvm
from cocotb_coverage.coverage import CoverPoint, coverage_db

from agents.msgbus_agent import MsgbusAgent
from agents.phy_responder_agent import MsgbusResponder
from seq_lib.pipe7_seq_lib import MsgbusSeq
from models import msgbus_model as mb


@CoverPoint("top.mb.kind",
            xf=lambda item, res, dec: ("read" if not item.write else
                                       ("wr_commit" if item.committed else "wr_uncommit")),
            bins=["read", "wr_uncommit", "wr_commit"])
@CoverPoint("top.mb.is_read", xf=lambda item, res, dec: res["is_read"], bins=[0, 1])
def _sample_mb(item, res, dec):
    pass


class MsgbusScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.fifo = uvm_tlm_analysis_fifo("fifo", self)
        self.errors = []
        self.n = 0
        self.responder = None   # set by env

    def check_phase(self):
        decoded = list(self.responder.transactions)   # independent PHY-side decode, in order
        di = 0
        while self.fifo.can_get():
            ok, (item, res) = self.fifo.try_get()
            if not ok:
                break
            if not res["completed"]:
                self.errors.append(f"txn#{self.n}: no rsp_valid")
                self.n += 1
                continue

            # (a) framing: the responder-decoded transaction matches the request + encoded bytes.
            exp_bytes = mb.encode_m2p(item.write, item.committed, item.addr, item.wdata)
            if di < len(decoded):
                d = decoded[di]
                di += 1
                exp_cmd = mb.cmd_of(item.write, item.committed)
                if d["cmd"] != exp_cmd or d["addr"] != item.addr:
                    self.errors.append(
                        f"txn#{self.n}: decoded cmd/addr {d['cmd']},0x{d['addr']:x} != "
                        f"{exp_cmd},0x{item.addr:x}")
                if d["bytes"] != exp_bytes:
                    self.errors.append(
                        f"txn#{self.n}: M2P bytes {d['bytes']} != model {exp_bytes}")
                if item.write and d["wdata"] != (item.wdata & 0xFF):
                    self.errors.append(
                        f"txn#{self.n}: decoded wdata 0x{d['wdata']:x} != 0x{item.wdata:x}")
            else:
                self.errors.append(f"txn#{self.n}: responder did not decode a transaction")

            # (b) read data must equal the register model (as tracked by the responder's regs).
            if not item.write:
                is_read = res["is_read"]
                if is_read != 1:
                    self.errors.append(f"txn#{self.n}: rsp_is_read=0 on a read")
                # expected read value = last written value or the deterministic init.
                exp_rd = self._expected_read(item.addr)
                if res["rdata"] != exp_rd:
                    self.errors.append(
                        f"txn#{self.n}: rdata 0x{res['rdata']:02x} != expected 0x{exp_rd:02x}")

            self._track_write(item)
            _sample_mb(item, res, decoded[di - 1] if di else None)
            self.n += 1

        # (c) round-trip: the read of 0x407 (written 0xE1) must have returned 0xE1 -- covered by
        #     (b) since _expected_read tracks the model, but assert the model saw it.
        if self._model.get(0x407 & 0xF) != 0xE1:
            self.errors.append("round-trip model tracking error at 0x407")

        for name in ("top.mb.kind", "top.mb.is_read"):
            pct = coverage_db[name].cover_percentage
            if pct != 100.0:
                self.errors.append(f"coverage {name} = {pct}% (< 100; bin parity gap)")

        self.logger.info(f"[SB-MB] transactions={self.n} decoded={len(decoded)}")
        assert not self.errors, \
            "message-bus cross-check failed:\n  " + "\n  ".join(self.errors)

    # Independent register-model shadow (low nibble index; deterministic 0xA0+i init).
    _model = None

    def _expected_read(self, addr):
        if self._model is None:
            MsgbusScoreboard._model = {i: (0xA0 + i) & 0xFF for i in range(16)}
        return self._model[addr & 0xF]

    def _track_write(self, item):
        if self._model is None:
            MsgbusScoreboard._model = {i: (0xA0 + i) & 0xFF for i in range(16)}
        if item.write:
            self._model[item.addr & 0xF] = item.wdata & 0xFF

    def report_phase(self):
        if not self.errors:
            self.logger.info("[SB-MB] message-bus cross-check PASS (DUT == model, framing OK)")


class MsgbusEnv(uvm_env):
    def build_phase(self):
        self.agent = MsgbusAgent("agent", self)
        self.responder = MsgbusResponder("responder", self)
        self.sb = MsgbusScoreboard("sb", self)

    def connect_phase(self):
        self.agent.driver.ap.connect(self.sb.fifo.analysis_export)
        self.sb.responder = self.responder


@pyuvm.test()
class MsgbusTest(uvm_test):
    def build_phase(self):
        self.env = MsgbusEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
        dut.reset_n.value = 0
        dut.req_valid.value = 0
        dut.req_write.value = 0
        dut.req_committed.value = 0
        dut.req_addr.value = 0
        dut.req_wdata.value = 0
        for _ in range(5):
            await FallingEdge(dut.clk)
        dut.reset_n.value = 1
        for _ in range(3):
            await FallingEdge(dut.clk)

        seqr = ConfigDB().get(self, "", "MB_SEQR")
        await MsgbusSeq("mb_seq").start(seqr)
        for _ in range(10):
            await FallingEdge(dut.clk)
        self.drop_objection()

    # Pass/fail assertions live in MsgbusScoreboard.check_phase (leaf) -- pyuvm check_phase
    # ordering is top-down (see test_datapath.py note).
