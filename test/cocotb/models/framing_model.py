"""Independent Python reference model for the Gen5 128b/130b MAC-owned framing.

Tier 1b (PyUVM-on-cocotb) cross-check, closure-plan item 13. This is written independently
of the SV RTL (pipe7_tx_framer / pipe7_rx_deframer) and the SV scoreboard -- the whole point
is implementation diversity, so a common-mode framing assumption baked into both the DUT and
its SV checker cannot pass silently. It mirrors the RTL bit order exactly (documented in
pipe7_tx_framer.sv):

    block[1:0]   = sync header  (data = 0b10, ordered-set = 0b01)
    block[129:2] = 128-bit payload
    the bitstream is LSB-first; a PIPE word's bit 0 is the oldest bit emitted.

The framer emits a width-bit word only once >= width bits have accumulated (matching the RTL's
`tx_data_valid <= (fill >= PIPE_WIDTH)`), so trailing < width bits are not emitted.
"""

SYNC_DATA = 0b10   # PCIe 128b/130b data block
SYNC_OS   = 0b01   # ordered-set block
BLOCK_PAYLOAD = 128
BLOCK_BITS = 130


def build_block(data128: int, is_os: bool) -> int:
    """Return the 130-bit block integer {payload, sync}, bit0 = sync[0]."""
    sync = SYNC_OS if is_os else SYNC_DATA
    return ((data128 & ((1 << BLOCK_PAYLOAD) - 1)) << 2) | sync


def frame_stream(payloads, width: int):
    """Serialize (data, is_os) payloads into a list of width-bit PIPE words (LSB-first).

    Matches the RTL framer: a word is produced only when >= width bits are buffered.
    """
    mask = (1 << width) - 1
    bits = 0
    nbits = 0
    words = []
    for data, is_os in payloads:
        bits |= build_block(data, is_os) << nbits
        nbits += BLOCK_BITS
        while nbits >= width:
            words.append(bits & mask)
            bits >>= width
            nbits -= width
    return words


def deframe_stream(words, width: int, nblocks: int):
    """Recover up to nblocks (data, is_os) payloads from a list of width-bit PIPE words.

    Independent of the RTL deframer; used to cross-check the DUT's recovered payloads and to
    check sync-header legality. Assumes an aligned stream (as the framer produces).
    """
    block_mask = (1 << BLOCK_BITS) - 1
    bits = 0
    nbits = 0
    out = []
    for w in words:
        bits |= (w & ((1 << width) - 1)) << nbits
        nbits += width
        while nbits >= BLOCK_BITS and len(out) < nblocks:
            blk = bits & block_mask
            sync = blk & 0b11
            data = blk >> 2
            out.append((data, sync == SYNC_OS, sync))
            bits >>= BLOCK_BITS
            nbits -= BLOCK_BITS
    return out


def sync_is_legal(sync: int) -> bool:
    return sync in (SYNC_DATA, SYNC_OS)
