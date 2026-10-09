#!/bin/bash
# Shared helpers for the R3c item 5 load tests. Source from spike/forge-spike-r1:  source r3/tools/r3c-item5-lib.sh
K="kubectl --context kind-forge-spike"; KN="$K -n kyverno"; NODE=forge-spike-control-plane; NS=r3c-load
log(){ echo "$(date -u +%H:%M:%S) $*"; }
strip(){ sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
io(){ awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io; }
waitio(){ for i in $(seq 1 100); do v=$(io); (( $(echo "$v < 8" | bc -l) )) && return 0; sleep 3; done; log "io wait expired"; }
ready(){ $KN rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null; }
restart_ctl(){ $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; ready; sleep 20; }
vpol_on(){ $K apply -f policies/r1-registry-allowlist.yaml -f policies/p3-deny-test-label.yaml | cat >/dev/null; sleep 10; }
files_for(){ case $1 in
  A) echo "policies/r3c-split-sig.yaml policies/r3c-split-sbom.yaml policies/r3c-split-vuln.yaml" ;;
  B) echo "policies/r3c-split-sig.yaml" ;; esac; }
cid(){ # container id of the (first) container of the pod with this component label
  local pod; pod=$($KN get pods -l app.kubernetes.io/component=$1 -o jsonpath='{.items[0].metadata.name}')
  docker exec $NODE crictl ps --label io.kubernetes.pod.name=$pod -q | head -1; }
restarts(){ $KN get pods -l app.kubernetes.io/component=$1 -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' | cat; }
# sampler_start <outfile> <runkey> <label:containerid>...   rows: epoch,runkey,label,cpu%,mem
sampler_start(){ local out=$1 key=$2; shift 2
  ( while true; do t=$(date +%s.%N); for li in "$@"; do l=${li%%:*}; i=${li#*:}
      v=$(docker exec $NODE crictl stats --id "$i" 2>/dev/null | strip | tail -1 | awk '{print $3","$4}'); echo "$t,$key,$l,$v" >> "$out"; done; sleep 2; done ) &
  SAMPLER_PID=$!; }
sampler_stop(){ kill $SAMPLER_PID 2>/dev/null; wait $SAMPLER_PID 2>/dev/null; }
# msnap: "<sum of validating review seconds> <count> <denied count>" from the admission controller's metrics (via the API server proxy)
msnap(){ $K get --raw "/api/v1/namespaces/kyverno/services/kyverno-svc-metrics:8000/proxy/metrics" | cat | awk '
  /^kyverno_admission_review_duration_seconds_sum/   && /request_webhook="ValidatingWebhookConfiguration"/ {s+=$NF}
  /^kyverno_admission_review_duration_seconds_count/ && /request_webhook="ValidatingWebhookConfiguration"/ {c+=$NF}
  /^kyverno_admission_requests_total/ && /request_allowed="false"/ && /ValidatingWebhookConfiguration/ {d+=$NF}
  END{printf "%.3f %d %d", s, c, d}'; }
# logcounts <deploy> <since-time>: "dns ratelimit deadline errs" lines in that controller's log since the time
logcounts(){ $KN logs deploy/$1 --since-time="$2" 2>&1 | strip | awk '
  /server misbehaving/ {d++} /429|toomanyrequests|rate limit|too many requests/ {r++} /context deadline|i\/o timeout|timed out/ {t++} / ERR / {e++}
  END{printf "%d %d %d %d", d, r, t, e}'; }
ns_up(){ $K get ns $NS >/dev/null 2>&1 || $K create namespace $NS | cat >/dev/null; }
