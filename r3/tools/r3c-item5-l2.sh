#!/bin/bash
# R3c item 5, L2: a real Deployment of golden with N replicas (10, 20), designs B then A, cold and warm.
# Run from spike/forge-spike-r1.   Usage: r3/tools/r3c-item5-l2.sh [design...]
#   cold = admission controller restarted, then the Deployment is created with N replicas (empty verify cache).
#   warm = Deployment created with 1 replica and waited until Ready (cache filled), then scaled to N.
#   The ReplicaSet controller retries failed pod creations with backoff, so this shows what users would see.
#   After the last run of a design (warm, N=20, 20 pods running) the background-scan cost is measured: the policies are
#   annotated to trigger a re-scan (fallback: restart of the reports controller) and the time until all 20 pods have a fresh
#   report result, the reports controller CPU/memory and the number of signature verifications in its log are recorded.
# Output: r3/R3c-item5-l2-meta.csv  design,mode,N,first_ready_s,all_ready_s,ready_at_end,failedcreate_events,rev_sum_delta,rev_count_delta,denied_delta,dns,ratelimit,deadline,errs,restarts_before,restarts_after
#         r3/R3c-item5-l2-timeline.csv  runkey,seconds,ready,pods,failedcreate   (every 3 s)
#         r3/R3c-item5-l2-stats.csv     crictl stats rows (admission and reports controllers)
#         r3/R3c-item5-l2-failures.txt  sample FailedCreate messages per run
#         r3/R3c-item5-l2-bgscan.csv    design,trigger,pods,policies,seconds_to_all_fresh,complete,rep_cpu_max,rep_mem_max,verify_lines,dns,errs
source r3/tools/r3c-item5-lib.sh
META=r3/R3c-item5-l2-meta.csv; TL=r3/R3c-item5-l2-timeline.csv; STAT=r3/R3c-item5-l2-stats.csv; FAIL=r3/R3c-item5-l2-failures.txt; BG=r3/R3c-item5-l2-bgscan.csv
[ -f $META ] || echo "design,mode,N,first_ready_s,all_ready_s,ready_at_end,failedcreate_events,rev_sum_delta,rev_count_delta,denied_delta,dns,ratelimit,deadline,errs,restarts_before,restarts_after" > $META
[ -f $TL ]   || echo "runkey,seconds,ready,pods,failedcreate" > $TL
[ -f $BG ]   || echo "design,trigger,pods,policies,seconds_to_all_fresh,complete,rep_cpu_max,rep_mem_max,verify_lines,dns,errs" > $BG
cleanup(){ log "cleanup: restoring"; $K -n $NS delete deploy load-dep --ignore-not-found | cat; $K delete namespace $NS --wait=false | cat; r3/tools/swap-policy.sh policies/r3-ivp.yaml | tail -2; vpol_on; $K get ivpol,vpol | cat; }
trap cleanup EXIT
dep(){ sed "s/__N__/$1/" r3/tools/r3c-item5-deploy.yaml | $K -n $NS apply -f - | cat >/dev/null; }
clean_ns(){ $K -n $NS delete deploy load-dep --ignore-not-found --wait=false | cat >/dev/null
  for i in $(seq 1 60); do [ "$($K -n $NS get pods --no-headers 2>/dev/null | wc -l)" = 0 ] && break; sleep 3; done
  $K -n $NS delete events --all | cat >/dev/null; }
fc(){ $K -n $NS get events --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.count}{"\n"}{end}' | awk '{s+=$1} END{print s+0}'; }
wait_ready(){ # <N> <timeout-s> <runkey> <t0>  -> sets FIRST and ALL (empty if not reached)
  FIRST=""; ALL=""
  while :; do
    el=$(echo "$(date +%s.%N) - $4" | bc -l)
    r=$($K -n $NS get deploy load-dep -o jsonpath='{.status.readyReplicas}' | cat); r=${r:-0}
    p=$($K -n $NS get pods -l app=load-dep --no-headers 2>/dev/null | wc -l)
    printf '%s,%.1f,%s,%s,%s\n' $3 $el $r $p "$(fc)" >> $TL
    [ -z "$FIRST" ] && [ "$r" -ge 1 ] && FIRST=$(printf %.1f $el)
    [ "$r" -ge "$1" ] && { ALL=$(printf %.1f $el); READY=$r; return; }
    READY=$r
    (( $(echo "$el > $2" | bc -l) )) && return
    sleep 3
  done; }
