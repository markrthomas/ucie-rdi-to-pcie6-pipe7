#!/usr/bin/env python3
"""gen_report.py -- aggregate the UCIe RDI <-> PIPE 7.1 bridge's verification + performance
metrics into one report (closure-plan item 37).

Consumes (all optional; missing inputs degrade gracefully):
  - <out>/logs/regress.log  : Verilator smoke stdout -> [PERF] perf lines + [TAG] PASS matrix
  - coverage.info           : LCOV line coverage (total + per-file)
  - <out>/logs/formal.log   : SymbiYosys `make formal` output -> per-proof PASS/FAIL
  - test/cocotb/results.xml  : cocotb JUnit -> per-test pass/fail + sim timing

Emits <out>/{metrics.json, report.md, report.html}. Perf figures are SIMULATION numbers at the
smoke operating point (rdi_clk ~71 MHz / pclk 100 MHz), not silicon timing.
"""
import argparse
import datetime
import html
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


# ---------------------------------------------------------------- parsing helpers
def parse_perf_and_tags(regress_log: Path):
    """Return (perf: {tb_key: {metric: val}}, tags: [(tag, detail)])."""
    perf, tags = {}, []
    if not regress_log.exists():
        return perf, tags
    for line in regress_log.read_text(errors="replace").splitlines():
        if "[PERF]" in line:
            body = line.split("[PERF]", 1)[1].strip()
            kv = {}
            for tok in body.split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    kv[k] = _num(v)
            key = f"pipe_width_{kv.get('pipe_width', '?')}"
            perf[key] = kv
        m = re.search(r"\[([A-Z0-9 ]+)\]\s+PASS\b(.*)", line)
        if m:
            tags.append((m.group(1).strip(), m.group(2).strip(" ()")))
    return perf, tags


def _num(v):
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def parse_coverage(info: Path):
    """LCOV -> {'total': (hit, lines, pct), 'files': [(file, hit, lines, pct)]}.

    DUT-only: counts src/ (the design); testbenches/stubs/monitor/assertions are excluded.
    """
    if not info.exists():
        return None
    files, cur, hit, lines = [], None, 0, 0
    tot_hit = tot_lines = 0
    for line in info.read_text(errors="replace").splitlines():
        if line.startswith("SF:"):
            path = line[3:]
            cur = path if ("/src/" in path or path.startswith("src/")) else None
            hit = lines = 0
        elif line.startswith("DA:") and cur is not None:
            try:
                _ln, hits = line[3:].split(",")[:2]
                lines += 1
                if int(hits) > 0:
                    hit += 1
            except ValueError:
                pass
        elif line.startswith("end_of_record") and cur is not None:
            files.append((os.path.basename(cur), hit, lines, _pct(hit, lines)))
            tot_hit += hit
            tot_lines += lines
            cur = None
    files.sort(key=lambda f: f[3])  # worst-covered first
    return {"total": (tot_hit, tot_lines, _pct(tot_hit, tot_lines)), "files": files}


def _pct(hit, total):
    return round(100.0 * hit / total, 2) if total else 0.0


