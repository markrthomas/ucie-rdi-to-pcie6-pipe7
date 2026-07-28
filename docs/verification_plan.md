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

- **Line coverage** (`make coverage_merge` → `coverage.info`; `make coverage_summary`): the
  **union** across the whole Verilator smoke suite (each smoke built with `--coverage`, the
  per-smoke `coverage.dat` merged, item 40) — current **DUT** baseline **~98% line** (651/662,
  `src/` only; testbenches, stubs, the perf monitor, and the assertion module are verification
  code and are excluded). The single integrated-bridge smoke alone covers only the Gen5 path
  (~84%); the standalone smokes add Gen6, the gearbox bursts, every FSM transition, all
  message-bus opcodes, and the watchdogs (item 40, ~94%). The directed error-path tests
  (`tb_pipe7_timeout` rate/pclk-input/committed-write watchdogs, `tb_pipe7_deframer_gb_ovf`
  flush/slip, `tb_pipe7_mac_bridge_cov` `sync_error`/`rx_overflow`, item 41–42) close the
  reachable residuals. The five unreachable defensive `default:` arms carry a justified
  `// verilator coverage_off` (unique-case FSMs); the ~11 lines that remain uncovered are
  config-dead ports (`PCLK_IS_PHY_INPUT`=0 handshake), intentionally-unused tie-off signals, the
  Gen6-RX-through-bridge integration (covered standalone by the `gen6` smoke + cocotb
  `test_gen6_rx`), and a function-return line the tool mis-attributes.
- **Functional coverage** (Tier 2 UVM, item 11): Rate×Width, PowerDown-state, framing-mode,
  message-bus-opcode, and PhyStatus-latency covergroups; percentages via `get_coverage()` in
  `report_phase`.

### Redundant / independent coverage (Phase G, items 43–45)

The primary line-coverage gate above is Verilator's. To make coverage confidence *engine-* and
*tool-independent* — not just a single toolchain's self-report — Phase G adds a second, fully
independent measurement built from three separate axes:

- **Independent engine:** the cocotb testbench runs on **Icarus Verilog** (`make cocotb_icarus`,
  `make fcov`), not Verilator. Both engines compile the **identical shipped `src/` RTL** (the only
  change was a behaviour-neutral CDC-buffer storage split, item 43, kept bit-for-bit at 651/662),
  so this is genuine engine diversity rather than a transformed copy — `sv2v` is deliberately
  unused. Running the independent engine even surfaced a real portability bug (an iverilog
  enum→port width truncation on `RATE_GEN6`, fixed in the cocotb wrapper).
- **Independent tool + metric:** functional-coverage bins are scored by **`cocotb_coverage`** (pure
  Python), a tool wholly separate from Verilator's line counter. The model
  (`test/cocotb/models/coverage_model.py`) is **spec-derived** from the interface state/encoding
  space — 19 coverpoints / 45 reachable bins over control (PowerDown, Rate, Width, request kind,
  accept/reject), message bus (opcode, is-read, committed), datapath/framing (rate, block-lock,
  `sync_error`, data-phase, tx-valid), and RDI/credits/overflow (`tx_crd`, `rx_valid`, OS/SOB,
  `rx_overflow`). Structurally-unreachable bins are documented and dropped (e.g. `tx_crd` returns
  only 0 or FPB=2, never 1), never gerrymandered.
- **Independent gate:** `make fcov` (`SIM=icarus`) writes `report/fcov.{json,txt}`, emits
  `[FCOV] … bins = …%`, and asserts **≥ 98%** (`FCOV_MIN`, advisory-then-gate, mirroring
  `report_check`). Current baseline: **45/45 bins = 100 %** functional coverage on the independent
  Icarus engine.

Both numbers are surfaced side-by-side by `make report` (`scripts/gen_report.py` folds
`report/fcov.json` into the JSON/Markdown/HTML report and the CI step summary): the **Verilator
line union 651/662 = 98.34 %** and the **independent `cocotb_coverage` functional 45/45 = 100 %**.
This is a redundant cross-check for confidence — Verilator line coverage remains the primary gate.

## Performance / KPIs

A passive perf monitor (`test/pipe7_perf_monitor.sv`, `bind`-attached to the bridge, item 36)
emits a machine-readable `[PERF]` line from the integrated smokes; `make report` (item 37)
aggregates the KPIs + coverage + smoke/formal/cocotb status into
`report/{metrics.json, report.md, report.html}`, and `make report_check` (item 38) gates them
against `scripts/report_thresholds.json`. **All figures are simulation numbers at the smoke
operating point (rdi_clk ≈ 71 MHz / pclk 100 MHz), not silicon timing.**

