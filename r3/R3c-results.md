# R3c results (started 2026-10-08)

> **Short version first:** the decisions taken from this evidence are in `R3_Decisions.md` (Forge folder, one page, plain language). This file is the long technical appendix with the raw evidence; read it only to check a number.

R3c = failure modes, latency of the split design, observability and load for image verification at admission. Work list order: 1) cause of the transient TUF-init denials, 2) split-policy latency, 3) failure modes under Fail and Ignore, 4) denial observability, 5) load test, 6) write-up. Each item below has the finding first, then a plain explanation. Context: `R3-prestudy.md`, `R3b-results.md`.

---

## Item 1 — Cause of the transient "failed to initialize TUF client" denials (2026-10-08)

### Why this test
In R3b, about 23% of cold attempts (first admission after the admission controller restarts) were denied with "no valid signature" in 2 to 2.5 s. The controller log pointed at TUF initialisation, but the saved log text was cut at 300 characters, so the real error was unknown. The question: is it Sigstore, the network, Kyverno, or something else in this cluster, and does waiting after the pod is Ready avoid it?

### Method
- Script: `r3/tools/r3c-item1-tufinit.sh` (run from `spike/forge-spike-r1`). 40 rounds, one admission per round. Each round: restart the admission controller, wait for Ready, wait a delay (0, 5, 20 or 45 s, cycled, so 10 rounds per delay), wait for I/O avg10 below 8, then one dry-run admission of golden (`tests/r1-t2-golden-ghcr.yaml`) with an 8 s client timeout.
- Full policy `r3-verify-forge-images` live (not changed). A TUF-init failure shows up at about 2 s. A call still running at 8 s has passed TUF init and is logged as `past-init` (the server finishes the call alone; the next restart ends it).
- Output: `r3/R3c-item1-raw.csv` (one row per round, with the TUF error text), `r3/R3c-item1-logs/round-NN-dDD.log` (full, uncut controller log of each round), `r3/R3c-item1-run1.out` (console output), `r3/R3c-item1-dns/` (CoreDNS logs of both pods, saved after the run).
- I/O pressure (avg10) before the sample ranged from 5.2 to 8.0 in this run.

### Results
| Delay after Ready | TUF-init denials | past-init |
| --- | --- | --- |
| 0 s | 1 of 10 | 9 |
| 5 s | 1 of 10 | 9 |
| 20 s | 1 of 10 | 9 |
| 45 s | 2 of 10 | 8 |
| **Total** | **5 of 40 (12.5%)** | 35 |

All 5 denials have the same error in the controller log (full line in `R3c-item1-raw.csv`, column `tuf_error`):

> failed to initialize TUF client (mirror="https://tuf-repo-cdn.sigstore.dev"): updating local metadata and targets: error updating to TUF remote mirror: tuf: failed to download 13.root.json: Get "https://tuf-repo-cdn.sigstore.dev/13.root.json": dial tcp: **lookup tuf-repo-cdn.sigstore.dev on 10.96.0.10:53: server misbehaving**

`10.96.0.10` is the cluster DNS (CoreDNS). "server misbehaving" is Go's wording for a DNS answer of SERVFAIL (a server error), as opposed to "no such host".

CoreDNS log (both pods, whole life of the cluster since its last boot, `r3/R3c-item1-dns/`):

| Query (A record, without search suffix) | NOERROR | SERVFAIL |
| --- | --- | --- |
| `tuf-repo-cdn.sigstore.dev` | 40 | **12** |
| `ghcr.io` | 46 | 0 |
| `pkg-containers.githubusercontent.com` | 46 | 0 |

