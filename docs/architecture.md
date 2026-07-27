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
| `pipe7_tx_framer_gb` / `pipe7_rx_deframer_gb` | Full-width **gearbox** variants: accept/emit up to **two** 130b blocks per `pclk`, so the full SerDes width set {10..160} works (width-160 ≈ 1.23 blocks/cycle, bursts to two). |
| `pipe7_mac_datapath` | Gen5 datapath (framer + deframer) with a **data-phase FSM that owns `TxElecIdle`**: asserted (idle) except while transmitting, so `TxDataValid` is never high while `TxElecIdle` is asserted (assertion P1). A data phase starts only in P0 and ends after the framer drains. |
| `pipe7_mac_datapath_ra` | **Rate-aware** datapath: muxes the Gen5 gearbox vs the Gen6 raw path by `Rate`; the data-phase FSM owns `TxElecIdle` across both rates (rate-mux exclusivity + gating are formally proved). |
| `pipe7_gen6_datapath` | Gen6 (Rate=5) raw wide datapath: no 128b/130b sync header (1b/1b at the PIPE datapath); carries the `PAM4RestrictedLevels` config. Flit/FEC/LCRC are controller-side. |
| `pipe7_rdi_ingress` / `pipe7_rdi_egress` | **UCIe RDI credit flow control**: reassemble credit-gated RDI flits (`sob`/`is_os`) ↔ 128b block payloads; the sink advertises `CREDITS` slots and returns a credit per freed flit (no-underflow/over-credit is formally proved). |
| `pipe7_msgbus_master` + `pipe7_regfile` | 8-bit M2P/P2M message-bus master (read = 2 cyc, write = 3 cyc; read_completion / write_ack) + MAC-side register file. |
| `ucie_rdi_to_pipe7_mac_bridge` | **Integrated top** (item 20): RDI ingress/egress (+credits) → RDI↔PCLK CDC → Gen5 128b/130b datapath (`TxElecIdle`-gated) → PIPE MAC, alongside the control FSM and the message-bus master/regfile. Dual-clock (`rdi_clk` + `pclk`). |

## Clock-domain crossing & reset

The RDI (`rdi_clk`) and PIPE (`pclk`) domains are bridged by `pipe7_cdc_elastic_buf` (Gray-coded
pointers + 2-flop synchronizers). The dual-clock crossing is proven safe under **independent**
clocks by the multiclock formal proof (`verification/formal/cdc_mc.sby`, on the real RTL via
yosys-slang): physical occupancy `wr_ptr − rd_ptr` stays in `[0, BUFFER_DEPTH]` (writes are gated
by `wr_full`, computed from the conservative *lagging* synchronized read pointer). CDC timing
intent is captured in `constraints/pipe7_cdc_elastic_buf.sdc` (asynchronous clock groups +
`set_max_delay -datapath_only` on the Gray crossings).

**Reset:** `rst_n` is async and fans into both domains. Assertion is async-safe; deassertion must
be recovery/removal-clean **per domain** — a deployment feeds `rst_n` through a per-domain reset
synchronizer (async-assert, sync-deassert). The SDC notes where to cut the raw reset crossing.

## Datapath

```
RDI TX flits ─► rdi_ingress (credits) ─► RDI↔PCLK CDC ─► framer (Gen5 128b/130b) ─► TxData ─► (PHY)
   (rdi_clk)                                                or gen6_datapath (raw wide, Gen6)

(PHY) ─► RxData/RxValid ─► deframer (Gen5 block align + sync) ─► RDI↔PCLK CDC ─► rdi_egress ─► RDI RX flits
                            or gen6_datapath (raw)                                              (rdi_clk)
```

Two RDI_WIDTH-bit flits (`sob`=1 then `sob`=0, same `is_os`) reassemble one 128b block. The
integrated top now uses the **rate-aware datapath** (`pipe7_mac_datapath_ra`, item 29): the Gen5
full-width gearbox / Gen6 raw plane muxed by `Rate`. The gearbox can recover up to two blocks per
`pclk` at width 160 (a block straddling two 160-bit words); a small **burst FIFO**
(`pipe7_rx_burst_fifo`) absorbs the 0/1/2-per-cycle burst and drains one block/`pclk` into the
block-payload CDC. So the top works across the width set (validated end-to-end at 80 and 160), as
long as the RDI source rate keeps the recovered rate within the CDC drain (else `rx_overflow`).

**RX has no PHY backpressure** (the deframer cannot stall `RxData`): a recovered block presented
while the RX CDC is full is dropped, so the operating point must keep the PIPE-RX rate within the
RDI sink's drain rate. The bridge surfaces each such drop on `rx_overflow` (a one-`pclk` pulse the
controller latches/counts); the smokes bind an assertion that it never fires in the verified
envelope (item 26). Sizing the RDI clock/width/credits so overflow is provably impossible is
tracked as item 26's policy follow-through.

Gen5 embeds a 2-bit sync header per 130-bit block (data `0b10` / ordered-set `0b01`). Gen6
carries raw already-encoded data with no per-block header (the 256B flit + FEC + LCRC are built
controller-side and arrive on RDI). Width/RxWidth ∈ {10,20,40,80,160}.

## Control plane

A request FSM (`pipe7_mac_ctrl_fsm`) sequences PowerDown/Rate/Width changes toward the PHY and
waits for the single-cycle `PhyStatus` completion. **L0p** is realized as an ordinary
`Width`/`RxWidth` change — there is no dedicated L0p handshake. Each `PhyStatus`/`PclkChangeOk`
wait is bounded by a parameterized watchdog (`TIMEOUT_CYCLES`, default 1024): a hung PHY aborts
the request with a `req_error` pulse and recovers to idle rather than hanging (item 28). The
message-bus master carries the same watchdog on its `write_ack`/`read_completion` waits,
completing a timed-out access with `rsp_valid` + `rsp_error`. Non-latency-sensitive control
(Tx equalization presets/de-emphasis, `PAM4RestrictedLevels`, Rx margining) is programmed over
the 8-bit message bus into the PHY register space; there is **no FEC register** on the PIPE
interface. A committed write to `REG_PHY_PAM4_RESTRICTED_LEVELS` is additionally **written
through** into a MAC-side register that drives the Gen6 datapath's `PAM4RestrictedLevels` — the
MAC's only PAM4 knob (item 30). `PIPE_WIDTH` is compile-parameterized (validated at 80 and 160);
runtime sub-width lane selection is a datapath refinement.

## What crosses the PIPE boundary vs. not

- **Crosses (MAC drives / samples):** TxData/TxDataValid, PowerDown/Rate/Width/RxWidth,
  TxElecIdle, Reset#, M2P/P2M message bus; RxData/RxValid, PhyStatus, RxStatus (only the
  "receiver detected" code applies in SerDes), RxElecIdle, message-bus responses.
- **Does not cross:** 128b/130b block-coding pins (MAC does the coding in-band), FEC / flit-LCRC
  (controller-side), PAM4 precoding math (PHY-side), 256B flit framing (controller-side).
