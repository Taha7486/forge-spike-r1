#!/bin/bash
# R3c item 1: capture the full error of the transient TUF-init denial after a controller restart.
# Usage (run from spike/forge-spike-r1):
#   r3/tools/r3c-item1-tufinit.sh <rounds> <manifest> [delays...]
# Default delays (seconds after the new pod is Ready): 0 5 20 45, cycled one per round.
# Each round: restart the admission controller, wait for Ready, wait <delay>, then ONE dry-run admission
# with an 8 s client timeout. We only care whether TUF init fails (it fails at about 2 s), so a call
# still running after 8 s has passed TUF init ("past-init"); the server finishes it alone.
# Outputs:
#   r3/R3c-item1-raw.csv      one row per round: round,delay,outcome,seconds,io_before,tuf_error
#   r3/R3c-item1-logs/        one full (uncut) controller log per round: round-NN-dDD.log
# Outcomes: tuf-denied | other-denied | admitted | past-init | other
ROUNDS=$1; MAN=$2; shift 2
DELAYS=("$@"); [ ${#DELAYS[@]} -eq 0 ] && DELAYS=(0 5 20 45)
K="kubectl --context kind-forge-spike"
OUT=r3/R3c-item1-raw.csv; LOGS=r3/R3c-item1-logs
mkdir -p "$LOGS"
[ -f "$OUT" ] || echo "round,delay,outcome,seconds,io_avg10_before,tuf_error" > "$OUT"
io(){ awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io; }
waitio(){ for i in $(seq 1 100); do v=$(io); (( $(echo "$v < 8" | bc -l) )) && return 0; sleep 3; done; echo "io wait expired" >&2; return 1; }
strip(){ sed 's/\x1b\[[0-9;]*m//g'; }
start=$(grep -c . "$OUT"); start=$((start))   # continue numbering after existing rows
for n in $(seq 1 "$ROUNDS"); do
  r=$((start + n - 1)); d=${DELAYS[$(( (n - 1) % ${#DELAYS[@]} ))]}
  $K -n kyverno rollout restart deploy/kyverno-admission-controller | cat >/dev/null
  $K -n kyverno rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null
  sleep "$d"
  waitio; v=$(io)
  s=$(date +%s.%N)
  o=$($K --request-timeout=8s apply --dry-run=server -f "$MAN" 2>&1 | cat)
  e=$(echo "$(date +%s.%N) - $s" | bc -l)
  # full, uncut controller log of the new pod (all levels) for this round
  f=$(printf '%s/round-%02d-d%02d.log' "$LOGS" "$r" "$d")
  { echo "# round $r delay ${d}s io=$v client-output:"; echo "$o"; echo "# controller log:";
    $K -n kyverno logs deploy/kyverno-admission-controller 2>&1 | strip; } > "$f"
  oc=other
  if echo "$o" | grep -q "server dry run"; then oc=admitted
  elif echo "$o" | grep -q "denied the request"; then
    if strip < "$f" | grep -q "failed to initialize TUF client"; then oc=tuf-denied; else oc=other-denied; fi
  elif echo "$o" | grep -qiE "timeout|deadline|timed out"; then oc=past-init; fi
  te=$(strip < "$f" | grep "failed to initialize TUF client" | head -1 | sed 's/.*failed to initialize TUF client//' | tr ',"' '  ' | head -c 600)
  printf '%s,%s,%s,%.2f,%s,"%s"\n' "$r" "$d" "$oc" "$e" "$v" "$te" >> "$OUT"
  echo "round $r delay ${d}s: $oc ($(printf %.1f "$e") s, io $v)"
done
