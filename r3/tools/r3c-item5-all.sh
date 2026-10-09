#!/bin/bash
# Runs item 5 in sequence: L1 (controlled concurrency), then L2 (Deployment + background scan). Run from spike/forge-spike-r1.
r3/tools/r3c-item5-l1.sh
r3/tools/r3c-item5-l2.sh
echo "ALL ITEM 5 DONE"
