# Interface specification — UCIe RDI → PIPE 7.1 MAC bridge

**Integration contract** for `ucie_rdi_to_pipe7_mac_bridge`. Two ports face outward: the
**UCIe RDI** side (controller-facing) and the **PIPE 7.1 MAC** side (PHY-facing). This
document is the human-readable contract; the machine-readable PIPE contract is
`test/uvm/pipe7_mac_if.sv`, and every PIPE signal's direction/width/§ref is tabulated in
`docs/pipe71_mac_signal_map.md`.

> **Status (closure-plan item 2): contract only — no behavior.** The PIPE side is defined
> here and in `pipe7_mac_if.sv`; the control FSM, message-bus master, and framers that
> *drive* these signals arrive in items 3–6. PIPE signal names/widths are confirmed against
> Intel **PIPE 7.1 (Ref 643108, Rev 7.1)** — see `docs/pipe71_spec_crosscheck.md`.

## Scope

- **PIPE architecture:** SerDes (async PHY interface); the PHY is parallel↔serial only, so
  the **MAC (this bridge) owns 128b/130b encode/decode, block alignment, and the elastic
  buffer**. The block sync header rides *in-band* in `TxData`/`RxData` — there are **no**
  `TxStartBlock`/`TxSyncHeader`/`RxStartBlock`/`RxSyncHeader`/`*DataK` pins (Original-PIPE-only).
- **Rates:** Gen5 (`Rate=4`, 32 GT/s, 128b/130b) and Gen6 (`Rate=5`, 64 GT/s, PAM4). No
  legacy Gen1–4. "FLIT mode", FEC, and flit-LCRC are controller-side (above PIPE) and cross
  the interface as opaque `TxData`/`RxData`.
- **Role:** MAC-facing — the bridge drives MAC-owned signals and reacts to PHY-owned ones;
  it does not model PHY internals (SerDes, PAM4 precoding, CDR, EI detection).

## Parameters (compile-time)

`pipe7_pkg` centralizes geometry; `pipe7_mac_if` is parameterized per lane.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_LANES` | 4 | Per-lane independent datapaths (bridge top). |
| `RDI_DATA_WIDTH` | 16 | RDI data width per lane (bits). |
| `TX_DATA_WIDTH` | 160 | PIPE Tx parallel width per lane; **must be one of {10,20,40,80,160}** (PCIe SerDes), selected by `Width`. |
| `RX_DATA_WIDTH` | 160 | PIPE Rx parallel width per lane; same valid set, selected by `RxWidth`. |
| `MB_WIDTH` | 8 | `M2P`/`P2M` message-bus width (`pipe7_pkg::MB_BUS_WIDTH`). |
| `MB_ADDR_WIDTH` | 12 | Message-bus register address-space width (`pipe7_pkg::MB_ADDR_WIDTH`). |
| `BUFFER_DEPTH` | 16 | Elastic-buffer entries **per lane**; ≥ 1. |

> The item-1 pass-through still uses `PIPE_DATA_WIDTH=32` as a placeholder; items 5–6
> re-derive the real per-lane width from `Width`/`RxWidth` (see `pipe7_pkg` note).

## Clocking and reset

| Signal | Domain | Description |
|--------|--------|-------------|
| `rdi_clk` | RDI | Controller-side clock; captures all RDI-domain sequential logic. |
| `pclk` | PIPE parallel | PIPE command/status/message-bus clock. May be a PHY **output** or **input** (clocking topology, §8.1). |
| `rx_clk` | PIPE Rx (recovered) | SerDes recovered clock; `RxData`/`RxValid` are synchronous to it, **not** `pclk`. PHY keeps it running ≥ 8 clocks after `RxValid` deasserts. |
| `Reset#` (`reset_n`) | async | Active-low, asynchronous; may assert any time. PHY holds its lowest-power state while asserted; reports its default power state after reset. |

The RDI↔PCLK and PCLK↔RxCLK crossings are handled by `pipe7_cdc_elastic_buf` (ported,
formally-checked CDC).

## UCIe RDI side (controller ↔ bridge)

Per-lane valid/ready with packed data (unchanged from item 1; carries controller-formed
data — including any flit/FEC/LCRC framing built upstream).

| Signal | Width | Dir | Description |
|--------|-------|-----|-------------|
| `rdi_valid` | `NUM_LANES` | In | Per-lane beat valid. |
| `rdi_ready` | `NUM_LANES` | Out | Per-lane accept (elastic buffer not full). |
| `rdi_data` | `NUM_LANES*RDI_DATA_WIDTH` | In | Packed: lane `k` = `rdi_data[k*RDI_DATA_WIDTH +: RDI_DATA_WIDTH]`. |
| `rdi_error` | `NUM_LANES` | In | Per-lane metadata/error flag sampled with the beat. |
| `rdi_flow_ctrl` | `NUM_LANES` | Out | Asserted when that lane's buffer is full. |

