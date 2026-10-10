#!/bin/bash
# R3e item 2: spreading and PDB. Run from spike/forge-spike-r1.
source r3/tools/r3e-lib.sh; OUT=r3/R3e/step1-timeline.csv
[ -f "$OUT" ] || echo "label,utc_time,seconds,outcome,detail" > "$OUT"
echo "== placement"; adm_pods; $KN get pdb | cat; $K get nodes | cat
W1=$($KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].spec.nodeName}')
W2=$($KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[1].spec.nodeName}')
echo "replicas on: $W1 $W2"
drain_one(){ $K drain $W1 --ignore-daemonsets --delete-emptydir-data --timeout=60s 2>&1 | tail -6 | cat; }
drain_two(){ $K drain $W2 --ignore-daemonsets --delete-emptydir-data --timeout=45s 2>&1 | tail -8 | cat; }
timeline "drain-first-node" 90 drain_one
echo "== after first drain"; adm_pods; $KN get pdb | cat
timeline "drain-second-node" 80 drain_two
echo "== after second drain attempt"; adm_pods; $KN get pdb | cat
$KN get events --sort-by=.lastTimestamp 2>&1 | grep -iE "evict|FailedScheduling|disruption|Killing" | tail -10 | cat
mark "uncordon both"; $K uncordon $W1 $W2 | cat
sleep 40; ready; adm_pods
