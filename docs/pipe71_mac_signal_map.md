# PIPE 7.1 MAC signal map (closure-plan item 2)

Every PIPE MAC-side signal the bridge drives or samples, plus the message-bus register
address map. Directions are given **from the MAC (bridge) perspective** — `drive` = the
bridge is the source (a PHY input); `sample` = the bridge is the sink (a PHY output).

- **Scope:** SerDes architecture, PCIe mode, **Gen5 (`Rate=4`, 32 GT/s) + Gen6 (`Rate=5`,
  64 GT/s)** only.
- **Authority:** widths/directions confirmed vs Intel **PIPE 7.1, Ref 643108, Rev 7.1
  (Sep 2025)**; `§` refs point into that document. See `docs/pipe71_spec_crosscheck.md`
  for the row-by-row reconciliation and `test/uvm/pipe7_mac_if.sv` for the machine-readable
  contract (the `interface` port/modport names match the "IF signal" column below).
- **Not present in SerDes arch (do not implement):** `TxStartBlock`, `TxSyncHeader`,
  `RxStartBlock`, `RxSyncHeader`, `TxDataK`, `RxDataK`, `RxDataValid`, `TxCompliance`,
  `AlignDetect` — all Original-PIPE-only (§6.3). The MAC does 128b/130b in-band, so the
  sync header rides inside `TxData`/`RxData`.

## Clock / domain legend

| Domain | Signals synchronous to it |
|--------|---------------------------|
| `pclk` | all command, status, and message-bus signals |
| `rx_clk` (recovered) | `RxData`, `RxValid` (SerDes) |
| async | `Reset#`, `RxElecIdle`, `PhyStatus` when PCLK is absent, `DeepPMReq#/Ack#`, `Restore#`, `RxEIDetectDisable`, `TxCommonmodeDisable`, `SerDesArch` |

## Clocks & reset (external / common)

| Spec signal | IF signal | Dir (MAC) | Width | Domain | Spec § | Notes |
|-------------|-----------|-----------|-------|--------|--------|-------|
| PCLK | `pclk` | in | 1 | — | §8.1 | Parallel-interface clock. May be PHY output or PHY input (clocking topology). |
| RxCLK | `rx_clk` | sample | 1 | — | §6.2.1 (Table 6-15) | SerDes recovered Rx clock; `RxData`/`RxValid` domain. PHY keeps it running ≥8 clocks after `RxValid` deasserts. |
| Reset# | `reset_n` | drive | 1 | async | §6.1.2 (Table 6-5) | Active-low; may assert any time; PHY holds lowest-power state while asserted. |

## MAC → PHY : Tx data (bridge drives)

| Spec signal | IF signal | Dir | Width | Domain | Spec § | Notes |
|-------------|-----------|-----|-------|--------|--------|-------|
| TxData | `tx_data` | drive | `TX_DATA_WIDTH` ∈ {10,20,40,80,160} | `pclk` | §6.1.1 (Table 6-1) | SerDes parallel width per `Width`. Block-encoded data uses 8 of each 10-bit slice ([9:8],[19:18]… reserved). |
| TxDataValid | `tx_data_valid` | drive | 1 | `pclk` | §6.1.1 (Table 6-1) | Used at 8/16/32/**64**/128 GT/s. Also qualifies `TxElecIdle` sampling. |

## MAC → PHY : command / config (bridge drives)

