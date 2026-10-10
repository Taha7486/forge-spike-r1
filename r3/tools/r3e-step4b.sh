#!/bin/bash
# R3e item 6, part b: positive control for the TUF block + does a WARM controller need TUF at all?
# 1 admission replica. CoreDNS gets `log` and an NXDOMAIN template for tuf-repo-cdn.sigstore.dev. Steps:
#  1 warm pod (just restarted and verified golden on the OPEN network), block, verify the never-seen rekor-v2 image  -> needs TUF?
#  2 read CoreDNS log: did the warm controller still ask for the TUF host?
#  3 rollout restart (fresh pod, empty TUF cache) under the same block, verify golden and rekor-v2 -> must be denied if the block works
#  4 unblock, verify again.
source r3/tools/r3e-lib.sh; OUT=r3/R3e/step4b-raw.csv; REK=tests/r1-t15-rekor-v2-ghcr.yaml
[ -f "$OUT" ] || echo "step,image,seconds,outcome,detail" > "$OUT"
rec(){ local r; r=$(probe $2); printf '%s,%s,%s,%s,"%s"\n' "$1" "$(basename $2 .yaml)" "$(echo "${r%%|*}" | cut -d' ' -f2)" "$(echo "${r%%|*}" | cut -d' ' -f1)" "${r#*|}" >> "$OUT"; log "$1 $(basename $2): ${r%%|*}"; }
cm_set(){ [ -s "$1" ] || { log "REFUSING to apply empty $1"; return 1; }
  $K -n kube-system patch cm coredns --type=merge -p "$(python3 -c "import json,sys;print(json.dumps({'data':{'Corefile':open(sys.argv[1]).read()}}))" "$1")" | cat
  $K -n kube-system rollout restart deploy/coredns | cat >/dev/null; $K -n kube-system rollout status deploy/coredns --timeout=200s | cat >/dev/null; sleep 10; }
dnslog(){ $K -n kube-system logs -l k8s-app=kube-dns --since=${1:-120s} --tail=-1 2>&1 | cat | grep -i "tuf-repo" | awk '{print $1,$5,$6,$7,$8,$9,$10}' | sort | uniq -c | sort -rn | head -6; }
sed 's|^\(\s*\)ready|\1ready\n\1log\n\1template ANY ANY tuf-repo-cdn.sigstore.dev {\n\1  rcode NXDOMAIN\n\1}|' r3/R3e/corefile.orig > r3/R3e/corefile.blocked-log
grep -q "tuf-repo-cdn" r3/R3e/corefile.blocked-log || exit 1
trap 'log cleanup; cm_set r3/R3e/corefile.orig; $KN scale deploy kyverno-admission-controller --replicas=2 | cat >/dev/null' EXIT
$KN scale deploy kyverno-admission-controller --replicas=1 | cat >/dev/null; ready; $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; ready; sleep 30; waitio
rec 0-open-warmup-golden $GOLD
cm_set r3/R3e/corefile.blocked-log; log "blocked"
rec 1-warm-pod-blocked-golden $GOLD
rec 1-warm-pod-blocked-NEWimage $REK
echo "--- coredns log for the TUF host (warm pod, last 120 s)"; dnslog 120s | tee -a r3/R3e/step4b-dns.txt
$KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; ready; sleep 30; log "fresh pod"
rec 3-fresh-pod-blocked-golden $GOLD
rec 3-fresh-pod-blocked-NEWimage $REK
echo "--- coredns log for the TUF host (fresh pod, last 120 s)"; dnslog 120s | tee -a r3/R3e/step4b-dns.txt
$KN logs deploy/kyverno-admission-controller --since=3m 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "ERR|tuf|TUF" | tail -3 | cut -c1-300 | tee -a r3/R3e/step4b-dns.txt
cm_set r3/R3e/corefile.orig; log "unblocked"; waitio
rec 4-fresh-pod-unblocked-golden $GOLD