(The only other SERVFAILs in the logs are CoreDNS's own start-up probes, not relevant.) The SERVFAIL answers took 0.01 to 0.08 s, so the upstream resolver refused quickly; it did not time out.

### Findings
1. **The cause is a DNS failure for the TUF host inside the cluster, not TUF, Sigstore or Kyverno.** The TUF server was never contacted in the 5 denials. Kyverno asked cluster DNS for the address of `tuf-repo-cdn.sigstore.dev` and got SERVFAIL.
2. **It hits only the TUF name** in the data we have: 12 SERVFAIL out of 52 A lookups for that name, and 0 out of 92 for the two registry names. Why is not known yet (see "Not established").
3. **Waiting after Ready does not help** (1, 1, 1 and 2 denials at 0, 5, 20 and 45 s). A readiness delay is not a fix.
4. **The disk is not required for it.** One denial happened at I/O 5.27, the lowest of the run. I did not test whether I/O changes the rate; this run was not designed for it.
5. **Rate: 5 of 40 (12.5%)**, lower than R3b's roughly 23% of cold attempts. With 40 rounds the uncertainty is wide (roughly 4% to 27%), so the two rates are not clearly different. A different network moment or different day is also possible.
6. **The 12 SERVFAILs are not all explained by the 5 denials.** The pairs match: most denials show two SERVFAIL lines from the same pod IP a few milliseconds apart (the second answer comes back in about 0.1 to 0.3 ms with the `aa` flag, which looks like CoreDNS answering from its own cache, not asking upstream again; not confirmed). That gives about 5 pairs, but there are 2 single SERVFAILs left over. Possibly a SERVFAIL that did not lead to a denial; the logs have no timestamps, so I cannot match them. Open until the DNS test.
7. **Consequence for the misleading message.** The user sees "no valid signature from the forge-spike-r1 signing workflow". The real cause (a DNS failure on the first lookup) is only in the controller log. For the runbook: a denial at about 2 s that says "no valid signature" may be infrastructure, not an unsigned image; retry once and read the controller log.

### Not established
- Which DNS hop returns the SERVFAIL: CoreDNS's upstream is Docker's resolver (172.18.0.1), which forwards to the host's systemd-resolved (127.0.0.53), then to the home network. The DNS-only test (next) is meant to separate these.
- Why only the TUF name fails. A cold CoreDNS cache for that name (cache TTL 30 s) is an idea, not a result.
- Whether this happens on AKS. Cluster DNS and the upstream there are different, so the rate here is a property of this laptop's DNS path. What does carry over: a single failed DNS lookup during the first TUF init becomes a denial, because Kyverno 1.19.1 does not retry it.

### Plain-language explanation
- Before checking a signature, Kyverno has to download the Sigstore trust files from `tuf-repo-cdn.sigstore.dev`. To do that it first asks the cluster's address book (CoreDNS) "where is that server?".
- In 5 of 40 tests the address book answered "I have a problem" and not an address. Kyverno cannot continue without the trust files, so it refused the pod, with a message that talks about signatures. Nothing was wrong with the image or with Sigstore.
- Waiting longer after the controller starts changes nothing. The failure is random, not a start-up race.
- This is useful for the design: the hard-to-explain "random denials" are an infrastructure hiccup that can happen on any cluster whose DNS fails once at the wrong moment. Options to discuss later: a retry in the pipeline or runbook, an in-cluster TUF mirror (still needs DNS for the mirror, but a Kubernetes service name resolves inside the cluster without going upstream), or `failurePolicy: Ignore` (a trade-off in item 3).

### Files
`r3/tools/r3c-item1-tufinit.sh`, `r3/R3c-item1-raw.csv`, `r3/R3c-item1-logs/` (40 files), `r3/R3c-item1-run1.out`, `r3/R3c-item1-dns/`.

### Item 1b — DNS-only test: where does the SERVFAIL come from? (2026-10-08)

**Method.** `r3/tools/r3c-item1b-dns.sh 120 35`: 120 cycles, one every 35 s (about 70 min), no Kyverno involved. Each cycle asks the same question (A record of `tuf-repo-cdn.sigstore.dev`) at the same moment through four hops, plus `ghcr.io` on the cluster hop as a control. Cluster and node hops run from a throw-away container (`alpine` + `bind-tools`, shares the kind node's network; removed afterwards, the `alpine` image stays on the machine). Router and systemd-resolved are queried from the host. Raw data: `r3/R3c-item1b-dns.csv` (600 rows), console output `r3/R3c-item1b-run.out`.

The chain is: Kyverno pod → CoreDNS (10.96.0.10) → kind node resolver (172.18.0.1, Docker) → host systemd-resolved (127.0.0.53) → home router (192.168.11.1) → the ISP and beyond.

**Results (A record of the TUF host).**
| Hop | NOERROR | SERVFAIL | Typical time |
| --- | --- | --- | --- |
| router (192.168.11.1) | 104 | **16 (13%)** | median 11 ms, p90 84 ms |
| host systemd-resolved (127.0.0.53) | 105 | **15 (12.5%)** | median 3 ms |
| kind node (172.18.0.1) | 119 | 1 | median 0 ms (72% of answers took 0 ms) |
| cluster CoreDNS (10.96.0.10) | 119 | 1 | median 1 ms |
| cluster CoreDNS, `ghcr.io` (control) | 120 | 0 | |

- Failures are fast SERVFAILs (9 to 24 ms), never timeouts.
- 24 of 120 cycles had at least one failure on the router or resolved hop: both in 7 cycles, router only in 9, resolved only in 8.
- The TTL of the TUF record is 60 s.

**Findings.**
1. **The SERVFAIL starts at the router or beyond it** (the router's own upstream), not in CoreDNS, Docker or Kyverno. Querying the router directly gives SERVFAIL for the TUF name in about 13% of queries, `ghcr.io` never (control tested on the cluster hop only, so a direct router control is missing; see "Not established").
2. **It matches the Kyverno denial rate.** 13% of router queries fail, and 5 of 40 (12.5%) Kyverno cold rounds were denied. The rates are close; 40 rounds are too few to call them equal.
3. **systemd-resolved fails on its own queries, not only on the router's failures.** It failed 8 times in cycles when my direct router query succeeded. Its only configured server is the router, so these are separate queries that the router (or the network behind it) answered with SERVFAIL. The router does not fail in lockstep, it fails per query.
4. **The cluster and node hops look almost clean (1 failure each) only because of caching, not because they are immune.** The record lives 60 s and my probe asked every 35 s, so the Docker resolver answered 72% of the node queries from its own cache (0 ms) and never went upstream. In the one cycle where the upstream failed with a cold cache (cycle 80, 13:52:43), the node hop and the cluster hop both returned SERVFAIL too, so a failed upstream answer does travel the whole chain to Kyverno's pod. My probe therefore under-measures the failure rate at the cluster hop. A real Kyverno cold start, 1 to 3 minutes after the previous one, finds the cache expired and sees the router's raw failure rate. This reading fits both data sets but I did not run a probe with long gaps to prove it.
5. **Why only the TUF name failed in the CoreDNS logs of item 1** (12 of 52, versus 0 of 92 for the registry names): not explained. The control here (`ghcr.io`, 0 of 120) shows the same difference, but only on the cluster hop where the cache hides most upstream queries. Possible reasons: the router's upstream resolver handles that particular name badly (it sits behind Google's load balancer, the answer is a single address with TTL 60), or something name-specific at the ISP. Not tested.

**Not established.**
- A direct router control for `ghcr.io` and for another unrelated name (to show whether the router fails on all names or on this one only).
- A long-gap probe (for example every 90 s) to measure the failure rate at the cluster hop with a cold cache.
- Whether the same happens with another network (phone hotspot or a public resolver) as the host's upstream. Not planned unless you want it.

**Plain-language explanation.**
- Kyverno's question "where is the Sigstore server?" travels through several address books in a row: the cluster's, Docker's, the laptop's, the home router's. We asked the same question to each of them 120 times.
- The home router answered "I have a problem" in about 1 out of 8 asks for this one name. The laptop's own address book, which asks the router, did the same. The cluster's address book and Docker's seemed fine, but only because they remember answers for 60 seconds and our test asked often enough to keep their memory fresh. When their memory is empty, as at a Kyverno restart, the router's failure goes straight through to Kyverno.
- So the transient TUF denials in R3b and R3c are caused by this home network's DNS, not by anything in Kyverno, Sigstore or the cluster. The one lesson that carries over to AKS: Kyverno 1.19.1 has no retry for the very first lookup. One failed DNS answer during the first TUF initialisation turns into a denial, and the message says "no valid signature".

**What this means for the design (to discuss, nothing decided).**
- Do not read these denials as signature failures: a 2-second denial with "no valid signature" and a controller log naming `lookup ... server misbehaving` is a DNS failure. Runbook line, and a reason to see Audit/observability in item 4.
- A TUF mirror inside the cluster would be resolved by cluster DNS without leaving the cluster, so it would remove this failure for the TUF name, at the cost of the refresh job (prestudy step 8). Registry lookups (`ghcr.io`, ACR) depend on the same DNS but did not fail here.
- Under `failurePolicy: Ignore` a DNS failure during admission would let the pod through unverified; under `Fail` it is a transient denial. That is item 3.
- Measurements of "denial rate" and "cold-start latency" from this laptop include about a 12% chance of a DNS failure that does not belong to the design. Later latency items should use valid samples only, as `r3-latency.sh` already does (TUF-init denials are retried and logged).

**Files.** `r3/tools/r3c-item1b-dns.sh`, `r3/R3c-item1b-dns.csv`, `r3/R3c-item1b-run.out`.

---

## Item 2 — Latency of the candidate designs, cold and warm (2026-10-08)

### Why this test
R3b showed that the single full policy does not fit in the 30 s webhook cap when cold (0 of 30 finished) and takes 23.8 s warm. The pre-study explained why (three checks one after another, each about 10-11 s) and showed that policies with their own `timeoutSeconds` run in parallel. This item measures the candidate designs properly.

### Method
- Script: `r3/tools/r3c-item2-run.sh` (cases in the order c3, c1, c2, c4, extras), summary: `r3/tools/r3c-summary.py`. Run 14:56 to 17:14 UTC, machine otherwise idle, I/O avg10 below 8 before each sample (observed 5.2 to 8.0).
- Each case: `swap-policy.sh` (only that case's image policies live), then 20 valid cold+warm pairs with `r3-latency.sh coldwarm` on golden (5 bundles, `tests/r1-t2-golden-ghcr.yaml`). Cold = first call after a restart of the admission controller (empty verify cache). Warm = an immediate repeat call. Server-side dry run (`kubectl apply --dry-run=server`), not a real pod creation.
- Only **admitted** calls count as latency samples. Any other attempt (TUF-init denial, timeout) is logged with its outcome and retried; none was dropped.
- Policies: c1 = `r3c-split-sig`; c2 = sig + `r3c-split-sbom`; c3 = sig + sbom + `r3c-split-vuln` (design A); c4 = sig + `r3c-tripwire-vuln-warn` (the vuln policy with `validationActions: [Warn]`). All with `timeoutSeconds: 30`, `failurePolicy: Fail`, 720h freshness window.
- Extras on the c3 policies: `bigsbom` (3 bundles, 10 pairs) and `unsigned` (10 cold denial timings).
- Raw: `r3/R3c-item2-raw.csv`, `r3/R3c-item2-extras-raw.csv`, `r3/R3c-item2-run.out`, CoreDNS logs `r3/R3c-item2-dns/`.

### Results (seconds; n = valid samples)
| Case | Phase | n | min | p50 | p95 | max | Invalid attempts (TUF-init denials) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| c1 signature only | cold | 20 | 13.4 | 14.3 | 15.5 | 15.8 | 7 of 27 |
| | warm | 20 | 1.6 | 1.7 | 1.9 | 2.0 | |
| c2 signature + SBOM | cold | 20 | 13.4 | 14.0 | 16.5 | **28.9** | 2 of 22 |
| | warm | 20 | 11.6 | 12.7 | 13.9 | 17.1 | |
| **c3 split into three (design A)** | cold | 20 | 14.2 | 15.2 | 17.3 | 22.8 | 5 of 25 |
| | warm | 20 | 12.4 | 12.9 | 13.7 | 13.9 | |
| c4 sig Deny + vuln `Warn` | cold | 20 | 13.5 | 14.1 | 14.5 | 14.6 | 3 of 23 |
| | warm | 20 | 12.2 | 12.9 | 13.8 | 14.4 | |
| extra: c3 policies, bigsbom | cold | 10 | 12.3 | 13.1 | 14.5 | 15.0 | 2 of 12 |
| | warm | 10 | 10.4 | 10.8 | 11.2 | 11.3 | |

For reference, R3b on the same image: single full policy cold 0 of 30 finished inside 30 s, warm p50 23.8 s; signature-only cold p50 14.5 s. The summary script reproduces R3b's p50 values from `R3b-raw.csv`.

Unsigned image under the three policies (cold, 10 attempts, all denied): 9 genuine denials took **6.6 to 8.3 s (median 7.9 s)**. One (attempt 7) took 2.2 s and the controller log shows DNS errors: a DNS failure that also ended in a denial naming the vuln policy, indistinguishable from a real one without the log. The policy named in the denial varied: signature policy 3 times, SBOM 4, vuln 3.

### Findings
1. **The split fits.** Design A (c3): cold p50 15.2 s, warm p50 12.9 s. Every admitted sample is under 23 s. The single policy never finished inside the cap when cold. The three checks run in parallel (confirmed with three policies, 60 admitted pairs across c2 to c4).
2. **Cold costs about the same whatever you check.** Cold p50 is 14.3 (signature), 14.0 (sig + SBOM), 15.2 (three), 14.1 (tripwire). The cold wait is dominated by one verification (about 14 s), and the extra policies run beside it for about 1 s more. The signature-only design (B) does **not** make the cold admission faster than design A.
3. **Warm is where the designs differ.** Only the signature result is cached: signature alone warm 1.7 s; anything with an attestation check warm 12.7 to 12.9 s (attestation checks are re-done every time, pre-study step 5). Design B is about 11 s faster per repeat admission of the same image, and does one verification instead of three (about a third of the registry requests and CPU), not a faster first admission.
4. **`Warn` saves nothing.** c4 equals c3 (warm 12.9 s both). The Warn policy still does the check inside the webhook. Only taking a policy out of admission (background only) removes its cost; not tested here (item 4). Also not tested: that a warning reaches a client. Golden's scan is fresh, so the Warn policy had nothing to warn about.
5. **Tail risk is small but not zero.** One sample took 28.9 s (c2, attempt 4, I/O 7.58), 1.1 s from the cap, and it passed. The next highest are 22.8 s (c3, I/O 7.92) and 17.7 s or lower. So 2 of 90 admitted cold samples were above 20 s. I have no explanation for either. On this evidence a cold admission can occasionally approach 30 s even when split; a design with no margin (or a lower timeout) would not be safe. With n=20 per case the p95 is weak; read the max too.
6. **Fewer bundles are a bit faster.** bigsbom (3 bundles) against golden (5): cold p50 13.1 vs 15.2 s, warm 10.8 vs 12.9 s. About 2 s less with two fewer bundles. n=10, indicative.
7. **The denial of an unsigned image takes about 8 s, not 14 s** (no bundles to list means fewer registry requests). The policy named in the message varies from run to run, so the message may not say "signature". For the runbook: read the controller log, not just the message.
8. **DNS failures in this item.** 19 of 109 attempts (17%) were invalid, all with the TUF-init error. CoreDNS (both pods, whole life of the cluster so far) now holds 87 SERVFAIL answers for the TUF host, from 35 different client pods, and **none for any other name** (0 of 287 `ghcr.io` lookups). That is consistent with item 1. The per-denial text in the CSV is cut at 300 characters, so I cannot show "server misbehaving" for each of the 19; one unsigned-case denial does show it in the log. The number of SERVFAIL lines (about 75 for this item) is larger than the number of invalid attempts (20), because every policy (and every retry) does its own lookup, so there is no 1:1 mapping. The rate does not follow the number of live policies: 26% (1 policy), 9% and 13% (2), 20% and 17% (3); samples too small to see a trend. Pooled with item 1 (5 of 40): 24 of 149, about 16%.
9. **Slow denials only with several policies.** 5 of the 19 invalid attempts took 13.7 to 14.7 s (all in c2 and c3), the rest about 2 s. This fits the API server waiting for all webhooks before it answers, but 2 of the 5 c3 denials took only 2 s, so it is not settled.

### Not established
- The cause of the two high outliers (28.9 s, 22.8 s).
- Behaviour with more than one admission controller replica (the cache is per replica: more cold admissions) and under concurrent load (item 5).
- Whether a new image digest (never admitted before) behaves like "cold" even without a controller restart. The cache key contains the image, so it should; not tested.
- Design B and the background-only tripwire measured as designs (c1 gives B's admission cost; the background scan is item 4).
- p95 with n=20 is a rough estimate.
- Absolute numbers include this laptop's HDD, Moroccan home internet to GHCR (US/EU) and the kind node. On AKS with ACR in the same region the registry round trips shrink; treat the ratios (cold about 14 s for any design, warm 1.7 s versus 12.9 s, parallel not additive) as the transferable result.

### Plain-language explanation
- A check at admission is slow because Kyverno asks the registry about 36 small questions one by one, one after another, for each check. One check takes about 14 s when nothing is remembered.
- Our old single policy did three checks in a row (3 x 14 s = more than 30 s: the pod was refused for being too slow). Splitting into three policies makes the three checks run side by side, so the total is about 15 s, the time of one check. The test confirms it.
- If you keep only the signature check at admission, the first admission is not faster (still about 14 s), but a repeat of the same image is instant (1.7 s), because Kyverno remembers the signature. It does not remember the attestations, so with them each repeat costs about 13 s.
- Making the freshness policy "warn only" does not save time: Kyverno still does the whole check before answering.
- A rare slow case exists: 1 time in 90 a cold admission took 28.9 s, almost the whole 30 s allowance. We do not know why.
- Denying an unsigned image takes about 8 s, and the message may name any one of the three policies.
- About one cold attempt in six was refused by a DNS hiccup on this network (item 1), not by the image. Those were not counted as latency samples.

### What this means for the design (to discuss; nothing decided)
- A (three parallel policies) works within the cap on this machine, with margin 7 s for the normal tail but 1 s in the worst case seen.
- B (signature only at admission, attestations enforced in CI and re-checked by a job) gives the same cold time but a much cheaper warm path and a third of the load; whether that is worth the weaker admission guarantee is the design decision for the ADR.
- The attestations cannot be cached between admissions in Kyverno 1.19.1, as far as we can see, so any design that keeps them at admission pays about 13 s per admission of the same image.
- Each policy needs `timeoutSeconds` set (pre-study step 6), or it gets the 10 s webhook.

### Files
`r3/tools/r3c-item2-run.sh`, `r3/tools/r3c-summary.py`, `policies/r3c-tripwire-vuln-warn.yaml`, `r3/R3c-item2-raw.csv`, `r3/R3c-item2-extras-raw.csv`, `r3/R3c-item2-run.out`, `r3/R3c-item2-dns/`.

---

## Item 3 — Failure modes under failurePolicy Fail and Ignore, designs A and B (2026-10-08)

### Why this test
Admission-time verification depends on things that can break: the TUF host, the registry (and its blob CDN), and Kyverno itself. The question for the ADR: when one of them breaks, does a pod get refused (fail closed) or admitted (fail open), and does `failurePolicy: Ignore` change that? The open question from session 4 was whether `Ignore` changes the TUF/registry denials.

### Method
- Script `r3/tools/r3c-item3-run.sh` (run 17:35 to 18:21 UTC), summary `r3/tools/r3c-item3-summary.py`. Four sets: A-Fail, A-Ignore (three parallel policies), B-Fail, B-Ignore (signature policy only). Ignore sets use `policies/r3c-ign-*.yaml`, identical to the Fail policies except name and `failurePolicy`. Recorded setup: `r3/R3c-item3-setup.log` (all webhooks of the Ignore sets show `fp=Ignore timeout=30`).
- Per set, 7 scenarios, each with dry-run admissions of golden (should pass) and `unsigned` (should be denied): control; TUF host refused; `ghcr.io` refused; blob CDN refused; TUF host "slow"; `ghcr.io` "slow"; controller scaled to 0. 5 samples per image per scenario (3 for the slow ones). A-Ignore also ran "scaled to 0 with the two Fail-mode vpol policies live".
- Injection: `hostAliases` on the admission controller (host name mapped to 127.0.0.1 = connection refused; to 192.0.2.1 = "slow"). The two vpol policies were removed during the run (so they could not hide the result) and restored at the end. The cluster was verified restored: full policy Ready, vpols Ready, 1 replica, no `hostAliases`.
- 258 samples in `r3/R3c-item3-raw.csv` (set, scenario, image, outcome, time, webhook named, last controller error, client message).

### Results
| Scenario | Fail (A and B) | Ignore (A and B) |
| --- | --- | --- |
| control | golden admitted, unsigned denied | same (one golden denied by the DNS hiccup of item 1, log shows "server misbehaving") |
| TUF refused (connection refused) | all denied, 1.6 to 2.5 s | all denied, same times |
| `ghcr.io` refused | all denied, 0.3 to 0.5 s | all denied |
| blob CDN refused | all denied, 1.0 to 1.9 s | all denied |
| TUF / `ghcr.io` "slow" (24 samples per policy mode) | **0 admitted**, all denied, up to 14.9 s | **2 admitted** after 30.3 and 30.5 s: one golden (A) and **one unsigned image (B)**; the others denied |
| controller scaled to 0 | **all admitted, unsigned too** (A: 10 of 10, B: 10 of 10) | **all admitted, unsigned too** (A: 10 of 10, B: 10 of 10) |
| scaled to 0 with vpol policies (Fail) live | not run | all admitted (10 of 10) |

Total: the 120 samples where a host was refused (3 hosts x 2 images x 5 samples x 4 sets) were all denied. All 50 samples with the controller at 0 were admitted.

Scale-to-0 check (`r3/R3c-item3-scaled0/`): before scaling the cluster has 10 Kyverno webhook configurations; with the controller at 0 only 2 remain (the cleanup and TTL ones, which belong to another controller), `kyverno-svc` has no endpoints, and the resource and policy webhook configurations are gone. After scaling back to 1, the pod was Ready and the webhook configurations were recreated within 35 s.

Wording of the denials (from the client message):
| Cause | Message |
| --- | --- |
| TUF unreachable | `Policy <name> failed: no valid signature ...` (or `missing or unverified vulnerability attestation`, or `missing or invalid CycloneDX SBOM attestation`, depending on which policy answers first). Misleading. |
| `ghcr.io` or blob CDN unreachable | `Policy <name> error: failed to evaluate policy: Get https://ghcr.io/v2/: dial tcp ... connection refused`. Honest. |

### Findings
> **Update after item 3b (below):** the "slow" injection of this item was leaky (the pod got a route error after a variable time). With a real hang the result is deterministic: TUF hang = 12 of 12 admitted under `Ignore` and 12 of 12 refused under `Fail`; and the crash and two-replica cases are now tested. Read findings 2 and 3 together with 3b.

1. **`Ignore` does not change denials that come from a policy result.** When TUF, `ghcr.io` or the blob CDN is refused, Kyverno itself answers "deny" (the webhook works, the verification fails), so the webhook never fails and `failurePolicy` is never consulted. 120 of 120 refused-host samples were denied, under both modes and both designs. This answers the session 4 question.
2. **`Ignore` does let pods through when the webhook itself times out.** With the TUF host made unreachable by a route error ("no route to host"), the time Kyverno needed to give up varied from 0.3 s to over 30 s. Twice it reached 30 s and the pod was admitted: 30.5 s for golden (A-Ignore) and 30.3 s for an **unsigned image (B-Ignore)**. The time equals the webhook timeout, and the controller log only shows the TUF error, so my reading is that the API server gave up on the webhook and `Ignore` let the pod through. I did not see the timeout itself in any log. Under `Fail`, no sample reached the timeout (maximum 14.9 s, 24 samples), so "timeout under Fail = denial" is the expected Kubernetes behaviour but was not observed here.
3. **A scaled-down or stopped Kyverno fails open whatever `failurePolicy` says (single replica).** On a graceful stop Kyverno removes its resource and policy webhook configurations, so the API server has nothing to call and admits everything, unsigned images included, under Fail and Ignore alike, even with the Fail-mode vpol policies live. The pod needed 35 s to be back. Not tested: a crash or kill of the pod (the webhook configurations may then stay, and `Fail` would block pods, the opposite effect), and two or more replicas (the webhook would stay while one pod remains).
4. **Design A and B behave the same in every scenario.** Both fail closed on refused hosts, both fail open on timeouts under `Ignore` and when the controller is stopped. B had shorter slow-case times under Fail (maximum 3.7 s vs 14.9 s for A), but the "slow" injection varies so much that I do not read this as a real difference.
5. **Two kinds of message for the runbook.** "failed to evaluate policy ... dial tcp" names the broken registry or CDN. A TUF failure (refused or DNS) looks like a bad signature or missing attestation, and the policy named can be any of the three. A denial that arrives in about 2 s with a signature message is infrastructure until the controller log says otherwise.
6. **Each image policy creates a validating and a mutating webhook** (A: six webhooks, B: two), all with the policy's `failurePolicy` and a 30 s timeout. I did not see the mutating one double the wait: the longest admission under `Ignore` was 30.5 s, not 60 s. It was not tested separately.
7. **Naming:** the Fail webhooks are called `...svc-fail-finegrained-<policy>`, the Ignore ones `...svc-ignore-finegrained-<policy>`. Changing a policy's `failurePolicy` therefore replaces its webhooks.

### Not established / limits
- **No real hang was tested.** The "slow" scenarios ended with an error (`no route to host`) after a variable time; a connection that opens and then never answers could behave differently. The planned follow-up is a listener that accepts connections and stays silent.
- The crash path (item 3 finding 3) and two-replica behaviour are untested.
- Sample sizes are small (3 or 5 per cell); the two fail-open admissions under `Ignore` are 2 of 24 slow samples, which shows the path exists, not how often it happens.
- Dry-run admissions, one namespace, golden and unsigned images only.
- The optional Kyverno-namespace exclusion rehearsal was not done.
- The no-failure control of A-Ignore has one golden sample lost to the DNS hiccup of item 1 (kept in the data, cause confirmed in the log).

### Plain-language explanation
- We broke the things Kyverno relies on, one at a time, and asked: does the pod get refused or let in?
- If Sigstore's server or the registry is *refused* (a clear "no"), Kyverno notices, says "I cannot verify this", and refuses the pod. That happens whether the policy says "Fail" or "Ignore", because Kyverno is working and gives an answer.
- If something is *slow or silent*, Kyverno may not answer within 30 seconds. Then Kubernetes decides. With "Fail" it refuses; with "Ignore" it lets the pod in, even an unsigned one. We saw that happen twice.
- If Kyverno is switched off completely, it takes its own doorbells off the wall when it shuts down. Nobody asks Kyverno anything, so everything is let in, with "Fail" or "Ignore". With only one Kyverno pod, any restart is a short window where unsigned images could enter. More than one pod, or a second control, is needed to cover that.
- Messages: if the registry is down the message says so; if the Sigstore server is down the message wrongly talks about signatures.

### What this means for the design (to discuss; nothing decided)
- `failurePolicy: Fail` for the image policies: `Ignore` adds a fail-open path (timeouts) and buys nothing for refused hosts.
- The "Kyverno down" case is not controlled by `failurePolicy`. It needs replicas (two or more with a PodDisruptionBudget), a pipeline-level control (only signed images reach the registry), or a check for missing webhook configurations. Drift detection after an outage is the "background scan" idea.
- A and B are equal for these failure modes; the choice between them stays a latency and load question (item 2).

### Files
`r3/tools/r3c-item3-run.sh`, `r3/tools/r3c-item3-summary.py`, `policies/r3c-ign-{sig,sbom,vuln}.yaml`, `r3/R3c-item3-raw.csv`, `r3/R3c-item3-setup.log`, `r3/R3c-item3-run.out`, `r3/R3c-item3-scaled0/` (webhook lists before, at zero and after).

---

## Item 3b — Real hang, crash, and two replicas (2026-10-08)

### Why this test
Item 3 left three gaps: (1) the "slow" scenarios were not real hangs (the pod got `no route to host` after a variable time), (2) only a graceful scale-to-0 was tested, not a crash, and (3) only one replica. These decide whether `Fail` or `Ignore` is safe and what protects against Kyverno being down.

### Method
- Scripts: `r3/tools/r3c-item3b-hang.sh` (3b-1), `r3/tools/r3c-item3b-gate.sh crash|replicas` (3b-2, 3b-3), run in sequence by `r3/tools/r3c-item3b-all.sh`, 18:27 to 19:14 UTC. Each part restores the cluster on exit (verified: 1 replica, no `hostAliases`, no iptables rule, no test PDB, full policy and both vpols Ready). The vpol policies were removed during the tests so they could not hide the result.
- **3b-1 real hang:** the dependency host is mapped (`hostAliases`) to `192.0.2.1` and packets to that address are DROPped in the kind node's FORWARD chain, so connections open and never answer. Sets A-Fail, A-Ignore, B-Fail, B-Ignore; control (2 samples per image), TUF hang and `ghcr.io` hang (3 per image). Raw: `r3/R3c-item3b-hang-raw.csv` (64 samples).
- **3b-2 crash:** design B, once with `Fail` and once with `Ignore`, one replica. The controller container is killed with `crictl stop --timeout 0` (no graceful shutdown). Two probe loops admit the **unsigned** image back to back (it must always be denied; "admitted" = the gate is open) and a third loop records whether the resource webhook configuration exists. Raw: `r3/R3c-item3b-crash-timeline.csv`.
- **3b-3 replicas:** design B with `Fail`, 2 replicas and a PodDisruptionBudget (`minAvailable: 1`, created for the test; none existed before). Three events with the same probes: delete the leader pod, delete the other pod, `rollout restart`. Raw: `r3/R3c-item3b-replicas-timeline.csv`.

### Results
**3b-1 real hang** (golden and unsigned both; 3 samples per image per cell):
| Host that hangs | Fail (A and B) | Ignore (A and B) |
| --- | --- | --- |
| TUF (`tuf-repo-cdn.sigstore.dev`) | **12 of 12 refused** as a webhook failure at 30.3 to 30.5 s | **12 of 12 admitted** at 30.3 to 30.4 s, including all 6 unsigned |
| `ghcr.io` | 12 of 12 denied by a policy result in 5 to 11 s | 12 of 12 denied by a policy result in 5 to 11 s |
Controls were valid in all four sets (golden admitted, unsigned denied).

**3b-2 crash** (one replica, container killed without a graceful stop):
| Policy | Gate during the restart | Unsigned image |
| --- | --- | --- |
| Fail | closed: every probe refused as a webhook failure for about 9 s (19:00:26 to 19:00:35), container back in place in about 9 s | never admitted |
| Ignore | **open: every probe admitted** for about 19 s (83 admitted probes; kill at 19:03:16, first denial again at 19:03:35; the pod went `Error`, then `CrashLoopBackOff`, Ready at 19:03:38) | **admitted on every probe** |
In both runs the webhook configurations stayed present the whole time (unlike the graceful stop of item 3).

**3b-3 two replicas + PDB, Fail:**
| Event | Probes | Gate gaps |
| --- | --- | --- |
| delete leader pod | 51 of 51 denied by policy | none |
| delete non-leader pod | 48 of 48 denied by policy | none |
| rollout restart | 68 of 68 denied by policy | none |
Webhook configurations stayed present throughout; each replacement pod was Ready about 30 to 35 s after the event.

### Findings
1. **A silent TUF endpoint is a deterministic outcome of failurePolicy.** `Fail`: every admission in scope is refused after about 30 s. `Ignore`: every admission is admitted after about 30 s, **with no verification done**, unsigned images included. Item 3's "2 of 24" understated this because that injection was not a real hang.
2. **A silent registry (`ghcr.io`) does not reach the webhook timeout.** Kyverno gives up on it itself within 5 to 11 s and answers with a policy denial, so `Ignore` changes nothing there. Why those 5 and 11 s: not examined (probably timeouts inside the registry client).
3. **Cost of a silent TUF endpoint, apart from the security question:** every pod creation in scope waits 30 s whichever mode is set. Pods that are already running are not affected.
4. **A crash is fail-closed under `Fail` and fail-open under `Ignore`.** The webhook configurations survive a crash, so `failurePolicy` decides. Under `Fail` pod creation in scope is blocked for the length of the restart (about 9 s here); under `Ignore` unsigned images get through for the same time (about 19 s here). The two windows are not comparable: the second kill came within minutes of the first and hit a crash-loop backoff. So read both as "seconds to tens of seconds", not as a property of the mode.
5. **A graceful stop of the only replica is fail-open under both modes (item 3), and a crash is not.** The difference is that a graceful stop removes the webhook configurations.
6. **Two replicas with a PDB closed the gap in all three events tested** (delete leader, delete other, rollout restart): 167 of 167 probes denied, none admitted, no webhook failures. The webhook configurations stayed in place while one replica was always up. I did not establish why they stay with two replicas but disappear when the last one stops (my guess: only the last stopping replica removes them; not tested).
7. **`Fail` plus two or more replicas plus a PDB is the combination that fails closed in every case tested** except a silent TUF endpoint (30 s refusals) and the single-replica graceful stop (fail-open).

### Not established
- Both replicas down at once, a node failure, an out-of-memory kill (the memory limits of this cluster are raised from the chart defaults; the original 128 Mi thrashed on this machine).
- `Ignore` with two replicas (not needed for the argument).
- The cause of the 5 s and 11 s registry timeouts, and whether a TUF mirror inside the cluster removes the 30 s case (a Kubernetes service answers or refuses immediately).
- Small samples in 3b-1 (3 per image per cell, but the outcomes were uniform); one crash per mode.
- Dry-run admissions of one unsigned and one golden image, one node.

### Plain-language explanation
- A hung Sigstore server makes Kyverno wait until Kubernetes cuts the call after 30 seconds. Then Kubernetes follows the rule written on the policy: "Fail" refuses the pod, "Ignore" lets it in, signed or not. A hung registry is different: Kyverno gives up on its own after a few seconds and refuses the pod.
- If Kyverno's single pod crashes, its doorbell stays on the wall but nobody answers for about ten seconds. "Fail" refuses everything in that time; "Ignore" lets everything in.
- If Kyverno has two pods and one is deleted or replaced, the other one keeps answering and nothing changes for the pods being created.
- If Kyverno's only pod is stopped gracefully, it takes the doorbell down, and everything is let in whatever the rule says.

### What this means for the design (to discuss; nothing decided)
- Use `failurePolicy: Fail` on the image policies. `Ignore` is open exactly when Sigstore's TUF endpoint or Kyverno is unavailable, which is when verification matters, and it never helped for refused hosts.
- Run at least two admission controller replicas with a PodDisruptionBudget. This closes the restart and rollout gaps in the tests.
- Treat the TUF endpoint as an availability dependency of pod creation (30 s refusals when it hangs, 2 s refusals when it is refused or DNS fails): a TUF mirror inside the cluster (item 1 and prestudy step 8) is the candidate fix, together with the refresh job it needs.
- Keep a way to see the gate is missing: alert on fewer than two ready replicas or on the Kyverno webhook configurations being absent.
- Break-glass: with `Fail`, a broken Kyverno blocks all pod creation in scope; namespace exclusion (`kyverno`, `kube-system` are already excluded) and a documented rollback are ADR items. The optional namespace-exclusion rehearsal was not done.

### Files
`r3/tools/r3c-item3b-hang.sh`, `r3/tools/r3c-item3b-gate.sh`, `r3/tools/r3c-item3b-all.sh`, `r3/R3c-item3b-hang-raw.csv`, `r3/R3c-item3b-crash-timeline.csv`, `r3/R3c-item3b-replicas-timeline.csv`, `r3/R3c-item3b-run.out`.

---

## Item 4 — Denial observability: Deny, Warn, Audit and a background-only tripwire (2026-10-08)

### Why this test
Refusing an image is only half of the job: someone must be able to see it afterwards, and the tripwire idea (check scan freshness without slowing admission) has to be practical. Question: where does a refusal, a warning or an audit failure show up, how fast, and what does a background-only policy cost?

### Method
By hand, with real pod creations (dry-runs create no reports) in a test namespace `r3c-obs`, on design B (signature policy) plus a freshness policy with the scan window shortened to 1 hour so that golden's 2 October scan counts as stale. Raw outputs in `r3/R3c-item4/` (`4a-*`, `4b-*`, `4c-*`: client output, trail, metrics, reports JSON). Policies: `policies/r3c-obs-sig.yaml` (`[Audit]`), `r3c-obs-stale.yaml` (`[Warn, Audit]` plus an `auditAnnotations` entry), `r3c-obs-stale-bg.yaml` (`[Audit]` with `evaluation.admission.enabled: false`). Metrics read through a `port-forward` to the admission controller's metrics service. Afterwards the namespace was deleted and the full policy restored.

### Results
**4a — what a `Deny` leaves behind** (signature policy in `Deny`; unsigned image refused in 4.6 s, golden admitted in 13.7 s):
| Place | Refusal of the unsigned image |
| --- | --- |
| Client | `... denied the request: Policy r3c-split-sig failed: no valid signature ... for: <image>@sha256:...` (policy name, cause, image) |
| Kubernetes Events | nothing (the pod never exists) |
| Policy reports | nothing (no resource to attach a report to; no ephemeral report either) |
| Admission controller log (`--v=2`) | one `ERR ... image verification failed error="failed to verify cosign signatures: no signatures found"` line with the digest; no namespace, pod name or user |
| Prometheus (admission controller, port 8000) | `kyverno_admission_requests_total{request_allowed="false", resource_namespace="r3c-obs", ...} 1` and `kyverno_image_validating_policy_results_total{policy_name, policy_validation_mode="Deny", resource_namespace, result="fail"}`; no image or pod label |
The metrics also count dry-run requests (17 earlier failures in namespace `default` came from the item 3b probes). The admitted golden pod got a policy report only about 100 s later, from the **background scan**, which re-verified the signature against the registry and TUF.

**4b — `Warn` and `Audit`** (signature `[Audit]`, freshness `[Warn, Audit]` with a 1 h window; nothing is `Deny`, so every pod is admitted):
- **Client:** one `Warning:` line per failing `Warn` policy, with policy name and cause, e.g. `Warning: Policy r3c-obs-stale failed: stale vulnerability attestation (scanFinishedOn older than 1h) for: <image>`. An `Audit`-only policy shows nothing to the client.
- **Policy reports:** appear 4 to 48 s after the pod is created, one report per pod, owned by the pod. Each entry has `policy`, `rule`, `result`, `message`, `timestamp`, `source`, and `properties` (`process: background scan` plus the `auditAnnotations` key and value, here `r3c-stale-scan: stale or unverified scan for: <image>`). A `[Warn, Audit]` failure is recorded as `fail`, not `warn`.
- **Lifetime:** the report is deleted within 15 s of the pod's deletion. It is a picture of what exists now, not a history.
- **Metrics:** `kyverno_image_validating_policy_results_total{policy_name, policy_validation_mode="Audit", resource_namespace, result}` counts the admission-time results (here r3c-obs-sig: fail 4, pass 1; r3c-obs-stale: fail 5).
- **DNS hiccup (item 1) leaks into the records.** 2 of the 5 pod creations hit the TUF SERVFAIL. Effects: a false client warning (`missing or unverified vulnerability attestation` for a valid golden image), and for one pod a report that kept `r3c-obs-sig: fail no valid signature` for a correctly signed image because the background scan hit the same failure; another pod's wrong admission-time result was later corrected by a scan. Audit/Warn counters and report entries therefore contain false failures on this network.

**4c — background-only tripwire** (`evaluation.admission.enabled: false`, signature policy `Deny`):
- **No webhook is created** for it (zero webhooks with its name, neither validating nor mutating), so it adds nothing to admission. Pod admission stayed at 1.5 to 1.8 s (the signature result was already cached).
- **For a pod that already existed**, the freshness result appeared about 38 s after the policy was created: a policy change triggers a scan, no wait for the hourly interval.
- **For new pods** the result appeared about 66 to 68 s after creation (two samples).
- **Cost moves, it does not vanish:** the reports controller log shows `verifying cosign image signature` lines, i.e. every scan re-verifies signatures and attestations against registry and TUF. The background scan also re-evaluated the `Deny` signature policy (a `pass` entry), so any image policy with background evaluation left at its default (`true`) is re-verified by the scan too, including the live full policy.

**4d — metrics and flags.** The admission controller exposes `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds`, `kyverno_image_validating_policy_results_total` and `kyverno_image_validating_policy_execution_duration_seconds` (with `policy_name`, `policy_validation_mode`, `resource_namespace`, `result`). Flags in this install: `--maxAdmissionReports=1000` (admission controller), `--backgroundScan=true`, `--backgroundScanInterval=1h`, `--backgroundScanWorkers=2`, `--aggregateReports=true` (reports controller), `--omitEvents=PolicyApplied,PolicySkipped`.

### Findings
1. **A `Deny` leaves almost no server-side record.** The client sees a clear message; afterwards only one log line (digest and cause, no pod or namespace) and two label-poor counters remain. There is no Event and no report. If denials must be reviewable later, the controller log (at `--v=2`) and the counters must be shipped somewhere, or the pipeline (CI) must keep its own record.
2. **`Warn` is the only mode that reaches the person creating the pod**, with policy name and cause. `Audit` reaches the policy reports, within about a minute.
3. **Reports are current state, not history**, and they come from the background scan, not from the admission call. They disappear with the pod.
4. **`auditAnnotations` do land in the report** as `properties`, a place to put the image digest or a runbook hint.
5. **Audit and Warn are noisy on a network with DNS hiccups:** a false failure appears in the warning, the report and the counters. An alert needs persistence (for example "failing in two consecutive scans") to be usable.
6. **The background-only tripwire works and is free at admission time**, but its cost is registry and TUF traffic from the reports controller on every scan for every matching resource. Item 5 should measure that.
7. **Cost of defaults:** background evaluation is on by default for image policies. If the load matters, `evaluation.background.enabled: false` on the enforcement policies would avoid re-verification by the scan (not tested).

### Not established
- Kubernetes Events for audit-mode results (not checked in 4b).
- The API server audit log (the kind cluster has none, so `auditAnnotations` could not be seen there).
- The effect of `--maxAdmissionReports=1000` when exceeded, and whether metrics from the reports controller are better alert sources than the admission controller's (only the admission controller was scraped).
- The load of the background scan with many pods (item 5).
- Report timing from only two to five samples per case.

### Plain-language explanation
- When Kyverno refuses a pod, you see the reason on screen at that moment. Behind the scenes it keeps a tally (a counter) and one log line, nothing like a visitors' book. If you want a record of who was refused and why, you must collect those yourself.
- "Warn" shouts at the person creating the pod without blocking them. "Audit" writes a note in a report that stays only as long as the pod exists.
- The background-only check is like a night inspector: it does not slow the front door, and it reports about a minute later, but it walks through everything again and again, so it also uses the network.
- On this laptop the address-book hiccup (item 1) makes the inspector sometimes write a false note about a good image. An alert should wait for the same note twice.

### What this means for the design (to discuss; nothing decided)
- Keep refusals (`Deny`) for what must never run; add `Warn` to the policies where a human at a terminal should see the reason, and `Audit` or the background-only tripwire for the freshness check. This keeps the tripwire out of the 30 s budget.
- Plan the record-keeping explicitly: a log shipper for the admission controller's `ERR` lines and a metrics scrape of the counters; reports alone are not a history.
- Alert rules need persistence because of false failures from DNS and registry hiccups; a TUF mirror in the cluster lowers them.
- Decide in the ADR whether background evaluation stays on for the enforcement policies.

### Files
`policies/r3c-obs-sig.yaml`, `policies/r3c-obs-stale.yaml`, `policies/r3c-obs-stale-bg.yaml`, `r3/R3c-item4/` (13 files: client output, trail, metrics, reports JSON and the cleanup log).

---

## Item 5 — Load: simultaneous admissions, Deployment rollouts and the background scan (2026-10-08)

### Why this test
Items 2 to 4 measured one admission at a time. A cluster sees bursts: a Deployment with many replicas, several Deployments rolling at once, a restart of Kyverno followed by a rollout (empty cache). Question: do designs A (three policies) and B (signature policy only) survive the burst, what do users see, and what does the background scan cost?

### Method
Machine: single kind node on a 4-core laptop with an HDD, one admission controller replica (no CPU limit, memory limit 768 Mi), kept as quiet as possible (I/O below 8 before each cold start). One image, golden. Scripts: `r3/tools/r3c-item5-l1.sh`, `r3c-item5-l2.sh` (shared helpers `r3c-item5-lib.sh`, Deployment `r3c-item5-deploy.yaml`, summary `r3c-item5-summary.py`), run 19:36 to 20:39 UTC.
- **L1, simultaneous dry-run admissions:** N = 5, 10, 20 server-side dry-runs of golden fired at the same moment (distinct pod names). Cold = admission controller just restarted (empty verify cache). Warm = one priming admission first (retried until admitted). Every call is logged; nothing was dropped.
- **L2, Deployment of golden** with N = 10 and 20 replicas in a test namespace. Cold = Deployment created right after a controller restart. Warm = created with 1 replica, waited until Ready, then scaled to N. Measured: time until the first and until all replicas are Ready, `FailedCreate` events, and the pod count every 3 s.
- **Resources:** `crictl stats` of the admission and reports controllers every 2 s (CPU % where 100 % is one core, memory), restarts, log counters (DNS errors, rate-limit text, deadline text, `ERR` lines), and the admission review metrics.
- **Background scan:** after the last L2 run of each design (20 pods running) the policies were annotated to trigger a re-scan (fallback: restart of the reports controller after 120 s) and the time until all 20 pods had a fresh report result was measured.
- One invalid cell (B warm N=5: the priming call was denied by the DNS hiccup of item 1, so the burst ran cold) was moved to `r3/R3c-item5-l1-discarded.csv` and re-run with a retrying priming call.
- Raw: `r3/R3c-item5-l1-{raw,meta,stats,discarded}.csv`, `r3/R3c-item5-l2-{meta,timeline,stats,bgscan}.csv`, `r3/R3c-item5-l2-failures.txt`, `r3/R3c-item5-run.out`.

### Results
**L1 — N simultaneous dry-run admissions** (seconds; p50/max of the admitted calls; peaks of the admission controller):
| Design | Mode | N | Outcome | p50 | max | Wall | Peak CPU / memory |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B | cold | 5 | 5 admitted | 15.7 | 18.1 | 18.1 | 37 %, 81 MB |
| B | cold | 10 | 10 admitted | 18.2 | 23.5 | 23.5 | 38 %, 95 MB |
| B | cold | 20 | 15 admitted, **5 webhook timeouts** | 23.9 | 33.0 | 33.9 | 46 %, 108 MB |
| B | warm | 5 | 5 admitted | 2.0 | 2.2 | 2.2 | 54 %, 83 MB |
| B | warm | 10 | 10 admitted | 3.0 | 3.1 | 3.1 | 9 %, 70 MB |
| B | warm | 20 | 20 admitted | 4.8 | 5.1 | 5.1 | 0 %, 65 MB |
| A | cold | 5 | 5 admitted | 26.1 | 27.8 | 27.8 | 94 %, 108 MB |
| A | cold | 10 | 5 admitted, **5 webhook timeouts** | 24.9 | 30.1 | 32.2 | 80 %, 152 MB |
| A | cold | 20 | 6 admitted, **14 webhook timeouts** | 28.2 | 33.5 | 34.5 | 85 %, 192 MB |
| A | warm | 5 | 5 admitted | 18.3 | 20.8 | 20.8 | 85 %, 101 MB |
| A | warm | 10 | 8 admitted, **2 webhook timeouts** | 23.4 | 31.6 | 32.2 | 54 %, 135 MB |
| A | warm | 20 | 6 admitted, **14 webhook timeouts** | 21.0 | 26.9 | 34.3 | 54 %, 186 MB |
No restarts in any run. The log counters for DNS errors, rate-limit text, deadline text and `ERR` lines were 0 in every run, so the timeouts leave no trace in Kyverno's own log; they are seen only by the API server. Admitted calls took up to 33 s, longer than the 30 s webhook timeout, which I read as the mutating webhook (which runs first) adding time; not verified.

**L2 — Deployment of golden (real pods):**
| Design | Mode | Replicas | First Ready | All Ready | FailedCreate events | Peak CPU / memory |
| --- | --- | --- | --- | --- | --- | --- |
| B | cold | 10 | 22.1 s | 34.6 s | 0 | 24 %, 71 MB |
| B | cold | 20 | 25.4 s | 60.0 s | 0 | 26 %, 82 MB |
| B | warm | 10 | 1.8 s | 21.1 s | 0 | 24 %, 71 MB |
| B | warm | 20 | 2.0 s | 34.5 s | 0 | 28 %, 88 MB |
| A | cold | 10 | 85.0 s | 88.8 s | 0 | 41 %, 104 MB |
| A | cold | 20 | 142.6 s | 146.9 s | **1** (a webhook timeout, retried) | 158 %, 119 MB |
| A | warm | 10 | 13.6 s | 86.4 s | 0 | 63 %, 109 MB |
| A | warm | 20 | 12.0 s | 123.7 s | 0 | 53 %, 120 MB |
The pod count over time (`r3/R3c-item5-l2-timeline.csv`) shows that the pods of a Deployment are created gradually (for A cold with 10 replicas: the first pod object at about 31 s, 3 at 46 s, 7 at 66 s, 10 at 85 s), not all at once.

**Background scan, 20 pods running:**
| Design | Policies | Trigger | Time until all 20 pods had fresh results | Reports controller peak | Signature verifications in its log |
| --- | --- | --- | --- | --- | --- |
| B | 1 | annotation of the policy | 123 s | 63 % CPU, 226 MB | 22 |
| A | 3 | restart of the reports controller (the annotation had refreshed only 5 of 20 pods after 120 s, so the script restarted it) | 401 s | 38 % CPU, 232 MB | 22 |
No errors and no DNS lines in either scan.

### Findings
1. **Design B takes a burst of 10 simultaneous cold admissions and 20 warm ones without a failure; design A cannot.** B cold fails 5 of 20 at N=20. A cold fails 5 of 10 at N=10 and 14 of 20 at N=20, and even A warm fails 2 of 10 and 14 of 20. The reason is the work per admission: A does three verifications, and the attestation checks are redone every time (item 2).
2. **A real Deployment hides most of this, because it does not create all pods at once.** In 8 rollouts there was a single `FailedCreate` event (A cold, 20 replicas, a 30 s webhook timeout that the ReplicaSet controller retried). The cost shows up as a slow rollout instead: A needs 89 s (10 replicas) and 147 s (20) cold, 86 s and 124 s warm; B needs 35 s and 60 s cold, 21 s and 35 s warm. That is a rollout 2.4 to 3.5 times slower with A. (The gradual pod creation fits the way the ReplicaSet controller creates pods in growing batches; I did not isolate that mechanism.)
3. **Sources of simultaneous requests other than one ReplicaSet are not covered.** Several Deployments rolling together, Jobs or CronJobs, or many `kubectl apply` calls would look like L1. L1 shows A failing at 10 simultaneous requests and B at 20 cold.
4. **Kyverno itself is not short of memory.** Peak admission controller memory was 192 MB and the reports controller 232 MB, against a 768 Mi limit; no restarts. Peak CPU reached 158 % of one core for A (L2 cold 20) and stayed below 55 % for B in Deployments. I did not establish what limits throughput: Kyverno's own CPU, the 4-core node (shared with the API server, etcd and the kubelet), the HDD, or GHCR.
5. **No rate limit or DNS problem appeared in this item** (zero such lines), unlike items 1 to 3, even though many registry calls ran in parallel. GHCR was accessed anonymously and only for one image.
6. **The background scan verifies every pod on its own and scales with pods x policies.** B: about 6 s per pod (123 s for 20); A: about 20 s per pod (401 s for 20). The signature verifications are not shared between pods of the same image (22 for 20 pods). With the install's defaults (2 workers, hourly interval) a simple division gives about 600 pods per hour for B and about 180 for A before a scan no longer fits in its interval. This is arithmetic from one measurement, not a tested limit; it ignores contention with admission traffic.
7. **The signature result is cached, the attestations are not** (confirmed again): B warm admits 20 simultaneous requests in 5 s, A warm needs more than 30 s for them.

### Not established
- Whether two or more admission controller replicas share the load (the verify cache is per replica, so cold admissions may increase).
- Larger bursts (50 or more), several images, concurrent admission and scan, and mixed workloads.
- What limits throughput (CPU, disk, GHCR).
- GHCR rate limits with authenticated or multi-image traffic. ACR in Azure will behave differently (nearer, authenticated).
- Chart-default resource limits (this cluster has the memory limit raised and no CPU limit).
- The cause of the 33 s admitted calls.
- The scan time with the annotation trigger for A (the script restarted the reports controller first, so the 401 s figure includes that restart).

### Plain-language explanation
- Each pod admission asks the registry dozens of questions. Design B asks them once per image and then remembers the answer; design A asks the extra questions about the attached documents (SBOM and scan) again for every pod and never remembers them.
- When many pods arrive together, A's work piles up until Kubernetes' 30-second limit cuts some off. B has more headroom: it copes with 10 at once from a cold start and with 20 once it has seen the image.
- A real Deployment spreads its pods out, so you do not see errors, just waiting: about 1.5 to 2.5 minutes instead of 20 to 60 seconds for 10 to 20 pods.
- The nightly inspector (background scan) checks every pod again, one after another: about 6 seconds a pod with B and 20 with A. In a big cluster that adds up to more than an hour.
- Kyverno did not run out of memory and did not crash at any point.

### What this means for the design (to discuss; nothing decided)
- On this evidence B (signature at admission) is the design that holds up under a burst; A needs more capacity (admission replicas, CPU) or a faster path for the attestations to be safe at 10 simultaneous creations.
- Keeping SBOM and vulnerability checks out of the admission path (CI enforcement plus a background freshness check) matches this result, but the background check has its own cost that grows with the number of pods; set the interval, workers and scope deliberately, and consider turning background evaluation off on the enforcement policies.
- Two or more admission replicas are already needed for availability (item 3b); whether they also help with load is to be tested.

### Files
`r3/tools/r3c-item5-{lib.sh,l1.sh,l2.sh,all.sh,deploy.yaml,summary.py}`, `r3/R3c-item5-*` (data listed under Method).

---

## Item 6 — Conclusions of R3c and inputs for ADR-002 (2026-10-08)

Status: for the user to review. **Nothing in the "Proposals" section is decided**; ADR-002 is written only after the user has discussed it.

### 1. What the plan asked, and the answers in one line each
| Question | Answer (evidence) |
| --- | --- |
| Why do cold admissions sometimes fail with "no valid signature" after a controller restart? | DNS: the home router answers SERVFAIL for the TUF host in about 13% of queries; Kyverno 1.19.1 does not retry the first lookup, so it becomes a denial (item 1, 1b). |
| Can verification fit the 30 s cap? | One policy with all checks: no (never finished cold). Three parallel policies: yes, cold p50 15.2 s, worst 22.8 s; signature only: 14.3 s cold, 1.7 s warm (item 2). |
| Do `Fail` and `Ignore` differ? | Only for webhook failures, not for policy results. Refused TUF/registry/CDN: denied under both. Silent TUF host: `Fail` refuses all after 30 s, `Ignore` admits all after 30 s, unsigned included (items 3, 3b). |
| What if Kyverno is down? | Graceful stop of the only replica: everything admitted under both modes (webhooks are removed). Crash: `Fail` blocks pod creation for the restart (seconds), `Ignore` admits unsigned images for the same time. Two replicas plus a PodDisruptionBudget: no gap in delete and rollout tests (items 3, 3b). |
| Can a denial be seen afterwards? | A `Deny` leaves one log line and two label-poor counters; `Warn` reaches the client; `Audit` gives a report within about a minute that disappears with the pod; a background-only policy costs nothing at admission (item 4). |
| Does it survive load? | Design B: yes up to 10 simultaneous cold and 20 warm. Design A: no, it fails at 10 simultaneous creations; real Deployments only roll out slowly (item 5). |
| Which Sigstore hosts are needed at admission? | TUF host, the registry, the registry's blob CDN. Not Rekor, Fulcio, timestamp, CT log (R3a). |

### 2. Numbers across the items (this laptop: HDD, 4 cores, home internet; see section 6)
| Item | Result |
| --- | --- |
| R3b | baseline 0.30 s; signature only cold 14.5 s; full policy warm 23.8 s; full policy cold 0 of 30 inside 30 s |
| 2 | cold p50 (n=20): signature 14.3 s, sig+SBOM 14.0, three policies 15.2 (max 22.8), tripwire with `Warn` 14.1; warm p50: 1.7 s for signature only, 12.7 to 12.9 s whenever an attestation check is present; unsigned denied in about 8 s; one cold sample at 28.9 s |
| 1 | 5 of 40 cold rounds denied by DNS (12.5%); waiting 0, 5, 20 or 45 s after Ready makes no difference; router SERVFAIL 16 of 120 direct queries |
| 3, 3b | refused hosts: 120 of 120 denied under both modes; silent TUF host: `Fail` 12 of 12 refused at 30 s, `Ignore` 12 of 12 admitted at 30 s; silent `ghcr.io`: denied by policy in 5 to 11 s under both; scale to 0: 50 of 50 admitted; crash: `Fail` blocked about 9 s, `Ignore` admitted unsigned about 19 s; two replicas: 167 of 167 probes denied |
| 4 | reports 4 to 48 s after pod creation, gone within 15 s of deletion; background-only policy: no webhook, result about 38 s (existing pod) or about 66 s (new pod) |
| 5 | B cold 5 of 20 timeouts at N=20; A cold 5 of 10 and 14 of 20; Deployments: A rollout 86 to 147 s, B 21 to 60 s; scan 6 s per pod (B) and 20 s per pod (A) |

### 3. What is established, inferred, and unknown
**Established by test (on this setup):** the numbers above; that policies with their own `timeoutSeconds` run in parallel; that the signature result is cached per policy and the attestations are not; that `Ignore` is open exactly when the webhook times out or Kyverno is gone; that a graceful stop removes the webhooks and a crash does not; that two replicas close the restart gaps tested; that the TUF-init denials are DNS SERVFAILs.
**Inferred, not shown:** why the webhooks stay with two replicas but vanish with the last one; why ReplicaSets create pods gradually (read from the timeline); what limits throughput under load (CPU, disk or GHCR); the mutating webhook adding time; the 33 s admitted calls.
**Unknown / not tested:** an in-cluster TUF mirror (and whether Kyverno accepts an `http://` mirror); both replicas down, node failure, OOM kill; load with several admission replicas, bigger bursts and several images; registry rate limits with authenticated or Azure traffic; Kubernetes Events and the API server audit log for audit-mode results; behaviour when `--maxAdmissionReports` is exceeded; the optional namespace-exclusion rehearsal.

### 4. Proposals for ADR-002 (recommendation, evidence, confidence, what would change it)
| # | Decision | Proposal | Evidence | Confidence | What would change it |
| --- | --- | --- | --- | --- | --- |
| 1 | `failurePolicy` of the image policies | **`Fail`** | `Ignore` is open on a silent TUF host (12 of 12) and during a crash (unsigned admitted for the restart); it adds nothing for refused hosts (items 3, 3b) | High | A requirement that pod creation must never be blocked by Kyverno or Sigstore trouble (then `Ignore` plus a compensating control) |
| 2 | What stays at admission | **B: signature at admission.** SBOM and vulnerability attestations enforced in CI; freshness as a background `Audit` tripwire | cold time is about 14 s whatever is checked (item 2); B survives bursts, A does not (item 5); attestations are not cached, A warm is 12.7 s against 1.7 s | Medium: one image, one node, home network | Real traffic shapes (many simultaneous creations) and more admission capacity could make A viable; a decision that admission must check attestations |
| 3 | `timeoutSeconds` | **30 (the maximum), set explicitly on every image policy** | an unset value gives a 10 s webhook; one cold sample reached 28.9 s; bursts reach 33 s | High | A faster registry (ACR in region) would lower the times, not the need for headroom |
| 4 | Admission controller replicas and PDB | **At least 2 replicas and a PodDisruptionBudget (`minAvailable: 1`)**; alert on fewer than 2 ready replicas or on missing Kyverno webhook configurations | item 3b: a single replica fails open on a graceful stop and blocks or opens on a crash; two replicas had no gap | Medium: three events tested | Both replicas down, node failure, OOM kill, and whether two replicas also share the load |
| 5 | Resources | Set requests and limits explicitly in the Helm values (Phase 1). This cluster ran the admission controller with a raised 768 Mi limit (peak use 192 MB) and no CPU limit (peak 158% of one core under design A) | item 5; the chart default memory limit (128 Mi) thrashed on this machine (session 4) | Medium | Behaviour at the chart defaults on AKS |
| 6 | TUF dependency | **Treat TUF as an availability dependency of pod creation.** Decide on an in-cluster TUF mirror after one more test (does Kyverno accept it, what is the refresh job's cadence: `timestamp.json` expires in about a week, daily sync with its own alert). Until then: accept the transient DNS-type denial, document the retry, and keep the runbook wording below | items 1, 1b, 3b; `trustedRoot` does not remove TUF (pre-study step 8) | Medium (the mirror is untested) | The mirror test failing or being too costly to operate; DNS on AKS being more reliable |
| 7 | Cache time-to-live | Keep the default (1 h per policy per replica); do not rely on it for attestations | pre-study step 7, items 2, 5 | High | Evidence that attestations can be cached in a later Kyverno version |
| 8 | Background evaluation | Decide per policy: leave it on for the freshness tripwire; consider `evaluation.background.enabled: false` on the enforcement policies; set the scan interval and workers so the scan fits its interval (arithmetic from one measurement: about 600 pods per hour for B, about 180 for A at 2 workers) | items 4, 5 | Low to medium | A measurement with more pods, and contention with admission traffic |
| 9 | Observability | Ship the admission controller's `ERR` lines and scrape its counters (`kyverno_image_validating_policy_results_total`, `kyverno_admission_requests_total`); use `Warn` where a human should see the reason; alert on persistence, not on a single failure | item 4 (reports are not a history; DNS hiccups cause false failures) | Medium | The log and metrics stack chosen in Phase 1 |
| 10 | Namespace scope and break-glass | Keep the chart's exclusions (`kyverno`, `kube-system`); document recovery as deleting the Kyverno webhook configurations (Kyverno recreates them) and an expiring PolicyException for exceptions. **Not rehearsed** | item 3 setup; Kyverno docs | Low until rehearsed | The optional rehearsal (a few minutes) |
| 11 | Runbook wording | Entry for each message: "no valid signature" or "missing or unverified attestation" arriving in about 2 s = TUF or DNS failure, read the controller log; the same arriving after about 30 s = TUF hang; "error: failed to evaluate policy ... dial tcp" = the registry or its CDN; the policy named in the denial is whichever answered first | items 1, 3, 3b | High | |

**Draft answer to spec section 11, "What happens if Sigstore is unreachable at admission time?"**
Only the Sigstore TUF host is needed at admission (plus the registry and its blob CDN); Rekor, Fulcio, the timestamp authority and the CT log are not contacted. With `failurePolicy: Fail`, a pod whose image has not been verified yet is refused: in about 2 seconds when the TUF host is refused or its DNS lookup fails, in 30 seconds when it hangs. The message may read like a signature failure, so the runbook points at the controller log. Pods that are already running are not affected; images already verified and still in the cache (one hour per policy and per replica) are admitted without contacting TUF. With `Ignore`, the same hang would let every pod in unverified, which is why `Ignore` is not proposed. (To be confirmed in ADR-002 after the user's review; the cached-image sentence is inferred from the signature cache behaviour, not tested with TUF blocked after a warm-up.)

### 5. What I would still test, in order of value (each is optional; none blocks ADR-002 except possibly the first)
1. **In-cluster TUF mirror** (decision 6): does Kyverno accept it, and what does the refresh job look like. About 1 to 2 hours.
2. **Two admission replicas under the item 5 load**: do they share the work, and what does the cold cache across replicas cost. About 1 hour.
3. **Namespace-exclusion rehearsal and the recovery by deleting the webhook configurations** (decision 10). About 15 minutes.
4. **Both replicas down, OOM kill**, to complete decision 4. About 30 minutes.
5. **Cache behaviour with TUF blocked after a warm-up**, to confirm the last sentence of the draft answer. About 15 minutes.

### 6. How far these numbers travel
Measured on a home laptop (spinning disk, 4 cores, one kind node, one Kyverno replica, home internet to GHCR and Sigstore in the US and EU, one image, dry-run admissions). Absolute times will be different on AKS with an in-region ACR and authenticated pulls; round trips shrink, the cold cost of one verification should fall, and the DNS and rate-limit behaviour will change. What should transfer: the structure (three checks in parallel cost the slowest one, only the signature is cached, attestations are repeated per pod and per scan), the `failurePolicy` semantics (policy results are not affected, webhook failures are), the graceful-stop and crash behaviour of the webhooks, and the observability facts. The Phase 1 carry-forward from the plan stays: on the real cluster, re-run the DNS probe and the latency loop and check the egress allowlist against the dependency map, blob CDNs included.
