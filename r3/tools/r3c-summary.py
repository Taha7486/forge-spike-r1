#!/usr/bin/env python3
"""Summarise an r3-latency.sh style CSV: per case and phase, admitted samples (n, min, p50, p95, max)
and counts of every other outcome. Usage: python3 -I r3/tools/r3c-summary.py r3/R3c-item2-raw.csv
Rows: case,attempt,phase,seconds,outcome,io_avg10_before,note"""
import csv, sys, collections

def pct(xs, p):
    xs = sorted(xs); k = (len(xs) - 1) * p; f = int(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

rows = list(csv.DictReader(open(sys.argv[1])))
by = collections.OrderedDict()
for r in rows:
    by.setdefault((r["case"], r["phase"]), []).append(r)
print("%-22s %-5s %3s %6s %6s %6s %6s   other outcomes" % ("case", "phase", "n", "min", "p50", "p95", "max"))
for (case, phase), rs in by.items():
    ok = [float(r["seconds"]) for r in rs if r["outcome"] == "admitted"]
    other = collections.Counter(r["outcome"] for r in rs if r["outcome"] != "admitted")
    if ok:
        print("%-22s %-5s %3d %6.1f %6.1f %6.1f %6.1f   %s" % (case, phase, len(ok), min(ok), pct(ok, .5), pct(ok, .95), max(ok), dict(other) or ""))
    else:
        print("%-22s %-5s %3d %6s %6s %6s %6s   %s" % (case, phase, 0, "-", "-", "-", "-", dict(other)))
