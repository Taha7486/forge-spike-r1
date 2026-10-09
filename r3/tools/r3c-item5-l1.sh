#!/bin/bash
# R3c item 5, L1: controlled concurrency. N simultaneous server-side dry-run admissions of golden (distinct pod names).
# Run from spike/forge-spike-r1.   Usage: r3/tools/r3c-item5-l1.sh [design...]   designs: B A (default both, B first)
#   cold = admission controller restarted just before the burst (empty verify cache);  warm = one priming admission first.
#   N in 5, 10, 20.  Every call is logged (nothing is discarded).
# Output: r3/R3c-item5-l1-raw.csv   design,mode,N,i,seconds,outcome,note
#         r3/R3c-item5-l1-meta.csv  design,mode,N,wall_s,rev_sum_delta,rev_count_delta,denied_delta,dns,ratelimit,deadline,errs,restarts_before,restarts_after
#         r3/R3c-item5-l1-stats.csv epoch,runkey,label,cpu%,mem   (crictl stats every 2 s: admission and reports controllers)
source r3/tools/r3c-item5-lib.sh
RAW=r3/R3c-item5-l1-raw.csv; META=r3/R3c-item5-l1-meta.csv; STAT=r3/R3c-item5-l1-stats.csv
[ -f $RAW ]  || echo "design,mode,N,i,seconds,outcome,note" > $RAW
[ -f $META ] || echo "design,mode,N,wall_s,rev_sum_delta,rev_count_delta,denied_delta,dns,ratelimit,deadline,errs,restarts_before,restarts_after" > $META
cleanup(){ log "cleanup: restoring"; $K delete namespace $NS --wait=false | cat; r3/tools/swap-policy.sh policies/r3-ivp.yaml | tail -2; vpol_on; $K get ivpol,vpol | cat; }
trap cleanup EXIT
call(){ # <design> <mode> <N> <i>
  local s=$(date +%s.%N)
  local o; o=$(sed "s/name: t2-golden-ghcr/name: l1-$4/" tests/r1-t2-golden-ghcr.yaml | $K -n $NS --request-timeout=150s apply --dry-run=server -f - 2>&1 | cat)
  local d; d=$(echo "$(date +%s.%N) - $s" | bc -l) oc=other
  if echo "$o" | grep -q "server dry run"; then oc=admitted
  elif echo "$o" | grep -q "denied the request"; then oc=denied
  elif echo "$o" | grep -qE "failed calling webhook|deadline|timeout"; then oc=webhook-failure; fi
  printf '%s,%s,%s,%s,%.2f,%s,"%s"\n' "$1" "$2" "$3" "$4" "$d" "$oc" "$(echo "$o" | tr '\n,"' '   ' | cut -c1-200)" >> $RAW; }
ns_up
designs=("$@"); [ ${#designs[@]} -eq 0 ] && designs=(B A)
for D in "${designs[@]}"; do
  log "== design $D"; r3/tools/swap-policy.sh $(files_for $D) | tail -3
  for MODE in ${MODES:-cold warm}; do for N in ${NLIST:-5 10 20}; do
    key="$D-$MODE-$N"; log "-- $key"
    restart_ctl; waitio
    if [ $MODE = warm ]; then for t in 1 2 3; do call $D prime $N 0; [ "$(tail -1 $RAW | cut -d, -f6)" = admitted ] && break; sleep 3; done; sleep 5; fi
    st=$(date -u +%Y-%m-%dT%H:%M:%SZ); m0=($(msnap)); r0=$(restarts admission-controller)
    sampler_start $STAT $key adm:$(cid admission-controller) rep:$(cid reports-controller)
    t0=$(date +%s.%N)
    pids=(); for i in $(seq 1 $N); do call $D $MODE $N $i & pids+=($!); done; wait "${pids[@]}"
    t1=$(date +%s.%N); sampler_stop
    m1=($(msnap)); lc=($(logcounts kyverno-admission-controller $st)); r1=$(restarts admission-controller)
    printf '%s,%s,%s,%.1f,%.2f,%d,%d,%s,%s,%s,%s,%s,%s\n' $D $MODE $N "$(echo "$t1 - $t0" | bc -l)" \
      "$(echo "${m1[0]} - ${m0[0]}" | bc -l)" $(( ${m1[1]} - ${m0[1]} )) $(( ${m1[2]} - ${m0[2]} )) ${lc[0]} ${lc[1]} ${lc[2]} ${lc[3]} $r0 $r1 >> $META
    tail -1 $META
  done; done
done
log "== L1 done"
