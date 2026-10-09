#!/bin/bash
# Runs item 3b in sequence: hang, crash, replicas. Run from spike/forge-spike-r1. Each part restores the cluster on exit.
r3/tools/r3c-item3b-hang.sh
r3/tools/r3c-item3b-gate.sh crash
r3/tools/r3c-item3b-gate.sh replicas
echo "ALL 3B DONE"
