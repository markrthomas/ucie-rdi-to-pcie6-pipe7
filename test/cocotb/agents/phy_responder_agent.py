"""Independently-authored PyUVM PHY-side responders (item 14).

Mirror the *role* of the SV/UVM phy_responder_agent (spec-timed PhyStatus / P2M) but are a
separate implementation in Python -- so the control-plane and message-bus proofs are
corroborated by a responder written independently of the SV pipe7_phy_responder_stub /
pipe7_msgbus_responder_stub.
"""
import cocotb
from cocotb.triggers import RisingEdge
from pyuvm import uvm_component

from models.msgbus_model import (RegModel, MB_READ, MB_WRITE_UNCOMMIT, MB_WRITE_COMMIT,
                                  MB_READ_COMPLETION, MB_WRITE_ACK)


class PhyStatusResponder(uvm_component):
    """Watches the MAC command signals (PowerDown/Rate/Width/RxWidth) and answers each change
    with a single-cycle PhyStatus after `latency` cycles (PCLK-as-PHY-output)."""
    def build_phase(self):
        self.latency = 4

    @staticmethod
    def _snap(dut):
        return (int(dut.power_down.value), int(dut.rate.value),
                int(dut.width.value), int(dut.rx_width.value))

    async def run_phase(self):
        dut = cocotb.top
        dut.phy_status.value = 0
        if hasattr(dut, "pclk_change_ok"):
            dut.pclk_change_ok.value = 0
        prev = self._snap(dut)
        servicing = False
        cnt = 0
        while True:
            await RisingEdge(dut.clk)
            dut.phy_status.value = 0
            if int(dut.reset_n.value) != 1:
                prev = self._snap(dut)
                servicing = False
                continue
            cur = self._snap(dut)
            if not servicing:
                if cur != prev:
                    prev = cur
                    servicing = True
                    cnt = self.latency
            else:
                if cnt > 1:
                    cnt -= 1
                else:
                    dut.phy_status.value = 1
                    servicing = False


class MsgbusResponder(uvm_component):
    """Independently decodes the M2P framing the master drives and answers on P2M: reads get a
    read_completion (2 bytes) with data from a local register model; committed writes get a
    write_ack; uncommitted writes get no response. Records each decoded transaction (and the
    exact bytes consumed) for the scoreboard's framing cross-check."""
    def build_phase(self):
        self.latency = 3
        self.reg = RegModel(mem_bits=4)
        self.transactions = []   # [{cmd, addr, wdata, bytes}]

    async def run_phase(self):
        dut = cocotb.top
        dut.p2m.value = 0
        state = "IDLE"
        cmd = addr_hi = addr = 0
        committed = False
        seen = []
        cnt = 0
        while True:
            await RisingEdge(dut.clk)
            dut.p2m.value = 0
            if int(dut.reset_n.value) != 1:
                state = "IDLE"
                continue
            m = int(dut.m2p.value)

            if state == "IDLE":
                if m != 0:
                    cmd = (m >> 4) & 0xF
                    addr_hi = m & 0xF
                    seen = [m]
                    if cmd == MB_READ:
                        state = "RD_LO"
                    elif cmd in (MB_WRITE_UNCOMMIT, MB_WRITE_COMMIT):
                        committed = (cmd == MB_WRITE_COMMIT)
                        state = "WR_LO"
            elif state == "RD_LO":
                addr = (addr_hi << 8) | m
                seen.append(m)
                cnt = self.latency
                state = "RC_DELAY"
            elif state == "RC_DELAY":
                if cnt > 1:
                    cnt -= 1
                else:
                    dut.p2m.value = (MB_READ_COMPLETION << 4)
                    state = "RC_DATA"
            elif state == "RC_DATA":
                dut.p2m.value = self.reg.read(addr)
                self.transactions.append(dict(cmd=MB_READ, addr=addr, wdata=None, bytes=seen))
                state = "IDLE"
            elif state == "WR_LO":
                addr = (addr_hi << 8) | m
                seen.append(m)
                state = "WR_DATA"
            elif state == "WR_DATA":
                seen.append(m)
                self.reg.write(addr, m)
                self.transactions.append(
                    dict(cmd=(MB_WRITE_COMMIT if committed else MB_WRITE_UNCOMMIT),
                         addr=addr, wdata=m, bytes=list(seen)))
                if committed:
                    cnt = self.latency
                    state = "WACK_DELAY"
                else:
                    state = "IDLE"
            elif state == "WACK_DELAY":
                if cnt > 1:
                    cnt -= 1
                else:
                    dut.p2m.value = (MB_WRITE_ACK << 4)
                    state = "IDLE"
