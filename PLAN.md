# PLAN.md — UCIe RDI → PCIe PIPE 7.1 (Gen5/Gen6) MAC-Facing Bridge

> Portable blueprint for a **new repo**. Drop this in as `PLAN.md`, then execute the
> phased closure plan one item per commit (the workflow this author already uses).

## Context

The predecessor repo (`IP-ucie-rdi-to-pcie-pipe`) is a UCIe 1.0 RDI ↔ "PIPE-labeled"
CDC bridge. Its `pipe_*` ports are a **generic valid/ready/data/error handshake plus a
demo CRC** — none of the real PIPE control/status signalling (PowerDown, Rate, Width,
PhyStatus, RxStatus, message bus, flit framing) exists. It is functionally a dual-clock
elastic-buffer datapath with PIPE naming.

This project builds the **real thing**: a bridge whose downstream port is a genuine
**PIPE 7.1 MAC-facing interface** (the bridge plays the MAC/controller role and talks
to a PIPE PHY). It reuses the predecessor's proven **repo shape, DV methodology, and
build/CI discipline**, but replaces the stub datapath with a spec-accurate PIPE MAC.

**Locked scope decisions:**
- **Datapath architecture:** PIPE **SerDes Architecture** (async PHY interface, 8-bit
  **M2P/P2M message bus** carries most control/status; minimal discrete pins).
- **Rates/modes:** **Gen5 + Gen6** only — 32 GT/s **128b/130b** and 64 GT/s **PAM4 FLIT**.
  No legacy Gen1–4 rate ladder.
- **Role:** **MAC-facing only.** We drive MAC-owned signals and react to PHY-owned ones;
  we do **not** model PHY internals (SerDes, precoding math, CDR, elec-idle detection).
- **Build-out:** **Phased closure plan**, one numbered item per commit.

**Intended outcome:** a lint-clean, Verilator-smoke-gated, UVM-verified UCIe-RDI-to-PIPE-7.1
MAC bridge IP with the same "authored-and-review-validated" DV rigor as the predecessor,
where UVM is VCS-only and Verilator is the open-source CI gate.

---

## Target architecture (RTL)

### Block diagram (per direction, per lane group)

```
UCIe RDI  ──►  RDI ingress ──► TX flit/frame builder ──► CDC elastic buf ──► PIPE MAC TxData*  ──► (PHY)
(RDI clk)      + FC/backpr.      (Gen5 128b130b /                (RDI↔PCLK)    TxDataValid/StartBlock/
                                  Gen6 flit+FEC-passthru)                       SyncHeader

(PHY) ──► PIPE MAC RxData* ──► CDC elastic buf ──► RX flit/frame parser ──► RDI egress ──► UCIe RDI
          RxValid/StartBlock/    (PCLK↔RDI)         (block align, deskew,                   (RDI clk)
          SyncHeader/RxStatus                        sync-header check)

Control plane (shared): PIPE LTSSM-adjacent MAC state:
  PowerDown/Rate/Width request FSM  ── gated on ──►  PhyStatus completion handshake
  Message-bus master (M2P) ◄──responses── (P2M)      RxStatus/RxElecIdle/RxStandby sampling
```

### RTL module inventory (mirrors predecessor's `src/` granularity)

| Module | Role | Reuse from predecessor? |
|--------|------|--------------------------|
| `ucie_rdi_to_pipe7_mac_bridge.sv` | Top; per-lane generate; wires control + datapath | Structure/genvar pattern from `ucie_rdi_to_pcie_pipe_bridge.sv` |
| `pipe7_cdc_elastic_buf.sv` | Dual-clock Gray-pointer elastic buffer (RDI↔PCLK) | **Port directly** from `ucie_rdi_fifo_cdc.sv` (proven, formally checked) |
| `pipe7_mac_ctrl_fsm.sv` | PowerDown/Rate/Width request sequencing; **gated on `PhyStatus`** | New (net-new core) |
| `pipe7_msgbus_master.sv` | M2P/P2M 8-bit message-bus master FSM; register read/write transactions | New (net-new core) |
| `pipe7_tx_framer.sv` | Gen5 128b/130b block build; Gen6 flit build (sync header, block type) | New |
| `pipe7_rx_deframer.sv` | Block alignment, sync-header check, RxStatus decode | New |
| `pipe7_regfile.sv` | PIPE register space accessed over message bus (eq presets, margining, precoding-enable, FEC status pass-through) | New |
| `pipe7_pkg.sv` | Params, rate/power/width enums, message-bus opcode/addr constants | New (analogous to centralizing constants) |

