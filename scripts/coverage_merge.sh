#!/usr/bin/env bash
# coverage_merge.sh -- union DUT line coverage across the Verilator smoke suite (closure-plan
# item 40). The single integrated-bridge smoke exercises only the Gen5 path; the standalone
# smokes cover Gen6, the gearbox bursts, every FSM transition, all message-bus opcodes, the
# watchdogs, and the error paths. Building each with --coverage and merging the per-smoke
# coverage.dat files gives the real union coverage of the shipped design (BRIDGE_RTL src/ files).
#
# Only smokes that exercise the shipped bridge's src/ files are merged (the single-block
# framer/deframer/datapath variants are not in the integrated top, so their smokes are excluded
# to keep the denominator = the shipped design). Writes coverage.info at the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

VERILATOR="${VERILATOR:-$(command -v verilator_bin || command -v verilator)}"
VCOV="${VERILATOR_COVERAGE:-$(command -v verilator_coverage || echo verilator_coverage)}"
BDIR=obj_dir_covmerge
DAT="$BDIR/dat"
rm -rf "$BDIR"; mkdir -p "$DAT"

# make variable expander
getvar() { make -s --eval="__p__:;@echo \$($1)" __p__; }

# name  TOP-var  FILES-var  extra-flags
SMOKES=(
  "bridge   TOP_MODULE      VERILOG_FILES     --assert"
  "w160     W160_TOP        W160_FILES        --assert"
  "ratedp   RATE_DP_TOP     RATE_DP_FILES     --assert"
  "ctrl     CTRL_TOP        CTRL_FILES        "
  "msgbus   MSGBUS_TOP      MSGBUS_FILES      "
  "gen6     GEN6_TOP        GEN6_FILES        "
  "framgb   FRAMING_GB_TOP  FRAMING_GB_FILES  "
  "rdi      RDI_TOP         RDI_FILES         "
  "cdc      CDC_TOP         CDC_FILES         "
  "timeout  TIMEOUT_TOP     TIMEOUT_FILES     "
  "burst    BURST_TOP       BURST_FILES       "
  "dgbovf   DEFRAMER_GB_OVF_TOP  DEFRAMER_GB_OVF_FILES  "
)

for entry in "${SMOKES[@]}"; do
  read -r name topv filesv extra <<<"$entry"
  top=$(getvar "$topv"); files=$(getvar "$filesv")
  echo "[covmerge] build+run $name ($top)"
  # shellcheck disable=SC2086
  "$VERILATOR" --binary --timing --coverage $extra -Isrc \
      -Wno-STMTDLY -Wno-UNUSEDSIGNAL -Wno-WIDTH -Wno-BLKSEQ \
      --top-module "$top" --Mdir "$BDIR/$name" -o "sim_$name" $files >"$BDIR/build_$name.log" 2>&1
  "$BDIR/$name/sim_$name" "+verilator+coverage+file+$PWD/$DAT/$name.dat" >"$BDIR/run_$name.log" 2>&1 || true
done

echo "[covmerge] merging $(ls "$DAT"/*.dat | wc -l) coverage runs -> coverage.info"
"$VCOV" --write-info coverage.info "$DAT"/*.dat >"$BDIR/merge.log" 2>&1
awk '/^SF:/{inc=($0 ~ /src\//)} inc&&/^DA:/{split($0,a,","); t++; if(a[2]+0>0)h++} END{printf "[covmerge] union DUT (src/) line coverage: %d/%d = %.2f%%\n",h,t,(t?100*h/t:0)}' coverage.info
