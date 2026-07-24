"""PyUVM control-plane agent (item 14): drives PowerDown/Rate/Width requests into
pipe7_mac_ctrl_fsm (via pipe7_ctrl_top) and publishes the observed outcome for the scoreboard.
Mirrors the Tier-2 UVM taxonomy (item / driver / sequencer / agent)."""
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge
from pyuvm import (uvm_sequence_item, uvm_driver, uvm_agent, uvm_sequencer,
                   uvm_analysis_port, ConfigDB)


class CtrlItem(uvm_sequence_item):
    def __init__(self, name="CtrlItem", kind=0, pd=0, rate=4, width=4, rxw=4):
        super().__init__(name)
        self.kind = kind
        self.pd = pd
        self.rate = rate
        self.width = width
        self.rxw = rxw


class CtrlDriver(uvm_driver):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        while True:
            item = await self.seq_item_port.get_next_item()
            outcome, state = await self._drive(dut, item)
            self.ap.write((item, outcome, state))
            self.seq_item_port.item_done()

    async def _drive(self, dut, item):
        await FallingEdge(dut.clk)
        dut.req_kind.value = item.kind
        dut.req_power_down.value = item.pd
        dut.req_rate.value = item.rate
        dut.req_width.value = item.width
        dut.req_rxwidth.value = item.rxw
        dut.req_valid.value = 1
        await FallingEdge(dut.clk)
        dut.req_valid.value = 0
        # Wait for the single-cycle done / req_error pulse (settled read on negedge).
        outcome = None
        for _ in range(200):
            if int(dut.done.value) == 1:
                outcome = "done"
                break
            if int(dut.req_error.value) == 1:
                outcome = "reject"
                break
            await FallingEdge(dut.clk)
        state = dict(pd=int(dut.power_down.value), rate=int(dut.rate.value),
                     width=int(dut.width.value), rxw=int(dut.rx_width.value))
        return outcome, state


class CtrlAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = CtrlDriver("driver", self)
        ConfigDB().set(None, "*", "CTRL_SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