### Signal set the bridge OWNS (MAC → PHY, must drive)
> Corrected per item 0 for the SerDes architecture (crosscheck §E).
- **Tx data (SerDes arch):** `TxData[N-1:0]` (N ∈ {10,20,40,80,160}, set by `Width`),
  `TxDataValid`. **No** `TxStartBlock`/`TxSyncHeader`/`TxDataK` — those are Original-PIPE
  -only; in SerDes the MAC does the 128b/130b coding and embeds the 2b sync header in
  `TxData` itself. At Gen6 (64 GT/s) there is no 128b/130b sync header at all.
- **Tx control:** `TxElecIdle[3:0]`, `TxDetectRx/Loopback` (loopback N/A in SerDes — we
  drive it only for receiver-detect). Tx margin/compliance are **msg-bus registers** in
  SerDes, not discrete pins.
- **Command/config:** `PowerDown[3:0]`, `Rate[3:0]` (Gen5=`4`, Gen6=`5`), `Width[2:0]`,
  `RxWidth[2:0]`, `Reset#` (active-low, async).
- **Message-bus master:** `M2P_MessageBus[7:0]` transactions (Tx eq presets/de-emphasis
  in PHY Tx Control regs, Rx margining, `PAM4RestrictedLevels`). No FEC register exists.

### Signal set the bridge SAMPLES + reacts to (PHY → MAC)
> Corrected per item 0 for the SerDes architecture (crosscheck §F).
- **Rx data:** `RxData[N-1:0]` synchronous to the recovered clock **`RxCLK`** (not PCLK),
  `RxValid` (in SerDes = "RxCLK stable", not block-aligned). **No** `RxStartBlock`/
  `RxSyncHeader` (Original-PIPE-only) — the MAC recovers block start / decodes the sync
  header out of `RxData`. `RxStatus[2:0]` — only `0b011` "Receiver detected" applies in
  SerDes; SKP/decode/EB-error codes are Original-PIPE-only (EB lives in the MAC).
- **`PhyStatus`** — single-cycle completion for power/rate/width changes (async when PCLK
  is absent). Rate/Width change only in **P0 or P1** with `TxElecIdle` asserted. Completion
  latency is **PHY-specific** (parameterize the item-7 assertion). In PCLK-as-PHY-input
  mode add the `PclkChangeOk`→`PclkChangeAck` handshake.
- `RxElecIdle` (async; at Gen5/Gen6 the MAC must detect EI-*entry* with its own logic,
  not trust this pin), `RxStandbyStatus`, `P2M_MessageBus[7:0]` responses.

### PIPE-7.1-specific deltas built in from day one
> Reconciled with the spec in item 0 (crosscheck §B/§C/§I).
- **Gen6 at the PIPE interface is *not* "FLIT mode".** "Flit" is a PCIe-base concept above
  PIPE (0 occurrences in PIPE 7.1). At 64 GT/s (`Rate=5`) the datapath is wider `TxData`/
  `RxData` with **no** 128b/130b sync header; the 256B flit + FEC + LCRC are built
  controller-side and arrive on RDI. The bridge does **not** frame flits on the PIPE side.
  (This still replaces the predecessor's zero-extend mapping, which cannot carry real
  block/flit-formatted data.)
- **New Rate encoding**: `Rate[3:0]`, Gen5=`4` (32 GT/s), Gen6=`5` (64 GT/s); each rate
  change completes via a single-cycle `PhyStatus` (+ optional PCLK handshake).
- **L0p** is realized by an ordinary `Width`/`RxWidth` change using the standard
  rate/width→`PhyStatus` handshake — **no** dedicated L0p PIPE handshake or "partial
  width" pins exist.
- **PAM4 precoding**: PHY does the mapping/gray-code/precode; the MAC's only PAM4 register
  knob is `PAM4RestrictedLevels` (there is no generic "precoding-enable" register).
