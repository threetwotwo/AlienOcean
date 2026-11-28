#!/usr/bin/env python3
"""Perf runner summary 0.1.0 (perf runner thread, 28 Nov 2026).
Reads one or more perf_runner results.json folders and writes summary.md (plain text, for threads) and report.html
(one self-contained page, screenshots embedded, readable on a phone) into the first folder, or --out.
Usage: summarize.py RUN_DIR [RUN_DIR ...] [--out DIR] [--budget-ms 16.7]
Exit 0 always when the files are written; the numbers are judged by the reader or by tests/run_perf_runner.sh.
Standard library only."""
import base64, html, json, os, sys

WHITE_FLAG = 0.25   # share of near-white pixels above which a view is flagged as a white void


def load(d):
    with open(os.path.join(d, "results.json")) as f:
        r = json.load(f)
    r["_dir"] = d
    return r


def label(r):
    w = r.get("window", ["?", "?"])
    return r.get("label") or f"{w[0]}x{w[1]}"


def md(runs, budget):
    L = [f"# Perf run {runs[0]['utc']}", "",
         f"Machine: {runs[0]['machine']['gpu']}, Godot {runs[0]['machine']['godot']}, build {runs[0].get('version','?')}. "
         f"Vsync off, so the numbers are true frame cost (budget {budget} ms = 60 fps).", ""]
    gpu_ok = any(s["gpu_ms"] > 0 for r in runs for s in r["stations"])
    if not gpu_ok:
        L += ["GPU time: Godot reports 0 on Metal, so GPU ms is not shown; frame ms is the whole frame (CPU + GPU).", ""]
    for r in runs:
        L += [f"## Stations at {label(r)}", "",
              "| station | fps | mean ms | p95 ms | worst ms | tris | draws | white | over budget |",
              "|---|---|---|---|---|---|---|---|---|"]
        for s in sorted(r["stations"], key=lambda s: -s["mean_ms"]):
            over = "YES" if s["mean_ms"] > budget else ""
            wf = s["image"]["white_frac"]
            L.append(f"| {s['name']} | {s['fps']:.0f} | {s['mean_ms']:.1f} | {s['p95_ms']:.1f} | {s['worst_ms']:.0f} | "
                     f"{s['triangles']/1e6:.2f} M | {s['draw_calls']} | {wf:.2f}{' VOID' if wf > WHITE_FLAG else ''} | {over} |")
        L.append("")
        if r["toggles"]:
            L += [f"## What each switch costs at {label(r)} (ms saved when it is off; + = it costs that much)", "",
                  "| station | switch | default | frame ms with | frame ms without | cost ms |", "|---|---|---|---|---|---|"]
            for t in sorted(r["toggles"], key=lambda t: -t["cost_ms"]):
                on = t["base_mean_ms"] if t["default_on"] else t["flipped_mean_ms"]
                off = t["flipped_mean_ms"] if t["default_on"] else t["base_mean_ms"]
                L.append(f"| {t['station']} | {t['toggle']} | {'on' if t['default_on'] else 'off'} | {on:.1f} | {off:.1f} | {t['cost_ms']:+.1f} |")
            L.append("")
        moved = [s["name"] for s in r["stations"] if s.get("resized")]
        if moved:
            L += ["WINDOW RESIZED during the run (numbers not comparable) at: " + ", ".join(moved), ""]
        hitches = [s for s in r["stations"] if s["worst_ms"] > 4 * max(s["p50_ms"], 1)]
        if hitches:
            L += ["Hitches (a frame over 4x the median, usually a first-time shader compile or a load): " +
                  ", ".join(f"{s['name']} {s['worst_ms']:.0f} ms" for s in hitches), ""]
    return "\n".join(L)