| Spec signal | IF signal | Dir | Width | Domain | Spec § | Notes |
|-------------|-----------|-----|-------|--------|--------|-------|
| PowerDown[3:0] | `power_down` | drive | 4 | `pclk` | §6.1.2 (Table 6-5, p.51) | PCIe: P0=`0`, P0s=`1`, P1=`2`, P2=`3`; `4..15` PHY-specific (L1 substates). |
| Rate[3:0] | `rate` | drive | 4 | `pclk` | §6.1.2 (Table 6-5, p.57) | In scope: **Gen5=`4`** (32 GT/s), **Gen6=`5`** (64 GT/s). |
| Width[2:0] | `width` | drive | 3 | `pclk` | §6.1.2 (Table 6-5, p.59) | SerDes Tx width: `0`=10,`1`=20,`2`=40,`3`=80,`4`=160. |
| RxWidth[2:0] | `rx_width` | drive | 3 | `pclk` | §6.2.2 (Table 6-16, p.71) | SerDes-only; controls Rx datapath width (same encoding as Width). |
| TxElecIdle[3:0] | `tx_elec_idle` | drive | 4 | `pclk` | §6.1.2 (Table 6-5, p.50) | 1 bit / 2 symbols ≤32 GT/s; 1 bit / 4 symbols at 64 & 128 GT/s. Toggle only with `TxDataValid` high. |
| TxDetectRx/Loopback | `tx_detect_rx_loopback` | drive | 1 | `pclk` / async | §6.1.2 (Table 6-5, p.50) | Receiver-detect strobe. **Loopback N/A in SerDes** (MAC-side loopback). Async in PCLK-gated states. |
| SerDesArch | `serdes_arch` | drive | 1 | async | §6.1.2 (Table 6-5) | Static strap = 1 (SerDes enabled); change only during `Reset#`. |
| RxStandby | `rx_standby` | drive | 1 | `pclk` | §6.1.2 (Table 6-5, p.62) | Rx active(0)/standby(1) in P0/P0s; ignored otherwise. |
| SRISEnable | `sris_enable` | drive | 1 | `pclk` | §6.1.2 (Table 6-5) | PCIe SRIS config; set before first receiver detection (Rev6+ may change in Configuration). |
| PclkChangeAck | `pclk_change_ack` | drive | 1 | `pclk` | §6.1.3 (Table 6-7) | PCLK-as-PHY-input rate/width/PCLK-rate change handshake (pairs with `PclkChangeOk`). |
| AsyncPowerChangeAck | `async_power_change_ack` | drive | 1 | async | §6.1.3 (Table 6-7) | L1-substate power change without PCLK (pairs with `PhyStatus`). |

### Optional L1-substate / deep-PM (bridge drives; may be tied off)

| Spec signal | IF signal | Dir | Width | Domain | Spec § | Notes |
|-------------|-----------|-----|-------|--------|--------|-------|
| TxCommonmodeDisable | `tx_commonmode_disable` | drive | 1 | async | §6.1.2 (Table 6-5, p.56) | L1-substate mgmt (alt to `PowerDown`). |
| RxEIDetectDisable | `rx_ei_detect_disable` | drive | 1 | async | §6.1.2 (Table 6-5, p.55) | Disables Rx EI-detect (forces `RxElecIdle`=1). |
| DeepPMReq# | `deep_pm_req_n` | drive | 1 | async | §6.1.2 (Table 6-5, p.56) | Deep-PM request; full handshake with `DeepPMAck#`. Not asserted in P0. |
| Restore# | `restore_n` | drive | 1 | async | §6.1.2 (Table 6-5, p.56) | Restore-window indication. |

## PHY → MAC : Rx data + status (bridge samples)

| Spec signal | IF signal | Dir | Width | Domain | Spec § | Notes |
|-------------|-----------|-----|-------|--------|--------|-------|
| RxData | `rx_data` | sample | `RX_DATA_WIDTH` ∈ {10,20,40,80,160} | `rx_clk` | §6.1.1 (Table 6-4) | Per `RxWidth`. Synchronous to `rx_clk`, not `pclk`. |
| RxValid | `rx_valid` | sample | 1 | `rx_clk` | §6.1.3 (Table 6-8) | SerDes: "`rx_clk` stable". MAC starts its own symbol/block lock after this. |
| PhyStatus | `phy_status` | sample | 1 | `pclk` / async | §6.1.3 (Table 6-8); §8.4.1 | Single-cycle completion of power/rate/width/receiver-detect/post-reset. Async when PCLK absent. |
| RxStatus[2:0] | `rx_status` | sample | 3 | `pclk` | §6.1.3 (Table 6-8, p.65) | Only `0b011` "Receiver detected" applies in SerDes (SKP/decode/EB codes are Original-PIPE-only). |
| RxElecIdle | `rx_elec_idle` | sample | 1 | async | §6.1.3 (Table 6-8) | Async. **At Gen5/Gen6 the MAC must detect EI-entry with its own logic** — do not rely on this pin. |
| RxStandbyStatus | `rx_standby_status` | sample | 1 | `pclk` | §6.1.3 (Table 6-8, p.63) | Reflects Rx standby; undefined in P1/P2 (PCIe). |
| PclkChangeOk | `pclk_change_ok` | sample | 1 | `pclk` | §6.1.3 (Table 6-8) | PHY ready for PCLK/rate/width change (PCLK-input mode). |
| RefClkRequired# | `refclk_required_n` | sample | 1 | `pclk` | §6.1.2 (Table 6-6) | PHY deasserts when refclk can be removed in P1/P2/L1-substate. |
| DeepPMAck# | `deep_pm_ack_n` | sample | 1 | async | §6.1.3 (Table 6-8) | Present only if `DeepPMReq#` is implemented. |