- **FEC / flit-LCRC** live on the **controller/RDI** side; the PIPE interface has **no FEC
  signalling or register** — the bridge sizes the RDI datapath for them but nothing FEC
  crosses the PIPE boundary.

---

## Repo scaffolding (clone the predecessor's shape)

```
├── README.md                     # IP overview, parameters, build matrix, coverage note
├── CHANGELOG.md
├── LICENSE
├── Makefile                      # lint / regress / regress_cov / regress_nl1 / uvm / formal / docs_check
├── .github/workflows/ci.yml      # runs `make regress` then coverage + nl1 gates
├── sim_main.cpp, sim_main_nl1.cpp# Verilator C++ clock/reset drivers (RDI + PCLK domains)
├── src/
│   ├── pipe7_pkg.sv
│   ├── pipe7_cdc_elastic_buf.sv          # ported ucie_rdi_fifo_cdc
│   ├── pipe7_mac_ctrl_fsm.sv
│   ├── pipe7_msgbus_master.sv
│   ├── pipe7_tx_framer.sv
│   ├── pipe7_rx_deframer.sv
│   ├── pipe7_regfile.sv
│   └── ucie_rdi_to_pipe7_mac_bridge.sv
├── test/
│   ├── sim_top.sv                        # vendor-sim top with #-delay clocks
│   ├── tb_pipe7_mac_bridge.sv            # Verilator smoke stimulus
│   ├── tb_pipe7_mac_bridge_scoreboard.sv # self-checking reference
│   ├── tb_pipe7_mac_bridge_nl1.sv        # NUM_LANES=1 param smoke
│   ├── pipe7_mac_bridge_assertions.sv    # monitors/statistics + PIPE protocol assertions
│   └── uvm/
│       ├── Makefile.vcs
│       ├── README.md
│       ├── pipe7_mac_if.sv               # real PIPE MAC-side interface (clocking blocks)
│       ├── ucie_rdi_if.sv
│       ├── pipe7_mac_pkg.sv              # agents/drivers/monitors/scoreboard/coverage
│       ├── seq_lib/pipe7_seq_lib.sv
│       └── uvm_test_top.sv
├── docs/
│   ├── architecture.md
│   ├── interface_spec.md                 # PIPE 7.1 MAC integration contract
│   ├── verification_plan.md
│   ├── uvm_verification.md
│   └── pipe71_mac_signal_map.md          # every MAC signal: driven/sampled + reg addr
├── constraints/ (example.xdc / example.sdc)
└── verification/formal/                  # SymbiYosys props for CDC buf + FSM invariants
```

---

## DV environment (mirror predecessor's two-tier model)

**Tier 1 — Verilator open-source CI gate** (fast, always-run):
- Smoke TB + reference scoreboard + assertion monitor, clocks from `sim_main.cpp`.
- `NUM_LANES=1` param smoke (`sim_main_nl1.cpp`).
- Line coverage via `--coverage` → `coverage.info` + `coverage_summary` awk target.
- A **lightweight PHY-responder stub** (SV, non-UVM) that answers `PhyStatus`, returns
  `RxStatus`/`RxData`, and services message-bus reads — enough to exercise the FSM.

**Tier 2 — UVM (VCS/UVM 1.2), authored-and-review-validated, not in OSS CI:**
- **`ucie_rdi_agent`** (active): drives RDI TX, monitors accepted beats, publishes expected.
- **`pipe7_phy_responder_agent`** (the key new BFM): a **PHY-side responder** that drives
  `PhyStatus`/`RxStatus`/`RxData`/`P2M`, and *answers* `PowerDown`/`Rate`/`Width` requests
  with spec-timed completion handshakes. This replaces the predecessor's trivial
  ready-driver. One well-defined role — not a full PHY model.
