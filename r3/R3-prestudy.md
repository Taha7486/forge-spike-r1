# R3 pre-study — what to know before R3c (started 2026-10-08)

Goal: understand where the 14.5 s / 24 s / more-than-30 s of R3b goes, so R3c tests only fixes the evidence supports. Kyverno is v1.19.1 (chart 3.9.1). Each step below has the finding first, then a plain explanation.

Steps: 1 source reading · 2 version and field check · 3 cosign by hand · 4 network timing · 5 verbose log of one cold admission · 6 webhook configs · 7 cache experiment · 8 trusted root file · 9 test tooling.

---

## Step 1 — Read Kyverno's source (done)

Files read at tag v1.19.1: `pkg/image/verifiers/ivpol/cosign/verifier.go`, `.../cosign/opts.go`, `pkg/cel/libs/imageverify/impl.go` and `lib.go`, `pkg/image/verification/cache/client.go`. Method: fetched from GitHub through a summarising tool, so quotes are paraphrased by that tool; re-check any line before putting it in an ADR.

### Findings

1. **Every single verification repeats the whole trust setup.** Each call to the signature check or to an attestation check goes through `buildCheckOptsWithBundleDetection`, which calls `checkOptions`, which (for keyless) initialises a TUF client, downloads or refreshes `trusted_root.json`, and gets the Rekor keys, CT log keys and Fulcio roots, all from TUF. No cache or once-only guard exists in that code (the TUF library may keep a local disk copy; unconfirmed). Then it lists the image's bundles from the registry (`cosign.GetBundles`). So our full policy does that setup three times per admission (signature, SBOM, vulnerability), one after the other.
2. **The checks run one after another.** Loops over attestors are plain `for` loops, with no goroutines. Inside one policy, the three verifications are sequential. This explains why the times add up.
3. **`trustedRoot` does NOT remove the TUF dependency in this version.** The inline `trustedRoot` replaces only the "trusted material" object. The Rekor keys, CT log keys and Fulcio roots still come from TUF, and `trusted_root.json` is still fetched even when an inline one is given. So my earlier suggestion ("`trustedRoot` removes the TUF fetch") was wrong for v1.19.1. What the code does offer: `cosign.tuf.mirror` and `cosign.tuf.root` (a root file or base64 data), so TUF can point at a mirror we host ourselves (for example inside the cluster). Whether the mirror can be a local or in-cluster address is still to test. The only path with no Sigstore network work at all is key or certificate attestors with `insecureIgnoreTlog`, which is not keyless and not our design.
4. **The cache is per policy.** The key is `policy UID ; policy resourceVersion ; rule name ; image reference`. Three different policies never share cache entries, even with identical checks. Editing a policy changes its key, so old entries are no longer used. TTL 1 h, max size 1000 (defaults). Only a fully successful check is cached; a partial success is not.
5. **The signature result and each attestation result are cached separately.** The rule name is built from the function name, the attestation name and the attestors. For attestations the cache stores the verified payload, but the code only restores it when the policy later reads it with `extractPayload`. This fits R3b: warm admission skips the signature work but still takes about 24 s. The source does not show why attestations stay slow on a cache hit; to find out, see step 5 (logs).
6. **Failed TUF init becomes a denial.** In `checkOptions` the TUF failure is wrapped as `failed to initialize TUF client (mirror="...")`, the error we saw in R3b. `VerifyImageSignature` logs it as "image verification failed" and the policy then sees zero valid signatures, which produces the "no valid signature" message. That is the misleading wording.
7. **No timing logs in the code.** Only `V(2)`/`V(4)`/`V(6)` messages, no durations. To get step timings we need higher verbosity and timestamps (step 5) or external timing (steps 3 and 4). `context.TODO()` is used in the CEL functions, so no per-call timeout exists inside; the only limit is the webhook's own 30 s.

### Plain-language explanation

- Think of each check as a visitor going through airport security. In Kyverno 1.19.1, every check re-does the "set up the security desk" work (get the trusted keys from Sigstore) before looking at the passport. Three checks mean setting up the desk three times in a row.
- Splitting into three policies puts them side by side instead of one after the other, but each one still sets up its own desk, and none shares the "already checked" notebook (the cache), because the cache belongs to one policy.
- `trustedRoot` was supposed to give Kyverno the trusted keys directly, so it needs no download. In this version Kyverno still downloads the other keys, so it saves almost nothing.

