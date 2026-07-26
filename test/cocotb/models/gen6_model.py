"""Independent Python reference model for the Gen6 (Rate=5) raw wide RX datapath.

Tier 1b (PyUVM-on-cocotb) cross-check, closure-plan item 23. Item 0 established that the Gen6
PIPE datapath carries NO 128b/130b sync header and does NO block alignment: it is a registered
wide pass-through (word boundaries are an above-PIPE / controller concern; FEC/LCRC/PAM4
precoding are elsewhere). So the RX recovery is the identity over the injected word stream,
order-preserving. Written independently of the RTL so a common-mode assumption cannot pass.
"""


def recover_rx(words):
    """Model the Gen6 RX recovery of a list of injected raw words: identity, in order."""
    return list(words)