- **`pipe7_mac_monitor`** (passive): observes MAC-side Tx + control transitions.
- **Scoreboard:** per-lane ordering queues (reuse the predecessor's queue+drain pattern),
  **plus** a control-plane checker (every power/rate/width request eventually completes via
  `PhyStatus`; illegal transitions flagged) and a message-bus transaction checker.
- **Coverage:** reuse per-lane valid/error/occupancy covergroups; **add** Rate×Width cross,
  PowerDown-state cross, flit-vs-130b framing coverage, message-bus opcode coverage,
  PhyStatus-latency bins.

**Formal:** port the predecessor's SymbiYosys CDC/handshake proofs onto
`pipe7_cdc_elastic_buf`; add FSM safety props (no `Rate` change while not in the right
PowerDown state; no Tx data while `TxElecIdle`).

---

## Build / CI (reuse predecessor targets verbatim where possible)

Makefile target set to replicate: `lint`, `regress` (lint + Verilator smoke = CI gate),
`regress_cov`, `regress_nl1`, `coverage_summary`, `ci` (regress + cov + nl1 + docs_check),
`uvm`/`uvm_compile`/`uvm_run` (via `test/uvm/Makefile.vcs`), `formal`, `docs_check`, `clean`.
Vendor flows (`simv`/`questa`/`xsim`) compile `sim_top.sv`. CI runs `make regress` then
`verilator_cov` + `verilator_nl1`, matching `.github/workflows`.

---

## Phased closure plan (one numbered item per commit)

> Each item is self-contained, lint-clean, and leaves `make regress` green. Advance one
> per commit, matching the predecessor's closure-plan workflow.

> **Provenance caveat — RESOLVED (2026-07-23).** The signal names, message-bus
> opcodes/addresses, flit sizing, rate/power-state encodings, and PhyStatus timing were
> originally working-knowledge placeholders. **Item 0 is now complete**: they were
> reconciled against the official **Intel PIPE 7.1 spec (Ref 643108, Rev 7.1, Sep 2025)**
> — see `docs/pipe71_spec_crosscheck.md` for the row-by-row verdicts. Corrections are
> folded in below and in `src/pipe7_pkg.sv`. **Key deltas from the original plan:**
> (a) Gen6 is **not** "FLIT mode" *at the PIPE interface* — "flit" is a PCIe-base concept
> above PIPE (0 occurrences in PIPE 7.1); the bridge passes already-framed data as
> `TxData`/`RxData`, it does not build 256B flits on the PIPE side.
> (b) In the **SerDes architecture the MAC owns 128b/130b encode/decode + block
> alignment** (PHY is parallel↔serial only), so `TxStartBlock`/`TxSyncHeader`/
> `RxStartBlock`/`RxSyncHeader`/`TxDataK`/`RxDataK` **do not exist** on this interface.
> (c) Field widths: `PowerDown[3:0]`, `Rate[3:0]` (Gen5=`4`, Gen6=`5`), `TxElecIdle[3:0]`,
> `Width[2:0]` + separate `RxWidth[2:0]`; SerDes `TxData` is 10/20/40/80/160 bits.
> (d) L0p is an ordinary `Width` change, not a special PIPE handshake; PhyStatus
> completion latency is PHY-specific (parameterized), not a spec constant; there is **no
> FEC register** on the PIPE interface.

0. **Spec cross-check + errata sheet.** Obtain the controlled **PIPE 7.1** spec (and the
   relevant **PCIe 6.x base** sections for FLIT/PAM4/L0p). Produce
   `docs/pipe71_spec_crosscheck.md` that, for each item this plan asserts, records
   **spec §ref → confirmed / corrected / N-A**, covering at minimum: SerDes-architecture
   signal list and directions; M2P/P2M message-bus framing, opcodes, and register
   addresses; Gen5/Gen6 `Rate` and `PowerDown`/`Width` encodings; PhyStatus completion
   semantics and max-latency bounds; flit size and sync-header/block-type rules; L0p
   partial-width handshake; and which functions are MAC-owned vs PHY-owned. Fold every
   correction back into this PLAN before starting item 1. **Blocks items 2–12.**
1. **Repo skeleton + CDC port.** Scaffold dirs, `pipe7_pkg.sv`, port
   `ucie_rdi_fifo_cdc.sv` → `pipe7_cdc_elastic_buf.sv`, Makefile + CI + `sim_main.cpp`,
   Verilator lint/smoke green on a datapath-only pass-through. Port formal props for the buf.
2. **PIPE MAC interface skeleton.** `pipe7_mac_if.sv` + `docs/interface_spec.md` +
   `docs/pipe71_mac_signal_map.md` enumerating every MAC-owned/PHY-owned signal and the
   register map. No behavior yet — contract first.
3. **PowerDown/Rate/Width control FSM** (`pipe7_mac_ctrl_fsm.sv`) **gated on `PhyStatus`.**
   Add the Verilator PHY-responder stub so the FSM can complete handshakes; smoke-test
   P0↔P0s↔P1↔P2 and Gen5↔Gen6 rate changes.
4. **Message-bus master** (`pipe7_msgbus_master.sv` + `pipe7_regfile.sv`). M2P/P2M
   transactions; register read/write; eq-preset + precoding-enable + margining regs.
5. **Gen5 128b/130b TX framer + RX deframer.** Sync-header build/check, block alignment.
   Scoreboard checks RDI payload ↔ framed PIPE data round-trip.
6. **Gen6 PAM4 FLIT mode.** Flit builder/parser (256B), Gen6 rate encoding + PhyStatus
   timing, precoding-enable config path, L0p partial-width handshake.
7. **Protocol assertions** (`pipe7_mac_bridge_assertions.sv`): no Tx while `TxElecIdle`,
   Rate change only in legal PowerDown, PhyStatus completion within bound, sync-header legality.
8. **UVM base env** (`pipe7_mac_pkg.sv`): RDI active agent + MAC passive monitor +
   per-lane scoreboard (port predecessor's queue/drain), base + sanity test, `Makefile.vcs`.
9. **UVM PHY-responder agent** — the spec-timed `PhyStatus`/`RxStatus`/`P2M` BFM answering
   power/rate/width requests; wire into env; control-plane scoreboard checker.
10. **UVM RX path + message-bus checker** — RX flit/130b stimulus, mirrored RX queues,
    message-bus transaction scoreboard.
11. **Functional coverage closure** — Rate×Width, PowerDown-state, framing-mode,
    message-bus-opcode, PhyStatus-latency covergroups; report in README metrics.
12. **Docs + coverage sign-off** — finalize `architecture.md`, `verification_plan.md`,
    `uvm_verification.md`; `docs_check` target; record line-coverage baseline.

---

## Verification (how to prove it end-to-end)

- **Per commit:** `make lint && make regress` must stay green (lint-clean + Verilator
  smoke with `[SCOREBOARD] PASS`), plus `make regress_nl1` for the `NUM_LANES=1` gate.
- **Coverage:** `make regress_cov` → `coverage.info`; `make coverage_summary` prints the
  line-coverage table. Keep README's coverage claim in sync (predecessor gates this in
  `docs_check`).
- **Control-plane proof:** the PHY-responder + control-plane scoreboard checker must show
  every `PowerDown`/`Rate`/`Width` request reaching a `PhyStatus` completion, and illegal
  transitions flagged — this is the item with no predecessor analog, so it is the primary
  new sign-off gate.
- **Framing proof:** scoreboard round-trips RDI payload through Gen5 130b **and** Gen6 flit
  framing back to RDI; upper/lower field mapping checked per mode (not the old zero-extend).
- **UVM (VCS):** `make uvm` compiles + runs the sanity test; review-validate (this env is
  authored-not-run in the OSS environment, per the predecessor's convention).
- **Formal:** `make formal` (SymbiYosys) for CDC-buf invariants + FSM safety props.

## Key reuse pointers (from predecessor repo)

- **CDC elastic buffer** — port `src/ucie_rdi_fifo_cdc.sv` wholesale; it is the one proven,
  formally-checked block and needs only PCLK-domain renaming.
- **Scoreboard queue/drain pattern** — per-lane `exp_q[$]` with `check_phase` drain
  (`ucie_rdi_pcie_pkg.sv`) transfers directly to the framed datapath.
- **Two-tier DV split** — Verilator = OSS CI gate, UVM = VCS-only growth path
  (`docs/verification_plan.md` environment map).
- **Makefile target vocabulary** — copy `regress` / `regress_cov` / `regress_nl1` / `ci` /
  `docs_check` names so muscle memory and CI carry over.

## Explicitly out of scope
PHY internals (SerDes, PAM4 precoding math, CDR, elec-idle detection); FEC/flit-LCRC codec
(controller-side); Gen1–4 legacy rates; the predecessor's demo CRC (`0x17047432` residue) —
it is unrelated to Gen6 flit CRC and is dropped from the PIPE interface entirely.