### What this changes for R3c
- Split-policy test: still worth doing, but expect the setup cost to repeat in each policy (more load, same wait). The time to beat is the slowest single policy.
- `trustedRoot`: drop as a fix for the 30 s problem. Replace it by a **TUF mirror** test only if step 4 shows the TUF round trips dominate.
- New question for step 5: is TUF fetched over the network on every verification, or served from a local copy? That decides whether a mirror helps.
- Step 7 (cache experiment): the source already says caches are not shared across policies, so that experiment becomes a one-minute confirmation, not a research question.

---

## Step 2 — Version and field check on the live cluster (done 2026-10-08)

Method: `kubectl explain imagevalidatingpolicy...` and the admission controller's Deployment spec on the running cluster.

### Findings
1. Admission controller image `reg.kyverno.io/kyverno/kyverno:v1.19.1`; CRD serves `policies.kyverno.io` v1, v1alpha1, v1beta1.
2. **`validationActions` supports `Deny`, `Warn` and `Audit`** (CRD text). `Warn` goes to the client as an HTTP warning (code 299); `Audit` goes into policy reports; `Deny` and `Warn` cannot be combined. So the "freshness tripwire" policy can use `Warn` (visible to the person applying, not blocking) or `Audit` (recorded in reports). The Kyverno docs page did not say this; the CRD does.
3. **`trustedRoot` exists, but at `cosign.trustedRoot`** (fields `expression`, `value`), not under `cosign.keyless` as the docs page implied. Combined with step 1: it replaces only the trusted-material object and TUF is still contacted.
4. **`cosign.tuf` has `mirror` and `root` (`path` or base64 `data`).** This is the knob for pointing TUF at our own mirror.
5. `webhookConfiguration` has only `timeoutSeconds`. `spec.matchConditions` exists (CEL conditions) and would also put a policy on its own webhook.
6. **`validationConfigurations` defaults are all true**: `mutateDigest`, `verifyDigest`, `required`. Our policies use the defaults. `mutateDigest` rewrites a tag to a digest at admission, which costs a registry lookup for tag-based images; our test pods use digests so R3b did not pay for it. Real workloads that use tags would. To decide in the ADR.
7. `evaluation` has `admission.enabled`, `background.enabled`, `mode`; unset on our policy. If background evaluation is on by default, the background controller may also verify images periodically (load on the same node). Not confirmed; check in step 5/6 logs.
8. The admission controller already runs with `--v=2` and `--disableMetrics=false --metricsPort=8000` (Prometheus metrics available without a change). No `imageVerifyCache*` flag is set, so defaults apply (on, 1000 entries, 60 min; the source confirms ttl 1 h and size 1000).
9. Other flags worth noting: `--apiCallTimeout=30s`, `--registryCredentialHelpers=default,google,amazon,azure,github`.

### Plain-language explanation
- The cluster's rulebook (the CRD) is the source of truth, and it differs slightly from the web docs. We checked the rulebook directly, so the tests will not fail on a field that does not exist.
- "Warn" mode is the right fit for a soft alarm: it tells the person but does not block.
- Kyverno already exposes measurements (metrics) on port 8000 and logs at level 2. We do not need to install anything to look inside, only raise the log level for one test.

---

## Step 3 — Time `cosign` by hand, outside Kyverno (done 2026-10-08)

Method: cosign v3.1.3 on the host (not inside the kind node; same internet path, so numbers are comparable but not identical), same identity and issuer as the policy, golden digest `f5eb8b57...`. `TUF_ROOT` pointed at a scratch folder. I/O pressure 5-6% during the runs. Wall-clock with `date`. Raw traces were kept in the scratchpad only (not in the repo): `cosign verify -d` for the request list, `strace -e connect` for connection times.

### Timings (golden)

| Command | Time |
| --- | --- |
| `cosign verify` (signature), empty TUF cache | 8.17 s |
| `cosign verify`, warm TUF cache, 3 runs | 7.54 / 6.98 / 7.80 s |
| `cosign verify-attestation --type cyclonedx` (SBOM), 3 runs | 6.96 / 6.76 / 7.01 s |
| `cosign verify-attestation --type vuln` (scan), 3 runs | 6.60 / 7.19 / 7.15 s |

