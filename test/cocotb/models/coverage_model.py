"""Functional-coverage model for the integrated bridge (Phase G, item 44).

INDEPENDENT-tool functional coverage: the bins here are scored by ``cocotb_coverage`` (pure
Python), a tool entirely separate from Verilator's line coverage, and the stimulus runs on the
INDEPENDENT Icarus Verilog engine (``make fcov``). Together they are a redundant cross-check to
the Verilator line-coverage union (651/662 = 98.34%).

The bin set is derived from the interface encoding space (``docs/interface_spec.md`` /
``src/pipe7_pkg.sv``): PowerDown P0/P0s/P1/P2, Rate Gen5/Gen6, Width W_10..W_160, control request
kind/outcome, message-bus opcode, and the observable datapath / RDI-credit / overflow status. All
bins are reachable from the ``pipe7_bridge_top`` (+ its cocotb inject knobs) and ``pipe7_gen6_rx``
wrappers; nothing here is gerrymandered. Sampling is done from Python monitors that read the DUT
handles -- no RTL involvement (mirrors the SV ``pipe7_perf_monitor`` signal taps).
"""
import json

from cocotb_coverage.coverage import CoverPoint, coverage_db

# ---- encodings (mirror pipe7_pkg::*) -------------------------------------------------------
RATE_GEN5, RATE_GEN6 = 4, 5
PD_BINS    = [0, 1, 2, 3]                 # P0, P0s, P1, P2
WIDTH_BINS = [0, 1, 2, 3, 4]             # W_10, W_20, W_40, W_80, W_160
KIND_BINS  = [0, 1, 2]                   # REQ_POWER, REQ_RATE, REQ_WIDTH

# The exact CoverPoint names this model owns (so the overall % never double-counts the
# hierarchical parent nodes cocotb_coverage also stores in coverage_db). Every bin is reachable
# from the bridge (+ inject knobs) / gen6_rx wrappers -- there are deliberately no cross bins with
# structurally-unreachable cells (e.g. POWER x reject), so the target is an honest 100% of the set.
POINTS = [
    "bridge.ctrl.kind", "bridge.ctrl.outcome", "bridge.ctrl.pd", "bridge.ctrl.rate",
    "bridge.ctrl.width", "bridge.ctrl.busy",
    "bridge.mb.op", "bridge.mb.is_read", "bridge.mb.committed",
    "bridge.dp.rate_obs", "bridge.dp.block_locked", "bridge.dp.sync_error",
    "bridge.dp.in_data_phase", "bridge.dp.tx_valid",
    "bridge.rdi.tx_crd", "bridge.rdi.rx_valid", "bridge.rdi.is_os", "bridge.rdi.sob",
    "bridge.rdi.overflow",
]


# ---- control plane ------------------------------------------------------------------------
@CoverPoint("bridge.ctrl.kind", xf=lambda s: s["kind"], bins=KIND_BINS,
            bins_labels=["POWER", "RATE", "WIDTH"])
@CoverPoint("bridge.ctrl.outcome", xf=lambda s: s["outcome"], bins=["done", "reject"])
@CoverPoint("bridge.ctrl.pd", xf=lambda s: s["pd"], bins=PD_BINS,
            bins_labels=["P0", "P0s", "P1", "P2"])
@CoverPoint("bridge.ctrl.rate", xf=lambda s: s["rate"], bins=[RATE_GEN5, RATE_GEN6],
            bins_labels=["Gen5", "Gen6"])
@CoverPoint("bridge.ctrl.width", xf=lambda s: s["width"], bins=WIDTH_BINS,
            bins_labels=["W10", "W20", "W40", "W80", "W160"])
@CoverPoint("bridge.ctrl.busy", xf=lambda s: s["busy"], bins=[0, 1])
def sample_ctrl(s):
    """s = {kind, outcome('done'|'reject'), pd, rate, width, busy}."""
    pass


