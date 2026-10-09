#!/bin/bash
# R3c item 3: failure modes of image verification under failurePolicy Fail and Ignore, designs A and B.
# Run from spike/forge-spike-r1.   Usage: r3/tools/r3c-item3-run.sh [set...]    sets: A-Fail A-Ignore B-Fail B-Ignore (default: all, in this order)
#   A = three parallel policies (signature, SBOM, vuln)      B = signature policy only
#   Fail sets use policies/r3c-split-*.yaml, Ignore sets use policies/r3c-ign-*.yaml (identical except name and failurePolicy)
# Scenarios per set (dry-run admission of golden = should pass, unsigned = should be denied):
#   control         no failure injected (proves the test is valid)
#   tuf-refused     tuf-repo-cdn.sigstore.dev -> 127.0.0.1 in the admission controller's /etc/hosts (hostAliases): connection refused
#   ghcr-refused    ghcr.io -> 127.0.0.1
#   cdn-refused     pkg-containers.githubusercontent.com -> 127.0.0.1   (blob CDN)
#   tuf-slow        tuf-repo-cdn.sigstore.dev -> 192.0.2.1 (TEST-NET-1: connections hang, nothing answers)
#   ghcr-slow       ghcr.io -> 192.0.2.1
#   scaled0         admission controller scaled to 0 replicas (webhook service has no endpoints)
#   scaled0-vpol    (set A-Ignore only) same, with the two Fail-mode vpol policies also live
# The two vpol policies (r1-registry-allowlist, p3-deny-test-label) are removed for the run and restored at the end,
# because they share the controller and are failurePolicy Fail: they would hide the image-policy result.
# Output: r3/R3c-item3-raw.csv  set,scenario,image,attempt,seconds,outcome,webhook,log_cause,message
#   outcome: admitted | denied | webhook-failure | other.  Setup facts (webhook failurePolicies etc.): r3/R3c-item3-setup.log
# A trap restores hostAliases, replicas, the full policy r3-verify-forge-images and the vpol policies on exit.
K="kubectl --context kind-forge-spike"; KN="$K -n kyverno"; NODE=forge-spike-control-plane
GOLD=tests/r1-t2-golden-ghcr.yaml; UNS=tests/r1-t3-unsigned-ghcr.yaml
OUT=r3/R3c-item3-raw.csv; SETUP=r3/R3c-item3-setup.log
N_FAST=5; N_SLOW=3
[ -f "$OUT" ] || echo "set,scenario,image,attempt,seconds,outcome,webhook,log_cause,message" > "$OUT"
log(){ echo "$(date -u +%H:%M:%S) $*" | tee -a "$SETUP"; }
strip(){ sed 's/\x1b\[[0-9;]*m//g'; }
io(){ awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io; }
waitio(){ for i in $(seq 1 100); do v=$(io); (( $(echo "$v < 8" | bc -l) )) && return 0; sleep 3; done; log "io wait expired"; }
ready(){ $KN rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null; }
clear_alias(){ if [ -n "$($KN get deploy kyverno-admission-controller -o jsonpath='{.spec.template.spec.hostAliases}' | cat)" ]; then
  $KN patch deploy kyverno-admission-controller --type=json -p '[{"op":"remove","path":"/spec/template/spec/hostAliases"}]' | cat >/dev/null; ready; fi; }
set_alias(){ # <host> <ip>
  clear_alias
  $KN patch deploy kyverno-admission-controller --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$2\",\"hostnames\":[\"$1\"]}]}]" | cat >/dev/null; ready; }
scale(){ $KN scale deploy kyverno-admission-controller --replicas=$1 | cat >/dev/null
  if [ "$1" = 0 ]; then for i in $(seq 1 60); do [ -z "$($KN get pods -l app.kubernetes.io/component=admission-controller --no-headers 2>/dev/null | cat)" ] && break; sleep 2; done; else ready; fi; }
