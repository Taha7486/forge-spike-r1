#!/bin/bash
# R3c item 1b: where does the SERVFAIL for the TUF host come from? DNS-only, no Kyverno.
# Usage (run from spike/forge-spike-r1):  r3/tools/r3c-item1b-dns.sh <cycles> [interval-seconds]
# Every cycle (default 35 s, longer than CoreDNS's 30 s cache, so cluster-DNS queries are cold)
# the same question is asked at the same moment through several hops:
#   cluster   10.96.0.10     CoreDNS, what Kyverno uses            (from a probe container sharing the kind node's network)
#   node      172.18.0.1     the kind node's own resolver          (same probe container)
#   resolved  127.0.0.53     the host's systemd-resolved           (from the host)
#   router    192.168.11.1   the home router                      (from the host)
# Names: tuf-repo-cdn.sigstore.dev on all hops; ghcr.io on the cluster hop only (control).
# Output: r3/R3c-item1b-dns.csv  utc_time,cycle,hop,name,status,query_ms
# The probe container (r3-dnsprobe, alpine + bind-tools) is created if missing; remove it with
#   docker rm -f r3-dnsprobe
CYCLES=$1; INT=${2:-35}
OUT=r3/R3c-item1b-dns.csv
NODE=forge-spike-control-plane; PROBE=r3-dnsprobe
TUF=tuf-repo-cdn.sigstore.dev
[ -f "$OUT" ] || echo "utc_time,cycle,hop,name,status,query_ms" > "$OUT"
if ! docker exec $PROBE which dig >/dev/null 2>&1; then
  docker rm -f $PROBE >/dev/null 2>&1
  docker run -d --name $PROBE --network container:$NODE alpine sh -c 'apk add --no-cache bind-tools >/dev/null 2>&1; sleep infinity' >/dev/null
  for i in $(seq 1 60); do docker exec $PROBE which dig >/dev/null 2>&1 && break; sleep 2; done
fi
q(){ # <cycle> <hop> <server> <name> <where: host|node>
  local pre=""; [ "$5" = node ] && pre="docker exec $PROBE"
  local o; o=$($pre dig +tries=1 +time=5 +noall +comments +stats @"$3" A "$4" 2>&1)
  local st; st=$(echo "$o" | grep -o 'status: [A-Z]*' | head -1 | cut -d' ' -f2); [ -z "$st" ] && st=$(echo "$o" | grep -qi 'timed out' && echo TIMEOUT || echo ERROR)
  local ms; ms=$(echo "$o" | grep -o 'Query time: [0-9]*' | grep -o '[0-9]*$'); echo "$(date -u +%H:%M:%S),$1,$2,$4,$st,${ms:--}" >> "$OUT"
}
for c in $(seq 1 "$CYCLES"); do
  s=$(date +%s)
  q $c cluster  10.96.0.10   $TUF node &
  q $c cluster  10.96.0.10   ghcr.io node &
  q $c node     172.18.0.1   $TUF node &
  q $c resolved 127.0.0.53   $TUF host &
  q $c router   192.168.11.1 $TUF host &
  wait
  d=$(( INT - ($(date +%s) - s) )); [ $d -gt 0 ] && sleep $d
done
echo "done $CYCLES cycles"