bgscan(){ # <design> <N>   (pods running, policies of the design live)
  local pols; pols=$($K get ivpol -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); local np=$(echo $pols | wc -w)
  local trig=annotate st=$(date -u +%Y-%m-%dT%H:%M:%SZ) touch=$(date +%s)
  sampler_start $STAT "$1-bgscan" rep:$(cid reports-controller)
  for p in $pols; do $K annotate ivpol $p r3c-touch=$touch --overwrite | cat >/dev/null; done
  local s=$(date +%s) done=0
  fresh(){ $K -n $NS get policyreport -o json | cat | python3 -I -c '
import json,sys
touch=int(sys.argv[1]); pols=set(sys.argv[2:]); j=json.load(sys.stdin); ok=0
for it in j["items"]:
    got={r["policy"] for r in it["results"] if r.get("timestamp",{}).get("seconds",0)>=touch}
    if pols<=got: ok+=1
print(ok)' $touch $pols; }
  for i in $(seq 1 40); do n=$(fresh); [ "$n" -ge "$2" ] && { done=1; break; }; sleep 3; done
  if [ $done = 0 ]; then trig=restart; log "annotation did not trigger a full re-scan in 120 s ($n of $2 pods fresh); restarting the reports controller"
    $KN rollout restart deploy/kyverno-reports-controller | cat >/dev/null; $KN rollout status deploy/kyverno-reports-controller --timeout=300s | cat >/dev/null
    touch=$(date +%s); st=$(date -u +%Y-%m-%dT%H:%M:%SZ); s=$(date +%s)
    for i in $(seq 1 200); do n=$(fresh); [ "$n" -ge "$2" ] && { done=1; break; }; sleep 3; done; fi
  local el=$(( $(date +%s) - s )); sleep 4; sampler_stop
  local ll; ll=($(logcounts kyverno-reports-controller $st)); local v; v=$($KN logs deploy/kyverno-reports-controller --since-time=$st 2>&1 | grep -c "verifying cosign image signature")
  local mx; mx=$(awk -F, -v k="$1-bgscan" '$2==k {gsub(/MB/,"",$5); c=$4+0; m=$5+0; if(c>cm)cm=c; if(m>mm)mm=m} END{printf "%s,%s", cm, mm}' $STAT)
  echo "$1,$trig,$2,$np,$el,$done,$mx,$v,${ll[0]},${ll[3]}" >> $BG; tail -1 $BG; }
ns_up
designs=("$@"); [ ${#designs[@]} -eq 0 ] && designs=(B A)
for D in "${designs[@]}"; do
  log "== design $D"; r3/tools/swap-policy.sh $(files_for $D) | tail -3
  for MODE in ${MODES:-cold warm}; do for N in ${NLIST:-10 20}; do
    key="$D-$MODE-$N"; log "-- $key"; clean_ns; restart_ctl; waitio
    st=$(date -u +%Y-%m-%dT%H:%M:%SZ); r0=$(restarts admission-controller)
    sampler_start $STAT $key adm:$(cid admission-controller) rep:$(cid reports-controller)
    if [ $MODE = cold ]; then m0=($(msnap)); t0=$(date +%s.%N); dep $N
    else dep 1; wait_ready 1 300 "$key-prime" $(date +%s.%N); sleep 5; m0=($(msnap)); t0=$(date +%s.%N); dep $N; fi
    wait_ready $N 600 $key $t0
    sampler_stop; m1=($(msnap)); lc=($(logcounts kyverno-admission-controller $st)); r1=$(restarts admission-controller); f=$(fc)
    { echo "== $key (failedcreate events: $f)"; $K -n $NS get events --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.count}{"x "}{.message}{"\n"}{end}' | cut -c1-260 | sort | uniq -c | sort -rn | head -4; } >> $FAIL
    printf '%s,%s,%s,%s,%s,%s,%s,%.2f,%d,%d,%s,%s,%s,%s,%s,%s\n' $D $MODE $N "${FIRST:--}" "${ALL:--}" "$READY" "$f" \
      "$(echo "${m1[0]} - ${m0[0]}" | bc -l)" $(( ${m1[1]} - ${m0[1]} )) $(( ${m1[2]} - ${m0[2]} )) ${lc[0]} ${lc[1]} ${lc[2]} ${lc[3]} $r0 $r1 >> $META
    tail -1 $META
    if [ $MODE = warm ] && [ $N = 20 ] && [ -n "$ALL" ]; then log "-- background scan with 20 pods running ($D)"; bgscan $D 20; fi
  done; done
done
log "== L2 done"
