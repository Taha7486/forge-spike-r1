#!/bin/bash
# Create the R3e cluster (context kind-forge-r3e) and install Kyverno 1.19.1 (chart 3.9.1) with the ADR-002 values. Run from spike/forge-spike-r1 on a quiet machine.
set -e
echo "io pressure before: $(awk '/^some/' /proc/pressure/io)"
kind create cluster --name forge-r3e --config r3/tools/r3e-kind.yaml --wait 300s
K="kubectl --context kind-forge-r3e"
helm --kube-context kind-forge-r3e install kyverno kyverno/kyverno --version 3.9.1 -n kyverno --create-namespace -f r3/tools/r3e-kyverno-values.yaml --wait --timeout 15m
$K -n kyverno get pods -o wide | cat