**Rules:** a beat transfers on lane `k` when `rdi_valid[k] && rdi_ready[k]` on a rising
`rdi_clk`; `rdi_data[k]`/`rdi_error[k]` must be stable while `rdi_valid[k]` holds.

## PIPE 7.1 MAC side (bridge ↔ PHY)

Full per-signal detail (direction from the MAC perspective, width, sync domain, spec §) is
in **`docs/pipe71_mac_signal_map.md`**; the machine-readable form is the `mac` modport of
**`pipe7_mac_if.sv`**. Summary of the groups the bridge is responsible for:

- **Drives (MAC → PHY):** `TxData`, `TxDataValid`; `PowerDown[3:0]`, `Rate[3:0]`,
  `Width[2:0]`, `RxWidth[2:0]`, `TxElecIdle[3:0]`, `TxDetectRx/Loopback`, `SerDesArch`,
  `RxStandby`, `SRISEnable`, `Reset#`; the rate/power handshake acks `PclkChangeAck`,
  `AsyncPowerChangeAck`; `M2P_MessageBus[7:0]`; and (optional, may be tied off)
  `TxCommonmodeDisable`, `RxEIDetectDisable`, `DeepPMReq#`, `Restore#`.
- **Samples (PHY → MAC):** `RxData` (on `rx_clk`), `RxValid`; `PhyStatus`, `RxStatus[2:0]`,
  `RxElecIdle`, `RxStandbyStatus`, `PclkChangeOk`, `RefClkRequired#`, `DeepPMAck#`;
  `P2M_MessageBus[7:0]`.

### Handshake protocols (contract the item-3+ FSMs must honor)

1. **Power-state change** (`PowerDown[3:0]`): assert the new value; completion is a
   single-cycle `PhyStatus`. Transitions where PCLK is absent are asynchronous; L1-substate
   power changes without PCLK use `AsyncPowerChangeAck` (assert until `PhyStatus` deasserts).
2. **Rate / Width / PCLK-rate change:** permitted **only in P0 or P1**, with `TxElecIdle`
   asserted (and `RxStandby` in P0). Change the field(s); completion is a single-cycle
   `PhyStatus`. In *PCLK-as-PHY-input* mode, insert the `PclkChangeOk`→(MAC changes PCLK)→
   `PclkChangeAck`→`PhyStatus` handshake. **No numeric max-latency bound** exists — it is
   PHY-datasheet/implementation-specific, so any completion-timeout assertion (item 7) must
   be a **parameter**, not a fixed constant.
3. **Message bus** (`M2P`/`P2M`, both on `pclk`): idle = `0x00`; framing per §6.1.4.2
   (read = 2 cyc, read-completion = 2 cyc, write = 3 cyc); 12-bit addr, 8-bit data; 4-bit
   commands (`NOP`/`write_uncommitted`/`write_committed`/`read`/`read_completion`/
   `write_ack`). One outstanding read per direction; `write_committed` blocks further writes
   until `write_ack`. Register map in the signal-map doc.
4. **Receiver detect:** driven via `TxDetectRx/Loopback`; result reported as
   `RxStatus == 0b011` (the only `RxStatus` code meaningful in SerDes) and completed by
   `PhyStatus`.

### Reaction rules the bridge must implement

- `RxData`/`RxValid` are in the `rx_clk` domain; cross them to the RDI/PCLK domain through
  the elastic buffer, and start MAC-side symbol/block lock only after `RxValid` (= `rx_clk`
  stable).
- At Gen5/Gen6, **do not trust `RxElecIdle` for electrical-idle *entry***; the MAC detects
  EI-entry with its own logic (spec requirement ≥ 5 GT/s).
- `TxDataValid` must be asserted whenever `TxElecIdle` toggles (it qualifies EI sampling).

## Out of scope on this interface

PHY internals (SerDes, PAM4 precoding/gray-code, CDR, EI detection); FEC / flit-LCRC codec
(controller-side — no FEC signalling or register crosses PIPE); Original-PIPE block-coding
pins; Gen1–4 legacy rates. See `PLAN.md` "Explicitly out of scope".

## Timing / constraints placeholders

Example constraint shells (not signed off): `constraints/example.xdc`, `constraints/example.sdc`.

## Reference bundle

- `test/uvm/pipe7_mac_if.sv` — machine-readable PIPE MAC contract (modports + clocking blocks).
- `docs/pipe71_mac_signal_map.md` — per-signal direction/width/§ + register address map.
- `docs/pipe71_spec_crosscheck.md` — item-0 reconciliation against the controlled spec.
- `src/pipe7_pkg.sv` — parameters and control-plane encodings (PowerDown/Rate/Width, msg-bus commands).
