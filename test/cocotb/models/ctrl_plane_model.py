"""Independent control-plane legality model (item 14).

Predicts, for each PowerDown/Rate/Width request, whether pipe7_mac_ctrl_fsm should complete
(done) or reject it (req_error), and the resulting command-signal state. Written independently
of the RTL FSM. Encodings mirror pipe7_pkg (PowerDown/Rate/Width). Rule (PIPE 7.1 Sec 8.4.1):
a Rate/Width change is legal only in PowerDown P0 or P1; otherwise it is rejected with no change.
"""

# PowerDown
PD_P0, PD_P0S, PD_P1, PD_P2 = 0, 1, 2, 3
# Rate
RATE_GEN5, RATE_GEN6 = 4, 5
# Width
W_80, W_160 = 3, 4
# Request kind (ctrl_req_e)
REQ_POWER, REQ_RATE, REQ_WIDTH = 0, 1, 2

_RW_LEGAL = (PD_P0, PD_P1)


class CtrlModel:
    def __init__(self):
        # pipe7_mac_ctrl_fsm reset defaults.
        self.pd = PD_P0
        self.rate = RATE_GEN5
        self.width = W_160
        self.rxw = W_160

    def state(self):
        return dict(pd=self.pd, rate=self.rate, width=self.width, rxw=self.rxw)

    def predict(self, kind, pd, rate, width, rxw):
        """Return ('done'|'reject', expected_state_after)."""
        if kind == REQ_POWER:
            self.pd = pd
            return "done", self.state()
        if kind in (REQ_RATE, REQ_WIDTH):
            if self.pd in _RW_LEGAL:
                if kind == REQ_RATE:
                    self.rate = rate
                else:
                    self.width = width
                    self.rxw = rxw
                return "done", self.state()
            return "reject", self.state()   # illegal PowerDown: no change
        return "reject", self.state()
