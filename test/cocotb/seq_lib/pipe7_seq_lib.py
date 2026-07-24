"""PyUVM sequence library (item 13). Shares test intent with the SV/UVM sequences: a stream
of random 128-bit payloads tagged data/ordered-set. Seeded so the exact vectors are
reproducible and exportable for the SV env (shared-golden-vector cross-check mode)."""
import random
from pyuvm import uvm_sequence

from agents.ucie_rdi_agent import PayloadItem
from agents.ctrl_agent import CtrlItem
from agents.msgbus_agent import MsgbusItem
from models.ctrl_plane_model import (PD_P0, PD_P0S, PD_P1, PD_P2, RATE_GEN5, RATE_GEN6,
                                      W_80, W_160, REQ_POWER, REQ_RATE, REQ_WIDTH)


class DatapathSeq(uvm_sequence):
    def __init__(self, name="DatapathSeq", n=32, seed=0xC0FFEE):
        super().__init__(name)
        self.n = n
        self.seed = seed
        self.vectors = []   # [(data, is_os)] actually driven -- exportable golden vectors

    async def body(self):
        rng = random.Random(self.seed)
        for _ in range(self.n):
            data = rng.getrandbits(128)
            is_os = bool(rng.getrandbits(1))
            self.vectors.append((data, is_os))
            item = PayloadItem("it", data, is_os)
            await self.start_item(item)
            await self.finish_item(item)


class CtrlSeq(uvm_sequence):
    """Shared test intent with the SV item-3 smoke: power ladder, Gen5<->Gen6 rate changes, a
    Width change, and two illegal Rate changes (in P2 and P0s) that must be rejected."""
    # (kind, pd, rate, width, rxw). For RATE/WIDTH the FSM checks its *current* power state;
    # pd here is the current state for readability and is ignored by the FSM for those kinds.
    REQUESTS = [
        (REQ_POWER, PD_P0S, RATE_GEN5, W_160, W_160),
        (REQ_POWER, PD_P1,  RATE_GEN5, W_160, W_160),
        (REQ_POWER, PD_P2,  RATE_GEN5, W_160, W_160),
        (REQ_POWER, PD_P0,  RATE_GEN5, W_160, W_160),
        (REQ_RATE,  PD_P0,  RATE_GEN6, W_160, W_160),
        (REQ_RATE,  PD_P0,  RATE_GEN5, W_160, W_160),
        (REQ_WIDTH, PD_P0,  RATE_GEN5, W_80,  W_80),
        (REQ_POWER, PD_P2,  RATE_GEN5, W_80,  W_80),
        (REQ_RATE,  PD_P2,  RATE_GEN6, W_80,  W_80),   # illegal in P2 -> reject
        (REQ_POWER, PD_P0,  RATE_GEN5, W_80,  W_80),
        (REQ_POWER, PD_P0S, RATE_GEN5, W_80,  W_80),
        (REQ_RATE,  PD_P0S, RATE_GEN6, W_80,  W_80),   # illegal in P0s -> reject
        (REQ_POWER, PD_P0,  RATE_GEN5, W_80,  W_80),
    ]

    async def body(self):
        for kind, pd, rate, width, rxw in self.REQUESTS:
            item = CtrlItem("ctrl", kind, pd, rate, width, rxw)
            await self.start_item(item)
            await self.finish_item(item)


class MsgbusSeq(uvm_sequence):
    """Shared test intent with the SV item-4 smoke: uncommitted/committed writes, a read of a
    preloaded address, and a committed-write -> read round-trip."""
    # (write, committed, addr, wdata)
    REQUESTS = [
        (True,  False, 0x401, 0x5A),
        (True,  True,  0x402, 0x3C),
        (False, False, 0x405, 0x00),
        (True,  True,  0x407, 0xE1),
        (False, False, 0x407, 0x00),
    ]

    async def body(self):
        for write, committed, addr, wdata in self.REQUESTS:
            item = MsgbusItem("mb", write, committed, addr, wdata)
            await self.start_item(item)
            await self.finish_item(item)
