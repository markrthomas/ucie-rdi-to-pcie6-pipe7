# PIPE 7.1 spec cross-check (closure-plan item 0)

**Status: SCAFFOLD — all rows UNCONFIRMED.** This document reconciles every
PIPE-related assertion this project currently makes (in `PLAN.md`, `src/pipe7_pkg.sv`,
and the item-2 interface work to come) against the **controlled Intel PIPE 7.1
specification** and the relevant **PCIe 6.x base** sections (FLIT / PAM4 / L0p).

Until each row is resolved, every concrete constant below is a **working-knowledge
placeholder**, not a verified fact. **Item 0 blocks items 2–12** — do not freeze the
interface (`pipe7_mac_if.sv`), register map, or control-plane encodings until the rows
they depend on read ✅ Confirmed or ✏️ Corrected.

## How to use

1. Open the controlled PIPE 7.1 spec (+ PCIe 6.x base for flit/PAM4/L0p).
2. For each row, fill **Spec §** and set **Verdict**:
   - ✅ **Confirmed** — placeholder matches the spec.
   - ✏️ **Corrected** — put the spec-correct value in **Notes**; then fix the source
     (`pipe7_pkg.sv`, `PLAN.md`, interface).
   - 🚫 **N/A** — assertion doesn't apply to our MAC-facing SerDes-arch / Gen5+Gen6 scope.
3. Record spec **document + revision** used below, and log resolutions at the bottom.
4. Fold every ✏️ correction back into source **before** starting item 2.

**Spec references used:** _TBD — record document title + revision/date here._

---

## A. Datapath architecture

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| A1 | SerDes Architecture (async PHY interface) is a supported PIPE 7.1 mode | _TBD_ | ❓ TODO | |
| A2 | The 8-bit M2P/P2M message bus carries most control/status in SerDes arch | _TBD_ | ❓ TODO | |
| A3 | Discrete PCLK/PowerDown/Rate/Width pins are NOT required in SerDes arch (folded into msg bus) | _TBD_ | ❓ TODO | confirm which signals stay discrete vs msg-bus |
| A4 | MAC drives Tx + config; PHY drives Rx + status (direction split as in §D/§E) | _TBD_ | ❓ TODO | |

## B. Rate / mode scope (Gen5 + Gen6 only)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| B1 | Gen5 = 32 GT/s, 128b/130b block encoding | _TBD_ | ❓ TODO | |
| B2 | Gen6 = 64 GT/s, PAM4 signaling, FLIT mode | _TBD_ | ❓ TODO | |
| B3 | `pipe7_pkg::rate_e` = { RATE_GEN5=2'd0, RATE_GEN6=2'd1 } | _TBD_ | ❓ TODO | **placeholder encoding — almost certainly wrong vs spec Rate field** |
| B4 | `Rate` field bit-width on the MAC interface | _TBD_ | ❓ TODO | spec may use 3+ bits / msg-bus register |
| B5 | Rate-change requires a specific PowerDown state (see D3) | _TBD_ | ❓ TODO | |

## C. Power management (PowerDown / L0p)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| C1 | `pipe7_pkg::powerdown_e` = { P0=0, P0S=1, P1=2, P2=3 } | _TBD_ | ❓ TODO | confirm exact 2-bit encoding |
| C2 | PowerDown is 2 bits on the MAC interface | _TBD_ | ❓ TODO | |
| C3 | L0p (partial-width low-power L0) exists in Gen6 and uses the Width handshake | _TBD_ | ❓ TODO | |
| C4 | L0p entry/exit request + acknowledge mechanism | _TBD_ | ❓ TODO | discrete pins vs msg-bus register |

## D. Control-plane handshakes (PhyStatus)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| D1 | `PhyStatus` asserts to signal completion of a PowerDown change | _TBD_ | ❓ TODO | |
| D2 | `PhyStatus` also gates Rate and Width changes | _TBD_ | ❓ TODO | |
| D3 | Legal PowerDown states in which a Rate change may be requested | _TBD_ | ❓ TODO | drives the item-3 FSM |
| D4 | Max latency bound for `PhyStatus` completion (assertion for item-7) | _TBD_ | ❓ TODO | per-transition timing table |
| D5 | `PhyStatus` handshake protocol (pulse vs level; N-cycle) | _TBD_ | ❓ TODO | |

## E. Signal inventory — MAC-owned (bridge drives → PHY)