## Message bus (bidirectional)

| Spec signal | IF signal | Dir | Width | Domain | Spec § | Notes |
|-------------|-----------|-----|-------|--------|--------|-------|
| M2P_MessageBus[7:0] | `m2p_message_bus` | drive | 8 | `pclk` | §6.1.4 (Table 6-9) | MAC → PHY commands/responses. |
| P2M_MessageBus[7:0] | `p2m_message_bus` | sample | 8 | `pclk` | §6.1.4 (Table 6-9) | PHY → MAC commands/responses. |

**Framing** (§6.1.4.2, Tables 6-11…6-14): idle = `0x00`; idle→non-idle marks a transaction
start. Read = 2 cycles (`Cmd[3:0]+Addr[11:8]`, `Addr[7:0]`); read-completion = 2 cycles
(`Cmd`, `Data[7:0]`); write = 3 cycles (`Cmd+Addr[11:8]`, `Addr[7:0]`, `Data[7:0]`).
Address is **12-bit**, data **8-bit**.

**Commands** (§6.1.4.1, Table 6-10; enumerated in `pipe7_pkg::msgbus_cmd_e`):

| Encoding | Command | Cycles | Fields |
|----------|---------|--------|--------|
| `0x0` | NOP | 1 | Cmd |
| `0x1` | write_uncommitted | 3 | Cmd, Addr, Data |
| `0x2` | write_committed | 3 | Cmd, Addr, Data |
| `0x3` | read | 2 | Cmd, Addr |
| `0x4` | read_completion | 2 | Cmd, Data |
| `0x5` | write_ack | 1 | Cmd |

`write_uncommitted*` + `write_committed` give atomic multi-register updates (write buffer
depth ≥ 5). One outstanding `read` per direction; no new write until `write_ack`.

## Message-bus register address map

12-bit address spaces, one hosted by the PHY and one by the MAC (§7.1 / §7.2). Addresses
and register names below are from the PIPE 7.1 table of contents; **per-field bit layouts
are captured incrementally as items 4/5/6 consume each register** — cross-reference the
cited `§` for the field definitions rather than treating this as a frozen field map.

### PHY registers (MAC accesses via M2P) — §7.1

| Addr | Register | Relevant to |
|------|----------|-------------|
| `0x000` | Rx Margin Control0 | Rx margining |
| `0x001` | Rx Margin Control1 | Rx margining |
| `0x002` | Elastic Buffer Control | (MAC-side EB in SerDes) |
| `0x003`–`0x006` | PHY Rx Control0–3 | Rx config |
| `0x007` | Elastic Buffer Location Update Frequency | EB |
| `0x008` | PHY Rx Control4 | Rx config |
| `0x009` | PHY Rx Control5 | Rx config |
| `0x400`–`0x40A` | PHY Tx Control0–10 | **Tx eq presets / de-emphasis / `PAM4RestrictedLevels`** |
| `0x800` | PHY Common Control0 | common (incl. `MacTransmitLFPS`) |
| `0x801` | PHY Near End Loopback Control | loopback |

### MAC registers (PHY accesses via P2M) — §7.2

| Addr | Register | Relevant to |
|------|----------|-------------|
| `0x000`–`0x002` | Rx Margin Status0–2 | Rx margining status |
| `0x003` | Elastic Buffer Status | EB |
| `0x004` | Elastic Buffer Location | EB |
| `0x005` | Rx Status0 | Rx status |
| `0x006` | Rx Control0 | Rx control |
| `0x007` | Rx Margin Status3 | Rx margining status |
| `0x00A`–`0x00B` | Rx Link Evaluation Status0–1 | link eval |
| `0x00C`–`0x00D` | Rx Status4–5 | Rx status |
| `0x00E`–`0x00F` | Rx Link Evaluation Status2–3 | link eval |
| `0x010` | Rx Status6 | Rx status |
| `0x400`–`0x40C` | Tx Status0–12 | Tx status |
| `0x800` | Near End Loopback Status | loopback |

> **No FEC register exists on the PIPE interface** — FEC / flit-LCRC are controller-side
> (above PIPE). Do not add a FEC register to this map.
