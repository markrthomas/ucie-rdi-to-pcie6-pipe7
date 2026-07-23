# PIPE 7.1 spec cross-check (closure-plan item 0)

**Status: RESOLVED against the controlled spec (2026-07-23).** All rows below are
reconciled against the **official Intel PIPE 7.1 specification** (see provenance). Every
✏️ Corrected row has had its correction folded back into `src/pipe7_pkg.sv` and/or
`PLAN.md`; see the "Source items updated" list and the resolution log at the bottom.

## Provenance (spec references used)

- **PIPE spec:** *PHY Interface for the PCI Express, SATA, USB 3.2, DisplayPort, and
  USB4 Architectures*, **Reference Number 643108, Revision 7.1, September 2025**, Intel
  Corporation. Obtained from Intel's public document server
  (`cdrdv2-public.intel.com/643108/643108_PIPE_Arch_Spec_Rev_7_1.pdf`). This is Intel's
  officially published PIPE 7.1 release — treated as authoritative. Section/table numbers
  cited below are from this document. Page numbers (`p.N`) are given where a table's `§`
  number was ambiguous in the extracted text.
- **PCIe 6.x base:** **NOT fetched** (PCI-SIG membership-gated; not publicly retrievable).
  Rows that would otherwise depend on the PCIe base spec (flit internal layout, PAM4
  precoding math, LCRC/FEC codec) are resolved **via what PIPE 7.1 itself says about
  them** — namely that these functions live *above* the PIPE interface and are **not**
  signalled across it. Those rows are marked accordingly; none of them block our
  MAC-facing interface, so the missing base spec does not gate items 2–12.

### Headline findings (read these first — they change the PLAN)

1. **SerDes architecture ⇒ the PHY is parallel↔serial only.** 128b/130b block
   encode/decode, block alignment, and the elastic buffer all live in the **MAC**
   (§4.2, Fig 4-8/4-9). The bridge (playing MAC) owns framing.
2. **No sync-header / start-block / DataK pins in SerDes.** `TxStartBlock`,
   `TxSyncHeader`, `RxStartBlock`, `RxSyncHeader`, `TxDataK`, `RxDataK`, `RxDataValid`,
   `TxCompliance`, `AlignDetect` are all explicitly *"not used in the SerDes
   architecture"* (§6.3, Tables 6-19…6-23). The sync header is **embedded in
   `TxData`/`RxData`** because the MAC does the 128b/130b coding.
3. **The word "flit" does not appear in PIPE 7.1 (0 occurrences).** Flit framing, FEC, and
   flit-LCRC are PCIe-base concepts that sit *above* PIPE. At the PIPE interface, Gen6
   (64 GT/s) is just `Rate=5` + a wider parallel `TxData`/`RxData` with **no** 128b/130b
   sync header (1b/1b). The bridge does **not** build 256B flits on the PIPE side.
4. **Field widths are wider than placeholdered:** `PowerDown[3:0]`, `Rate[3:0]`,
   `TxElecIdle[3:0]`, `Width[2:0]`, plus SerDes-only `RxWidth[2:0]`.
5. **Rate encoding:** Gen5 (32 GT/s) = `Rate=4`, Gen6 (64 GT/s) = `Rate=5` — **not** 0/1.
6. **SerDes `TxData` is 10/20/40/80/160 bits** (PCIe), not 32. Datapath geometry must be
   re-derived from Width/RxWidth × PCLK-rate, not the placeholder `PIPE_DATA_WIDTH=32`.

**Legend:** ✅ Confirmed · ✏️ Corrected (spec-correct value in Notes; source fixed) ·
🚫 N/A (out of our MAC-facing / SerDes / Gen5+Gen6 scope, or not a PIPE-interface concern).

---