### Same signature check on the three images (one run each)

| Image | Bundles | HTTP requests | Time |
| --- | --- | --- | --- |
| golden | 5 | 36 | 7.20 s |
| bigsbom | 3 | 24 | 6.95 s |
| rekor-v2 | 3 | 24 | 5.97 s |

### Findings
1. **Each single check takes about 7 s by itself, even with a warm TUF cache.** An empty TUF cache adds only about 0.6 s. Three checks in a row therefore cost about 21 s. Kyverno's warm admission in R3b was 23.8 s, and cold above 30 s. The numbers agree: the R3b latency is mostly "three checks, one after another, each about 7 s", plus a larger setup cost after a restart.
2. **The 7 s is mostly registry round trips.** One `cosign verify` of golden made 36 HTTP requests to GHCR, one after another: 1 ping, 1 token, 2 referrers lookups (both answer 404 on GHCR, so it falls back to a tag lookup), 12 manifest reads and 20 blob reads (each blob read is a GHCR request that answers with a redirect, then a second request to `pkg-containers.githubusercontent.com`). Each request takes about 0.1-0.5 s from here. 36 requests at about 0.22 s each is about 8 s.
3. **Bundle count drives the request count.** Golden (5 bundles) needs 36 requests; bigsbom and rekor-v2 (3 bundles) need 24. That is about 5 requests per extra bundle (manifest, config blob, layer blob with redirects). Time does not drop as much as the request count (7.2 s vs 6.95 s vs 5.97 s), so a fixed part exists too (TLS setup, TUF check, certificate work). One run each: indicative only. This supports my earlier hint, and corrects the caution in the handoff: bundle count does matter, but the fixed part is large.
4. **No Rekor call.** The cosign output says the transparency-log existence was "verified offline". The connection trace shows only three hosts: ghcr.io, the GHCR blob CDN, and the TUF host (`tuf-repo-cdn.sigstore.dev`, contacted once per run, about 4.6 s into the run). This matches R3a (Rekor, Fulcio and the others are not required).
5. **What is not yet known:** how long the TUF part takes (about 2-4 s of the 7-8 s is after the first TUF connection, but the trace cannot split TUF from certificate work). Step 4 measures TUF separately.

### Plain-language explanation
- One check = asking GHCR 36 questions one at a time ("what is attached to this image?", "give me this signature file", "now this one"...). Each question takes a fraction of a second because GHCR is far away, so the answers add up to about 7 seconds.
- Kyverno does three checks in a row, so about 21 seconds; add the setup cost after a restart and you go past 30.
- This is the key idea for the fix: the cost is mostly **waiting on the network**, not computing. Splitting into parallel policies attacks the waiting directly, because the waits would overlap. Making the registry closer (in Azure, an ACR in the same region) would also shrink each wait. Fewer bundles per image means fewer questions.

---

## Step 4 — Time the registry and TUF from the node (done 2026-10-08)

Method: `curl -w` timings run inside the kind node (`docker exec forge-spike-control-plane curl ...`) and from the host, 3 runs each; `cosign initialize` timed on the host with a scratch `TUF_ROOT`. Caveat: curl in the node uses the node's own network and DNS, not the DNS that pods get from CoreDNS. So this shows the path, not exactly what Kyverno's pod sees (step 5 does that).

### Timings

| Request | New connection (time to first byte) | Same connection reused |
| --- | --- | --- |
| `ghcr.io/v2/` from the host | 0.25-0.27 s | not measured |
| `ghcr.io/v2/` from the node, default | 0.47-0.49 s | 0.14 s per request |
| `ghcr.io/v2/` from the node, IPv4 only (`curl -4`) | 0.24-0.27 s | not measured |
| `tuf-repo-cdn.sigstore.dev/timestamp.json` from the node | 0.42-0.74 s | not measured |
| `tuf-repo-cdn.sigstore.dev/1.root.json` from the node | 0.32-0.55 s | not measured |
| `cosign initialize`, empty cache / with cache | 1.53 s / 1.23 s | |

