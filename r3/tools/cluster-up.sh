#!/bin/bash
# Start the kind node and wait until the API and all Kyverno pods are Ready. Run on a quiet machine (HDD).
K="kubectl --context kind-forge-spike"
echo "io pressure before start: $(awk '/^some/' /proc/pressure/io)"
docker start forge-spike-control-plane | cat
for i in $(seq 1 60); do $K get nodes 2>/dev/null | cat | grep -q " Ready" && break; sleep 5; done
$K get nodes | cat
$K -n kyverno wait --for=condition=Ready pod --all --timeout=400s | cat
$K get ivpol | cat
