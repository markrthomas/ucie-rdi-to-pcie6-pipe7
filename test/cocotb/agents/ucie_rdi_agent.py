"""PyUVM RDI-side agent for the Tier 1b datapath cross-check (closure-plan item 13).

Mirrors the Tier-2 SV/UVM taxonomy (sequence_item / driver / monitor / sequencer / agent) so
the two envs share test intent 1:1. The active agent drives 128-bit payloads into the Gen5
framer (pipe7_framing_top wrapper) and an output monitor observes the recovered payloads and
the raw PIPE TxData stream for the independent-model cross-check.
"""
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from pyuvm import (uvm_sequence_item, uvm_driver, uvm_monitor, uvm_agent,
                   uvm_sequencer, uvm_analysis_port, ConfigDB)


class PayloadItem(uvm_sequence_item):
    """One 128-bit block payload tagged data (0) or ordered-set (1)."""
    def __init__(self, name="PayloadItem", data=0, is_os=False):
        super().__init__(name)
        self.data = data
        self.is_os = is_os

    def __str__(self):
        return f"PayloadItem(data=0x{self.data:032x}, is_os={int(self.is_os)})"


class RdiDriver(uvm_driver):
    """Drives payloads into the framer with the race-free single-accept handshake proven in
    the SV testbench (assert valid on negedge, hold until a negedge shows pl_ready, let exactly
    the next posedge accept, deassert). Publishes each accepted item as the 'expected' stream."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        while True:
            item = await self.seq_item_port.get_next_item()
            await self._drive(dut, item)
            self.ap.write((item.data, bool(item.is_os)))
            self.seq_item_port.item_done()

    async def _drive(self, dut, item):
        await FallingEdge(dut.clk)
        dut.pl_data_i.value = item.data
        dut.pl_is_os_i.value = int(item.is_os)
        dut.pl_valid_i.value = 1
        await Timer(1, units="ns")            # let pl_ready (comb) settle
        while int(dut.pl_ready_i.value) == 0:
            await FallingEdge(dut.clk)
            await Timer(1, units="ns")
        await RisingEdge(dut.clk)             # single accepting edge
        await FallingEdge(dut.clk)
        dut.pl_valid_i.value = 0


class RdiOutMonitor(uvm_monitor):
    """Samples (settled, on negedge) the recovered payloads and the raw PIPE TxData stream.
    Publishes recovered (data, is_os) on `ap` and each valid TxData word on `stream_ap`; also
    tracks whether the DUT ever raised sync_error (should never happen on a clean link)."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.stream_ap = uvm_analysis_port("stream_ap", self)
        self.sync_errors = 0
        self.saw_lock = False

    async def run_phase(self):
        dut = cocotb.top
        while True:
            await FallingEdge(dut.clk)
            if int(dut.reset_n.value) != 1:
                continue
            if int(dut.tx_data_valid.value) == 1:
                self.stream_ap.write(int(dut.tx_data.value))
            if int(dut.pl_valid_o.value) == 1:
                self.ap.write((int(dut.pl_data_o.value), bool(int(dut.pl_is_os_o.value))))
            if int(dut.sync_error.value) == 1:
                self.sync_errors += 1
            if int(dut.block_locked.value) == 1:
                self.saw_lock = True


class RdiAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = RdiDriver("driver", self)
        self.out_mon = RdiOutMonitor("out_mon", self)
        ConfigDB().set(None, "*", "SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
