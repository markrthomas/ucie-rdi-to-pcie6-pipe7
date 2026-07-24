"""Tier 1b datapath cross-check test (closure-plan item 13).

A PyUVM uvm_test driving the Gen5 128b/130b framing DUT (pipe7_framing_top) via cocotb, whose
scoreboard cross-checks the RDI<->PIPE payload/framing round-trip against an independent Python
reference model. Runs on Verilator (default) or Icarus -- an actually-executing OSS gate,
unlike the VCS/UVM tier. Run with `make` (or `make datapath`) in this directory.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from pyuvm import uvm_test, ConfigDB
import pyuvm

from pipe7_pyuvm_env import Pipe7DatapathEnv
from seq_lib.pipe7_seq_lib import DatapathSeq

N_BLOCKS = 32


@pyuvm.test()
class DatapathTest(uvm_test):
    def build_phase(self):
        self.env = Pipe7DatapathEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top

        cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
        dut.reset_n.value = 0
        dut.pl_valid_i.value = 0
        dut.pl_data_i.value = 0
        dut.pl_is_os_i.value = 0
        for _ in range(5):
            await FallingEdge(dut.clk)
        dut.reset_n.value = 1
        for _ in range(2):
            await FallingEdge(dut.clk)

        seqr = ConfigDB().get(self, "", "SEQR")
        seq = DatapathSeq("seq", n=N_BLOCKS)
        await seq.start(seqr)

        # Let the framer drain its final buffered blocks so every payload is recovered.
        for _ in range(60):
            await FallingEdge(dut.clk)

        self._export_vectors(seq.vectors)
        self.drop_objection()

    def _export_vectors(self, vectors):
        """Dump the driven golden vectors so the SV/UVM env can consume the same stimulus."""
        try:
            path = os.path.join(os.path.dirname(__file__), "vectors", "datapath_vectors.txt")
            with open(path, "w") as f:
                f.write("# data_hex is_os  (Gen5 128b/130b datapath golden vectors)\n")
                for data, is_os in vectors:
                    f.write(f"{data:032x} {int(is_os)}\n")
        except OSError:
            pass

    # Pass/fail assertions live in DatapathScoreboard.check_phase (a leaf) -- pyuvm runs
    # check_phase top-down, so the test's own check_phase would read scoreboard results before
    # the scoreboard computes them.
