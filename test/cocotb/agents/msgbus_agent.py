"""PyUVM message-bus agent (item 14): drives register read/write transactions into
pipe7_msgbus_master (via pipe7_msgbus_top) and publishes the response for the scoreboard."""
import cocotb
from cocotb.triggers import FallingEdge
from pyuvm import (uvm_sequence_item, uvm_driver, uvm_agent, uvm_sequencer,
                   uvm_analysis_port, ConfigDB)


class MsgbusItem(uvm_sequence_item):
    def __init__(self, name="MsgbusItem", write=False, committed=False, addr=0, wdata=0):
        super().__init__(name)
        self.write = write
        self.committed = committed
        self.addr = addr
        self.wdata = wdata


class MsgbusDriver(uvm_driver):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        while True:
            item = await self.seq_item_port.get_next_item()
            result = await self._drive(dut, item)
            self.ap.write((item, result))
            self.seq_item_port.item_done()

    async def _drive(self, dut, item):
        await FallingEdge(dut.clk)
        dut.req_write.value = int(item.write)
        dut.req_committed.value = int(item.committed)
        dut.req_addr.value = item.addr
        dut.req_wdata.value = item.wdata
        dut.req_valid.value = 1
        await FallingEdge(dut.clk)
        dut.req_valid.value = 0
        completed = False
        is_read = 0
        rdata = 0
        for _ in range(300):
            if int(dut.rsp_valid.value) == 1:
                completed = True
                is_read = int(dut.rsp_is_read.value)
                rdata = int(dut.rsp_rdata.value)
                break
            await FallingEdge(dut.clk)
        return dict(completed=completed, is_read=is_read, rdata=rdata)


class MsgbusAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = MsgbusDriver("driver", self)
        ConfigDB().set(None, "*", "MB_SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
