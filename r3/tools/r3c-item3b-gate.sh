#!/bin/bash
# R3c item 3b-2 and 3b-3: is the admission "gate" open while the controller is crashed or being replaced?
# Run from spike/forge-spike-r1.   Usage: r3/tools/r3c-item3b-gate.sh crash | replicas
#   crash     B design (signature policy only), once with failurePolicy Fail and once with Ignore, 1 replica.
#             The controller container is killed without a graceful stop (crictl stop -t 0): no shutdown cleanup.
#   replicas  B-Fail, 2 replicas + a PodDisruptionBudget (minAvailable 1, created for the test): delete the leader pod,
#             delete the other pod, then a rollout restart.
# During each run two probe loops (offset by about 2 s) admit the UNSIGNED image back to back and a third loop records whether
# the resource webhook configuration exists. The unsigned image must always be denied; "admitted" = gate open.
#   outcome: admitted (gate OPEN) | denied-by-policy (gate up, Kyverno answered) | webhook-failure (gate down, closed by Fail) | other
# Output: r3/R3c-item3b-<mode>-timeline.csv   label,utc_time,seconds,outcome,detail   (label EVENT = a marker, WEBHOOK = config presence)
# The vpol policies are removed for the run (they are Fail mode and would hide the ivpol result) and restored by the trap.
K="kubectl --context kind-forge-spike"; KN="$K -n kyverno"; NODE=forge-spike-control-plane
UNS=tests/r1-t3-unsigned-ghcr.yaml; MODE=$1
OUT=r3/R3c-item3b-$MODE-timeline.csv
[ -f "$OUT" ] || echo "label,utc_time,seconds,outcome,detail" > "$OUT"
log(){ echo "$(date -u +%H:%M:%S) $*"; }
ready(){ $KN rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null; }
vpol_on(){ $K apply -f policies/r1-registry-allowlist.yaml -f policies/p3-deny-test-label.yaml | cat >/dev/null; sleep 10; }
vpol_off(){ $K delete vpol r1-registry-allowlist p3-deny-test-label --ignore-not-found | cat >/dev/null; }
cleanup(){ log "cleanup: restoring"; $K delete pdb -n kyverno r3c-test-pdb --ignore-not-found | cat; $KN scale deploy kyverno-admission-controller --replicas=1 | cat >/dev/null; ready; r3/tools/swap-policy.sh policies/r3-ivp.yaml | tail -2; vpol_on; $K get ivpol,vpol | cat; }
trap cleanup EXIT
mark(){ echo "EVENT,$(date -u +%H:%M:%S),0,-,$1" >> "$OUT"; log "EVENT $1"; }
probe_loop(){ # <label> <end-epoch>
  while [ $(date +%s) -lt $2 ]; do
    local s=$(date +%s.%N) t; t=$(date -u +%H:%M:%S)
    local o; o=$($K --request-timeout=90s apply --dry-run=server -f $UNS 2>&1 | cat)
    local d; d=$(echo "$(date +%s.%N) - $s" | bc -l) oc=other
    if echo "$o" | grep -q "server dry run"; then oc=admitted
    elif echo "$o" | grep -q "denied the request"; then oc=denied-by-policy
    elif echo "$o" | grep -qE "failed calling webhook|no endpoints|connection refused|context deadline|timeout"; then oc=webhook-failure; fi
    printf '%s,%s,%.2f,%s,"%s"\n' "$1" "$t" "$d" "$oc" "$(echo "$o" | tr '\n,"' '   ' | cut -c60-200)" >> "$OUT"
  done; }
webhook_loop(){ while [ $(date +%s) -lt $1 ]; do
    n=$($K get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg --no-headers 2>/dev/null | wc -l)
    echo "WEBHOOK,$(date -u +%H:%M:%S),0,$([ "$n" = 1 ] && echo present || echo absent),$($KN get pods -l app.kubernetes.io/component=admission-controller --no-headers 2>/dev/null | awk '{printf "%s:%s:%s ",substr($1,length($1)-4),$2,$3}')" >> "$OUT"
    sleep 2; done; }
timeline(){ # <name> <total-seconds> <action-function>
  local end=$(( $(date +%s) + $2 ))
  mark "$1 start (probes running)"
  probe_loop "$1-p1" $end & probe_loop "$1-p2" $end & sleep 2
  webhook_loop $end &
  sleep 12; mark "$1 ACTION"; $3; mark "$1 action returned"
  wait; mark "$1 end"
  ready; sleep 20; }
swap_to(){ r3/tools/swap-policy.sh $@ | tail -3; }
crash_action(){ local pod id; pod=$($KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].metadata.name}')
  id=$(docker exec $NODE crictl ps --label io.kubernetes.pod.name=$pod --name kyverno -q | head -1)
  mark "killing container $id of $pod (no graceful stop)"; docker exec $NODE crictl stop --timeout 0 "$id" | cat >/dev/null; }
leader(){ $KN get lease kyverno -o jsonpath='{.spec.holderIdentity}'; }
pods(){ $KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
delete_leader(){ local l; l=$(leader); mark "deleting LEADER pod $l"; $KN delete pod "$l" --wait=false | cat >/dev/null; }
delete_other(){ local l o; l=$(leader); o=$(pods | grep -v "$l" | head -1); mark "deleting NON-leader pod $o (leader $l)"; $KN delete pod "$o" --wait=false | cat >/dev/null; }
roll(){ mark "rollout restart"; $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; }
vpol_off
case $MODE in
  crash)
    for P in Fail Ignore; do
      if [ $P = Fail ]; then f=policies/r3c-split-sig.yaml; else f=policies/r3c-ign-sig.yaml; fi
      log "== crash, policy $P"; swap_to $f; $KN scale deploy kyverno-admission-controller --replicas=1 | cat >/dev/null; ready; sleep 15
      timeline "crash-$P" 110 crash_action
    done ;;
  replicas)
    swap_to policies/r3c-split-sig.yaml
    cat <<EOF | $K apply -f - | cat
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: r3c-test-pdb, namespace: kyverno}
spec:
  minAvailable: 1
  selector: {matchLabels: {app.kubernetes.io/component: admission-controller}}
EOF
    $KN scale deploy kyverno-admission-controller --replicas=2 | cat >/dev/null; ready; sleep 30
    log "pods: $(pods | tr '\n' ' ') leader: $(leader)"
    timeline "delete-leader" 100 delete_leader
    timeline "delete-other"  100 delete_other
    timeline "rollout"       130 roll ;;
  *) echo "usage: $0 crash|replicas" >&2; exit 2 ;;
esac
log "== item 3b $MODE done"
