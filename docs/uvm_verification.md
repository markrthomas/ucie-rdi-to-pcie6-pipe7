# UVM verification guide

Describes the Tier-2 UVM environment in `test/uvm/` for the UCIe RDI ↔ PIPE 7.1 MAC-facing
bridge (Gen5 + Gen6). **Authored-and-review-validated:** there is no VCS in the open-source
environment, so the UVM classes are not run here — the Verilator smoke (`make regress`) is the
release gate and the PyUVM-on-Cocotb tier (`make cocotb`) is the runnable cross-check. The DUT
wiring is Verilator-lint-clean (built by `make lint`), so the structural core of the env is
gate-validated even though the UVM classes are review-only.

Run under VCS: `make -C test/uvm -f Makefile.vcs` (or `make uvm` at the repo root).

## Scope

| Area | Status |
|------|--------|
| Simulator target | Synopsys VCS, `-ntb_opts uvm-1.2` (`test/uvm/Makefile.vcs`). |
| DUT | `pipe7_mac_dut` wraps the **integrated** `ucie_rdi_to_pipe7_mac_bridge` (item 22): credit-based flit UCIe RDI front end (rdi_clk domain) → RDI↔PCLK CDC → Gen5 128b/130b datapath → PIPE MAC, alongside `pipe7_mac_ctrl_fsm`, `pipe7_msgbus_master` + `pipe7_regfile`. Dual-clock (pclk + rdi_clk); PIPE width 80. |
| Interfaces | `pipe7_mac_if` (the real PIPE 7.1 MAC signal set, item 2), `ucie_rdi_if` (credit-based `RDI_FLIT_WIDTH`=64 flits with `sob`/`is_os`), `pipe7_ctrl_if` (control requests), `pipe7_msgbus_if` (register requests), `pipe7_gen6_rx_if` (Gen6 raw wide RX). |
| Control plane | Active `pipe7_ctrl_agent` drives PowerDown/Rate/Width; `pipe7_phy_agent` answers with spec-timed `PhyStatus`; `pipe7_ctrl_scoreboard` checks outcome + command state vs an independent legality model. |
| Datapath (RX) | Active `rdi_agent` drives credit-gated flits; the PHY BFM loops `RxData` back; the round-trip scoreboard checks recovered flits (data/sob/is_os) in order. |
| Gen6-wide RX | `gen6_rx_agent` injects raw Gen6 words into an aux `pipe7_mac_datapath_ra` (held in Gen6 data phase); `pipe7_gen6_rx_scoreboard` mirrored-queue-checks the recovered words (the deferred item-10 follow-on). |
| Message bus | Active `pipe7_msgbus_agent` drives reads/writes; `pipe7_msgbus_responder` independently decodes M2P and drives P2M; `pipe7_msgbus_scoreboard` checks framing + register round-trip. |
| Coverage | Rate×Width, PowerDown-state, framing-mode, message-bus-opcode, PhyStatus-latency covergroups (see below). |

## Components (`test/uvm/pipe7_mac_pkg.sv`)

