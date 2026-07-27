# Verification plan — UCIe RDI ↔ PIPE 7.1 MAC bridge

## Goals

- Prove the MAC-facing control plane: every PowerDown/Rate/Width request reaches a `PhyStatus`
  completion, and illegal transitions (Rate/Width outside P0/P1) are rejected.
- Prove the MAC-owned Gen5 128b/130b framing round-trip (RDI payload ↔ framed PIPE data) and
  the Gen6 raw wide datapath (no sync header).
- Prove the 8-bit M2P/P2M message-bus framing + register read/write.
- Keep the open-source regression fast, reproducible, and green per commit.

## Regression commands

```bash
make              # grouped target list (default)
make regress      # lint + every Verilator smoke (CI release gate)
make ci           # regress + coverage + NL1 + docs_check
make cocotb       # Tier 1b PyUVM-on-Cocotb cross-checks (datapath + control + message bus)
make regress_cov  # line coverage -> coverage.info ; make coverage_summary prints the table
make waves WAVE_TB=framing|ctrl|msgbus|gen6|assn   # VCD + saved GTKWave layout
make uvm          # Tier 2 VCS/UVM (not run in the OSS environment)
```

GitHub Actions (`.github/workflows/ci.yml`) runs, per push/PR to `main`/`master`:
`sim` (`make regress`), `coverage` (`make verilator_cov`), `nl1` (`make verilator_nl1`), and
`cocotb` (all three PyUVM cross-checks) — the cocotb job is a **required** gate.

## Three-tier environment

| Tier | Location | Simulator | Role | Gate |
|------|----------|-----------|------|------|
| **1 — Verilator** | root `Makefile`, `test/tb_pipe7_*.sv` | Verilator | RTL lint + per-block self-checking smokes + line coverage + NL1 | **OSS release gate** |
| **1b — PyUVM/Cocotb** | `test/cocotb/` | Verilator / Icarus | Independent Python models 3-way cross-check the datapath, control plane, message bus | **Required** CI job (runnable here) |
| **2 — UVM** | `test/uvm/` | VCS/UVM 1.2 | Constrained-random + coverage growth path | Authored-and-review-validated (no VCS here); DUT wiring is Verilator-lint gated |

### Tier 1 — Verilator smokes (the gate)

Each self-checking TB `$fatal`s on mismatch, so `make regress` is red on any regression:

| Target | Checks |
|--------|--------|
| `make verilator` | Item-1 datapath pass-through smoke + scoreboard (`[SMOKE] PASS`). |
| `make verilator_ctrl` | PowerDown/Rate/Width FSM vs the PHY-responder stub (`[CTRL FSM] PASS`, 12 completions / 2 rejections). |
| `make verilator_msgbus` | M2P/P2M framing round-trip: master + regfile + responder stub (`[MSGBUS] PASS`). |
| `make verilator_framing` | Gen5 128b/130b framer → deframer round-trip; blocks straddle words so the RX genuinely re-aligns (`[FRAMING] PASS`). |
| `make verilator_gen6` | Gen6 raw wide datapath + L0p width + PAM4 carry (`[GEN6] PASS`). |
| `make verilator_assn` | PIPE protocol SVA (see below). |
| `make verilator_nl1` | `NUM_LANES=1` parameter smoke. |

### PIPE 7.1 protocol assertions (item 7)

`test/pipe7_mac_bridge_assertions.sv` is a reusable, parameterizable SVA checker; each property
is `CHECK_*`-guarded and a violation `$fatal`s (non-zero CI exit):

| Property | Check | Crosscheck |
|----------|-------|------------|
| P1 `CHECK_TX_EI` | No `TxDataValid` while `TxElecIdle == 4'hF` | E5 |
| P2 `CHECK_RATE_PD` | A `Rate` change occurs only in `PowerDown` P0/P1 | §8.4.1 / B5·D3 |
| P3 `CHECK_PHYSTAT` | Every accepted request completes via `PhyStatus` within `PHYSTATUS_MAX_LATENCY` (a **parameter**, not a spec constant) | D4 |
| P4 `CHECK_SYNC` | On a correct Gen5 link the deframer never flags an illegal sync header | H1·H2 |

`make verilator_assn` (Verilator `--assert`) drives a coherent good scenario so every property
holds, **counts each antecedent** so a vacuous pass is itself a failure, and the checker's teeth
are confirmed out-of-band by injecting a violation and observing the `$fatal`.

### Tier 1b — PyUVM-on-Cocotb cross-check (items 13–14; runnable here)

A third, open-source-*runnable* tier built with **PyUVM** (UVM 1.2 in Python, on cocotb). Its job
is independent-implementation diversity: reference models authored independently of the SV env —
in Python, on a different simulator — make a common-mode modelling bug far less likely to pass
silently. The PyUVM taxonomy is aligned 1:1 with the Tier-2 UVM env, so intent is shared and
divergences compare like-for-like. Three cross-checks execute via `make cocotb` (each with a
`cocotb-coverage` bin-parity check):

