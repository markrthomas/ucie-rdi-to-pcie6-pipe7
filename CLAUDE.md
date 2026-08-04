# CLAUDE.md — ucie-rdi-to-pcie6-pipe7

Orientation for a Claude Code session working in this repo.

## What this is

A ground-up **UCIe 1.0 RDI ↔ PCIe 6.x / PIPE 7.1 MAC-facing** bridge IP (Gen5 + Gen6).
Successor to a predecessor whose "PIPE" port was only a generic valid/ready stub; here the
PIPE side is a real MAC-facing interface. Full design intent, locked scope decisions, and
the phased build-out are in **`PLAN.md`** — read it first.

## Locked scope (do not re-litigate)

- **SerDes Architecture** (async PHY interface; 8-bit M2P/P2M message bus carries most control/status).
- **Gen5 + Gen6 only** — 32 GT/s 128b/130b and 64 GT/s PAM4 FLIT. No legacy Gen1–4.
- **MAC-facing only** — drive MAC-owned signals, react to PHY-owned ones; no PHY internals
  (SerDes, PAM4 precoding math, CDR, elec-idle detection). FEC/flit-LCRC are controller-side.

## Workflow

- Execute `PLAN.md` as a **numbered closure plan, one item per commit**. The plan has grown
  well past the original 0–12: items 0–14 (cores + three DV tiers), 15–25 (integrated IP +
  all-tier verification), and 26–49 (hardening: correctness guards, formal-on-real-RTL,
  coverage closure to 98.3%, independent functional-coverage DV, randomized waveform suite).
  **All items 0–49 are delivered.**
- **Item 0 (spec cross-check) is COMPLETE** (2026-07-23). The errata sheet
  `docs/pipe71_spec_crosscheck.md` is reconciled against the controlled **Intel PIPE 7.1
  spec (Ref 643108, Rev 7.1, Sep 2025)** + PCIe 6.x base; corrections are folded into
  `PLAN.md` and `src/pipe7_pkg.sv`. The interface, register map, and encodings are frozen.
- `src/pipe7_pkg.sv` encodings are no longer placeholders — they carry the item-0 verdicts.

## Current state

**Functionally complete, three-tier-verified IP. All plan items 0–49 delivered; Verilator
gate green** (`make lint` clean, `make regress` → all smokes PASS incl. `[BRIDGE] PASS` and
the randomized suite `[RND *] PASS`). Last commit: `7cbd0e0` (Item 49, Phase H).

- **Design (`src/`):** integrated top `ucie_rdi_to_pipe7_mac_bridge.sv` composing RDI
  ingress/egress (+credit FC) → RDI↔PCLK CDC → rate-aware MAC datapath
  (`pipe7_mac_datapath_ra`: Gen5 128b/130b full-width gearbox `pipe7_tx_framer_gb`/
  `pipe7_rx_deframer_gb` up to 2 blocks/PCLK + `pipe7_rx_burst_fifo`; Gen6 raw wide plane
  `pipe7_gen6_datapath`) → PIPE MAC, with control FSM (`pipe7_mac_ctrl_fsm`, PhyStatus-gated
  + completion watchdog), message-bus master + regfile (`pipe7_msgbus_master`/`pipe7_regfile`,
  PAM4RestrictedLevels write-through), and bound SVA. Overflow/accumulator guards in place.
- **Verification:** Tier 1 Verilator smoke suite (integrated + NL1 + directed error-path +
  Phase H randomized waveform TBs), **DUT line coverage 651/662 = 98.34%**; Tier 1b
  PyUVM-on-Cocotb cross-check (`make cocotb`, Verilator); Phase G independent functional
  coverage on **Icarus** via `cocotb_coverage` (`make fcov`, **45/45 = 100%**); Tier 2
  UVM (VCS) authored/review-validated; formal (`make formal`) — CDC multiclock, RDI credit
  FC, gearbox bounds, deframer guard on real RTL via yosys-slang. Perf/KPI report via
  `make report`.
- **Next:** hardening backlog residuals only — notably **runtime sub-width lane selection**
  (drive low-N lanes within `PIPE_WIDTH` from `Width`/`RxWidth`), deferred in item 30. No
  open correctness items. Check `PLAN.md` "Hardening backlog" for anything reopened.

## Verification

Three-tier (see `docs/verification_plan.md`):

- **Tier 1 — Verilator = the open-source gate** (toolchain: oss-cad-suite on PATH —
  `verilator`, `iverilog`, `sby`). Per commit keep green:
  - `make lint` (RTL strict `-Wall`; TB passes waive UNUSEDSIGNAL/UNDRIVEN — externally-driven TB clocks)
  - `make regress` — the full smoke suite (integrated `[BRIDGE] PASS`, framing/gearbox,
    ctrl/msgbus, Gen6, error-path, and the Phase H `[RND *] PASS` randomized TBs)
  - `make regress_nl1` → `[BRIDGE MIN] PASS` (NUM_LANES=1) · `make regress_cov` → line coverage
  - `make coverage_merge` → union DUT-`src/` line coverage (**651/662 = 98.34%** baseline)
- **Tier 1b — PyUVM-on-Cocotb cross-check**, *runnable here*: `make cocotb` (Verilator).
  Phase G adds an independent functional-coverage cross-check on **Icarus**:
  `make fcov` (`cocotb_coverage`, **45/45 = 100%** bins).
- **Tier 2 — UVM (VCS/UVM 1.2) is authored-and-review-validated, NOT run here** — no VCS in
  this environment. Validate UVM by review; the Verilator gate is what actually runs.
- **Power-aware (UPF) — `test/upf/`, authored-and-review-validated, NOT run here.** IEEE-1801
  power intent (always-on ctrl/msgbus `PD_AON` + switchable datapath `PD_DP` with power switch,
  isolation, and config-regfile retention) + a P0→P2→P0 power-aware test. No OSS tool models UPF
  semantics; the real run is `make upf` (VCS `-upf`). `make verilator_upf` builds the same TB as a
  skeleton (elaboration + control/PMU/data, no power intent) and IS in `regress`. Docs:
  `docs/power_intent.md`.
- **Formal:** `make formal` (SymbiYosys; CDC multiclock, RDI credit FC, gearbox bounds,
  deframer guard on real RTL via yosys-slang). **Report:** `make report` → `report/`.

## Conventions

- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Only commit/push when asked. Branch off `main` if the user wants a PR.
