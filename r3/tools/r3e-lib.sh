#!/bin/bash
# Shared helpers for the R3e scripts (source this). Run from spike/forge-spike-r1. Cluster context: kind-forge-r3e (nodes forge-r3e-control-plane, -worker, -worker2).
K="kubectl --context kind-forge-r3e"; KN="$K -n kyverno"
UNS=tests/r1-t3-unsigned-ghcr.yaml; GOLD=tests/r1-t2-golden-ghcr.yaml
log(){ echo "$(date -u +%H:%M:%S) $*"; }
io(){ awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io; }
waitio(){ for i in $(seq 1 100); do v=$(io); (( $(echo "$v < 8" | bc -l) )) && return 0; sleep 3; done; echo "io wait expired" >&2; return 1; }
ready(){ $KN rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null; }
adm_pods(){ $KN get pods -l app.kubernetes.io/component=admission-controller -o wide --no-headers | cat; }
leader(){ $KN get lease kyverno -o jsonpath='{.spec.holderIdentity}'; }
# classify the outcome of one dry-run of a manifest: prints "<outcome> <seconds>"
probe(){ local man=$1 s o d oc=other; s=$(date +%s.%N)
  o=$($K --request-timeout=90s apply --dry-run=server -f $man 2>&1 | cat); d=$(echo "$(date +%s.%N) - $s" | bc -l)
  if echo "$o" | grep -q "server dry run"; then oc=admitted
  elif echo "$o" | grep -q "denied the request"; then oc=denied-by-policy
  elif echo "$o" | grep -qE "failed calling webhook|no endpoints|connection refused|context deadline|timeout|timed out"; then oc=webhook-failure; fi
  printf '%s %.2f|%s' "$oc" "$d" "$(echo "$o" | tr '\n,"' '   ' | cut -c1-160)"; }
# Timeline helpers: OUT must be set. CSV: label,utc_time,seconds,outcome,detail
mark(){ echo "EVENT,$(date -u +%H:%M:%S),0,-,$1" >> "$OUT"; log "EVENT $1"; }
probe_loop(){ # <label> <end-epoch> [manifest]
  local man=${3:-$UNS} r
  while [ $(date +%s) -lt $2 ]; do local t; t=$(date -u +%H:%M:%S); r=$(probe $man)
    printf '%s,%s,%s,%s,"%s"\n' "$1" "$t" "$(echo "${r%%|*}" | cut -d' ' -f2)" "$(echo "${r%%|*}" | cut -d' ' -f1)" "${r#*|}" >> "$OUT"; done; }
state_loop(){ # <end-epoch>: pod states + webhook configuration presence every 2 s
  while [ $(date +%s) -lt $1 ]; do
    n=$($K get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg --no-headers 2>/dev/null | wc -l)
    echo "STATE,$(date -u +%H:%M:%S),0,webhook-$([ "$n" = 1 ] && echo present || echo absent),$($KN get pods -l app.kubernetes.io/component=admission-controller --no-headers 2>/dev/null | awk '{printf "%s:%s:%s ",substr($1,length($1)-4),$2,$3}')" >> "$OUT"
    sleep 2; done; }
timeline(){ # <name> <total-seconds> <action-function>   two probe loops (offset 2 s) + state loop; action fires after 12 s
  local end=$(( $(date +%s) + $2 ))
  mark "$1 start (probes running)"
  probe_loop "$1-p1" $end & probe_loop "$1-p2" $end & sleep 2
  state_loop $end &
  sleep 12; mark "$1 ACTION"; $3; mark "$1 action returned"
  wait; mark "$1 end"; }