vpol_on(){ $K apply -f policies/r1-registry-allowlist.yaml -f policies/p3-deny-test-label.yaml | cat >/dev/null; sleep 10; }
vpol_off(){ $K delete vpol r1-registry-allowlist p3-deny-test-label --ignore-not-found | cat >/dev/null; }
cleanup(){ log "cleanup: restoring"; clear_alias; scale 1; r3/tools/swap-policy.sh policies/r3-ivp.yaml | tail -2; vpol_on; $K get ivpol,vpol | cat; }
trap cleanup EXIT
sample(){ # <set> <scenario> <image-label> <manifest> <attempt> <with-log:1|0>
  local s=$(date +%s.%N) st; st=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local o; o=$($K --request-timeout=150s apply --dry-run=server -f "$4" 2>&1 | cat)
  local d; d=$(echo "$(date +%s.%N) - $s" | bc -l) oc=other
  if echo "$o" | grep -q "server dry run"; then oc=admitted
  elif echo "$o" | grep -q "denied the request"; then oc=denied
  elif echo "$o" | grep -qE "failed calling webhook|no endpoints|connection refused|context deadline|timeout"; then oc=webhook-failure; fi
  local wh; wh=$(echo "$o" | grep -oE 'webhook "?[^" ]+' | head -1 | sed 's/webhook "\?//')
  local lc=""
  [ "$6" = 1 ] && lc=$($KN logs deploy/kyverno-admission-controller --since-time="$st" 2>&1 | strip | grep " ERR " | tail -1 | sed -E 's/.*(failed to [^:]*:|error=)/\1/' | head -c 260 | tr ',"\n' '   ')
  printf '%s,%s,%s,%s,%.2f,%s,%s,"%s","%s"\n' "$1" "$2" "$3" "$5" "$d" "$oc" "$wh" "$lc" "$(echo "$o" | tr '\n,"' '   ' | head -c 330)" >> "$OUT"
  echo "  $1/$2 $3 #$5: $oc ($(printf %.1f "$d") s)"
}
run_scenario(){ # <set> <scenario> <n> <with-log>
  local n=$3
  waitio
  for i in $(seq 1 $n); do sample "$1" "$2" golden $GOLD $i $4; done
  for i in $(seq 1 $n); do sample "$1" "$2" unsigned $UNS $i $4; done
}
sets=("$@"); [ ${#sets[@]} -eq 0 ] && sets=(A-Fail A-Ignore B-Fail B-Ignore)
log "== item 3 start: sets ${sets[*]}; removing vpol policies for the run"
vpol_off
for S in "${sets[@]}"; do
  case $S in
    A-Fail)   files="policies/r3c-split-sig.yaml policies/r3c-split-sbom.yaml policies/r3c-split-vuln.yaml" ;;
    A-Ignore) files="policies/r3c-ign-sig.yaml policies/r3c-ign-sbom.yaml policies/r3c-ign-vuln.yaml" ;;
    B-Fail)   files="policies/r3c-split-sig.yaml" ;;
    B-Ignore) files="policies/r3c-ign-sig.yaml" ;;
    *) log "unknown set $S"; continue ;;
  esac
  log "== set $S: swap to $files"
  clear_alias; scale 1
  r3/tools/swap-policy.sh $files | tail -4 | tee -a "$SETUP"
  log "webhook failurePolicies (validating then mutating):"
  $K get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{range .webhooks[*]}{.name}{" fp="}{.failurePolicy}{" timeout="}{.timeoutSeconds}{"\n"}{end}' | cat | tee -a "$SETUP"
  $K get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg -o jsonpath='{range .webhooks[*]}{.name}{" fp="}{.failurePolicy}{" timeout="}{.timeoutSeconds}{"\n"}{end}' | cat | tee -a "$SETUP"
  log "-- control"; run_scenario $S control $N_FAST 1
  log "-- tuf-refused";  set_alias tuf-repo-cdn.sigstore.dev 127.0.0.1; sleep 20; run_scenario $S tuf-refused $N_FAST 1
  log "-- ghcr-refused"; set_alias ghcr.io 127.0.0.1; sleep 20; run_scenario $S ghcr-refused $N_FAST 1
  log "-- cdn-refused";  set_alias pkg-containers.githubusercontent.com 127.0.0.1; sleep 20; run_scenario $S cdn-refused $N_FAST 1
  log "-- tuf-slow";     set_alias tuf-repo-cdn.sigstore.dev 192.0.2.1; sleep 20; run_scenario $S tuf-slow $N_SLOW 1
  log "-- ghcr-slow";    set_alias ghcr.io 192.0.2.1; sleep 20; run_scenario $S ghcr-slow $N_SLOW 1
  clear_alias
  log "-- scaled0";      scale 0; run_scenario $S scaled0 $N_FAST 0; scale 1; sleep 20
  if [ $S = A-Ignore ]; then
    log "-- scaled0-vpol"; vpol_on; scale 0; run_scenario $S scaled0-vpol $N_FAST 0; scale 1; sleep 20; vpol_off
  fi
done
log "== item 3 done"
