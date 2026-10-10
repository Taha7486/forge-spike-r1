#!/bin/bash
# R3e item 3: load with 2 admission replicas (design A = three policies, public TUF). Repeat of R3c item 5 (1 replica).
# L1: N simultaneous server-side dry-runs of golden (distinct names) in namespace r3e-load; cold (both replicas restarted) and warm (6 priming calls first).
# L2: a Deployment of golden with N replicas (10, 20); cold and warm (1 replica first, then scale).
# Per replica: validating reviews handled (from each pod's metrics) and peak memory/CPU (crictl stats on its node, every 2 s).
# Output: r3/R3e/step6-l1-raw.csv, step6-l1-meta.csv, step6-l2-meta.csv, step6-l2-timeline.csv, step6-stats.csv
source r3/tools/r3e-lib.sh; NS=r3e-load
L1R=r3/R3e/step6-l1-raw.csv; L1M=r3/R3e/step6-l1-meta.csv; L2M=r3/R3e/step6-l2-meta.csv; TL=r3/R3e/step6-l2-timeline.csv; ST=r3/R3e/step6-stats.csv
[ -f $L1R ] || echo "mode,N,i,seconds,outcome,note" > $L1R
[ -f $L1M ] || echo "mode,N,wall_s,ok,timeouts,denied,reviews_podA,reviews_podB,peak_mem_A,peak_mem_B,peak_cpu_A,peak_cpu_B" > $L1M
[ -f $L2M ] || echo "mode,N,first_ready_s,all_ready_s,ready_at_end,failedcreate_events,reviews_podA,reviews_podB,peak_mem_A,peak_mem_B" > $L2M
[ -f $TL ] || echo "runkey,seconds,ready,pods,failedcreate" > $TL
strip(){ sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
podinfo(){ $KN get pods -l app.kubernetes.io/component=admission-controller --no-headers -o custom-columns=N:.metadata.name,NODE:.spec.nodeName | sort | cat; }
reviews(){ $K get --raw "/api/v1/namespaces/kyverno/pods/$1:8000/proxy/metrics" | cat | awk '/^kyverno_admission_review_duration_seconds_count/ && /request_webhook="ValidatingWebhookConfiguration"/ {c+=$NF} END{print c+0}'; }
cid(){ docker exec $2 crictl ps --label io.kubernetes.pod.name=$1 --name kyverno -q | head -1; }
sampler_start(){ # <key>   samples both admission containers every 2 s
  local key=$1; set -- $(podinfo | awk '{print $1","$2}'); local a=${1%,*} an=${1#*,} b=${2%,*} bn=${2#*,}; local ia=$(cid $a $an) ib=$(cid $b $bn)
  ( while true; do t=$(date +%s.%N)
      for x in "A $an $ia" "B $bn $ib"; do set -- $x; v=$(docker exec $2 crictl stats --id $3 2>/dev/null | strip | tail -1 | awk '{print $3","$4}'); echo "$t,$key,$1,$v" >> $ST; done; sleep 2; done ) &
  SP=$!; }
sampler_stop(){ kill $SP 2>/dev/null; wait $SP 2>/dev/null; }
peak(){ awk -F, -v k="$1" -v w="$2" '$2==k && $3==w {c=$4+0; m=$5; gsub(/MB|MiB/,"",m); m=m+0; if(c>cm)cm=c; if(m>mm)mm=m} END{printf "%s %s", mm+0, cm+0}' $ST; }
fresh(){ $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; ready; sleep 25; waitio; }
ns_up(){ $K get ns $NS >/dev/null 2>&1 || $K create namespace $NS | cat >/dev/null; }
cleanup(){ log "cleanup"; $K -n $NS delete deploy load-dep --ignore-not-found | cat >/dev/null; $K delete namespace $NS --wait=false | cat >/dev/null; }
trap cleanup EXIT
call(){ local s=$(date +%s.%N) o d oc=other
  o=$(sed "s/name: t2-golden-ghcr/name: l1-$2/" tests/r1-t2-golden-ghcr.yaml | $K -n $NS --request-timeout=150s apply --dry-run=server -f - 2>&1 | cat); d=$(echo "$(date +%s.%N) - $s" | bc -l)
  if echo "$o" | grep -q "server dry run"; then oc=admitted; elif echo "$o" | grep -q "denied the request"; then oc=denied; elif echo "$o" | grep -qE "failed calling webhook|deadline|timeout"; then oc=webhook-failure; fi
  printf '%s,%s,%s,%.2f,%s,"%s"\n' "$MODE" "$1" "$2" "$d" "$oc" "$(echo "$o" | tr '\n,"' '   ' | cut -c1-160)" >> $L1R; }
ns_up
log "== L1"
for MODE in cold warm; do for N in 5 10 20; do
  key="l1-$MODE-$N"; log "-- $key"; fresh
  if [ $MODE = warm ]; then for t in 1 2 3 4 5 6; do call $N 0; done; sleep 5; fi
  set -- $(podinfo | awk '{print $1}'); PA=$1; PB=$2; ra=$(reviews $PA); rb=$(reviews $PB); n0=$(wc -l < $L1R)
  sampler_start $key; t0=$(date +%s.%N)
  pids=(); for i in $(seq 1 $N); do call $N $i & pids+=($!); done; wait "${pids[@]}"; t1=$(date +%s.%N); sampler_stop
  ra1=$(reviews $PA); rb1=$(reviews $PB); rows=$(tail -n +$((n0+1)) $L1R)
  ok=$(echo "$rows" | grep -c ',admitted,'); to=$(echo "$rows" | grep -c ',webhook-failure,'); dn=$(echo "$rows" | grep -c ',denied,')
  printf '%s,%s,%.1f,%s,%s,%s,%s,%s,%s,%s\n' $MODE $N "$(echo "$t1 - $t0" | bc -l)" $ok $to $dn $((ra1-ra)) $((rb1-rb)) "$(peak $key A | tr ' ' ',')" "$(peak $key B | tr ' ' ',')" >> $L1M; tail -1 $L1M
done; done
log "== L2"
dep(){ sed "s/__N__/$1/" r3/tools/r3c-item5-deploy.yaml | $K -n $NS apply -f - | cat >/dev/null; }
clean_ns(){ $K -n $NS delete deploy load-dep --ignore-not-found --wait=false | cat >/dev/null
  for i in $(seq 1 60); do [ "$($K -n $NS get pods --no-headers 2>/dev/null | wc -l)" = 0 ] && break; sleep 3; done; $K -n $NS delete events --all | cat >/dev/null; }
fc(){ $K -n $NS get events --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.count}{"\n"}{end}' | awk '{s+=$1} END{print s+0}'; }
wait_ready(){ FIRST=""; ALL=""; READY=0
  while :; do el=$(echo "$(date +%s.%N) - $4" | bc -l); r=$($K -n $NS get deploy load-dep -o jsonpath='{.status.readyReplicas}' | cat); r=${r:-0}
    p=$($K -n $NS get pods -l app=load-dep --no-headers 2>/dev/null | wc -l); printf '%s,%.1f,%s,%s,%s\n' $3 $el $r $p "$(fc)" >> $TL
    [ -z "$FIRST" ] && [ "$r" -ge 1 ] && FIRST=$(printf %.1f $el); READY=$r
    [ "$r" -ge "$1" ] && { ALL=$(printf %.1f $el); return; }
    (( $(echo "$el > $2" | bc -l) )) && return; sleep 3; done; }
for MODE in cold warm; do for N in 10 20; do
  key="l2-$MODE-$N"; log "-- $key"; clean_ns; fresh
  set -- $(podinfo | awk '{print $1}'); PA=$1; PB=$2; ra=$(reviews $PA); rb=$(reviews $PB)
  sampler_start $key
  if [ $MODE = cold ]; then t0=$(date +%s.%N); dep $N; wait_ready $N 300 $key $t0
  else dep 1; wait_ready 1 200 $key-prime $(date +%s.%N); t0=$(date +%s.%N); dep $N; wait_ready $N 300 $key $t0; fi
  sampler_stop; ra1=$(reviews $PA); rb1=$(reviews $PB)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' $MODE $N "${FIRST:-na}" "${ALL:-na}" $READY "$(fc)" $((ra1-ra)) $((rb1-rb)) "$(peak $key A | cut -d' ' -f1)" "$(peak $key B | cut -d' ' -f1)" >> $L2M; tail -1 $L2M
done; done
log "== step6 done"
