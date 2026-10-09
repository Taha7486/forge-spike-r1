#!/bin/bash
# Usage: swap-policy.sh policies/a.yaml [policies/b.yaml ...]  -> deletes ALL image policies, applies the given ones, waits until all are Ready.
K="kubectl --context kind-forge-spike"
$K delete ivpol --all | cat
$K apply $(for f in "$@"; do printf -- '-f %s ' "$f"; done) | cat
for i in $(seq 1 60); do [ "$($K get ivpol --no-headers | cat | grep -c ' true')" = "$#" ] && break; sleep 4; done
$K get ivpol | cat
sleep 20