def img64(path):
    """the station's small JPEG if there is one (keeps the page phone sized), else its PNG"""
    thumb = path[:-4] + "_thumb.jpg" if path.endswith(".png") else ""
    if thumb and os.path.exists(thumb):
        path, mime = thumb, "image/jpeg"
    elif os.path.exists(path) and path.endswith(".png"):
        mime = "image/png"
    else:
        return ""
    with open(path, "rb") as f:
        return f"data:{mime};base64," + base64.b64encode(f.read()).decode()


def page(runs, budget, text):
    css = (":root{--bg:#fdfdfb;--fg:#161616;--muted:#555;--rule:#d6d6d0;--bad:#a30d0d}"
           "@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#141414;--fg:#e4e4e0;--muted:#a0a09a;--rule:#3a3a36;--bad:#ff7b6b}}"
           ":root[data-theme=dark]{--bg:#141414;--fg:#e4e4e0;--muted:#a0a09a;--rule:#3a3a36;--bad:#ff7b6b}"
           "body{font-family:Georgia,'Times New Roman',serif;max-width:900px;margin:0 auto;padding:16px;background:var(--bg);color:var(--fg);line-height:1.45}"
           ".scroll{overflow-x:auto}table{border-collapse:collapse;font:13px/1.3 -apple-system,Helvetica,sans-serif;width:100%;margin:8px 0 20px}"
           "td,th{border-bottom:1px solid var(--rule);padding:3px 6px;text-align:right;white-space:nowrap}td:first-child,th:first-child,td:nth-child(2){text-align:left}"
           ".fig{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}.fig img{width:100%;display:block}"
           ".fig div{font:12px -apple-system,Helvetica,sans-serif;color:var(--muted)}.bad{color:var(--bad)}h1{font-size:22px}h2{font-size:17px;margin-top:28px}")
    H = [f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
         f"<title>Test level perf run</title><style>{css}</style><h1>Perf run, {html.escape(runs[0]['utc'])}</h1>"]
    out_md = []
    for line in text.split("\n")[2:]:
        out_md.append(line)
    rows = []
    in_table = False
    for line in out_md:
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if set("".join(cells)) <= set("-"):
                continue
            tag = "th" if not in_table else "td"
            cls = " class=bad" if ("YES" in cells or any("VOID" in c for c in cells)) else ""
            rows.append(("<div class=scroll><table>" if not in_table else "") + f"<tr{cls}>" + "".join(f"<{tag}>{html.escape(c)}</{tag}>" for c in cells) + "</tr>")
            in_table = True
        else:
            if in_table:
                rows.append("</table></div>"); in_table = False
            if line.startswith("## "):
                rows.append(f"<h2>{html.escape(line[3:])}</h2>")
            elif line.strip():
                rows.append(f"<p>{html.escape(line)}</p>")
    if in_table:
        rows.append("</table></div>")
    H += rows
    for r in runs:
        H.append(f"<h2>Views at {label(r)}</h2><div class=fig>")
        for s in r["stations"]:
            src = img64(os.path.join(r["_dir"], s.get("shot", "")))
            if src:
                H.append(f"<div><img src='{src}'><br>{html.escape(s['name'])}: {s['fps']:.0f} fps, {s['mean_ms']:.1f} ms, "
                         f"worst {s['worst_ms']:.0f} ms, white {s['image']['white_frac']:.2f}</div>")
        H.append("</div>")
    return "\n".join(H)


def main(a):
    budget = 16.7
    out = None
    dirs = []
    i = 0
    while i < len(a):
        if a[i] == "--out": out = a[i + 1]; i += 1
        elif a[i] == "--budget-ms": budget = float(a[i + 1]); i += 1
        else: dirs.append(a[i])
        i += 1
    runs = [load(d) for d in dirs]
    out = out or dirs[0]
    text = md(runs, budget)
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write(text + "\n")
    with open(os.path.join(out, "report.html"), "w") as f:
        f.write(page(runs, budget, text))
    print(text)


if __name__ == "__main__":
    main(sys.argv[1:])