Connect time (TCP handshake only): node default 0.25 s; node IPv4-only 0.05 s; host 0.05 s.

### Findings
1. **Each round trip to GHCR costs about 0.14-0.27 s, and a new connection costs about 0.25 s extra in the default node setup.** The 36 sequential requests of one `cosign verify` (step 3) fit this: 36 x 0.2 s is about 7 s.
2. **The extra 0.2 s on new connections in the node is an IPv6 attempt that fails.** With `curl -4` the node's connect time drops from 0.25 s to 0.05 s, the same as the host. IPv6 to GHCR does not work from here (it fails or times out on both host and node). Pods get an IPv4-only answer from our CoreDNS rule (the AAAA-empty template from R3a), so Kyverno's pod probably does not pay this penalty. To confirm in step 5.
3. **TUF is not the biggest cost.** A full TUF initialisation takes about 1.2-1.5 s on the host, and an incremental refresh is about the same (1.2 s). Three verifications each repeating it would add about 4 s, not 15. The registry chain (about 7 s per verification) is the bigger part. This lowers the value of the "TUF mirror" idea for latency. It still matters for the random TUF-init denials (availability), not for speed.
4. **Distance matters.** All of this is a home connection to GitHub/Google servers in the US/EU. Most of these round trips would shrink on AKS with an ACR in the same region. Treat R3b numbers as relative, as the plan already says.

### Plain-language explanation
- Every question to GHCR costs about a fifth of a second just for the trip there and back. Kyverno asks about 36 questions per check and does 3 checks, so most of the 24 seconds is simply travel time.
- Getting the Sigstore trust keys (TUF) takes about 1.3 seconds each time. That is small next to the registry trips.
- This changes the ranking of fixes: fewer registry questions or running them side by side beats trying to avoid TUF.

---

## Step 5 — One cold and one warm admission with detailed logs (done 2026-10-08)

Method: raised the admission controller's `--v=2` to `--v=4` (patch of the Deployment args, which restarts the pod), waited for I/O below 8%, ran one cold admission (the first call after the restart) and one warm admission (repeat 60 s later) of golden under the full policy `r3-verify-forge-images`, and read the controller log timestamps. Log level restored to `--v=2` afterwards (verified). Raw log kept in the scratchpad only.

### Cold admission (the first call; it hit the 30 s limit)

| Time (UTC) | What the log says | Elapsed |
| --- | --- | --- |
| 11:09:08.8 | `kubectl` sends the request | 0 s |
| 11:09:09 | image information read from the pod | about 0.2 s |
| 11:09:11 | `verifyImageSignatures called` | about 2 s (setup) |
| 11:09:11 to 11:09:22 | signature check | 11 s |
| 11:09:22 to 11:09:32 | SBOM attestation check | 10 s |
| 11:09:32 to 11:09:42 | vulnerability attestation check | 10 s |
| 11:09:38.8 | the API server gives up (30 s limit) | 30 s |
| 11:09:42 | the check finishes on the server (too late) | about 33 s |

The client saw: `Internal error ... failed calling webhook` (timeout), counted as a timeout in R3b.

### Warm admission (the same call 60 s later): 23.2 s

| Time (UTC) | What the log says |
| --- | --- |
| 11:10:25 | request sent |
| 11:10:26 | `verifyImageSignatures called`, then `image signature verification cache hit` (no work) |
| 11:10:26 to 11:10:37 | SBOM attestation verified again (11 s) |
| 11:10:37 to 11:10:48 | vulnerability attestation verified again (11 s) |

### Findings
1. **The three checks run strictly one after another and each takes 10-11 s inside the pod.** Cold total is about 2 s of setup + 11 + 10 + 10 = 33 s. This is the 30 s problem, directly observed.
2. **The signature check is not much slower than the attestation checks** (11 s vs 10 s). So the one-time TUF setup is only about 1 s; most of the cost repeats in every check. This matches step 4 (TUF about 1.2 s) and step 1 (every check redoes its setup and bundle listing).
3. **A warm admission skips only the signature.** The cache hit message appears for the signature only. The two attestation checks run again at about 10-11 s each, even though they succeeded a minute earlier. (We saw no "cache" or "skipping cache write" message for attestations at this log level, so why they are not served from cache is still open. The code says an attestation result is cached only if its payload can be captured; the log shows no failure message, so more digging is needed if we want to rely on it.)
4. **Inside the pod each check takes 10-11 s, versus about 7 s by hand on the host.** The pod is about 40-50% slower. The pod has no CPU limit (request 100m, memory limit 768Mi). Candidates, not tested: container networking (kind NAT), CPU contention with the other pods and the host on this machine, or the HDD. R3b numbers therefore include some machine overhead.
5. **The first admission works as a good diagnostic**: with `--v=4` the log shows exactly which check is running. No code change or extra tooling needed.

