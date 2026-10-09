#!/usr/bin/env python3
"""Summarise the item 5 load tests.  Usage: python3 -I r3/tools/r3c-item5-summary.py   (run from spike/forge-spike-r1)
L1: per design/mode/N: outcomes of the burst, p50/p95/max seconds of admitted calls, wall time, log counters, resource peaks.
L2: the meta table, sampler peaks, background-scan rows."""
import csv, os, collections

def pct(xs, p):
    xs = sorted(xs)
    if not xs: return float("nan")
    k = (len(xs) - 1) * p; f = int(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

def peaks(path):
    out = collections.defaultdict(lambda: [0.0, 0.0])
    if not os.path.exists(path): return out
    for line in open(path):
        p = line.strip().split(",")
        if len(p) < 5: continue
        try: cpu = float(p[3]); mem = float(p[4].replace("MB", "").replace("kB", "e-3").replace("GB", "e3"))
        except ValueError: continue
        k = (p[1], p[2]); out[k][0] = max(out[k][0], cpu); out[k][1] = max(out[k][1], mem)
    return out

if os.path.exists("r3/R3c-item5-l1-raw.csv"):
    rows = [r for r in csv.DictReader(open("r3/R3c-item5-l1-raw.csv")) if r["mode"] != "prime"]
    meta = {(m["design"], m["mode"], m["N"]): m for m in csv.DictReader(open("r3/R3c-item5-l1-meta.csv"))}
    pk = peaks("r3/R3c-item5-l1-stats.csv")
    print("== L1: N simultaneous dry-run admissions of golden")
    print("%-3s %-5s %3s | %-44s | %6s %6s %6s | %6s | dns rl dl err | adm cpu%% mem MB | restarts" % ("des", "mode", "N", "outcomes", "p50", "p95", "max", "wall"))
    g = collections.OrderedDict()
    for r in rows: g.setdefault((r["design"], r["mode"], r["N"]), []).append(r)
    for k, rs in g.items():
        ok = [float(r["seconds"]) for r in rs if r["outcome"] == "admitted"]
        oc = dict(collections.Counter(r["outcome"] for r in rs)); m = meta.get(k, {})
        a = pk.get(("%s-%s-%s" % k, "adm"), [0, 0])
        print("%-3s %-5s %3s | %-44s | %6.1f %6.1f %6.1f | %6s | %3s %2s %2s %3s | %5.0f %6.0f | %s->%s" % (
            k[0], k[1], k[2], oc, pct(ok, .5), pct(ok, .95), max(ok) if ok else float("nan"), m.get("wall_s", "?"),
            m.get("dns", "?"), m.get("ratelimit", "?"), m.get("deadline", "?"), m.get("errs", "?"), a[0], a[1], m.get("restarts_before", "?"), m.get("restarts_after", "?")))
if os.path.exists("r3/R3c-item5-l2-meta.csv"):
    pk = peaks("r3/R3c-item5-l2-stats.csv")
    print("\n== L2: Deployment of golden")
    print("%-3s %-5s %3s | first all ready | failedcreate | dns rl dl err | adm cpu%% mem MB | restarts" % ("des", "mode", "N"))
    for m in csv.DictReader(open("r3/R3c-item5-l2-meta.csv")):
        a = pk.get(("%s-%s-%s" % (m["design"], m["mode"], m["N"]), "adm"), [0, 0])
        print("%-3s %-5s %3s | %5s %5s %5s | %12s | %3s %2s %2s %3s | %5.0f %6.0f | %s->%s" % (
            m["design"], m["mode"], m["N"], m["first_ready_s"], m["all_ready_s"], m["ready_at_end"], m["failedcreate_events"],
            m["dns"], m["ratelimit"], m["deadline"], m["errs"], a[0], a[1], m["restarts_before"], m["restarts_after"]))
if os.path.exists("r3/R3c-item5-l2-bgscan.csv"):
    print("\n== Background scan with 20 pods running")
    for r in csv.DictReader(open("r3/R3c-item5-l2-bgscan.csv")): print("  ", dict(r))
