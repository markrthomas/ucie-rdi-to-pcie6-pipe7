# Tier 2 — UVM environment (VCS/UVM 1.2)

The commercial-simulator verification tier for the UCIe RDI ↔ PIPE 7.1 MAC-facing bridge.
**Authored-and-review-validated**: there is no VCS in the open-source environment, so this tier
is not run here — the Verilator gate (`make regress`) and the runnable PyUVM-on-Cocotb tier
(`make cocotb`) are what execute. This env is the constrained-random / coverage growth path,
built to mirror the predecessor's agent + scoreboard structure.

Run under VCS with `make -C test/uvm -f Makefile.vcs` (or `make uvm` at the repo root).

## Item 8 — base datapath env (this commit)

```
ucie_rdi_if.sv        RDI-side payload interface (128b block payload + is_os handshake)
pipe7_mac_if.sv       PIPE 7.1 MAC-facing interface (item 2; spec-accurate signal set)
pipe7_mac_dut.sv      datapath DUT: pipe7_tx_framer -> pipe7_rx_deframer (Gen5 128b/130b)
pipe7_mac_pkg.sv      UVM env: rdi_transaction, rdi_agent (active), pipe7_mac_monitor
                      (passive), round-trip scoreboard, Rate×Width / PowerDown / framing coverage
seq_lib/pipe7_seq_lib.sv  sequences (random / data-only / OS-only) + base & sanity tests
uvm_test_top.sv       interfaces + DUT + PHY loopback BFM + config_db + run_test
Makefile.vcs          VCS compile/run (UVM 1.2)
```

**What it checks:** the active RDI agent drives 128-bit block payloads; the DUT frames them to
`TxData`; the PHY BFM loops `TxData → RxData`; the deframer recovers the payloads; the
scoreboard checks the **RDI-payload round-trip** (recovered == driven, in order) and flags any
leak. Coverage samples the framing mode (data vs ordered-set) and the `Rate × Width` /
`PowerDown` state off the MAC interface. The top drives static Gen5 command values for now.

**Verilator cross-check:** the DUT wiring (`pipe7_mac_dut`, built from the lint-clean framer +
deframer) is elaborated by the repo-root `make lint`, so the structural core of this env is
gate-validated even though the UVM classes are review-only.

## Item 9 — control plane (this commit)

Wires the item-3 control FSM into the DUT and adds the control-plane env:

```
pipe7_ctrl_if.sv          controller request/status interface (req/busy/done/req_error)
pipe7_mac_dut.sv          now also instantiates pipe7_mac_ctrl_fsm (command outputs -> mac_if)
pipe7_mac_pkg.sv (added)  ctrl_transaction; pipe7_ctrl_agent (active request driver, captures
                          outcome + PIPE command state); pipe7_phy_agent (PHY-responder BFM:
                          watches PowerDown/Rate/Width and drives PhyStatus after a latency,
                          via the interface's new phy_cb); pipe7_ctrl_scoreboard (independent
                          legality model -- Rate/Width legal only in P0/P1 -- checks each
                          request's outcome and resulting command state)
seq_lib/pipe7_seq_lib.sv  pipe7_ctrl_directed_seq (power ladder + Gen5<->Gen6 + Width + two
                          illegal rate changes) and tests: pipe7_ctrl_test, pipe7_full_test
```

**What it checks:** the PHY-responder agent answers every PowerDown/Rate/Width change with a
spec-timed `PhyStatus`; the legality scoreboard confirms each request reaches the right outcome
(11 completions + 2 rejections in the directed scenario) and the command state matches the
model. `pipe7_full_test` runs the datapath round-trip and the control scenario concurrently.

## Item 10 — RX path + message-bus checker (this commit)

```
pipe7_msgbus_if.sv        controller request/response interface for the message-bus master
pipe7_mac_if.sv (added)   phy_rx_cb clocking block (PHY drives RxData in the rx_clk domain)
pipe7_mac_dut.sv (added)  instantiates pipe7_msgbus_master + pipe7_regfile (M2P/P2M + snapshot)
pipe7_mac_pkg.sv (added)  msgbus_transaction; pipe7_msgbus_agent (drives register read/writes,
                          captures the response); pipe7_msgbus_responder (INDEPENDENTLY decodes
                          the M2P framing, drives P2M read_completion/write_ack from a local
                          register model, publishes each decode); pipe7_msgbus_scoreboard
                          (pairs each request with the decode: checks the M2P bytes vs an
                          independent encode, cmd/addr/wdata, and read data vs a register model).
                          The pipe7_phy_agent now also drives RxData (loopback of the framed
                          TxData) via phy_rx_cb -- the RX path is PHY-sourced, and the round-trip
                          scoreboard is the mirrored-queue RX check.
seq_lib/pipe7_seq_lib.sv  pipe7_msgbus_directed_seq + pipe7_msgbus_test, pipe7_rx_test; the
                          combined pipe7_full_test now also runs the message-bus scenario.
```

**What it checks:** register read/writes are framed by the master, independently decoded by the
PHY responder, and cross-checked (framing bytes + cmd/addr/wdata + read data / committed-write→
read round-trip) — mirroring the PyUVM message-bus tier. The PHY now sources RxData so the
deframe is genuinely PHY-driven.

**Scope note:** the RX path exercises Gen5 128b/130b (loopback of the framed stream). Gen6
wide-data UVM RX stimulus is a documented follow-on — the Gen6 raw path is already proven by the
Verilator `verilator_gen6` smoke and the PyUVM datapath tier; folding it into this DUT needs the
Gen5/Gen6 rate-mux + width gearbox (the same integration deferred elsewhere).

## Item 11 — functional-coverage closure (this commit)

The env's coverage model (all covergroups report `%` via `get_coverage()` in `report_phase`
under VCS; the directed `pipe7_full_test` is built to close every bin):

| Covergroup (component) | Coverpoints / crosses | Closed by |
|------------------------|-----------------------|-----------|
| `cg_ctrl` (`ctrl_cov`, off the MAC monitor) | `cp_rate` (Gen5/Gen6), `cp_width` (10/20/40/80/160), `cp_pd` (P0/P0s/P1/P2), **`cp_framing_mode`** (Gen5-130b / Gen6-wide), **`x_rate_width`** cross | control ladder + Gen5↔Gen6 |
| `cg_req` (`req_cov`, off the control agent) | `cp_kind` (power/rate/width), `cp_done`, **`cp_latency`** (PhyStatus completion: immediate/short/long/over), `x_kind_done` | directed control scenario (11 done + 2 reject) |
| `cg_op` (`mbus_cov`, off the msgbus agent) | **`cp_opcode`** (read / write_uncommitted / write_committed), `cp_is_read` | directed message-bus scenario |
| `cg_frame` (`frame_cov`, off the recovered RDI) | `cp_is_os` (data / ordered-set block) | random datapath payloads |

This closes the plan's item-11 set: **Rate×Width**, **PowerDown-state**, **framing-mode**,
**message-bus-opcode**, and **PhyStatus-latency**. Because the tier is authored-not-run here,
the numeric percentages are produced under VCS; the sampling wiring and bins are review-fixed.

## Roadmap (PLAN.md item 12)

- **12** — docs + coverage sign-off (finalize architecture / verification_plan / uvm docs;
  record the coverage baseline).
