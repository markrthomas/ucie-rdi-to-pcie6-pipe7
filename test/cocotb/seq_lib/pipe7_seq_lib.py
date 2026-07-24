"""PyUVM sequence library (item 13). Shares test intent with the SV/UVM sequences: a stream
of random 128-bit payloads tagged data/ordered-set. Seeded so the exact vectors are
reproducible and exportable for the SV env (shared-golden-vector cross-check mode)."""
import random
from pyuvm import uvm_sequence

from agents.ucie_rdi_agent import PayloadItem


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