# ---- message bus --------------------------------------------------------------------------
@CoverPoint("bridge.mb.op", xf=lambda s: s["op"], bins=["read", "wr_unc", "wr_com"])
@CoverPoint("bridge.mb.is_read", xf=lambda s: s["is_read"], bins=[0, 1])
@CoverPoint("bridge.mb.committed", xf=lambda s: s["committed"], bins=[0, 1])
def sample_mb(s):
    """s = {op('read'|'wr_unc'|'wr_com'), is_read(0|1), committed(0|1)}."""
    pass


# ---- datapath / framing (observed) --------------------------------------------------------
@CoverPoint("bridge.dp.rate_obs", xf=lambda s: s["rate"], bins=[RATE_GEN5, RATE_GEN6],
            bins_labels=["Gen5", "Gen6"])
@CoverPoint("bridge.dp.block_locked", xf=lambda s: s["locked"], bins=[0, 1])
@CoverPoint("bridge.dp.sync_error", xf=lambda s: s["sync_err"], bins=[0, 1])
@CoverPoint("bridge.dp.in_data_phase", xf=lambda s: s["data_phase"], bins=[0, 1])
@CoverPoint("bridge.dp.tx_valid", xf=lambda s: s["tx_valid"], bins=[0, 1])
def sample_dp(s):
    """s = {rate, locked, sync_err, data_phase, tx_valid}."""
    pass


# ---- RDI credits / overflow (observed) ----------------------------------------------------
@CoverPoint("bridge.rdi.tx_crd", xf=lambda s: s["tx_crd"], bins=[0, 1, 2])
@CoverPoint("bridge.rdi.rx_valid", xf=lambda s: s["rx_valid"], bins=[0, 1])
@CoverPoint("bridge.rdi.is_os", xf=lambda s: s["is_os"], bins=[0, 1])
@CoverPoint("bridge.rdi.sob", xf=lambda s: s["sob"], bins=[0, 1])
@CoverPoint("bridge.rdi.overflow", xf=lambda s: s["overflow"], bins=[0, 1])
def sample_rdi(s):
    """s = {tx_crd(0|1|2), rx_valid(0|1), is_os(0|1), sob(0|1), overflow(0|1)}."""
    pass


# ---- aggregation / reporting --------------------------------------------------------------
def per_point():
    """[(name, covered, size, pct), ...] over this model's own points (present in coverage_db)."""
    rows = []
    for name in POINTS:
        if name in coverage_db:
            ci = coverage_db[name]
            rows.append((name, int(ci.coverage), int(ci.size), float(ci.cover_percentage)))
    return rows


def overall():
    """(hit_bins, total_bins, pct) unioned across this model's points -- the headline number."""
    rows = per_point()
    hit = sum(r[1] for r in rows)
    total = sum(r[2] for r in rows)
    pct = (100.0 * hit / total) if total else 0.0
    return hit, total, pct


def dump(json_path=None, txt_path=None):
    """Write a machine-readable (JSON) + human (txt) functional-coverage report; return the dict."""
    rows = per_point()
    hit, total, pct = overall()
    doc = {
        "tool": "cocotb_coverage",
        "metric": "functional",
        "engine": "icarus",
        "bins_hit": hit,
        "bins_total": total,
        "pct": round(pct, 2),
        "points": [{"name": n, "covered": c, "size": s, "pct": round(p, 2)}
                   for (n, c, s, p) in rows],
    }
    if json_path:
        with open(json_path, "w") as f:
            json.dump(doc, f, indent=2)
    if txt_path:
        with open(txt_path, "w") as f:
            f.write(f"Functional coverage (cocotb_coverage, Icarus engine): "
                    f"{hit}/{total} bins = {pct:.2f}%\n\n")
            for (n, c, s, p) in rows:
                f.write(f"  {n:34s} {c:3d}/{s:<3d} {p:6.1f}%\n")
    return doc