def parse_formal(log: Path):
    """SymbiYosys output -> {proof: 'PASS'|'FAIL'} (a proof passes iff all its tasks pass)."""
    if not log.exists():
        return {}
    proofs = {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.search(r"\[([a-z0-9_]+?)(?:_bmc|_cover)?\]\s+DONE \((PASS|FAIL)", line)
        if m:
            name, status = m.group(1), m.group(2)
            if proofs.get(name) != "FAIL":
                proofs[name] = status
    return proofs


def parse_cocotb(xml_path: Path):
    """cocotb JUnit -> [(name, 'PASS'|'FAIL', time_s, sim_time_ns)]."""
    if not xml_path.exists():
        return []
    out = []
    try:
        root = ET.parse(xml_path).getroot()
    except ET.ParseError:
        return out
    for tc in root.iter("testcase"):
        failed = any(c.tag in ("failure", "error") for c in tc)
        out.append((tc.get("name", "?"), "FAIL" if failed else "PASS",
                    tc.get("time", ""), tc.get("sim_time_ns", "")))
    return out


def git_sha(root: Path):
    try:
        return subprocess.check_output(["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
                                       text=True).strip()
    except Exception:
        return "unknown"


# ---------------------------------------------------------------- KPI extraction
KPI_SPEC = [
    ("tx_util_pct",              "TX PIPE utilization",      "%"),
    ("gbps_eff",                 "Effective throughput",     "Gbit/s"),
    ("bits_per_pclk",            "RDI bits / PCLK",          "bits"),
    ("lat_ns_avg",               "Round-trip latency (avg)", "ns"),
    ("lat_ns_max",               "Round-trip latency (max)", "ns"),
    ("burst_fifo_peak",          "RX burst-FIFO peak",       "blocks"),
    ("egress_peak_outstanding",  "Peak credits outstanding", "credits"),
    ("rx_overflow",              "RX overflow drops",        "count"),
    ("tx_stall_cyc",             "TX-CDC stall cycles",      "cycles"),
]


def kpi_rows(perf):
    """Prefer the width-160 run (fuller path); fall back to any."""
    src = perf.get("pipe_width_160") or (next(iter(perf.values())) if perf else {})
    rows = []
    for key, label, unit in KPI_SPEC:
        if key in src:
            rows.append((label, src[key], unit, key))
    return rows, src


# ---------------------------------------------------------------- emitters
def build_metrics(perf, tags, cov, formal, cocotb, sha):
    return {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "git_sha": sha,
        "note": "simulation figures at rdi_clk ~71 MHz / pclk 100 MHz; not silicon timing",
        "performance": perf,
        "coverage": None if cov is None else {
            "total_hit": cov["total"][0], "total_lines": cov["total"][1],
            "pct": cov["total"][2],
            "files": [{"file": f, "hit": h, "lines": n, "pct": p} for f, h, n, p in cov["files"]],
        },
        "smokes": [{"tag": t, "detail": d} for t, d in tags],
        "formal": formal,
        "cocotb": [{"name": n, "status": s, "time_s": t, "sim_time_ns": st}
                   for n, s, t, st in cocotb],
    }


def build_md(m, cov, formal, cocotb, tags, perf):
    L = ["# UCIe RDI ↔ PIPE 7.1 bridge — metrics report",
         "",
         f"_Generated {m['generated']} · commit `{m['git_sha']}` · {m['note']}._", ""]
    rows, _ = kpi_rows(perf)
    if rows:
        L += ["## Performance KPIs (width-160 run)", "",
              "| KPI | Value | Unit |", "|-----|------:|------|"]
        L += [f"| {lbl} | {val} | {unit} |" for lbl, val, unit, _ in rows] + [""]
    if cov:
        h, n, p = cov["total"]
        L += ["## Line coverage", "", f"**{h}/{n} = {p}%**", "",
              "| File | Lines | % |", "|------|------:|--:|"]
        L += [f"| {f} | {hh}/{nn} | {pp}% |" for f, hh, nn, pp in cov["files"]] + [""]
    if tags:
        L += ["## Verilator smokes", "", "| Smoke | Detail |", "|-------|--------|"]
        L += [f"| {t} | {d} |" for t, d in tags] + [""]
    if formal:
        L += ["## Formal proofs", "", "| Proof | Status |", "|-------|--------|"]
        L += [f"| {k} | {v} |" for k, v in sorted(formal.items())] + [""]
    if cocotb:
        L += ["## PyUVM-on-cocotb", "", "| Test | Status | sim ns |", "|------|--------|-------:|"]
        L += [f"| {n} | {s} | {st} |" for n, s, _, st in cocotb] + [""]
    return "\n".join(L)


def _bar(pct):
    color = "#2e7d32" if pct >= 90 else ("#f9a825" if pct >= 75 else "#c62828")
    return (f'<div class="bar"><div class="fill" style="width:{pct}%;background:{color}"></div>'
            f'<span>{pct}%</span></div>')


def _badge(ok):
    return f'<span class="badge {"ok" if ok else "bad"}">{"PASS" if ok else "FAIL"}</span>'


def build_html(m, cov, formal, cocotb, tags, perf):
    rows, src = kpi_rows(perf)
    P = ['<!-- generated by scripts/gen_report.py -->',
         f'<p class="meta">Generated {html.escape(m["generated"])} · commit '
         f'<code>{html.escape(m["git_sha"])}</code><br>{html.escape(m["note"])}</p>']
    if rows:
        cards = "".join(
            f'<div class="card"><div class="k">{html.escape(label)}</div>'
            f'<div class="v">{v}<small> {html.escape(u)}</small></div></div>'
            for label, v, u, _ in rows)
        P.append(f'<h2>Performance KPIs <small>(width-160 run)</small></h2>'
                 f'<div class="cards">{cards}</div>')
    if cov:
        h, n, p = cov["total"]
        trs = "".join(f'<tr><td>{html.escape(f)}</td><td class="r">{hh}/{nn}</td>'
                      f'<td>{_bar(pp)}</td></tr>' for f, hh, nn, pp in cov["files"])
        P.append(f'<h2>Line coverage <small>{h}/{n} = {p}%</small></h2>'
                 f'<table><tr><th>File</th><th>Lines</th><th>Coverage</th></tr>{trs}</table>')
    if tags:
        trs = "".join(f'<tr><td>{_badge(True)} {html.escape(t)}</td>'
                      f'<td>{html.escape(d)}</td></tr>' for t, d in tags)
        P.append(f'<h2>Verilator smokes <small>{len(tags)} passing</small></h2>'
                 f'<table><tr><th>Smoke</th><th>Detail</th></tr>{trs}</table>')
    if formal:
        trs = "".join(f'<tr><td>{html.escape(k)}</td><td>{_badge(v=="PASS")}</td></tr>'
                      for k, v in sorted(formal.items()))
        P.append(f'<h2>Formal proofs <small>{len(formal)}</small></h2>'
                 f'<table><tr><th>Proof</th><th>Status</th></tr>{trs}</table>')
    if cocotb:
        trs = "".join(f'<tr><td>{html.escape(n)}</td><td>{_badge(s=="PASS")}</td>'
                      f'<td class="r">{html.escape(st)}</td></tr>' for n, s, _, st in cocotb)
        P.append(f'<h2>PyUVM-on-cocotb <small>{len(cocotb)}</small></h2>'
                 f'<table><tr><th>Test</th><th>Status</th><th>sim ns</th></tr>{trs}</table>')
    body = "\n".join(P)
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PIPE 7.1 bridge metrics</title><style>
:root{{--bg:#fff;--fg:#1a1a1a;--mut:#666;--line:#e2e2e2;--card:#f6f7f9}}
@media(prefers-color-scheme:dark){{:root{{--bg:#14171c;--fg:#e6e6e6;--mut:#9aa0a6;--line:#2a2f37;--card:#1c2027}}}}
*{{box-sizing:border-box}}body{{margin:0;padding:2rem;max-width:1100px;margin:auto;
font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg)}}
h1{{font-size:1.5rem;margin:0 0 .2rem}}h2{{margin:2rem 0 .6rem;font-size:1.15rem;border-bottom:1px solid var(--line);padding-bottom:.3rem}}
h2 small,h1 small{{color:var(--mut);font-weight:400;font-size:.8em}}.meta{{color:var(--mut);font-size:.85rem}}
.cards{{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:.7rem}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:.8rem}}
.card .k{{color:var(--mut);font-size:.8rem}}.card .v{{font-size:1.5rem;font-weight:600;margin-top:.2rem}}
.card .v small{{font-size:.55em;color:var(--mut);font-weight:400}}
table{{border-collapse:collapse;width:100%;font-size:.9rem}}th,td{{text-align:left;padding:.35rem .6rem;border-bottom:1px solid var(--line)}}
th{{color:var(--mut);font-weight:600}}td.r{{text-align:right;font-variant-numeric:tabular-nums}}
.bar{{position:relative;background:var(--line);border-radius:5px;height:16px;min-width:120px}}
.bar .fill{{height:100%;border-radius:5px}}.bar span{{position:absolute;right:6px;top:0;font-size:.72rem;line-height:16px}}
.badge{{font-size:.7rem;font-weight:700;padding:.1rem .35rem;border-radius:4px;color:#fff}}
.badge.ok{{background:#2e7d32}}.badge.bad{{background:#c62828}}
code{{background:var(--card);padding:.05rem .3rem;border-radius:4px}}
</style></head><body>
<h1>UCIe RDI ↔ PIPE 7.1 MAC bridge <small>metrics report</small></h1>
{body}
</body></html>"""


# ---------------------------------------------------------------- threshold check
def check_thresholds(out: Path, thresh_file: Path):
    """Evaluate report/metrics.json against thresholds; exit 1 on any violation."""
    mfile = out / "metrics.json"
    if not mfile.exists():
        print(f"[THRESH] no {mfile}; run `make report` first"); return 2
    m = json.loads(mfile.read_text())
    t = json.loads(thresh_file.read_text())
    perf = m.get("performance") or {}
    src = perf.get("pipe_width_160") or (next(iter(perf.values())) if perf else {})
    cov_pct = (m.get("coverage") or {}).get("pct", 0.0)

    checks = []  # (name, value, op, bound)
    if "min_tx_util_pct" in t:  checks.append(("tx_util_pct", src.get("tx_util_pct", 0), ">=", t["min_tx_util_pct"]))
    if "max_lat_ns_avg" in t:   checks.append(("lat_ns_avg",  src.get("lat_ns_avg", 1e9), "<=", t["max_lat_ns_avg"]))
    if "max_rx_overflow" in t:  checks.append(("rx_overflow", src.get("rx_overflow", 1e9), "<=", t["max_rx_overflow"]))
    if "min_coverage_pct" in t: checks.append(("coverage_pct", cov_pct, ">=", t["min_coverage_pct"]))

    fails = 0
    for name, val, op, bound in checks:
        ok = (val >= bound) if op == ">=" else (val <= bound)
        fails += not ok
        print(f"[THRESH] {'PASS' if ok else 'FAIL'}  {name}={val} {op} {bound}")
    if fails:
        print(f"[THRESH] {fails} threshold(s) violated")
    else:
        print(f"[THRESH] all {len(checks)} thresholds met")
    return 1 if fails else 0


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--out", default="report")
    ap.add_argument("--check", metavar="THRESHOLDS_JSON",
                    help="evaluate <out>/metrics.json against a thresholds file and exit nonzero on violation")
    a = ap.parse_args()
    root, out = Path(a.root).resolve(), Path(a.out).resolve()
    if a.check:
        raise SystemExit(check_thresholds(out, Path(a.check)))
    logs = out / "logs"
    out.mkdir(parents=True, exist_ok=True)

    perf, tags = parse_perf_and_tags(logs / "regress.log")
    cov = parse_coverage(root / "coverage.info")
    formal = parse_formal(logs / "formal.log")
    cocotb = parse_cocotb(root / "test" / "cocotb" / "results.xml")
    sha = git_sha(root)

    m = build_metrics(perf, tags, cov, formal, cocotb, sha)
    (out / "metrics.json").write_text(json.dumps(m, indent=2) + "\n")
    (out / "report.md").write_text(build_md(m, cov, formal, cocotb, tags, perf) + "\n")
    (out / "report.html").write_text(build_html(m, cov, formal, cocotb, tags, perf))

    cpct = cov["total"][2] if cov else "n/a"
    print(f"[REPORT] wrote {out}/metrics.json, report.md, report.html  "
          f"(perf_runs={len(perf)} smokes={len(tags)} coverage={cpct}% "
          f"formal={len(formal)} cocotb={len(cocotb)})")


if __name__ == "__main__":
    main()