### Plain-language explanation
- We watched the stopwatch inside Kyverno itself. The 30 seconds go: 2 seconds getting ready, then three checks of about 10 seconds each, one after another. The last one is cut off by the 30 s limit.
- On a repeat, Kyverno remembers the signature but not the two attestations, so it repeats those two (about 21 s).
- If the three checks ran side by side, the total would be about 10-11 s plus setup, not 33 s. That is the strongest argument yet for the split-policy test.

---

## Step 6 — Which webhooks does Kyverno create for our policies? (done 2026-10-08)

Method: listed the `kyverno-resource-validating-webhook-cfg` webhooks, then applied three throw-away probe policies that match no real image (`example.invalid/*`): probe-a with no `webhookConfiguration`, probe-b and probe-c each with `timeoutSeconds: 30`. Listed again, then deleted the probes (verified: none left).

### What exists

| Webhook name | Timeout | Path |
| --- | --- | --- |
| `ivpol.validate.kyverno.svc-fail` (probe-a, no custom timeout) | 10 s | `/ivpol/validate/probe-a` |
| `ivpol.validate.kyverno.svc-fail-finegrained-probe-b` | 30 s | `/ivpol/validate/probe-b` |
| `ivpol.validate.kyverno.svc-fail-finegrained-probe-c` | 30 s | `/ivpol/validate/probe-c` |
| `ivpol.validate.kyverno.svc-fail-finegrained-r3-verify-forge-images` (our policy) | 30 s | `/ivpol/validate/r3-verify-forge-images` |
| `vpol...-fail-9d71e4df` (r1-registry-allowlist) | 10 s | `/vpol/r1-registry-allowlist` |
| `vpol...-fail-e94d8fa6` (p3-deny-test-label) | 10 s | `/vpol/p3-deny-test-label` |

### Findings
1. **A policy with `webhookConfiguration.timeoutSeconds` set gets its own webhook entry** (name contains `finegrained`, own path, own timeout). Two probes with the same settings got two separate entries. So three split policies, each with a timeout set, will each have their own 30 s clock on the API-server side.
2. **A policy without a custom timeout goes into a generic webhook with a 10 s timeout** (default), not 30 s. Any new image policy we write must set `timeoutSeconds` explicitly, or it gets 10 s, which our checks never meet.
3. **Our other two policies (VAP-style `vpol`) have their own entries with 10 s.** They are fast checks, fine as they are.
4. Probes cleaned up: `kubectl get ivpol` shows only `r3-verify-forge-images`.
5. **Still not proven:** that the API server calls these entries in parallel (the docs page does not say). The split-policy timing test in R3c proves it: if the total is near the slowest policy, they run in parallel; if near the sum, they run in turn.

### Plain-language explanation
- Each policy that sets its own timeout gets its own "doorbell" at the API server. Kubernetes presses each doorbell and gives each its own 30-second countdown. Policies that do not set a timeout share a generic doorbell with only 10 seconds.
- So for the split test, we write three policies and give each `timeoutSeconds: 30`. Whether the three doorbells are pressed together or one after another is what the test measures.

---

## Step 7 — Cache and parallel experiment (done 2026-10-08)

Method: two identical signature-only policies (`r3b-sigonly`, `r3b-sigonly-b`, same checks, different names; both with `timeoutSeconds: 30`), golden digest, dry-run. Three repetitions of: restart the controller (empty cache), wait for I/O below 8%, then (1) admit with A and B live, both uncached; (2) admit again 30 s later; (3) add a third identical policy C and admit again (only C is new). Raw: `R3-prestudy-step7.csv`. Temporary policy C deleted after each repetition.