- **Datapath** (`test_datapath.py`) — a **three-way** agreement check: DUT round-trip identity;
  DUT `TxData` stream vs an independent Python framer (bit-exact); Python deframe of the DUT
  stream vs the DUT deframer.
- **Control-plane** (`test_ctrl_plane.py`) — PowerDown/Rate/Width requests answered by an
  independently-authored PyUVM `PhyStatusResponder`; per-request outcome + command state
  cross-checked against an independent legality model (13 requests, 2 rejects).
- **Message-bus** (`test_msgbus.py`) — register read/writes answered by an independent
  `MsgbusResponder`; M2P framing decoded independently and checked against the model's encoding,
  plus read data / a committed-write→read round-trip against a register model.
- **Integrated bridge** (`test_bridge.py`, item 23) — drives the real
  `ucie_rdi_to_pipe7_mac_bridge` (dual-clock, credit-based flit RDI, PHY loopback + responder
  stubs) end-to-end; three-way check: recovered flits == driven flits; Python deframe of the DUT
  `TxData` == the driven blocks; DUT `TxData` == an independent Python framer (bit-exact over the
  overlap). `models/rdi_model.py` maps flits ↔ 128b blocks independently.
- **Gen6-wide RX** (`test_gen6_rx.py`, item 23) — injects raw Gen6 wide words at the rate-aware
  datapath's RX (held in Gen6 data phase) and mirrored-queue-checks the recovered stream against
  `models/gen6_model.py` (identity, order-preserving) — the deferred item-10 follow-on.

A key pyuvm gotcha handled here: `check_phase` runs **top-down** (parent before child), so all
pass/fail assertions live in the leaf scoreboards' `check_phase`, not the test's (else the test
would read scoreboard results before they are computed — a silent vacuous pass).

### Tier 2 — UVM (VCS)

The constrained-random / coverage growth path; component roles, sequence matrix, and the
coverage model are documented in `docs/uvm_verification.md`. Authored-and-review-validated (no
VCS in the OSS environment); the DUT wiring (`test/uvm/pipe7_mac_dut.sv`) is Verilator-lint clean
via `make lint`.

## Coverage

- **Line coverage** (`make regress_cov` → `coverage.info`; `make coverage_summary`): the
  instrumented flow now covers the **integrated-bridge end-to-end smoke**
  (`tb_pipe7_mac_bridge`) — current baseline **~89% line** (643/723), up from the item-1
  datapath baseline (135/158). Remaining uncovered lines are error/edge branches (e.g. RX
  elastic-buffer overflow, message-bus error responses) exercised by the per-block self-checking
  Verilator smokes, the PyUVM cross-checks, and the authored UVM env rather than the single
  end-to-end smoke.
- **Functional coverage** (Tier 2 UVM, item 11): Rate×Width, PowerDown-state, framing-mode,
  message-bus-opcode, and PhyStatus-latency covergroups; percentages via `get_coverage()` in
  `report_phase`.

## Formal

`make formal` (SymbiYosys) runs four BMC + cover proofs in `verification/formal/`; each is a
faithful plain-Verilog model of the RTL core (Yosys's Verilog frontend cannot parse the SV
package-import module headers). Skips cleanly if `sby` is absent.

| Proof | Core | Properties |
|-------|------|------------|
| `fifo_cdc` | `pipe7_cdc_elastic_buf` | no overflow/underflow, flag consistency, output stability (ported) |
| `credit_fc` | `pipe7_rdi_egress` | no underflow, no over-credit (`credits ≤ CREDITS`), `credits+outstanding == CREDITS` |
| `gearbox` | `pipe7_tx_framer_gb` | `pl_acc ≤ pl_cnt`, `≤ 2`, `≤ room`; accumulator never overflows |
| `dataphase` | `pipe7_mac_datapath_ra` | `TxElecIdle` gating, rate-mux exclusivity (no Gen5+Gen6 overlap), data-phase-only-from-P0 |
| `deframer` | `pipe7_rx_deframer` | accumulator fill bounded `[0, RACC_W]` unconditionally (the item-27 flush guard) |

All five PASS (BMC + cover). The RTL guard is additionally exercised directly by the
`verilator_deframer_ovf` smoke (sustained garbage stays bounded + no spurious payload, then an
aligned stream re-locks and recovers).

## Exit criteria (per commit)

- `make lint` clean (RTL + every TB/interface + the UVM DUT wiring).
- `make regress` runs to `$finish` with `[SMOKE]/[CTRL FSM]/[MSGBUS]/[FRAMING]/[GEN6]/[ASSN] PASS`.
- `make cocotb` green (3 PyUVM cross-checks agree with the DUT and their independent models).
- `make docs_check` passes (required docs present; no stale-claim regressions).
