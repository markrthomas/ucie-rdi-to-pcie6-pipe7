# Tier 1b — PyUVM-on-Cocotb cross-check

A **PyUVM** (UVM 1.2 in Python) environment driving the RTL via **cocotb** on an open-source
simulator (**Verilator** default, **Icarus** alternate). Unlike the VCS/UVM tier (authored,
not run here), this tier **actually executes** in the OSS environment, giving a *second*
runnable gate whose job is to **cross-check** the SV/Verilator and UVM envs with an
independent Python reference model — implementation diversity that catches common-mode bugs.

See `PLAN.md` → "DV environment → Tier 1b" and closure items 13–14.

## Layout

```
Makefile                 cocotb flow (SIM=verilator default | icarus); MODULE selects the test
requirements.txt         cocotb + pyuvm (+ cocotb-coverage for item 14)
hdl/pipe7_framing_top.sv thin DUT wrapper: framer -> deframer loopback + observable TxData
hdl/pipe7_bridge_top.sv  thin DUT wrapper: INTEGRATED bridge + PHY loopback + responder stubs
hdl/pipe7_gen6_rx_top.sv thin DUT wrapper: rate-aware datapath in Gen6, raw wide RX injection
models/framing_model.py  INDEPENDENT Python 128b/130b framer/deframer reference
models/rdi_model.py      INDEPENDENT Python RDI flit <-> 128b block packing reference
models/gen6_model.py     INDEPENDENT Python Gen6 raw RX reference (identity, order-preserving)
agents/ucie_rdi_agent.py PayloadItem + driver + output monitor + agent (mirrors the UVM taxonomy)
pipe7_pyuvm_env.py       uvm_env + 3-way cross-check scoreboard
seq_lib/pipe7_seq_lib.py seeded payload sequence (exportable golden vectors)
test_datapath.py         uvm_test: Gen5 128b/130b datapath cross-check (item 13)
test_bridge.py           uvm_test: INTEGRATED-bridge RDI round-trip 3-way cross-check (item 23)
test_gen6_rx.py          uvm_test: Gen6-wide RX mirrored-queue cross-check (item 23)
vectors/                 exported golden vectors (shared-stimulus cross-check mode)
```

## Run

```
pip install -r requirements.txt          # into the Python that owns cocotb-config
make                                      # datapath cross-check, Verilator
make all_tests                            # all three cross-checks (or `make cocotb` from repo root)
make MODULE=test_ctrl_plane               # a specific cross-check
make SIM=icarus ...                       # alternate simulator
```

## Cross-checks

**Datapath (item 13, `test_datapath.py`)** — a **three-way** check so a common-mode framing bug
cannot pass:
1. **round-trip identity** — DUT recovered payloads == driven payloads.
2. **framer vs Python model** — the DUT's raw `TxData` word stream == `framing_model.frame_stream`,
   **bit-exact**.
3. **Python deframe vs DUT** — `framing_model.deframe_stream` of the DUT's own stream == the
   DUT's recovered payloads, all sync headers legal.

**Control-plane (item 14, `test_ctrl_plane.py`)** — PowerDown/Rate/Width requests answered by an
**independently-authored** PyUVM `PhyStatusResponder`; each request's outcome (done vs reject)
and command state cross-checked against `ctrl_plane_model` (13 requests, 2 rejects).

**Message-bus (item 14, `test_msgbus.py`)** — register read/writes answered by an independent
PyUVM `MsgbusResponder`; the M2P byte framing is decoded independently and checked against
`msgbus_model.encode_m2p`, plus read data / a committed-write→read round-trip vs a register model.

**Integrated bridge (item 23, `test_bridge.py`)** — drives the real
`ucie_rdi_to_pipe7_mac_bridge` (dual-clock, credit-based flit RDI) end-to-end and cross-checks
three ways: (1) recovered flits == driven flits (data/sob/is_os), (2) `framing_model.deframe_stream`
of the DUT `TxData` == the driven blocks, (3) the DUT `TxData` stream == `framing_model.frame_stream`
bit-exact over the overlap. `rdi_model` maps flits ↔ 128b blocks independently.

**Gen6-wide RX (item 23, `test_gen6_rx.py`)** — injects raw Gen6 wide words at the rate-aware
datapath's RX (held in Gen6 data phase) and checks the recovered stream against
`gen6_model.recover_rx` (identity, order-preserving) with a mirrored injection-order queue — the
deferred item-10 Gen6-wide RX follow-on.

Each cross-check ends with a `cocotb-coverage` bin-parity check. The datapath sequence also
exports its stimulus to `vectors/datapath_vectors.txt` (shared-golden-vector mode).

> pyuvm note: `check_phase` runs **top-down** (parent before child), so all pass/fail assertions
> live in the leaf scoreboards' `check_phase` — asserting in the test's own `check_phase` would
> read scoreboard results before they are computed (a silent vacuous pass).