## A. Datapath architecture

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| A1 | SerDes Architecture (async PHY interface) is a supported PIPE 7.1 mode | §4.2; enabled by `SerDesArch` cmd pin (§6.1.2, Table 6-5) | ✅ Confirmed | PHY does parallel↔serial only; RxData is on recovered `RxCLK`, async to PCLK. `SerDesArch` changed only during `Reset#`. |
| A2 | The 8-bit M2P/P2M message bus carries most control/status in SerDes arch | §6.1.4, §8.29 | ✅ Confirmed | Non-latency-sensitive control/status mapped to 8-bit registers in 12-bit PHY/MAC address spaces, driven over `M2P/P2M_MessageBus[7:0]`. |
| A3 | Discrete PCLK/PowerDown/Rate/Width pins are NOT required in SerDes arch (folded into msg bus) | §6.1.2, §6.2 | ✏️ Corrected | **Wrong.** `PowerDown`, `Rate`, `Width`, `TxElecIdle`, `Reset#`, `PhyStatus`, `RxValid` remain **discrete latency-sensitive pins** in SerDes arch. The msg bus carries only *non-latency-sensitive* control/status (margining, eq presets, elastic-buffer/status regs). SerDes *removes* the block-coding pins (see #2 above), not the command pins. |
| A4 | MAC drives Tx + config; PHY drives Rx + status | §6 (I/O defined from PHY's perspective) | ✅ Confirmed | PHY "Input" = MAC-driven; PHY "Output" = PHY-driven. Matches §E/§F split below. |

## B. Rate / mode scope (Gen5 + Gen6 only)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| B1 | Gen5 = 32 GT/s, 128b/130b block encoding | Table 6-5 `Rate` (p.57); §8.26 | ✅ Confirmed | `Rate=4` ⇒ 32 GT/s. 128b/130b coding done by the MAC in SerDes arch. |
| B2 | Gen6 = 64 GT/s, PAM4 signaling, FLIT mode | Table 6-5 `Rate` (p.57) | ✏️ Corrected | `Rate=5` ⇒ 64 GT/s is confirmed. **But "FLIT mode" is not a PIPE concept** — "flit" appears 0× in the spec. PAM4 signaling/precoding is entirely PHY-side; at the PIPE interface Gen6 is wider parallel data with **no** 128b/130b sync header. Flit/FEC/LCRC are controller-side (above PIPE). |
| B3 | `rate_e` = { RATE_GEN5=2'd0, RATE_GEN6=2'd1 } | Table 6-5 `Rate` (p.57) | ✏️ Corrected | **Encoding wrong and width wrong.** `Rate[3:0]` (4 bits). PCIe: 0=2.5, 1=5.0, 2=8.0, 3=16.0, **4=32.0 (Gen5)**, **5=64 (Gen6)**, 6=128, 7–15 reserved. Fixed in `pipe7_pkg::rate_e`. |
| B4 | `Rate` field bit-width on the MAC interface | Table 6-5 `Rate` (p.57) | ✏️ Corrected | **4 bits** (`Rate[3:0]`), not 2. |
| B5 | Rate-change requires a specific PowerDown state (see D3) | §8.4.1 (p.126) | ✏️ Corrected | Rate/Width/PCLK-rate change allowed **only in P0 or P1**, with `TxElecIdle` asserted (and `RxStandby` in P0). Completion = single-cycle `PhyStatus`. Not a single "specific" state — P0 **or** P1. |

## C. Power management (PowerDown / L0p)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| C1 | `powerdown_e` = { P0=0, P0S=1, P1=2, P2=3 } | Table 6-5 `PowerDown[3:0]` PCIe (p.51) | ✏️ Corrected | Low-nibble values are right (P0=0, P0s=1, P1=2, P2=3) but the **field is 4 bits** (`PowerDown[3:0]`); 4–15 are PHY-specific power states (used for L1 substates). Widened enum in `pipe7_pkg::powerdown_e`. |
| C2 | PowerDown is 2 bits on the MAC interface | Table 6-5 (p.51) | ✏️ Corrected | **4 bits** (`PowerDown[3:0]`). |
| C3 | L0p (partial-width low-power L0) exists in Gen6 and uses the Width handshake | §8.26 (2 mentions only; p.183 context) | ✏️ Corrected | PIPE 7.1 has **no dedicated L0p mechanism and no "partial width" term.** L0p is a PCIe-LTSSM concept realized at the PIPE interface by an ordinary `Width`/`RxWidth` change using the **standard** rate/width→`PhyStatus` handshake (§8.4.1). No extra PIPE handshake states. |
| C4 | L0p entry/exit request + acknowledge mechanism | — | ✏️ Corrected / 🚫 | No PIPE-level L0p request/ack signals exist. Achieved via `Width`/`RxWidth` change (msg-bus/discrete per §6.2.2) + `PhyStatus`. The entry/exit *decision* is MAC/LTSSM, above the PIPE boundary. |

## D. Control-plane handshakes (PhyStatus)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| D1 | `PhyStatus` asserts to signal completion of a PowerDown change | Table 6-8 (p.64); §8.3–8.4 | ✅ Confirmed | Signals completion of power-state transitions, rate change, width change, receiver detect, and post-`Reset#` PCLK-stable. |
| D2 | `PhyStatus` also gates Rate and Width changes | §8.4.1 (p.126) | ✅ Confirmed | Single-cycle `PhyStatus` assertion completes rate/width/PCLK-rate change. In *PCLK-as-PHY-input* mode add the `PclkChangeOk`→`PclkChangeAck` handshake (Table 8-3). |
| D3 | Legal PowerDown states in which a Rate change may be requested | §8.4.1 (p.126) | ✏️ Corrected | **P0 or P1** (not P0-only), with `TxElecIdle` asserted and `RxStandby` asserted (P0). Drives the item-3 FSM. |
| D4 | Max latency bound for `PhyStatus` completion | §8.4.4 (p.128); Table 6-5 exit-latency tables | ✏️ Corrected | **PIPE defines no universal numeric bound** — rate-change and power-exit latencies are "PHY-specific / Implementation Specific" (PHY datasheet). The item-7 assertion must be a **parameter**, not a hard-coded spec constant. |
| D5 | `PhyStatus` handshake protocol (pulse vs level; N-cycle) | Table 6-8 (p.64); §8.4.1 | ✏️ Corrected | For rate/width/PCLK-rate completion it is a **single-PCLK-cycle** assertion. For power-state entry/exit where PCLK is absent the transition is **asynchronous**. So: pulse (1 cycle) synchronous case + async-level case, not one fixed form. |

## E. Signal inventory — MAC-owned (bridge drives → PHY)

| # | Signal (placeholder) | Spec name / § | Verdict | Notes |
|---|---|---|---|---|
| E1 | `TxData` (parallel Tx symbols) | `TxData[159:0]`… Table 6-1 (p.46) | ✏️ Corrected | SerDes widths are **160/80/40/20/10** bits (PCIe), selected by `Width`. Block-encoded data uses 8 of each 10-bit slice ([9:8],[19:18]… reserved). Not 32. |
| E2 | `TxDataValid` | Table 6-1 (p.46) | ✅ Confirmed | Used at 8/16/32/**64**/128 GT/s PCIe. Also qualifies `TxElecIdle` sampling. |
| E3 | `TxStartBlock` | Table 6-19 (p.72) | 🚫 N/A | **Original-PIPE-only; "not used in the SerDes architecture."** In SerDes the MAC embeds block boundaries in `TxData`. Remove from the SerDes interface. |
| E4 | `TxSyncHeader` | `TxSyncHeader[3:0]` Table 6-21 (p.74) | 🚫 N/A | **Original-PIPE-only; not used in SerDes.** Sync header is embedded in `TxData` by the MAC's 128b/130b encoder. |
| E5 | `TxElecIdle` | `TxElecIdle[3:0]` Table 6-5 (p.50) | ✏️ Corrected | **4 bits.** In PCIe SerDes: 1 bit / 2 symbols at ≤32 GT/s; 1 bit / 4 symbols at 64 & 128 GT/s. `TxDataValid` must be high when it toggles. |
| E6 | `TxDetectRx/Loopback` | `TxDetectRx/Loopback` Table 6-5 (p.50) | ✏️ Corrected | One combined pin. **Loopback is N/A in SerDes** (loopback lives in the MAC). We drive it only for receiver-detect. |
| E7 | `TxCompliance` / Tx margin | `TxCompliance` Table 6-21 (p.74); `TxMargin` via reg | ✏️ Corrected | `TxCompliance` is **Original-PIPE-only, not used in SerDes**. Tx margining in SerDes is a **msg-bus register** (PHY Tx Control), not a discrete pin. |
| E8 | `PowerDown[1:0]` | `PowerDown[3:0]` Table 6-5 (p.51) | ✏️ Corrected | **`PowerDown[3:0]`** discrete pin (see C1/C2). |
| E9 | `Rate` | `Rate[3:0]` Table 6-5 (p.57) | ✏️ Corrected | **`Rate[3:0]`** (see B3/B4). |
| E10 | `Width` | `Width[2:0]` Table 6-5 (p.59); `RxWidth[2:0]` Table 6-16 (p.71) | ✏️ Corrected | **`Width[2:0]`** (Tx side). In SerDes: 0=10,1=20,2=40,3=80,4=160 bits. **Separate `RxWidth[2:0]`** controls the Rx datapath in SerDes. |
| E11 | `Reset#` | `Reset#` Table 6-5 (p.50) | ✅ Confirmed | Active-low, asynchronous, may assert any time; PHY holds lowest-power state while asserted. |
| E12 | M2P message-bus master signals | `M2P_MessageBus[7:0]` Table 6-9 (p.66) | ✅ Confirmed | 8-bit, PCLK-synchronous, reset by `Reset#`. See §G. |

## F. Signal inventory — PHY-owned (bridge samples ← PHY)

| # | Signal (placeholder) | Spec name / § | Verdict | Notes |
|---|---|---|---|---|
| F1 | `RxData` | `RxData[159:0]`… Table 6-4 (p.48) | ✏️ Corrected | SerDes widths 160/80/40/20/10 (per `RxWidth`). **Synchronous to `RxCLK`** (recovered clock), not PCLK. |
| F2 | `RxValid` | Table 6-8 (p.64) | ✏️ Corrected | In SerDes, `RxValid` means **"RxCLK is stable"** (not block-aligned). MAC starts its own symbol/block lock after `RxValid`. Sync to `RxCLK`. |
| F3 | `RxStartBlock` | Table 6-20 (p.72) | 🚫 N/A | **Original-PIPE-only; not used in SerDes.** MAC recovers block start itself. |
| F4 | `RxSyncHeader` | `RxSyncHeader[3:0]` Table 6-22 (p.74) | 🚫 N/A | **Original-PIPE-only; not used in SerDes.** MAC decodes the sync header out of `RxData`. |
| F5 | `RxStatus[2:0]` (encodings) | `RxStatus[2:0]` Table 6-8 (p.65) | ✏️ Corrected | 3 bits, but **only `0b011` "Receiver detected" applies in SerDes** (all SKP/decode/EB-error codes are Original-PIPE-only, since the EB and decoder are in the MAC). Full table captured for reference; our decoder needs just the receiver-detect code. |
| F6 | `PhyStatus` | Table 6-8 (p.64) | ✅ Confirmed | See §D. Single-bit. |
| F7 | `RxElecIdle` | Table 6-8 (p.64) | ✏️ Corrected | Async. **At 8/16/32/64/128 GT/s the MAC must detect electrical-idle *entry* with its own logic**, not rely on this pin. We sample it but do not trust it for EI-entry at Gen5/Gen6. |
| F8 | `RxStandbyStatus` | `RxStandbyStatus` Table 6-8 (p.63) | ✅ Confirmed | PHY-driven standby status; undefined in P1/P2 (PCIe). Paired with MAC-driven `RxStandby` cmd pin. |
| F9 | P2M message-bus response signals | `P2M_MessageBus[7:0]` Table 6-9 (p.66) | ✅ Confirmed | 8-bit PHY→MAC. See §G. |

## G. Message bus (M2P / P2M)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| G1 | Message bus is 8 bits per direction | Table 6-9 (p.66) | ✅ Confirmed | `M2P_MessageBus[7:0]`, `P2M_MessageBus[7:0]`, PCLK-sync, reset by `Reset#`. |
| G2 | Transaction framing (command/address/data phases) | §6.1.4.2, Tables 6-11…6-14 (p.67–68) | ✅ Confirmed | Idle=`0x00`; idle→non-idle = start. Read=2 cyc (`Cmd[3:0]+Addr[11:8]`, `Addr[7:0]`); Read-completion=2 cyc (`Cmd`, `Data[7:0]`); Write=3 cyc (`Cmd+Addr[11:8]`, `Addr[7:0]`, `Data[7:0]`). **12-bit** address, **8-bit** data. |
| G3 | Opcode set + encodings | Table 6-10 (p.67) | ✏️ Corrected | 4-bit commands: `NOP=0x0`, `write_uncommitted=0x1`, `write_committed=0x2`, `read=0x3`, `read_completion=0x4`, `write_ack=0x5`, others reserved. Committed/uncommitted give atomic multi-register writes; write buffer depth ≥ 5. Enumerate these in `pipe7_pkg` (item 4). |
| G4 | Register address map: eq presets | §7.1 PHY Tx Control regs `400h–40Ah` (p.86–93); §8.28–8.31 | ✏️ Corrected | Tx equalization / de-emphasis / presets live in **PHY Tx Control** registers (`0x400`+) and are driven via the equalization msg-bus sequences (LocalFS/LocalLF, LocalG4FS/LocalG4LF, TxDeemph). Not a single "eq preset" register. |
| G5 | Register address map: precoding-enable (PAM4) | PHY Tx Control reg `PAM4RestrictedLevels` field (p.87–90) | ✏️ Corrected | **No "precoding-enable" register exists.** The only PAM4 MAC knob is the `PAM4RestrictedLevels` field (MAC→PHY) plus the `PAM4RestrictedLevelsRequirement` parameter. Precoding math is entirely PHY-side. |
| G6 | Register address map: margining | PHY `0h/1h` Rx Margin Control0/1 (p.81); MAC `0h–2h,7h` Rx Margin Status (p.97–99) | ✅ Confirmed | Rx lane margining is a msg-bus register flow (§8.30, Fig at p.180); addresses as listed. |
| G7 | Register address map: FEC status (pass-through) | (absent) | 🚫 N/A | **No FEC register on the PIPE interface.** "FEC" appears once, only in functional-partitioning prose. FEC lives controller-side; nothing to drive/sample across PIPE. Drop the FEC-status register from the plan's PIPE reg map. |
| G8 | Handshake / flow-control on the message bus | Table 6-10; §6.1.4 | ✅ Confirmed | One outstanding `read` per direction; `write_committed` blocks further writes until `write_ack`. NOP/idle = `0x00`. |

## H. Framing — Gen5 128b/130b

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| H1 | 130b block = 2b sync header + 128b payload | §6.3 (`TxSyncHeader[1:0]` used), §8.26 | ✅ Confirmed | Sync header is 2 bits (only `[1:0]` of the 4-bit header field are used in PCIe). 128b payload. |
| H2 | Sync-header encodings (data vs ordered-set) | §8.26; PCIe base | ✅ Confirmed | 2b sync header distinguishes data vs ordered-set blocks (PCIe 128b/130b). Detailed OS layout is PCIe-base, above PIPE. |
| H3 | Block alignment / de-skew responsibility (MAC vs PHY) | §4.2, §6.3 | ✏️ Corrected | **In SerDes architecture, block alignment + 128b/130b decode are the MAC's job** (PHY is serial↔parallel only). So our `pipe7_rx_deframer` performs block align/sync-header check on `RxData`; there is no PHY-provided `RxStartBlock`/`RxSyncHeader`. |

## I. Framing — Gen6 PAM4 FLIT

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| I1 | Flit size = 256 bytes | (absent from PIPE) | 🚫 N/A | **"Flit" is not a PIPE concept (0 occurrences).** 256B flit sizing is PCIe-base, above PIPE. The bridge receives already-framed data on RDI and drives it as `TxData`; it does not size/build flits on the PIPE side. |
| I2 | Flit internal layout (TLP/DLLP/CRC/FEC) | (absent from PIPE; PCIe base not fetched) | 🚫 N/A | Entirely controller-side / PCIe-base. No flit fields cross the PIPE interface individually — it's opaque `TxData`/`RxData`. Nothing for the MAC-facing bridge to parse. |
| I3 | Sync-header/block-type semantics in flit mode | Table 6-5 `TxElecIdle` note (64/128 GT/s); §8.26 | ✏️ Corrected | At 64 GT/s there is **no 128b/130b sync header** (Gen6 is 1b/1b at the PIPE datapath; the `TxSyncHeader`/`RxSyncHeader` pins are 8/16/32 GT/s-only *and* Original-PIPE-only). So the Gen6 datapath carries raw encoded data, no per-block sync header on the interface. |
| I4 | PAM4 precoding: PHY performs it; MAC only enables via msg-bus reg | §2.1 Fig 2-1 (gray/precode PHY-side); `PAM4RestrictedLevels` | ✅ Confirmed (refined) | Precoding/gray-coding is PHY-side. The MAC's *only* PAM4-related register is `PAM4RestrictedLevels` (not a generic precoding-enable). See G5. |

## J. Function ownership (MAC-facing scope boundary)

| # | Assertion (placeholder) | Spec § | Verdict | Notes |
|---|---|---|---|---|
| J1 | SerDes / PAM4 symbol mapping / precoding math = PHY (out of scope) | §4.2, Fig 4-8/4-9; §2.1 | ✅ Confirmed | PHY does parallel↔serial + PAM4 mapping/precoding/gray-code. Out of our scope. |
| J2 | CDR / elec-idle detection = PHY (out of scope) | Fig 4-9; F7 note | ✅ Confirmed (with caveat) | CDR/RxCLK recovery is PHY. But **EI-*entry* detection at Gen5/Gen6 is MAC logic** per §6 (`RxElecIdle` not reliable ≥5 GT/s) — that MAC-side EI-entry logic is in-scope for the controller, though we treat detection primitives as PHY. |
| J3 | FEC codec = controller/RDI side, not the PIPE interface | (no FEC signalling in PIPE) | ✅ Confirmed | No PHY-side FEC signals to drive/sample. See G7. |
| J4 | Flit LCRC = controller/RDI side | (no flit/LCRC in PIPE) | ✅ Confirmed | LCRC/flit are above PIPE; nothing crosses the interface. |

---

## Source items updated on ✏️ corrections

- **`src/pipe7_pkg.sv`** — `powerdown_e` widened to `[3:0]` (C1/C2); `rate_e` widened to
  `[3:0]` with spec encodings incl. Gen5=`4`, Gen6=`5` (B3/B4); `width_e`/`rxwidth_e`
  SerDes encodings added (E10); message-bus 4-bit command enum + address-space widths
  added (G3); datapath-width note re SerDes 10/20/40/80/160 (E1/F1). Item-0 caveat
  comment replaced with "confirmed vs Ref 643108 Rev 7.1".
- **`PLAN.md`** — corrected: Gen6 is **not** "FLIT mode" at the PIPE interface (B2/I1);
  removed `TxStartBlock/TxSyncHeader/RxStartBlock/RxSyncHeader` from the SerDes owned/
  sampled signal lists (E3/E4/F3/F4); `PowerDown[3:0]`/`Rate[3:0]`/`Width[2:0]`+`RxWidth`
  widths (C/E); L0p is an ordinary Width-change, not a special handshake (C3/C4);
  framer/deframer scope re-stated (MAC owns 128b/130b + block align; no 256B flit build
  on PIPE side) (H3/I1–I3); FEC-status register dropped from PIPE reg map (G7);
  PhyStatus max-latency is PHY-specific/parameterized, not a spec constant (D4).

## Resolution log

| Date | Rows resolved | By | Spec rev | Notes |
|------|---------------|-----|----------|-------|
| 2026-07-23 | A1–A4, B1–B5, C1–C4, D1–D5, E1–E12, F1–F9, G1–G8, H1–H3, I1–I4, J1–J4 (all) | Claude (session), user-authorized public fetch | 643108 Rev 7.1, Sep 2025 | Fetched Intel's official public PIPE 7.1 PDF; full-text cross-check. PCIe 6.x base **not** fetched (PCI-SIG-gated) — flit/FEC/LCRC/PAM4-precoding rows resolved via PIPE's own statement that they live above the PIPE interface, so no base-spec dependency gates items 2–12. Human re-review against an internal controlled copy still recommended before tape-in, but item-0 gate is satisfied for design to proceed. |
