"""Independent Python reference model for the UCIe RDI flit <-> 128b block mapping.

Tier 1b (PyUVM-on-cocotb) integrated-bridge cross-check, closure-plan item 23. Mirrors the RTL
packing of pipe7_rdi_ingress / pipe7_rdi_egress exactly (documented there):

    a block payload is BLOCK_PAYLOAD (128) bits = FPB (128/RDI_WIDTH) flit words;
    word 0 (the sob=1 word) sits in the low bits, so
        block128 = word0 | (word1 << RDI_WIDTH) | ...
    the block type (is_os) travels on the sob word and the egress replicates it to every word.

Written independently of the SV RTL and the SV scoreboard so a common-mode packing assumption
cannot pass silently.
"""
BLOCK_PAYLOAD = 128


def blocks_to_flits(blocks, rdi_width: int = 64):
    """Split (data128, is_os) blocks into (data, sob, is_os) flit words, sob on word 0."""
    fpb = BLOCK_PAYLOAD // rdi_width
    mask = (1 << rdi_width) - 1
    flits = []
    for data, is_os in blocks:
        for i in range(fpb):
            word = (data >> (i * rdi_width)) & mask
            flits.append((word, i == 0, bool(is_os)))
    return flits


def flits_to_blocks(flits, rdi_width: int = 64):
    """Reassemble (data, sob, is_os) flit words into (data128, is_os) blocks (inverse packing)."""
    fpb = BLOCK_PAYLOAD // rdi_width
    blocks = []
    for base in range(0, len(flits) - fpb + 1, fpb):
        data = 0
        for i in range(fpb):
            word, _sob, _os = flits[base + i]
            data |= (word & ((1 << rdi_width) - 1)) << (i * rdi_width)
        blocks.append((data, flits[base][2]))   # is_os from the sob word
    return blocks
