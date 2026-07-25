# Architecture

The UCIe RDI ↔ PCIe 6.x / PIPE 7.1 MAC-facing bridge (Gen5 + Gen6). The bridge plays the
**MAC/controller** role: it drives MAC-owned signals and reacts to PHY-owned ones. It does not
model PHY internals (SerDes, PAM4 precoding/gray-code, CDR, electrical-idle detection). See
`PLAN.md` for the locked scope and `docs/pipe71_spec_crosscheck.md` for the item-0 reconciliation
against the controlled Intel PIPE 7.1 spec (Ref 643108, Rev 7.1).

## Clock domains

- **PCLK** — the parallel PIPE domain: command/status/message-bus signals and TxData.
- **RxCLK** — the SerDes recovered Rx clock: RxData / RxValid (asynchronous to PCLK).
- **RDI clock** — the UCIe RDI domain (upstream of the datapath gearbox).
- **Reset#** — active-low, asynchronous.

The elastic buffer `pipe7_cdc_elastic_buf` (ported, formally-checked Gray-pointer async FIFO)
crosses RDI↔PCLK with pointer-only synchronization (no combinational data path across domains).

## Modular cores (`src/`)

| Module | Role |
|--------|------|
| `pipe7_pkg` | Geometry + spec-accurate control-plane encodings (PowerDown/Rate/Width, message-bus opcodes/addresses, 128b/130b constants). |
| `pipe7_cdc_elastic_buf` | Dual-clock Gray-pointer elastic buffer (RDI↔PCLK). |
| `pipe7_mac_ctrl_fsm` | PowerDown/Rate/Width sequencer, gated on `PhyStatus`; Rate/Width legal only in P0/P1 (§8.4.1). PCLK-as-PHY-input adds the `PclkChangeOk`→`PclkChangeAck` handshake. |
| `pipe7_tx_framer` / `pipe7_rx_deframer` | **MAC-owned** Gen5 128b/130b block coding: the 2-bit sync header is embedded in TxData/RxData (no discrete sync-header/start-block pins in SerDes). The deframer recovers block alignment (sync-header hunt + bit-slip). |
| `pipe7_gen6_datapath` | Gen6 (Rate=5) raw wide datapath: no 128b/130b sync header (1b/1b at the PIPE datapath); carries the `PAM4RestrictedLevels` config. Flit/FEC/LCRC are controller-side. |
| `pipe7_msgbus_master` + `pipe7_regfile` | 8-bit M2P/P2M message-bus master (read = 2 cyc, write = 3 cyc; read_completion / write_ack) + MAC-side register file. |
| `ucie_rdi_to_pipe7_mac_bridge` | Top; per-lane generate (item-1 datapath skeleton; core integration is progressive). |

## Datapath

```
RDI payload ─► framer (Gen5 128b/130b)  ─► TxData / TxDataValid ─► (PHY)
                or gen6_datapath (raw wide, Gen6)

(PHY) ─► RxData / RxValid ─► deframer (Gen5 block align + sync check) ─► RDI payload
                              or gen6_datapath (raw)
```

Gen5 embeds a 2-bit sync header per 130-bit block (data `0b10` / ordered-set `0b01`). Gen6
carries raw already-encoded data with no per-block header (the 256B flit + FEC + LCRC are built
controller-side and arrive on RDI). Width/RxWidth ∈ {10,20,40,80,160}.

## Control plane

A request FSM (`pipe7_mac_ctrl_fsm`) sequences PowerDown/Rate/Width changes toward the PHY and
waits for the single-cycle `PhyStatus` completion. **L0p** is realized as an ordinary
`Width`/`RxWidth` change — there is no dedicated L0p handshake. Non-latency-sensitive control
(Tx equalization presets/de-emphasis, `PAM4RestrictedLevels`, Rx margining) is programmed over
the 8-bit message bus into the PHY register space; there is **no FEC register** on the PIPE
interface.

## What crosses the PIPE boundary vs. not

- **Crosses (MAC drives / samples):** TxData/TxDataValid, PowerDown/Rate/Width/RxWidth,
  TxElecIdle, Reset#, M2P/P2M message bus; RxData/RxValid, PhyStatus, RxStatus (only the
  "receiver detected" code applies in SerDes), RxElecIdle, message-bus responses.
- **Does not cross:** 128b/130b block-coding pins (MAC does the coding in-band), FEC / flit-LCRC
  (controller-side), PAM4 precoding math (PHY-side), 256B flit framing (controller-side).
