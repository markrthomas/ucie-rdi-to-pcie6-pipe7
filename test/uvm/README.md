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

## Roadmap (PLAN.md items 10–12)

- **10** — RX Gen5 130b + Gen6 wide-data stimulus, mirrored RX queues, message-bus transaction
  scoreboard (item-4 master + regfile).
- **11** — functional-coverage closure (Rate×Width, PowerDown, framing-mode, msgbus-opcode,
  PhyStatus-latency covergroups); metrics in the README.
- **12** — docs + coverage sign-off.