| Step | Rep 1 | Rep 2 | Rep 3 | What it shows |
| --- | --- | --- | --- | --- |
| A+B, both uncached | 14.07 s | 13.44 s | 13.52 s | two checks cost about the same as one |
| A+B again | 1.67 s | 1.69 s | 1.70 s | both cached |
| A+B+C, only C new | 13.60 s | 12.50 s | 12.38 s | C gets no benefit from A's or B's cache |

Reference: R3b signature-only single policy, cold: p50 14.5 s.

### Findings
1. **The two policies ran in parallel.** If the API server called the webhooks one after the other, A+B would take about 2 x 14 = 28 s. It took 13.4-14.1 s, the same as one policy. This is the first direct evidence for the split-policy idea. It closes the gap the docs left (they did not say whether validating webhooks run in parallel).
2. **The cache is per policy and not shared.** C, an exact copy of A, still did a full verification (12.4-13.6 s) while A and B were cached. This matches the source (cache key contains the policy's own UID and resource version).
3. **The cache works inside one policy.** After the first admission, repeat admissions of the same image cost 1.7 s (not 0.3 s as with no policy: that remainder is the webhook calls and policy evaluation).
4. Scope: this proves parallel for two policies, with a signature check only. Three policies (signature + two attestations) should behave the same, but the R3c test must confirm it, since three parallel verifications put more load on this small node.

### Plain-language explanation
- Two policies checking the same image at the same time finish in the time of one. So the split works: three checks of about 10 s each in separate policies should take about 10-14 s in total instead of 33 s.
- The price: each policy keeps its own "already checked" notebook, so none of them benefits from another's work. Each policy repeats its own setup and its own registry trips. The node does three times the work in the same time.

---

## Step 8 — The trusted root file, and does it remove the TUF dependency? (done 2026-10-08)

Method: took `trusted_root.json` from a TUF cache made by `cosign initialize`, put it in a policy (`policies/r3b-trustedroot.yaml`, signature only, field `cosign.trustedRoot.value`), applied it, then blackholed `tuf-repo-cdn.sigstore.dev` on the admission controller (`hostAliases` to 127.0.0.1, as in R3a) and admitted golden. Blackhole removed afterwards (verified); the full policy `r3-verify-forge-images` is live again.

### Where the file comes from and what it is
- `cosign initialize` downloads it; it is stored at `<TUF_ROOT>/<mirror host>/targets/trusted_root.json`. Copy kept at `r3/trusted_root.2026-10-08.json` (6.8 KB, untracked). It lists 2 transparency logs, 2 Fulcio CAs, 2 CT logs and 1 timestamp authority, with validity dates; Sigstore publishes new versions when keys rotate, so the copy would go stale.
- The whole set of files Kyverno could need from TUF is tiny: 11 target files totalling about 11 KB (`trusted_root.json` 6.8 KB, `rekor.pub`, `ctfe*.pub`, three Fulcio certificates, three signing configs) plus four small metadata files.
- In the policy, `trustedRoot` takes either an inline `value` (the code limits it to 1 MiB) or an `expression`. We used the inline value; the file was accepted by the API server.

### Result
| Condition | Outcome |
| --- | --- |
| TUF host reachable, `trustedRoot` set | admitted, 12.9 s |
| TUF host blocked, `trustedRoot` set, try 1 | denied in 2.2 s: "no valid signature ..." |
| TUF host blocked, `trustedRoot` set, try 2 | denied in 1.7 s: same |

Controller log for the denials: `failed to initialize TUF client (mirror="https://tuf-repo-cdn.sigstore.dev"): ... tuf: failed to download 13.root.json ...`.

### Findings
1. **Confirmed by test: `trustedRoot` does not remove the TUF dependency in Kyverno 1.19.1.** This agrees with the source reading in step 1. Do not use it as an availability or latency fix.
2. **Small extra finding: the TUF client in the pod starts from root version 13** (it tries to download `13.root.json`) while the current root is version 15. At each start it walks the root chain, which is part of the setup cost.
3. **A self-hosted TUF mirror (`cosign.tuf.mirror`) is the only documented way to cut the external dependency.** It is small to host but needs care: in the cache we copied, the TUF `timestamp.json` expires on 2026-10-14 (about a week from now), and the root expires on 2026-11-20. A static copy would stop working within days unless something refreshes it on a schedule. A mirror is therefore a job (sync every day or so) plus a place to serve the files (inside the cluster), not a one-off copy. Whether Kyverno accepts an in-cluster `http://` mirror, or requires https, was not tested.
4. Whether the availability gain is worth that operational cost is an ADR-002 question. With TUF taking only about 1.3 s per check (step 4), the mirror is mainly about reducing the transient failures (the 23% of cold attempts in R3b that hit a TUF-init denial), not about speed.

### Plain-language explanation
- We handed Kyverno the Sigstore trust list directly and then cut the line to the Sigstore server. Kyverno still failed, because it fetches other things from that server anyway. So that shortcut does not work in this version.
- The workable alternative is to run our own copy of the Sigstore server's files inside the cluster. It is tiny, but the files have expiry dates, so something has to refresh the copy regularly. That is a real maintenance cost, not a free fix.

---

## Step 9 — Test tooling for R3c (done 2026-10-08)

### What was prepared (all untracked, in `spike/forge-spike-r1`)
- `r3/tools/r3-latency.sh`: the R3b measurement loop, rewritten. Modes `plain`, `cold`, `coldwarm`, `primewarm` (the case 3 protocol: restart, priming call, 45 s pause, timed warm call). Logs every attempt with cause, retries invalid ones (TUF-init denials, timeouts), waits for I/O below 8%. Output file set with `R3_OUT` (default `r3/R3c-raw.csv`).
- `r3/tools/swap-policy.sh <policy files...>`: deletes all image policies, applies the given ones, waits until Ready.
- `r3/tools/cluster-up.sh` and `cluster-down.sh`: start and wait for Ready; stop with `docker stop -t 180`.
- `policies/r3c-split-sig.yaml`, `r3c-split-sbom.yaml`, `r3c-split-vuln.yaml`: the full policy cut into three, each with `timeoutSeconds: 30`. `policies/r3b-trustedroot.yaml`, `r3b-sigonly-b.yaml`, `r3b-sigonly-c.yaml` are from steps 7-8.
- `r3/trusted_root.2026-10-08.json`: the Sigstore trusted root copy.

### Honest note about the R3b scripts
The scripts used for R3b lived in the session scratchpad (`/tmp`) and were lost when the machine rebooted. The R3b method is documented in `R3b-results.md` and `r3-latency.sh` follows it, but it is a rewrite, not the original file. It was only smoke-tested (3 attempts on the full policy: one 32 s timeout, two admitted at 24-25 s, matching the earlier numbers). The raw data of R3b itself (`R3b-raw.csv`) is in the repo folder and was not lost.

### Sanity check of the three split policies (correctness, not a measurement)
Applied all three together and admitted each test image twice (dry run; one sample each, so treat the times as indicative only):

| Image | Result | Time, round 1 / round 2 |
| --- | --- | --- |
| golden | admitted | 13.7 s / 13.9 s |
| bigsbom | admitted | 12.3 s / 10.7 s |
| unsigned | denied | 6.7 s / 6.3 s |

- The full single policy needs about 33 s cold and 23-24 s warm for golden (step 5). The same three checks as three policies took about 14 s, in line with step 7 (parallel).
- Round 1 is cold for these new policies (their caches are empty), and round 2 is nearly the same time. The attestation checks are re-done every time (step 5), so the cache only helps the signature policy; the total stays near the slowest attestation check (about 11-14 s).
- The denial message for `unsigned` came from the vulnerability policy ("missing or unverified vulnerability attestation"), not from the signature policy. With several policies, the API server reports whichever webhook answers a denial first. For a runbook or user-facing message this means the error for a bad image may name any one of the policies; the full list of causes is not shown.
- The full policy `r3-verify-forge-images` was restored afterwards (Ready).

### Plain-language explanation
- The tools for R3c are saved in the repo, so the next chat can start testing right away instead of building them.
- The quick check already hints at the answer to the big question: splitting brought a 33 s admission down to about 14 s. R3c's job will be to measure that properly (20 runs, cold and warm), not to discover whether it works.
