# ADR-002: Admission failure policy, timeouts and availability of the gate

Status: Accepted (2026-10-09) by the project owner; proposed 2026-10-09. Evidence: [r3/R3c-results.md](r3/R3c-results.md) (appendix), [r3/R3a-results.md](r3/R3a-results.md), [r3/R3b-results.md](r3/R3b-results.md), [r3/R3-prestudy.md](r3/R3-prestudy.md). Amends ADR-001 decision 3 (one policy becomes three) and fills in the values ADR-001 left to this ADR (`failurePolicy`, `timeoutSeconds`).

## Context

Risk R3 asked what the admission gate depends on, how long it takes, and what happens when a dependency fails. Kyverno 1.19.1 verifies the signature, the SBOM attestation and the fresh vulnerability-scan attestation of every new pod's image, inside one webhook call that Kubernetes cuts off at 30 seconds.

All numbers below were measured on a laptop (spinning disk, 4 cores, one kind node, one Kyverno replica, home internet, one image). They show the shape of the behaviour, not the values on a cloud cluster. The target cloud is not settled, so this ADR says nothing that depends on Azure or AWS; cloud values are re-measured in Phase 1 (see the fallback rule).

What was found:
- At admission only three hosts are contacted: Sigstore's TUF service, the registry and the registry's blob CDN (`ghcr.io` and `pkg-containers.githubusercontent.com` in the spike). Rekor, Fulcio, the timestamp authority and the CT log are not (R3a).
- A single policy with all three checks never finished a cold admission inside 30 s (0 of 30). Each check repeats the trust setup and lists the registry's bundles. Three separate policies, each with its own `timeoutSeconds`, run in parallel: cold p50 15.2 s, worst 22.8 s.
- Only the signature result is cached (per policy, per replica, 1 hour). Attestation checks are repeated for every pod: warm admission is 1.7 s for signature only, about 13 s when an attestation check is present.
- `failurePolicy` does not change policy results (refused TUF, registry or CDN: denied under both settings). It matters for webhook failures: a silent TUF host makes `Fail` refuse every pod after 30 s and `Ignore` admit every pod after 30 s, unsigned ones included. A graceful stop of the only Kyverno replica removes the webhooks (everything admitted); a crash leaves them (`Fail` blocks for seconds, `Ignore` admits unsigned images for that time). Two replicas with a PodDisruptionBudget showed no gap (167 of 167 probes denied).
- About 12.5% of cold rounds were denied with "no valid signature" because the home router answered SERVFAIL for the TUF host and Kyverno 1.19.1 does not retry the first lookup.

## Decision

