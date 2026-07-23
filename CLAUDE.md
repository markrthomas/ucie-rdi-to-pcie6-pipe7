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

- Execute `PLAN.md` as a **numbered closure plan, one item per commit** (items 0–12).
- **Item 0 (spec cross-check) gates items 2–12.** Its errata sheet is
  `docs/pipe71_spec_crosscheck.md`; every row is UNCONFIRMED until reconciled against the
  controlled **Intel PIPE 7.1 spec** (+ PCIe 6.x base for flit/PAM4/L0p). Do **not** freeze
  the interface, register map, or `pipe7_pkg` encodings until the relevant rows resolve.
- All control-plane encodings in `src/pipe7_pkg.sv` are working-knowledge **placeholders**
  flagged for item-0 confirmation.

## Current state

- Seed + **item 1 done** (pkg, ported CDC `pipe7_cdc_elastic_buf.sv`, pass-through
  `ucie_rdi_to_pipe7_mac_bridge.sv`, smoke + NL1 TBs). Verilator gate green.
- **Item 0 scaffolded** (errata table written, awaiting spec §-refs).
- **Next:** fill item 0 against the spec, then item 2 (interface skeleton).

## Verification

Two-tier (see `docs/verification_plan.md`):

- **Verilator = the open-source gate** (toolchain: oss-cad-suite on PATH — `verilator`,
  `iverilog`, `sby`). Per commit keep green:
  - `make lint` (RTL strict `-Wall`; TB passes waive UNUSEDSIGNAL/UNDRIVEN — externally-driven TB clocks)
  - `make regress` → `[SMOKE] PASS` · `make verilator_nl1` → `[SMOKE NL1] PASS`
  - `make regress_cov` → line coverage
- **UVM (VCS/UVM 1.2) is authored-and-review-validated, NOT run here** — no VCS in this
  environment. Validate UVM by review; the Verilator gate is what actually runs.

## Conventions

- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Only commit/push when asked. Branch off `main` if the user wants a PR.
