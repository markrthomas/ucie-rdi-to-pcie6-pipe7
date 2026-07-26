"""Tier 1b Gen6-wide RX cross-check (closure-plan item 23; deferred item-10 follow-on).

A PyUVM uvm_test injecting raw Gen6 wide words at the PHY RX of the rate-aware datapath
(pipe7_gen6_rx_top wrapper, held in Gen6 data phase) and cross-checking the recovered word
stream against an independent Python model (gen6_model.recover_rx = identity, order-preserving),
using a mirrored injection-order queue. Runs on Verilator/Icarus.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from pyuvm import uvm_test
import pyuvm

from models import gen6_model as gm

WIDTH   = 160
N_WORDS = 24


@pyuvm.test()
class Gen6RxTest(uvm_test):
    def build_phase(self):
        pass

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top

        rng = random.Random(0x6E6A)
        injected = [rng.getrandbits(WIDTH) for _ in range(N_WORDS)]

        cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
        dut.rx_data.value = 0
        dut.rx_valid.value = 0
        dut.reset_n.value = 0
        for _ in range(5):
            await FallingEdge(dut.clk)
        dut.reset_n.value = 1
        for _ in range(3):
            await FallingEdge(dut.clk)   # let the data-phase FSM reach DP_DATA (gen6_mode high)

        recovered = []
        cocotb.start_soon(self._rx_mon(dut, recovered))

        # Inject one raw word per cycle (mirror = injection order).
        for w in injected:
            await FallingEdge(dut.clk)
            dut.rx_data.value = w
            dut.rx_valid.value = 1
        await FallingEdge(dut.clk)
        dut.rx_valid.value = 0
        for _ in range(10):
            await FallingEdge(dut.clk)

        self._check(injected, recovered)
        self.drop_objection()

    async def _rx_mon(self, dut, recovered):
        while True:
            await FallingEdge(dut.clk)
            if int(dut.reset_n.value) == 1 and int(dut.g6_rx_valid.value) == 1:
                recovered.append(int(dut.g6_rx_data.value))

    def _check(self, injected, recovered):
        errors = []
        model = gm.recover_rx(injected)
        n = min(len(recovered), len(model))
        if recovered[:n] != model[:n]:
            first = next((i for i in range(n) if recovered[i] != model[i]), n)
            errors.append(f"Gen6-RX mismatch at word #{first} "
                          f"(recovered {len(recovered)} vs model {len(model)})")
        if len(recovered) < len(injected):
            errors.append(f"only {len(recovered)}/{len(injected)} injected words recovered")
        self.logger.info(f"[SB] injected={len(injected)} recovered={len(recovered)}")
        assert not errors, "Gen6-wide RX cross-check failed:\n  " + "\n  ".join(errors)
        self.logger.info("[SB] Gen6-wide RX cross-check PASS (mirrored-queue agreement)")