1. **`failurePolicy: Fail`** on all image policies. `Ignore` lets unchecked images in exactly when verification is needed (silent TUF host, Kyverno crash). The cost is that new pods are refused during a Sigstore or Kyverno outage; running pods are unaffected. That cost is reduced by decisions 4 and 10.
2. **Three parallel policies**, not one: signature, SBOM attestation, and vulnerability-scan attestation with freshness window. All three checks stay at admission (the spec's differentiator). Measured cost, accepted: warm admission about 13 s because attestations are not cached; a 10-to-20-replica rollout takes 1.5 to 2.5 minutes; a burst of 10 or more simultaneous pod creations makes some webhooks time out and the ReplicaSet controller retries them.
   **Fallback rule:** in Phase 1, on the real cluster, measure cold admission p95, a 10-replica rollout and a burst of 10. If the cold p95 cannot stay inside the 30 s cap with margin, drop to signature plus scan freshness, or to signature only (attestations then enforced in CI, freshness as a background tripwire).
3. **`webhookConfiguration.timeoutSeconds: 30`** on every image policy (the Kubernetes maximum). Without it a policy gets a shared 10 s webhook and a normal cold check is refused under `Fail`. Cost: with a silent TUF host each pod creation waits 30 s before being refused. Phase 1: a CI lint that fails an image policy without `timeoutSeconds`.
4. **Availability of the gate:** 2 admission replicas, a PodDisruptionBudget (`minAvailable: 1`), topology spread or anti-affinity across nodes, and two alerts (fewer than 2 Ready admission replicas; Kyverno webhook configurations missing). Check in Phase 1 whether the Helm chart creates the PDB itself.
5. **Helm resource values (starting values):**

   | Component | Memory request / limit | CPU request / limit |
   | --- | --- | --- |
   | Admission controller (2 replicas) | 256 MB / 512 MB | 250m / none |
   | Reports controller | 256 MB / 512 MB | 100m / none |
   | Background and cleanup controllers | 128 MB / 512 MB | 100m / none |

   The chart's default memory limit (128 MB) made Kyverno thrash on the spike machine. Measured peaks were 192 MB (admission, heaviest burst) and 232 MB (reports); the limit is about 2.5 times the highest peak. No CPU limit, because throttling a webhook turns into 30 s timeouts (common practice, not measured here). Behaviour on an out-of-memory kill is untested. These values replace the `kubectl set resources` drift on the spike cluster.
6. **TUF is an availability dependency of pod creation.** Keep the public TUF service for now. Test an in-cluster mirror (`cosign.tuf.mirror`) in R3e. Build it if, on the real cluster, more than about 1% of cold admissions fail at the TUF step, or any hang is seen (1% is a starting number). `cosign.trustedRoot` does not remove the dependency in Kyverno 1.19.1 (tested with TUF blocked). A mirror needs a refresh job with its own alert: the signed metadata expires in about a week.
7. **Verification cache: keep the default** (1 hour per policy per replica). Attestation checks are never cached whatever the setting, so a different value does not change the freshness guarantee. Revisit only if fast signature revocation becomes a requirement.
8. **Background evaluation stays on for all three policies.** The demo is a few tens of pods; the scan takes minutes at that size (about 6 to 20 s per pod). It gives PolicyReports for every check, usable by the `conformity` tool, and a stale scan shows up in the reports as it ages, so no separate tripwire policy is needed. A DNS hiccup can put a false failure in a report: check the reports, or require a failure in two consecutive scans, before relying on them.
9. **Observability: minimal.** One Grafana panel from Kyverno's counters for refused versus allowed requests (a refusal leaves no Event and no PolicyReport, so the counters are the only history). No log shipper: the demo reads `kubectl logs` on the admission controller for the cause. Only the two alerts of decision 4; if there is no alerting stack, that is a recorded gap. Run `conformity` while the demo pods exist, because reports disappear with the pod.
10. **Namespace scope and break-glass.** Exclude the platform namespaces (`kyverno`, `kube-system`, and tools the project installs but does not build: ArgoCD, Grafana, Falco) from the image policies; verify the application namespace(s). If Kyverno breaks and blocks everything, recovery is deleting the Kyverno webhook configurations by hand (Kyverno recreates them). No expiring PolicyException in the demo scope: it needs `--enablePolicyException` (off now) and adds moving parts. Recovery is rehearsed once locally in R3e.
11. **Runbook.** The table below goes into the spike README and is linked from here.

   | What you see | What it really means | What to do |
   | --- | --- | --- |
   | "no valid signature" or "missing or unverified attestation", in about 2 s | Most likely Sigstore's TUF service was unreachable (DNS failure or refused connection), not a bad image | Read the admission controller log; if it names the TUF address or DNS, retry once |
   | The same message after about 30 s | The TUF service is hanging | Check the service; new pods stay blocked until it recovers, running pods are fine |
   | "error: failed to evaluate policy ... dial tcp ..." | The registry or its download servers are unreachable | Check registry access and the egress allowlist |
   | "no valid signature" after about 8 s on a new image | The image really is not signed by the pipeline | Fix it in CI |
   | Any refusal | The policy named is only the first of the three to answer, not necessarily the only reason | Read the log for the full cause |
   | Everything is refused, including simple pods | Kyverno is down or restarting and `Fail` is on | Check the 2 replicas and wait a few seconds; if it persists, use the recovery step (decision 10) |

## Answer to spec section 11: "What happens if Sigstore is unreachable at admission time?"

Only the Sigstore TUF host is needed at admission (plus the registry and its blob CDN); Rekor, Fulcio, the timestamp authority and the CT log are not contacted. With `failurePolicy: Fail`, a pod whose image has not been verified yet is refused: in about 2 seconds when the TUF host is refused or its DNS lookup fails, in 30 seconds when it hangs. The message may read like a signature failure, so the runbook points at the controller log. Pods that are already running are not affected. With `Ignore`, the same hang would let every pod in unverified, which is why `Ignore` is not used.

Not yet confirmed: that an image already verified and still cached (one hour per policy and per replica) is admitted without contacting TUF. This is inferred from the signature cache; R3e item 6 tests it. Because attestation checks are not cached, a cached signature alone would not admit a pod under the three-policy design, so the sentence may need to be dropped.

## Consequences and debts

- **Cold admission is slow and the attestation checks are repeated per pod.** Rollouts and bursts are the weak point (decision 2); the fallback rule is the exit.
- **Pod creation depends on Sigstore's TUF service** until a mirror exists (decision 6). Refusals during a TUF outage are by design.
- **Misleading messages:** a TUF or DNS failure reads as "no valid signature", and with three policies the API server shows only the first denial. The controller log is the only place the real cause shows.
- **Untested (R3e):** both replicas down, node failure, out-of-memory kill, spreading on real nodes, load with two replicas, the TUF mirror, the exclusion and recovery rehearsal, cache with TUF blocked. Recommended before the cloud cluster, not a hard gate.
- **Phase 1 exit checks on the cloud cluster:** DNS probe and latency loop, cold p95, 10-replica rollout and 10-pod burst against the fallback rule, egress allowlist against the dependency map (blob CDNs included), referrers support of the registry, spreading over real nodes.
- **Freshness window:** the R3 policies were measured with 720h (ADR-001 used 168h) so the 2026-10-02 spike scans stay valid until about 2026-11-01. The production window is a Phase 1 choice.
- **What production would add:** log shipping, alerts on persistence rather than single failures, an expiring PolicyException for exceptions.

## Revisit triggers

- Cloud measurements that break the fallback rule (cold p95 near 30 s, rollout or burst failures).
- More than about 1% of cold admissions failing at the TUF step, or any TUF hang (build the mirror).
- A new Kyverno minor (1.20 expected around November 2026): attestation caching, TUF retry or `trustedRoot` behaviour may change; re-run the latency loop first.
- A requirement that pod creation must never be blocked by Kyverno or Sigstore trouble (then `Ignore` plus a compensating control).
- A requirement for fast signature revocation (shorter cache).