| KPI | Definition | Source | Baseline | Threshold |
|-----|-----------|--------|---------:|----------:|
| TX PIPE utilization | `tx_data_valid` cycles / pclk cycles | `[PERF] tx_util_pct` | ~20 % | ≥ 12 % |
| Effective throughput | recovered RDI bits / pclk-ns | `[PERF] gbps_eff` | ~2.6 Gbit/s (w160) | — |
| RDI bits / PCLK | recovered flit-bits per pclk cycle | `[PERF] bits_per_pclk` | ~26 (w160) | — |
| Round-trip latency (avg) | RDI-in → RDI-out, timestamp queue | `[PERF] lat_ns_avg` | ~330 ns | ≤ 600 ns |
| Round-trip latency (max) | worst RDI-in → RDI-out | `[PERF] lat_ns_max` | ~476 ns | — |
| RX burst-FIFO peak | max recovered blocks buffered | `[PERF] burst_fifo_peak` | 2 (w160) | — |
| Peak credits outstanding | max in-flight egress credits | `[PERF] egress_peak_outstanding` | 1 | — |
| RX overflow drops | recovered blocks dropped (in-envelope) | `[PERF] rx_overflow` | 0 | 0 |
| TX-CDC stall cycles | cycles TX CDC full | `[PERF] tx_stall_cyc` | 0 | — |
| DUT line coverage | `src/` lines hit | `coverage.info` | 651/662 = 98.3 % | ≥ 80 % |
| Formal proofs | BMC + cover PASS | `make formal` | 8/8 | 8/8 |

The threshold gate is **advisory / opt-in** (runs `continue-on-error` in CI) so a simulation
timing wobble never reds the required gate; promote it to a hard gate once the baselines are
stable.

## Formal

`make formal` (SymbiYosys) runs eight BMC + cover proofs in `verification/formal/`. Most are
faithful plain-Verilog re-models of the RTL core (Yosys's built-in Verilog frontend cannot parse
the SV package-import module headers); `cdc_mc` (multiclock) and `deframer_rtl` bind to the
shipped RTL via the yosys-slang frontend (items 31–32). Skips cleanly if `sby` is absent.

| Proof | Core | Properties |
|-------|------|------------|
| `fifo_cdc` | `pipe7_cdc_elastic_buf` (re-model) | no overflow/underflow, flag consistency, output stability (ported, single-clock) |
| `cdc_mc` | **real** `pipe7_cdc_elastic_buf` | occupancy `wr_ptr−rd_ptr ∈ [0,DEPTH]` under **independent** clocks (multiclock, via slang) — the true dual-clock proof (item 32) |
| `credit_fc` | `pipe7_rdi_egress` | no underflow, no over-credit (`credits ≤ CREDITS`), `credits+outstanding == CREDITS` |
| `ingress_fc` | `pipe7_rdi_ingress` | no FIFO overflow (`count ≤ CREDITS`) under a credit-honest sender; closed loop (item 33) |
| `gearbox` | `pipe7_tx_framer_gb` | `pl_acc ≤ pl_cnt`, `≤ 2`, `≤ room`; accumulator never overflows |
| `dataphase` | `pipe7_mac_datapath_ra` | `TxElecIdle` gating, rate-mux exclusivity (no Gen5+Gen6 overlap), data-phase-only-from-P0 |
| `deframer` | `pipe7_rx_deframer` (re-model) | accumulator fill bounded `[0, RACC_W]` unconditionally (the item-27 flush guard) |
| `deframer_rtl` | **real** `pipe7_rx_deframer` | the same bound, proven on the shipped RTL via the yosys-slang frontend (item 31) |

All eight PASS (BMC + cover). The RTL guard is additionally exercised directly by the
`verilator_deframer_ovf` smoke (sustained garbage stays bounded + no spurious payload, then an
aligned stream re-locks and recovers).

**Real-RTL formal (item 31).** The `fifo_cdc` / `credit_fc` / `gearbox` / `dataphase` / `deframer`
proofs are faithful plain-Verilog re-models (Yosys's built-in Verilog frontend cannot parse the
SV package-import module headers). The **yosys-slang** plugin (`plugin -i slang; read_slang`)
*can* parse the real modules, so `deframer_rtl` binds the item-27 guard proof to the shipped
`pipe7_rx_deframer.sv` directly. yosys-slang supports immediate assertions (not concurrent SVA),
and modules whose combinational logic is written in `int` (e.g. the gearbox `offered`/`take`)
still translate more reliably as the `reg`-typed re-models — so those keep their re-model proofs
for now.

## Exit criteria (per commit)

- `make lint` clean (RTL + every TB/interface + the UVM DUT wiring).
- `make regress` runs to `$finish` with `[SMOKE]/[CTRL FSM]/[MSGBUS]/[FRAMING]/[GEN6]/[ASSN] PASS`.
- `make cocotb` green (3 PyUVM cross-checks agree with the DUT and their independent models).
- `make docs_check` passes (required docs present; no stale-claim regressions).
