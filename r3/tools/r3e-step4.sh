#!/bin/bash
# R3e item 6: verification cache with TUF blocked after a warm-up. Run from spike/forge-spike-r1.
# 1 admission replica (the cache is per replica). TUF is blocked in CoreDNS (NXDOMAIN for tuf-repo-cdn.sigstore.dev) so the controller is NOT restarted
# (a restart would empty the cache). Phase A: three policies. Phase B: signature policy only. rekor-v2 = a second image never verified before = control.
source r3/tools/r3e-lib.sh; OUT=r3/R3e/step4-raw.csv; REK=tests/r1-t15-rekor-v2-ghcr.yaml
[ -f "$OUT" ] || echo "phase,step,image,seconds,outcome,detail" > "$OUT"
rec(){ local r; r=$(probe $2); printf '%s,%s,%s,%s,%s,"%s"\n' "$PHASE" "$1" "$(basename $2 .yaml)" "$(echo "${r%%|*}" | cut -d' ' -f2)" "$(echo "${r%%|*}" | cut -d' ' -f1)" "${r#*|}" >> "$OUT"; log "$PHASE $1 $(basename $2): ${r%%|*}"; }
tuf_log(){ $KN logs deploy/kyverno-admission-controller --since=${1:-60s} 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE "tuf|lookup|no such host" | tail -2 | cut -c1-260; }
cm_set(){ # <file>: replace the CoreDNS Corefile from a non-empty file (kubectl is a snap: output must be piped, never redirected directly)
  [ -s "$1" ] || { log "REFUSING to apply empty $1"; return 1; }
  $K -n kube-system patch cm coredns --type=merge -p "$(python3 -c "import json,sys;print(json.dumps({'data':{'Corefile':open(sys.argv[1]).read()}}))" "$1")" | cat
  $K -n kube-system rollout restart deploy/coredns | cat >/dev/null; $K -n kube-system rollout status deploy/coredns --timeout=200s | cat >/dev/null; sleep 10; }
block(){ $K -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | cat > r3/R3e/corefile.current
  cmp -s r3/R3e/corefile.current r3/R3e/corefile.orig || { log "current Corefile differs from the saved original; stop"; return 1; }
  sed 's|^\(\s*\)ready|\1ready\n\1template ANY ANY tuf-repo-cdn.sigstore.dev {\n\1  rcode NXDOMAIN\n\1}|' r3/R3e/corefile.orig > r3/R3e/corefile.blocked
  grep -q "tuf-repo-cdn" r3/R3e/corefile.blocked || { log "block template missing"; return 1; }
  cm_set r3/R3e/corefile.blocked; }
unblock(){ cm_set r3/R3e/corefile.orig; }
trap 'log cleanup; unblock; $KN scale deploy kyverno-admission-controller --replicas=2 | cat >/dev/null; $K apply -f policies/r3c-split-sig.yaml -f policies/r3c-split-sbom.yaml -f policies/r3c-split-vuln.yaml | cat >/dev/null' EXIT
$KN scale deploy kyverno-admission-controller --replicas=1 | cat >/dev/null; ready
for PHASE in A B; do
  if [ $PHASE = B ]; then $K delete ivpol r3c-split-sbom r3c-split-vuln | cat; sleep 15; fi
  $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; ready; sleep 30; waitio
  rec warm-cold $GOLD; rec warm-again $GOLD
  block; log "TUF blocked in CoreDNS"; rec blocked-check-new-image $REK; tuf_log 90s | tee -a r3/R3e/step4-logs.txt
  rec blocked-golden $GOLD; rec blocked-golden-2 $GOLD; tuf_log 90s | tee -a r3/R3e/step4-logs.txt
  unblock; log "TUF unblocked"; waitio; rec unblocked-golden $GOLD
done
