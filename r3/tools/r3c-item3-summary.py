#!/usr/bin/env python3
"""Summarise r3/R3c-item3-raw.csv: per set, scenario and image, the outcome counts and the median/max seconds.
Usage: python3 -I r3/tools/r3c-item3-summary.py r3/R3c-item3-raw.csv
Flags FAIL-OPEN where an unsigned image was admitted, and CONTROL-BAD where a control did not behave."""
import csv, sys, collections, statistics

rows = list(csv.DictReader(open(sys.argv[1])))
by = collections.OrderedDict()
for r in rows:
    by.setdefault((r["set"], r["scenario"], r["image"]), []).append(r)
print("%-9s %-13s %-9s %2s  %-44s %6s %6s  flag" % ("set", "scenario", "image", "n", "outcomes", "med s", "max s"))
for (s, sc, im), rs in by.items():
    c = collections.Counter(r["outcome"] for r in rs)
    t = [float(r["seconds"]) for r in rs]
    flag = ""
    if im == "unsigned" and c["admitted"]:
        flag = "FAIL-OPEN"
    if sc == "control" and ((im == "golden" and c["admitted"] != len(rs)) or (im == "unsigned" and c["denied"] != len(rs))):
        flag = "CONTROL-BAD"
    print("%-9s %-13s %-9s %2d  %-44s %6.1f %6.1f  %s" % (s, sc, im, len(rs), dict(c), statistics.median(t), max(t), flag))
