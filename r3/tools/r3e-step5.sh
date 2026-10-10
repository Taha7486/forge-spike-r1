#!/bin/bash
# R3e item 4: in-cluster TUF mirror (nginx serving a copy; policies r3e-mirror-* point at http://tuf-mirror.tuf-mirror.svc).
#  A public TUF blocked in CoreDNS + fresh controllers: still works through the mirror?
#  C mirror DOWN, controllers warm: still admits (incl. a never-seen image)?
#  B mirror DOWN, fresh controllers: denied? (the dependency moves to the mirror)
#  D mirror back: recovery.
source r3/tools/r3e-lib.sh; OUT=r3/R3e/step5-raw.csv; REK=tests/r1-t15-rekor-v2-ghcr.yaml
[ -f "$OUT" ] || echo "step,image,seconds,outcome,detail" > "$OUT"
rec(){ local r; r=$(probe $2); printf '%s,%s,%s,%s,"%s"\n' "$1" "$(basename $2 .yaml)" "$(echo "${r%%|*}" | cut -d' ' -f2)" "$(echo "${r%%|*}" | cut -d' ' -f1)" "${r#*|}" >> "$OUT"; log "$1 $(basename $2): ${r%%|*}"; }
cm_set(){ [ -s "$1" ] || { log "REFUSING to apply empty $1"; return 1; }
  $K -n kube-system patch cm coredns --type=merge -p "$(python3 -c "import json,sys;print(json.dumps({'data':{'Corefile':open(sys.argv[1]).read()}}))" "$1")" | cat
  $K -n kube-system rollout restart deploy/coredns | cat >/dev/null; $K -n kube-system rollout status deploy/coredns --timeout=200s | cat >/dev/null; sleep 10; }
mirror(){ $K -n tuf-mirror scale deploy/tuf-mirror --replicas=$1 | cat >/dev/null; sleep 8; }
fresh(){ $KN rollout restart deploy/kyverno-admission-controller | cat >/dev/null; ready; sleep 30; waitio; }
cause(){ $KN logs deploy/kyverno-admission-controller --since=${1:-2m} 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep ERR | tail -1 | grep -o 'failed to initialize TUF client[^"]*"[^"]*"[^:]*' | head -1 | cut -c1-200; }
trap 'log cleanup; mirror 1; cm_set r3/R3e/corefile.orig' EXIT
log "== A: public TUF blocked in DNS, controllers restarted (empty local state)"
cm_set r3/R3e/corefile.blocked-log; fresh
rec A-golden $GOLD; rec A-golden-again $GOLD; rec A-unsigned $UNS
echo "public TUF queries from kyverno (coredns log, 3 min):"; $K -n kube-system logs -l k8s-app=kube-dns --since=3m --tail=-1 2>&1 | cat | grep -c "tuf-repo-cdn.sigstore.dev. udp" 
log "== C: mirror DOWN, controllers warm"
mirror 0; rec C-golden $GOLD; rec C-NEWimage $REK; rec C-unsigned $UNS
log "== B: mirror DOWN, controllers restarted"
fresh; rec B-golden $GOLD; rec B-unsigned $UNS; echo "cause: $(cause 3m)"
log "== D: mirror back (controllers keep running; first the same pods)"
mirror 1; sleep 5; rec D-golden-same-pods $GOLD
fresh; rec D-golden-fresh-pods $GOLD