| # | Signal (placeholder name) | Spec name / § | Verdict | Notes |
|---|---|---|---|---|
| E1 | `TxData` (parallel Tx symbols) | _TBD_ | ❓ TODO | width vs Rate/Width |
| E2 | `TxDataValid` | _TBD_ | ❓ TODO | SerDes-arch specific |
| E3 | `TxStartBlock` | _TBD_ | ❓ TODO | 130b + flit |
| E4 | `TxSyncHeader` | _TBD_ | ❓ TODO | Gen5 130b; flit equivalent? |
| E5 | `TxElecIdle` | _TBD_ | ❓ TODO | |
| E6 | `TxDetectRx/Loopback` | _TBD_ | ❓ TODO | |
| E7 | `TxCompliance` / Tx margin | _TBD_ | ❓ TODO | |
| E8 | `PowerDown[1:0]` | _TBD_ | ❓ TODO | discrete vs msg-bus (see A3) |
| E9 | `Rate` | _TBD_ | ❓ TODO | width per B4 |
| E10 | `Width` | _TBD_ | ❓ TODO | encoding + L0p partial |
| E11 | `Reset#` | _TBD_ | ❓ TODO | |
| E12 | M2P message-bus master signals | _TBD_ | ❓ TODO | see §G |

## F. Signal inventory — PHY-owned (bridge samples ← PHY)

| # | Signal (placeholder name) | Spec name / § | Verdict | Notes |
|---|---|---|---|---|
| F1 | `RxData` | _TBD_ | ❓ TODO | |
| F2 | `RxValid` | _TBD_ | ❓ TODO | |
| F3 | `RxStartBlock` | _TBD_ | ❓ TODO | |
| F4 | `RxSyncHeader` | _TBD_ | ❓ TODO | |
| F5 | `RxStatus[2:0]` (encodings) | _TBD_ | ❓ TODO | confirm width + code table |
| F6 | `PhyStatus` | _TBD_ | ❓ TODO | see §D |
| F7 | `RxElecIdle` | _TBD_ | ❓ TODO | |
| F8 | `RxStandbyStatus` | _TBD_ | ❓ TODO | |
| F9 | P2M message-bus response signals | _TBD_ | ❓ TODO | see §G |

## G. Message bus (M2P / P2M)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| G1 | Message bus is 8 bits per direction | _TBD_ | ❓ TODO | |
| G2 | Transaction framing (command/address/data phases) | _TBD_ | ❓ TODO | drives item-4 FSM |
| G3 | Opcode set (write/read/committed/etc.) + encodings | _TBD_ | ❓ TODO | enumerate in pipe7_pkg |
| G4 | Register address map: eq presets | _TBD_ | ❓ TODO | |
| G5 | Register address map: precoding-enable (PAM4) | _TBD_ | ❓ TODO | |
| G6 | Register address map: margining | _TBD_ | ❓ TODO | |
| G7 | Register address map: FEC status (pass-through) | _TBD_ | ❓ TODO | |
| G8 | Handshake / flow-control on the message bus | _TBD_ | ❓ TODO | |

## H. Framing — Gen5 128b/130b

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| H1 | 130b block = 2b sync header + 128b payload | _TBD_ | ❓ TODO | |
| H2 | Sync-header encodings (data vs ordered-set) | _TBD_ | ❓ TODO | |
| H3 | Block alignment / de-skew responsibility (MAC vs PHY) | _TBD_ | ❓ TODO | |

## I. Framing — Gen6 PAM4 FLIT

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| I1 | Flit size = 256 bytes | _TBD_ | ❓ TODO | confirm total incl. CRC/FEC fields |
| I2 | Flit internal layout (TLP payload / DLLP / CRC / FEC bytes) | _TBD_ | ❓ TODO | which fields cross the PIPE interface |
| I3 | Sync-header / block-type semantics in flit mode | _TBD_ | ❓ TODO | differs from 130b (H1) |
| I4 | PAM4 precoding: PHY performs it; MAC only enables via msg-bus reg (G5) | _TBD_ | ❓ TODO | |

## J. Function ownership (MAC-facing scope boundary)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| J1 | SerDes / PAM4 symbol mapping / precoding math = PHY (out of scope) | _TBD_ | ❓ TODO | |
| J2 | CDR / elec-idle detection = PHY (out of scope) | _TBD_ | ❓ TODO | |
| J3 | FEC codec = controller/RDI side, not the PIPE interface | _TBD_ | ❓ TODO | confirm no PHY-side FEC signalling we must drive |
| J4 | Flit LCRC = controller/RDI side | _TBD_ | ❓ TODO | |

---

## Source items to update on ✏️ corrections

- `src/pipe7_pkg.sv` — `powerdown_e` (C1), `rate_e` (B3), + new msg-bus opcode/addr
  constants (G3–G7) and Rate/Width widths (B4, E10).
- `PLAN.md` — any corrected signal names, flit sizing (I1), encodings.
- `docs/interface_spec.md` + `pipe71_mac_signal_map.md` (item 2) — authored **after**
  §E/§F/§G rows resolve.

## Resolution log

| Date | Rows resolved | By | Spec rev | Notes |
|------|---------------|-----|----------|-------|
| _TBD_ | | | | |
