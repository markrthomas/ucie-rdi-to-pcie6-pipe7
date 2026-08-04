# UPF power-intent verification (`test/upf/`)

Power-aware verification of `ucie_rdi_to_pipe7_mac_bridge` against IEEE-1801 (UPF) power intent.

## Status — authored-and-review-validated, **not run in the OSS gate**

There is **no open-source power-aware simulator** in this environment: Verilator, Icarus, and
Yosys/SymbiYosys do not model UPF supply/isolation/retention/corruption semantics. Power-aware
simulation needs a commercial engine — **VCS NLP (`-upf`)**, Questa PA, or Xcelium. So this tier
follows the same convention as the Tier-2 UVM env: **authored and validated by review, exercised
under VCS, not part of `make regress`.** (UPF, not CPF — CPF is legacy/Cadence-only; IEEE-1801 UPF
is what modern VCS/Questa/Xcelium flows consume.)

## Power architecture

| Domain | Rail | Contents | Behavior across P1/P2 |
|--------|------|----------|-----------------------|
| `PD_AON` | `VDD` (always-on) | control FSM (`ctrl`), message-bus master (`mbus`), top glue | stays powered — sequences the PowerDown/Rate/Width handshakes that bring the link back up |
| `PD_DP` | `VDD_DP` (switched) | TX/RX datapath: `ingress`, `tx_cdc`, `datapath`, `rx_burst`, `rx_cdc`, `egress`; **+ `rf` (retained)** | **gated off** in P1/P2; datapath state is transient (re-locks on wake), config regfile is **retained** |

- **Power switch** `sw_dp` gates `VDD_DP` from `VDD` under `pmu/dp_pwr_en`.
- **Isolation** clamps `PD_DP` outputs while gated: data/valid/status → `0`, **`TxElecIdle` → `1`**
  (assert electrical idle to the PHY while the datapath is down).
- **Retention** on the config register file `rf` (balloon latches on the always-on rail) so
  programmed PHY-Tx-Control / `PAM4RestrictedLevels` values survive a low-power episode.
- **Power state table:** P0/P0s → `VDD_DP` ON; P1/P2 → `VDD_DP` OFF.

See `../../docs/power_intent.md` for the full rationale and the PIPE-state → supply mapping.

## Files

| File | Role |
|------|------|
| `bridge.upf` | IEEE-1801 power intent (domains, supply sets, switch, isolation, retention, PST). |
| `pipe7_pmu.sv` | **DV-only** power sequencer — decodes `dut.power_down` into the switch/iso/retention controls. Not part of the shipped IP. |
| `tb_pipe7_upf_power.sv` | Power-aware directed test: P0 → P2 → P0, checking isolation clamps while gated and config retention across the OFF episode. Self-checking, bounded waits. |
| `Makefile.vcs` | `vcs -power=UPF -upf bridge.upf +define+UPF_POWER_AWARE …` compile+run. |

## Running

**Power-aware sign-off (VCS, not available here):**
```
make -C test/upf -f Makefile.vcs        # -> "[UPF POWER] PASS" (power intent exercised)
```

**Skeleton check (OSS, keeps the SV from bit-rotting):** the top Makefile builds the same TB under
Verilator **without** `UPF_POWER_AWARE`, so the DUT+PMU elaborate, the control FSM sequences
P0↔P2, the PMU produces the expected switch/isolation/retention waveform, and data round-trips
before and after the power cycle. This validates the RTL/TB wiring — it does **not** verify power
intent (no UPF semantics under Verilator).
```
make verilator_upf     # -> "[UPF POWER] PASS  (skeleton: … requires VCS -upf)"
make upf               # tries Makefile.vcs; reports authored-not-run if VCS is absent
```
