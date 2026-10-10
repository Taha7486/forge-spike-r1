#!/bin/bash
# R3e item 1: two admission replicas under failure. Run from spike/forge-spike-r1.  Usage: r3e-step3.sh <part>...   parts: single both crash-both node oom
# Two probe loops admit the UNSIGNED image back to back (admitted = gate OPEN; denied-by-policy = gate up; webhook-failure = gate down, closed by Fail).
source r3/tools/r3e-lib.sh; OUT=r3/R3e/step3-timeline.csv
[ -f "$OUT" ] || echo "label,utc_time,seconds,outcome,detail" > "$OUT"
restore(){ $KN scale deploy kyverno-admission-controller --replicas=2 | cat >/dev/null
  for n in forge-r3e-worker forge-r3e-worker2; do [ "$(docker inspect -f '{{.State.Running}}' $n)" = true ] || docker start $n | cat >/dev/null; done
  for i in $(seq 1 60); do [ "$($K get nodes --no-headers | grep -c ' Ready')" = 3 ] && break; sleep 5; done
  $K uncordon forge-r3e-worker forge-r3e-worker2 >/dev/null 2>&1
  ready; for i in $(seq 1 40); do [ "$(adm_pods | grep -c '1/1 *Running')" = 2 ] && break; sleep 5; done
  sleep 25; log "restored: $(adm_pods | awk '{printf "%s:%s:%s ",substr($1,length($1)-4),$3,$7}')"; }
pods(){ $KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
delete_leader(){ local l; l=$(leader); mark "deleting LEADER pod $l"; $KN delete pod "$l" --wait=false | cat >/dev/null; }
delete_other(){ local l o; l=$(leader); o=$(pods | grep -v "$l" | head -1); mark "deleting NON-leader pod $o (leader $l)"; $KN delete pod "$o" --wait=false | cat >/dev/null; }
roll(){ mark "rollout restart"; $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; }
delete_both(){ mark "deleting BOTH pods at once"; $KN delete pod -l app.kubernetes.io/component=admission-controller --wait=false | cat >/dev/null; }
crash_both(){ mark "killing BOTH containers (no graceful stop)"
  for pn in $($KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{range .items[*]}{.metadata.name}{"@"}{.spec.nodeName}{"\n"}{end}'); do n=${pn#*@}; p=${pn%@*}
    id=$(docker exec $n crictl ps --label io.kubernetes.pod.name=$p --name kyverno -q | head -1); docker exec $n crictl stop --timeout 0 $id >/dev/null & done; wait; }
VICTIM=
node_stop(){ VICTIM=$(docker exec forge-r3e-control-plane true 2>/dev/null; $KN get pod $(leader) -o jsonpath='{.spec.nodeName}'); mark "stopping node $VICTIM (hosts the LEADER)"; docker stop -t 0 $VICTIM | cat >/dev/null; }
oom_one(){ local l n id cg; l=$(leader); n=$($KN get pod $l -o jsonpath='{.spec.nodeName}')
  id=$(docker exec $n crictl ps --label io.kubernetes.pod.name=$l --name kyverno -q | head -1)
  mark "OOM: capping memory of the LEADER container $l on $n to 40M"
  docker exec $n sh -c "cg=\$(find /sys/fs/cgroup -type d -name '*$(echo $id | cut -c1-12)*' | head -1); echo \"cgroup \$cg\"; echo 41943040 > \$cg/memory.max; echo \"memory.max now \$(cat \$cg/memory.max)\""; }
for part in "$@"; do
  case $part in
    single) timeline "delete-leader" 100 delete_leader; restore; timeline "delete-other" 100 delete_other; restore; timeline "rollout-restart" 130 roll; restore ;;
    roll)   timeline "rollout-restart-fixed" 130 roll; restore ;;
    both)   timeline "delete-both-graceful" 120 delete_both; restore ;;
    crash-both) timeline "crash-both" 120 crash_both; restore ;;
    node)   timeline "node-stop" 200 node_stop; mark "starting node $VICTIM again"; docker start $VICTIM | cat >/dev/null; restore ;;
    oom)    timeline "oom-one" 120 oom_one; $KN get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{range .items[*]}{.metadata.name}{" lastState="}{.status.containerStatuses[0].lastState.terminated.reason}{" restarts="}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | cat; restore ;;
  esac
done
log "== step3 $* done"
