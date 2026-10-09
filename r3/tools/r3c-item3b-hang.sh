#!/bin/bash
# R3c item 3b-1: a REAL hang. A dependency host is mapped (hostAliases) to 192.0.2.1 and packets to that address are
# DROPped in the kind node's FORWARD chain, so connections open and never answer (unlike item 3, where the pod got
# "no route to host" after a variable time).
# Run from spike/forge-spike-r1.   Usage: r3/tools/r3c-item3b-hang.sh [set...]   sets: A-Fail A-Ignore B-Fail B-Ignore (default all)
# Per set: control (2+2 samples), tuf-hang (3+3), ghcr-hang (3+3). golden should pass, unsigned should be denied.
# Output: r3/R3c-item3b-hang-raw.csv (same columns as item 3), progress on stdout. A trap removes the DROP rule and hostAliases
# and restores the full policy and the vpol policies. vpol policies are removed for the run (they would hide the ivpol result).
K="kubectl --context kind-forge-spike"; KN="$K -n kyverno"; NODE=forge-spike-control-plane
GOLD=tests/r1-t2-golden-ghcr.yaml; UNS=tests/r1-t3-unsigned-ghcr.yaml; SINK=192.0.2.1
OUT=r3/R3c-item3b-hang-raw.csv
[ -f "$OUT" ] || echo "set,scenario,image,attempt,seconds,outcome,webhook,log_cause,message" > "$OUT"
log(){ echo "$(date -u +%H:%M:%S) $*"; }
strip(){ sed 's/\x1b\[[0-9;]*m//g'; }
io(){ awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io; }
waitio(){ for i in $(seq 1 100); do v=$(io); (( $(echo "$v < 8" | bc -l) )) && return 0; sleep 3; done; log "io wait expired"; }
ready(){ $KN rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null; }
clear_alias(){ if [ -n "$($KN get deploy kyverno-admission-controller -o jsonpath='{.spec.template.spec.hostAliases}' | cat)" ]; then
  $KN patch deploy kyverno-admission-controller --type=json -p '[{"op":"remove","path":"/spec/template/spec/hostAliases"}]' | cat >/dev/null; ready; fi; }
set_alias(){ clear_alias
  $KN patch deploy kyverno-admission-controller --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$SINK\",\"hostnames\":[\"$1\"]}]}]" | cat >/dev/null; ready; }
add_drop(){ docker exec $NODE iptables -C FORWARD -d $SINK -j DROP 2>/dev/null || docker exec $NODE iptables -I FORWARD 1 -d $SINK -j DROP; }
del_drop(){ while docker exec $NODE iptables -C FORWARD -d $SINK -j DROP 2>/dev/null; do docker exec $NODE iptables -D FORWARD -d $SINK -j DROP; done; }
vpol_on(){ $K apply -f policies/r1-registry-allowlist.yaml -f policies/p3-deny-test-label.yaml | cat >/dev/null; sleep 10; }
vpol_off(){ $K delete vpol r1-registry-allowlist p3-deny-test-label --ignore-not-found | cat >/dev/null; }
cleanup(){ log "cleanup: restoring"; del_drop; clear_alias; $KN scale deploy kyverno-admission-controller --replicas=1 | cat >/dev/null; ready; r3/tools/swap-policy.sh policies/r3-ivp.yaml | tail -2; vpol_on; $K get ivpol,vpol | cat; docker exec $NODE iptables -S FORWARD | grep -c "$SINK" ; }
trap cleanup EXIT
sample(){ # <set> <scenario> <image> <manifest> <attempt>
  local s=$(date +%s.%N) st; st=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local o; o=$($K --request-timeout=150s apply --dry-run=server -f "$4" 2>&1 | cat)
  local d; d=$(echo "$(date +%s.%N) - $s" | bc -l) oc=other
  if echo "$o" | grep -q "server dry run"; then oc=admitted
  elif echo "$o" | grep -q "denied the request"; then oc=denied
  elif echo "$o" | grep -qE "failed calling webhook|no endpoints|connection refused|context deadline|timeout"; then oc=webhook-failure; fi
  local wh; wh=$(echo "$o" | grep -oE 'webhook "?[^" ]+' | head -1 | sed 's/webhook "\?//')
  local lc; lc=$($KN logs deploy/kyverno-admission-controller --since-time="$st" 2>&1 | strip | grep " ERR " | tail -1 | sed -E 's/.*(failed to [^:]*:|error=)/\1/' | head -c 260 | tr ',"\n' '   ')
  printf '%s,%s,%s,%s,%.2f,%s,%s,"%s","%s"\n' "$1" "$2" "$3" "$5" "$d" "$oc" "$wh" "$lc" "$(echo "$o" | tr '\n,"' '   ' | head -c 330)" >> "$OUT"
  echo "  $1/$2 $3 #$5: $oc ($(printf %.1f "$d") s)"
}
run_scenario(){ local n=$3; waitio
  for i in $(seq 1 $n); do sample "$1" "$2" golden $GOLD $i; done
  for i in $(seq 1 $n); do sample "$1" "$2" unsigned $UNS $i; done; }
sets=("$@"); [ ${#sets[@]} -eq 0 ] && sets=(A-Fail A-Ignore B-Fail B-Ignore)
log "== item 3b-1 start: sets ${sets[*]}"; vpol_off
for S in "${sets[@]}"; do
  case $S in
    A-Fail)   files="policies/r3c-split-sig.yaml policies/r3c-split-sbom.yaml policies/r3c-split-vuln.yaml" ;;
    A-Ignore) files="policies/r3c-ign-sig.yaml policies/r3c-ign-sbom.yaml policies/r3c-ign-vuln.yaml" ;;
    B-Fail)   files="policies/r3c-split-sig.yaml" ;;
    B-Ignore) files="policies/r3c-ign-sig.yaml" ;;
    *) log "unknown set $S"; continue ;;
  esac
  log "== set $S: swap to $files"; del_drop; clear_alias; r3/tools/swap-policy.sh $files | tail -4
  log "-- control";   run_scenario $S control 2
  log "-- tuf-hang";  set_alias tuf-repo-cdn.sigstore.dev; add_drop; sleep 20; run_scenario $S tuf-hang 3; del_drop
  log "-- ghcr-hang"; set_alias ghcr.io;                  add_drop; sleep 20; run_scenario $S ghcr-hang 3; del_drop
  clear_alias
done
log "== item 3b-1 done"
