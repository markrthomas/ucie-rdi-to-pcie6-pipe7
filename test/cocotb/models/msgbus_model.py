"""Independent message-bus (M2P/P2M) framing + register model (item 14).

Encodes the M2P byte framing the master should drive and models the PHY-side register space,
written independently of the RTL (pipe7_msgbus_master / pipe7_msgbus_responder_stub). Framing
(PIPE 7.1 Sec 6.1.4.2): byte0 = {cmd[3:0], Addr[11:8]}, then Addr[7:0], then Data[7:0] for
writes; read = 2 bytes, write = 3 bytes; read_completion = {READ_COMPLETION,0}, Data.
"""

MB_NOP = 0x0
MB_WRITE_UNCOMMIT = 0x1
MB_WRITE_COMMIT = 0x2
MB_READ = 0x3
MB_READ_COMPLETION = 0x4
MB_WRITE_ACK = 0x5


def cmd_of(write: bool, committed: bool) -> int:
    if not write:
        return MB_READ
    return MB_WRITE_COMMIT if committed else MB_WRITE_UNCOMMIT


def encode_m2p(write: bool, committed: bool, addr: int, wdata: int):
    """Return the list of M2P bytes the master should drive for this transaction."""
    cmd = cmd_of(write, committed)
    b0 = ((cmd & 0xF) << 4) | ((addr >> 8) & 0xF)
    b1 = addr & 0xFF
    if write:
        return [b0, b1, wdata & 0xFF]
    return [b0, b1]


class RegModel:
    """PHY-side register space, initialised like pipe7_msgbus_responder_stub (mem[i]=0xA0+i by
    the low address nibble) so reads of un-written addresses are deterministic."""
    def __init__(self, mem_bits: int = 4):
        self.mem_bits = mem_bits
        self.mask = (1 << mem_bits) - 1
        self.regs = {i: (0xA0 + i) & 0xFF for i in range(1 << mem_bits)}

    def write(self, addr: int, data: int):
        self.regs[addr & self.mask] = data & 0xFF

    def read(self, addr: int) -> int:
        return self.regs[addr & self.mask]
