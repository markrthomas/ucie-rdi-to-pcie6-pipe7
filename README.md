# ucie-rdi-to-pcie6-pipe7

UCIe 1.0 RDI ↔ **PCIe 6.x / PIPE 7.1 MAC-facing** bridge IP (Gen5 + Gen6).

This is a ground-up successor to a UCIe-RDI-to-"PIPE" CDC bridge whose downstream port was
a generic valid/ready stub. Here the PIPE side is a **real PIPE 7.1 MAC-facing interface**:
the bridge plays the MAC/controller role and talks to a PIPE PHY over the **SerDes
Architecture** (async interface with the 8-bit M2P/P2M message bus carrying most
control/status), supporting **Gen5 (32 GT/s, 128b/130b)** and **Gen6 (64 GT/s, PAM4 FLIT)**.

## Status

Integrated IP complete. Execution followed [`PLAN.md`](PLAN.md) as a phased closure plan, one
numbered item per commit. **Item 0 (spec cross-check)** reconciled every placeholder constant
against the controlled Intel PIPE 7.1 specification; the cores (items 1–15) and the **integrated
bridge + all-tier verification** (items 16–25: full-width gearbox, rate-aware datapath, credit-
based UCIe RDI, RDI↔PCLK CDC, the integrated `ucie_rdi_to_pipe7_mac_bridge` top, and the
Verilator / PyUVM / UVM / formal tiers) are delivered, with the Verilator gate green per commit.

## Scope

- **MAC-facing only** — drive MAC-owned signals, react to PHY-owned ones; PHY internals
  (SerDes, PAM4 precoding math, CDR, elec-idle detection) are out of scope.
- **Rates:** Gen5 + Gen6 only (no legacy Gen1–4 ladder).
- **FEC / flit-LCRC:** controller/RDI-side, not implemented at the PIPE interface.

## Verification

Two-tier, mirroring the predecessor's methodology:

- **Verilator** — open-source CI gate (`make regress`): lint + the integrated-bridge end-to-end
  smoke (RDI round-trip + control + message bus, assertions bound) plus per-block self-checking
  smokes (control FSM, message bus, Gen5 framing + full-width gearbox, Gen6 datapath, rate-aware
  datapath, RDI credit FC, CDC, protocol SVA), a reduced-config param smoke, and line coverage
  (`make regress_cov`; baseline **~89% line (643/723)** on the integrated bridge).
- **PyUVM-on-Cocotb** — runnable cross-check (`make cocotb`, a required CI gate): independent
  Python models cross-check the datapath, control plane, and message bus, **plus the integrated
  bridge end-to-end** (`test_bridge.py`, 3-way) and a **Gen6-wide RX** check (`test_gen6_rx.py`).
- **Formal (SymbiYosys)** — `make formal`: four BMC + cover proofs — CDC-buffer invariants, RDI
  credit-FC (no underflow / over-credit), the Gen5 gearbox accept/accumulator bounds, and the
  rate-aware datapath control (TxElecIdle gating, rate-mux exclusivity, data-phase-only-from-P0).
- **UVM (VCS/UVM 1.2)** — authored-and-review-validated growth path (`make uvm`), retargeted at
  the integrated bridge (credit/flit RDI, dual-clock) with a **Gen6-wide RX** agent + mirrored-
  queue scoreboard, alongside the control/message-bus agents, PHY-responder BFM, and covergroups.

See [`docs/`](docs/) and [`PLAN.md`](PLAN.md) for architecture, interface contract, and the
verification plan.

## Build / developer workflow

`make` (no target) prints a grouped list of targets. Common ones:

- `make regress` — release gate (lint + every Verilator smoke).
- `make cocotb` — Tier 1b PyUVM-on-Cocotb cross-checks (datapath + control-plane + message-bus).
- `make waves WAVE_TB=framing|ctrl|msgbus|gen6|assn` — build+run a testbench with tracing to
  `waves/<tb>.vcd`; `make gtkwave WAVE_TB=...` opens it in GTKWave with the saved
  [`waves/<tb>.gtkw`](waves/) signal layout.
- `make ci` — the full local run (regress + coverage + NL1 + docs check).
