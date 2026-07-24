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
models/framing_model.py  INDEPENDENT Python 128b/130b framer/deframer reference
agents/ucie_rdi_agent.py PayloadItem + driver + output monitor + agent (mirrors the UVM taxonomy)
pipe7_pyuvm_env.py       uvm_env + 3-way cross-check scoreboard
seq_lib/pipe7_seq_lib.py seeded payload sequence (exportable golden vectors)
test_datapath.py         uvm_test: Gen5 128b/130b datapath cross-check (item 13)
vectors/                 exported golden vectors (shared-stimulus cross-check mode)
```

## Run

```
pip install -r requirements.txt          # into the Python that owns cocotb-config
make                                      # datapath cross-check, Verilator
make SIM=icarus                           # alternate simulator
make MODULE=test_datapath                 # explicit test
```

## Cross-check (item 13, datapath)

The scoreboard performs a **three-way** check so a common-mode framing bug cannot pass:

1. **round-trip identity** — DUT recovered payloads == driven payloads.
2. **framer vs Python model** — the DUT's raw `TxData` word stream == `framing_model.frame_stream`
   of the driven payloads, **bit-exact**.
3. **Python deframe vs DUT** — `framing_model.deframe_stream` of the DUT's own stream == the
   DUT's recovered payloads, and every sync header is legal.

Any disagreement localizes the bug to exactly one of {DUT, SV-TB, Python-TB}. The seeded
sequence also exports the exact stimulus to `vectors/datapath_vectors.txt` for the SV/UVM env
(shared-golden-vector mode). Control-plane, message-bus, and coverage-parity cross-checks are
item 14.
