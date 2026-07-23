# ucie-rdi-to-pcie6-pipe7

UCIe 1.0 RDI ↔ **PCIe 6.x / PIPE 7.1 MAC-facing** bridge IP (Gen5 + Gen6).

This is a ground-up successor to a UCIe-RDI-to-"PIPE" CDC bridge whose downstream port was
a generic valid/ready stub. Here the PIPE side is a **real PIPE 7.1 MAC-facing interface**:
the bridge plays the MAC/controller role and talks to a PIPE PHY over the **SerDes
Architecture** (async interface with the 8-bit M2P/P2M message bus carrying most
control/status), supporting **Gen5 (32 GT/s, 128b/130b)** and **Gen6 (64 GT/s, PAM4 FLIT)**.

## Status

Bring-up in progress. Execution follows [`PLAN.md`](PLAN.md) as a phased closure plan, one
numbered item per commit. **Item 0 (spec cross-check)** must reconcile every placeholder
constant against the controlled Intel PIPE 7.1 specification before interface/register
detail is frozen (blocks items 2–12).

## Scope

- **MAC-facing only** — drive MAC-owned signals, react to PHY-owned ones; PHY internals
  (SerDes, PAM4 precoding math, CDR, elec-idle detection) are out of scope.
- **Rates:** Gen5 + Gen6 only (no legacy Gen1–4 ladder).
- **FEC / flit-LCRC:** controller/RDI-side, not implemented at the PIPE interface.

## Verification

Two-tier, mirroring the predecessor's methodology:

- **Verilator** — open-source CI gate (`make regress`), lint + smoke + scoreboard, plus a
  `NUM_LANES=1` param smoke and line coverage (`make regress_cov`).
- **UVM (VCS/UVM 1.2)** — authored-and-review-validated growth path (`make uvm`), including
  a PHY-responder BFM that answers PowerDown/Rate/Width requests with spec-timed `PhyStatus`.

See [`docs/`](docs/) and [`PLAN.md`](PLAN.md) for architecture, interface contract, and the
verification plan.
