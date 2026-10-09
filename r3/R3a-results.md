# R3a — What Kyverno actually contacts

Date: 2026-10-06. Cluster `forge-spike` (kind, Kyverno chart 3.9.1 / app v1.19.1). Images: GHCR digest-form `golden` and `rekor-v2`. Policies: `policies/r3-ivp.yaml` and `policies/r3-ivp-ctlog.yaml` (R1 policy, no credentials, 720h; the second adds `cosign.ctlog.url: https://rekor.sigstore.dev`).

## Method

1. CoreDNS `log` on; cold admissions of `golden` and `rekor-v2`; list every non-cluster-local name resolved.
2. Blackhole a host for the admission controller only: `hostAliases` entry pointing it at `127.0.0.1` on the Deployment (the controller rolls, so every test starts with empty caches). Re-run both images. A host counts as required only if blocking it changes the admission result.
3. Repeat with `ctlog.url` set.

Rule applied: a result counts only if the denial or log names the expected cause. Webhook timeouts (first admission after a roll, 30 s) are not results; the call was repeated.

## Observed

| Host | Observed | Evidence |
| --- | --- | --- |
| `tuf-repo-cdn.sigstore.dev` | **Required**, on every cold verification (not startup-only). Blocked: fast deny, 2-4 s | Kyverno log: `failed to initialize TUF client (mirror="https://tuf-repo-cdn.sigstore.dev"): ... failed to download 13.root.json ... connection refused` |
| `ghcr.io` | **Required** (registry API). Blocked: error in 0.35 s | API response: `Policy ... error: failed to evaluate policy: Get "https://ghcr.io/v2/": ... connection refused`. No log line at this log level; 0 "verifying cosign" lines, so it failed before verification began. |
| `pkg-containers.githubusercontent.com` | **Required** (GHCR blob CDN). Blocked: error in 1.1 s | API response: `... Get "https://pkg-containers.githubusercontent.com/ghcrblobs18/blobs/sha256:...?hmac=REDACTED...": ... connection refused`. Same log caveat. |
| `rekor.sigstore.dev` | Not required, with or without `ctlog.url` | Both images admitted blocked; 0 DNS queries; 0 error lines |
| `log2025-1.rekor.sigstore.dev` (Rekor v2 shard) | Not required | same |
| `fulcio.sigstore.dev` | Not required | same |
| `timestamp.sigstore.dev` | Not required | same |
| `ctfe.sigstore.dev` | Not required | same |

The five not-required hosts were blocked together in one rollout, once per policy variant. Both images were admitted with full verification (signature, sbom, vuln) and the log held 0 matches for `127.0.0.1`, `connection refused`, `rekor`, `fulcio`, `ctfe`, `timestamp.sigstore`, `ERR`, `WRN`, `failed`. Not bisected, because nothing failed.

## Findings

1. **TUF is a per-verification dependency, not startup-only.** The controller starts Ready with TUF blocked; the first verification fails. Hypothesis (startup and refresh only) was wrong.
2. **A TUF outage is reported as a signature failure.** The `kubectl` error reads `no valid signature from the forge-spike-r1 signing workflow`; only the controller log shows the TUF error. Needs a line in the Phase 1 break-glass runbook.
3. **Error classes differ.** TUF block: policy result `failed`. Registry and CDN blocks: policy `error: failed to evaluate policy`, which names host and cause. Whether `failurePolicy: Ignore` treats these differently is an R3c question; do not assume.
4. **Dependency order.** Registry API first, then blob CDN, then TUF. With the registry down the admission never reaches TUF.
5. **Registry egress needs the blob host.** Allowing only `ghcr.io` denies every image. Phase 1 egress allowlist must include `pkg-containers.githubusercontent.com`; ACR's blob host is an R2 item.
6. **`ctlog.url` is the Rekor instance URL**, not the CT log (CRD: "url sets the url to the rekor instance"). Setting it to the public Rekor changed nothing observable: no DNS query, no dependency. Harmless, no benefit in this mode.
7. **The transparency-log failure mode in R3c does not apply**: no Rekor, Fulcio, TSA or CT host is contacted at admission. The one Sigstore dependency is TUF.
8. **Possible lever, untested:** the CRD has `cosign.trustedRoot` ("uses this trust material directly instead of fetching trusted_root.json from the Sigstore TUF repository"). It could remove the TUF dependency entirely, at the cost of rotating the root by hand. Candidate for R3c / ADR-002.
9. **Verify cache:** Kyverno caches image-verify results (`enabled=true maxsize=1000 ttl=1h`). A repeat admission of the same digest skipped the signature step (attestations were re-verified, about 10 s each). "Warm" in R3b is partly this cache.

## Environment findings (not Sigstore, but they cost hours)

- **Kyverno default memory limits are too tight on a slow disk.** background / cleanup / reports controllers: 128 Mi limit; admission: 384 Mi. On this 5400 rpm HDD the three small controllers re-read their own binaries continuously (about 214 MB per 10 s measured in the background controller), pinned the disk at 85-95% I/O pressure for 20+ minutes, and starved the liveness probes, so pods restarted in a loop and admissions timed out. Raised by `kubectl set resources` (admission 768 Mi / 256 Mi request; others 512 Mi / 128 Mi request). I/O pressure fell from 84% to about 17% within 40 s of the rollout; no restarts since. This is a kubectl drift from the Helm release. Input to Phase 1 Helm values: set explicit limits.
- **Shutdown was clean.** Container exit 0 on the previous day; etcd corruption check passed on both starts. The last `docker stop` under load exited 137 (force-killed after the 10 s default) and etcd started cleanly afterwards.
- **CoreDNS fix.** `log` plus `template IN AAAA . { rcode NOERROR }` (see `Corefile.r3a`; original in `coredns-orig.yaml`). Every AAAA for the three hosts returns NOERROR with an empty answer. With the node IPv6 sysctl reverted (all three `= 0`) the cold `golden` admission passed in 23 s. Caveat: the original timeouts of this session were measured with the sysctl set and turned out to be the memory-thrash above, so this shows the fix is sufficient, not that IPv6 was the cause on this run.
- **Admissions right after a roll hit the 30 s webhook timeout** (first call each time); the verification completes server-side and the retry passes (about 23-27 s golden, 17-19 s second rekor-v2 call).

## State left on the cluster

Live policies: `r3-verify-forge-images-ctlog`, `r1-registry-allowlist`, `p3-deny-test-label` (`r1-verify-forge-images` deleted from the cluster; `r1-ivp.yaml` unchanged in the repo). Admission controller: no `hostAliases`. CoreDNS: Corefile as `Corefile.r3a`. Memory limits as above.
