#!/bin/bash
# R3c item 2: latency of the candidate designs, cold and warm. Run from spike/forge-spike-r1.
# Usage: r3/tools/r3c-item2-run.sh <case...>      cases: c3 c1 c2 c4 extras   (default order: c3 c1 c2 c4 extras)
#   c1  signature only                                   policies/r3c-split-sig.yaml
#   c2  signature + SBOM                                 r3c-split-sig + r3c-split-sbom
#   c3  split into three (design A)                      r3c-split-sig + r3c-split-sbom + r3c-split-vuln
#   c4  tripwire: signature Deny + vuln freshness Warn   r3c-split-sig + r3c-tripwire-vuln-warn
#   extras  on the c3 policies: bigsbom (10 cold+warm) and unsigned (10 denial timings), separate file
# Each case: swap-policy.sh, then r3-latency.sh <case> tests/r1-t2-golden-ghcr.yaml 20 coldwarm.
# coldwarm = restart the controller, one cold call, and (only if admitted) an immediate repeat = warm.
# Invalid attempts (TUF-init DNS denials, timeouts) are logged with their cause and retried, never counted.
# Output: r3/R3c-item2-raw.csv (cases) and r3/R3c-item2-extras-raw.csv. Progress lines go to stdout.
GOLD=tests/r1-t2-golden-ghcr.yaml; BIG=tests/r1-t14-bigsbom-ghcr.yaml; UNS=tests/r1-t3-unsigned-ghcr.yaml
P=policies; T=r3/tools
export R3_OUT=r3/R3c-item2-raw.csv
run(){ echo "== $(date -u +%H:%M:%S) $1: swap $2"; $T/swap-policy.sh $2 | tail -4; shift 2
       echo "== $(date -u +%H:%M:%S) $1 start"; $T/r3-latency.sh "$@"; }
cases=("$@"); [ ${#cases[@]} -eq 0 ] && cases=(c3 c1 c2 c4 extras)
for c in "${cases[@]}"; do
  case $c in
    c1) run c1-sig        "$P/r3c-split-sig.yaml" c1-sig $GOLD 20 coldwarm ;;
    c2) run c2-sig-sbom   "$P/r3c-split-sig.yaml $P/r3c-split-sbom.yaml" c2-sig-sbom $GOLD 20 coldwarm ;;
    c3) run c3-split3     "$P/r3c-split-sig.yaml $P/r3c-split-sbom.yaml $P/r3c-split-vuln.yaml" c3-split3 $GOLD 20 coldwarm ;;
    c4) run c4-tripwire   "$P/r3c-split-sig.yaml $P/r3c-tripwire-vuln-warn.yaml" c4-tripwire $GOLD 20 coldwarm ;;
    extras)
      export R3_OUT=r3/R3c-item2-extras-raw.csv
      run x-bigsbom "$P/r3c-split-sig.yaml $P/r3c-split-sbom.yaml $P/r3c-split-vuln.yaml" x-split3-bigsbom $BIG 10 coldwarm
      # unsigned is denied by design: time the denial. cold only; r3-latency counts only "admitted", so use a simple loop.
      echo "== $(date -u +%H:%M:%S) x-unsigned denial timings"
      for i in $(seq 1 10); do
        kubectl --context kind-forge-spike -n kyverno rollout restart deploy/kyverno-admission-controller | cat >/dev/null
        kubectl --context kind-forge-spike -n kyverno rollout status deploy/kyverno-admission-controller --timeout=400s | cat >/dev/null
        sleep 20
        for w in $(seq 1 100); do v=$(awk -F'[= ]' '/^some/{print $3}' /proc/pressure/io); (( $(echo "$v < 8" | bc -l) )) && break; sleep 3; done
        s=$(date +%s.%N); o=$(kubectl --context kind-forge-spike --request-timeout=90s apply --dry-run=server -f $UNS 2>&1 | cat)
        d=$(echo "$(date +%s.%N) - $s" | bc -l)
        l=$(kubectl --context kind-forge-spike -n kyverno logs deploy/kyverno-admission-controller --since=2m 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -c "server misbehaving")
        printf 'x-split3-unsigned,%s,cold,%.2f,%s,%s,"dns_errors_in_log=%s | %s"\n' "$i" "$d" "$(echo "$o" | grep -q 'denied the request' && echo denied || echo other)" "$v" "$l" "$(echo "$o" | head -c 160 | tr '\n,"' '   ')" >> $R3_OUT
      done
      export R3_OUT=r3/R3c-item2-raw.csv ;;
    *) echo "unknown case $c" >&2 ;;
  esac
done
echo "== $(date -u +%H:%M:%S) restoring full policy"; $T/swap-policy.sh "$P/r3-ivp.yaml" | tail -3
echo "ALL DONE"
