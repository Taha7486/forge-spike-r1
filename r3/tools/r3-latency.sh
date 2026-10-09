#!/bin/bash
# Usage (run from spike/forge-spike-r1):
#   r3/tools/r3-latency.sh <case-label> <pod-manifest> <valid-runs> <mode>
# Modes:
#   plain     time the server-side dry run, no controller restart
#   cold      restart the admission controller before each sample (empties the verify cache), then time one call
#   coldwarm  cold sample, then a repeat call right after (only if the cold one was admitted)
#   primewarm restart, one priming call (result not used; it fills the cache even if it times out),
#             pause 45 s, then the timed warm call. A TUF-init denial on the priming call invalidates the attempt.
# Every attempt is appended to $R3_OUT (default r3/R3c-raw.csv): case,attempt,phase,seconds,outcome,io_avg10_before,note
# Only "admitted" samples are valid. Denials (with cause from the controller log) and timeouts are logged and retried
# (max attempts = valid-runs + 10), never dropped silently.
# Waits for I/O pressure avg10 < 8 before each sample (the disk is a spinning HDD).
CASE=$1; MAN=$2; RUNS=$3; MODE=$4
OUT=${R3_OUT:-r3/R3c-raw.csv}
K="kubectl --context kind-forge-spike"
[ -f "$OUT" ] || echo "case,attempt,phase,seconds,outcome,io_avg10_before,note" > "$OUT"
io(){ awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io; }
waitio(){ for i in $(seq 1 100); do v=$(io); (( $(echo "$v < 8" | bc -l) )) && return 0; sleep 3; done; echo "io wait expired" >&2; return 1; }
LASTOC=
call(){ # <attempt> <phase>
  local v=$(io) s=$(date +%s.%N)
  local o=$($K --request-timeout=90s apply --dry-run=server -f "$MAN" 2>&1 | cat)
  local d=$(echo "$(date +%s.%N) - $s" | bc -l) oc=other
  if echo "$o" | grep -q "server dry run"; then oc=admitted
  elif echo "$o" | grep -q "denied the request"; then oc=denied
  elif echo "$o" | grep -qiE "timeout|deadline|timed out"; then oc=timeout; fi
  local note="$(echo "$o" | head -c 200 | tr '\n,"' '   ')"
  if [ $oc != admitted ]; then
    note="$note | LOG: $($K -n kyverno logs deploy/kyverno-admission-controller --since=2m 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep ERR | tail -1 | head -c 300 | tr ',"' '  ')"
  fi
  printf '%s,%s,%s,%.2f,%s,%s,"%s"\n' "$CASE" "$1" "$2" "$d" "$oc" "$v" "$note" >> "$OUT"
  LASTOC=$oc
}
restart(){
  $K -n kyverno rollout restart deploy/kyverno-admission-controller | cat >/dev/null
  $K -n kyverno rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null
  sleep 20
}
valid=0; att=0
while [ $valid -lt "$RUNS" ] && [ $att -lt $((RUNS+10)) ]; do
  att=$((att+1))
  case $MODE in
    plain)     waitio; call $att plain; sleep 1; [ $LASTOC = admitted ] && valid=$((valid+1)) ;;
    cold)      restart; waitio; call $att cold; [ $LASTOC = admitted ] && valid=$((valid+1)) ;;
    coldwarm)  restart; waitio; call $att cold
               if [ $LASTOC = admitted ]; then valid=$((valid+1)); call $att warm; fi ;;
    primewarm) restart; waitio; call $att prime
               [ $LASTOC = denied ] && continue
               sleep 45; waitio; call $att warm
               [ $LASTOC = admitted ] && valid=$((valid+1)) ;;
    *) echo "unknown mode $MODE" >&2; exit 2 ;;
  esac
done
echo "done $CASE valid=$valid attempts=$att"