| Component | Role |
|-----------|------|
| `rdi_transaction` | One UCIe RDI flit: `RDI_FLIT_WIDTH`-bit data + `sob` (start-of-block) + `is_os`; two flits reassemble a 128b block. |
| `rdi_agent` (active) | Credit-gated flit driver (drives while a credit is held, folds returned credits back) + monitor + sequencer. |
| `rdi_monitor` (passive) | Publishes accepted RDI flits (any beat with `valid`). |
| `rdi_rx_sink` | Returns one credit per recovered RX flit so the bridge egress keeps draining. |
| `gen6_rx_agent` / `pipe7_gen6_rx_scoreboard` | Injects raw Gen6 RX words (with an injection-order mirror) and checks the aux datapath's recovered words in order. |
| `pipe7_mac_monitor` (passive) | Samples the PIPE MAC interface (Rate/Width/PowerDown, Tx valid). |
| `pipe7_mac_scoreboard` | RDI-payload round-trip: recovered == driven, in order (analysis-fifo queue/drain). |
| `ctrl_transaction` / `pipe7_ctrl_agent` | Control requests; the driver captures each request's outcome, command state, and PhyStatus latency. |
| `pipe7_phy_agent` | PHY-responder BFM: watches PowerDown/Rate/Width and pulses `PhyStatus` after a latency (`phy_cb`); also drives `RxData` (loopback, `phy_rx_cb`). |
| `pipe7_ctrl_scoreboard` | Independent legality model (Rate/Width legal only in P0/P1); checks outcome (done/req_error) + command state. |
| `msgbus_transaction` / `pipe7_msgbus_agent` | Register read/writes; the driver captures the response. |
| `pipe7_msgbus_responder` | Independently decodes M2P framing, drives P2M `read_completion`/`write_ack` from a local register model, publishes each decode. |
| `pipe7_msgbus_scoreboard` | Pairs request with decode: checks M2P bytes vs an independent encode, cmd/addr/wdata, and read data / committed-write→read round-trip vs a register model. |
| `pipe7_mac_env` | Instantiates and connects all of the above (agents, scoreboards, coverage). |

## Sequences & tests (`test/uvm/seq_lib/pipe7_seq_lib.sv`)

Sequences live in a separate package that imports `pipe7_mac_pkg` (so the env has no
sequence/test dependency — avoids a circular package import).

| Sequence | Intent |
|----------|--------|
| `pipe7_rdi_random_seq` / `_data_seq` / `_os_seq` | Random / data-only / ordered-set-only payloads. |
| `pipe7_ctrl_directed_seq` | Power ladder + Gen5↔Gen6 rate + Width change + two illegal rate changes (P2, P0s). |
| `pipe7_msgbus_directed_seq` | Uncommitted/committed writes, a preloaded read, and a committed-write→read round-trip. |

| Test | Runs |
|------|------|
| `pipe7_mac_sanity_test` | Datapath round-trip only. |
| `pipe7_ctrl_test` | Control-plane directed scenario (11 completions + 2 rejections). |
| `pipe7_msgbus_test` | Message-bus directed scenario. |
| `pipe7_rx_test` | RX-path round-trip (PHY-sourced RxData). |
| `pipe7_full_test` (default) | Datapath + control + message bus concurrently. |

## Coverage model (item 11)

Every covergroup reports its percentage via `get_coverage()` in `report_phase`; the directed
`pipe7_full_test` is built to close every bin.

| Covergroup | Coverpoints / crosses |
|------------|-----------------------|
| `cg_ctrl` | `cp_rate` (Gen5/Gen6), `cp_width` (10/20/40/80/160), `cp_pd` (P0/P0s/P1/P2), `cp_framing_mode` (Gen5-130b/Gen6-wide), `x_rate_width` |
| `cg_req` | `cp_kind` (power/rate/width), `cp_done`, `cp_latency` (PhyStatus: immediate/short/long/over), `x_kind_done` |
| `cg_op` | `cp_opcode` (read/write_uncommitted/write_committed), `cp_is_read` |
| `cg_frame` | `cp_is_os` (data / ordered-set block) |

## Relationship to the other tiers

- **Verilator (Tier 1)** — the OSS release gate: RTL lint + the per-block self-checking smokes
  (`make regress`) + line coverage. This is what actually runs per commit.
- **PyUVM-on-Cocotb (Tier 1b)** — the runnable cross-check (`make cocotb`): independent Python
  models 3-way-check the datapath, control plane, and message bus. Mirrors this env's taxonomy
  1:1 so intent is shared and divergences compare like-for-like.
- **UVM (Tier 2, this doc)** — the constrained-random / coverage growth path under VCS.

## Known scope / follow-ons

- Gen6 wide-data UVM RX stimulus is deferred (needs the Gen5/Gen6 rate-mux + width gearbox);
  the Gen6 raw path is proven by the Verilator `verilator_gen6` smoke and the PyUVM datapath.
- The datapath uses a fixed Gen5 width (80); width-change-affects-datapath integration and
  TxElecIdle data-phase gating are follow-ons.
