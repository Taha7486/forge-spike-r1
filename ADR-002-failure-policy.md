# ADR-002: Admission failure policy, timeouts and availability of the gate

Status: Accepted (2026-10-09) by the project owner; proposed 2026-10-09. Addendum 1 (2026-10-10, findings from R3e) Accepted by the project owner on 2026-10-10, see the end of this file. Evidence: [r3/R3c-results.md](r3/R3c-results.md) (appendix), [r3/R3a-results.md](r3/R3a-results.md), [r3/R3b-results.md](r3/R3b-results.md), [r3/R3-prestudy.md](r3/R3-prestudy.md). Amends ADR-001 decision 3 (one policy becomes three) and fills in the values ADR-001 left to this ADR (`failurePolicy`, `timeoutSeconds`).

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

---

## Addendum 1 (2026-10-10): findings from the R3e checks

Status: Accepted (2026-10-10) by the project owner. Evidence: [r3/R3e-results.md](r3/R3e-results.md) (3-node kind cluster `forge-r3e`, same laptop and network as R3a to R3c). The six findings were reviewed one by one with the project owner on 2026-10-10; decision A3 was taken by the owner during that review. Where this addendum contradicts the text above, **the addendum wins**; the original text is left as written so the history stays readable.

### A1. Spreading the admission replicas (amends decision 4)

Spreading with `DoNotSchedule` on a cluster with 2 worker nodes **stalls every rolling update** (Helm upgrade, `rollout restart`): the rollout starts the new pod before removing an old one, there is no node left for a third pod, and `maxUnavailable` (40% of 2) rounds to 0, so nothing moves. The gate stays up, only upgrades hang. The fix, tested, is `nodeTaintsPolicy: Honor` in the constraint (my best explanation is that the tainted control-plane node was counted as an empty node; the fix is proven, the cause is not). After it, a `helm upgrade` finished in 82 s with one replica per worker.

Also established:
- The Helm chart creates the PodDisruptionBudget by itself when `replicas > 1` (the "check in Phase 1" in decision 4 is answered). With `minAvailable: 1` the drain of the last Ready replica is refused.
- The chart's own anti-affinity is only a preference; the hard constraint is ours.
- With exactly 2 schedulable nodes, a drained or lost node leaves 1 replica until the node returns (the replacement cannot sit next to the survivor). **The real cluster needs at least 3 worker nodes** so a replacement can be scheduled elsewhere. The values used are in `r3/tools/r3e-kyverno-values.yaml`.

### A2. TUF is needed when a replica starts, not on every verification (amends the Context, decision 6 and the section 11 answer)

R3a to R3c always restarted the controller before blocking TUF, so they measured a freshly started pod and read it as "cold verification". R3e blocked TUF in DNS **without restarting** the controller. Result: a running replica that had initialised once admitted the same image and an image it had never seen, with all three checks, and never asked DNS for the TUF host. A fresh replica under the same block was denied in about 2 s with `failed to initialize TUF client` in its log (the control that proves the block works).

Corrected statements:
- TUF (Sigstore's key service) is an availability dependency of a **replica starting** (restart, rollout, scale-up, rescheduling after a node loss), not of each admission. Running replicas keep verifying while TUF is down.
- **Corrected answer to spec section 11, "What happens if Sigstore is unreachable at admission time?"** Only the Sigstore TUF host is needed (plus the registry and its blob CDN); Rekor, Fulcio, the timestamp authority and the CT log are not contacted. Admission controllers that are already running keep verifying, including images they have not seen before, because they keep the trust data they loaded at start. A controller replica that **starts** while TUF is unreachable refuses every pod covered by the image policies (`Fail`): in about 2 seconds if the lookup or connection is refused, in 30 seconds if the host hangs. The message may read like a signature failure, so the runbook points at the controller log. Running pods are never affected. With `Ignore`, a hang would let every pod in unverified, which is why `Ignore` is not used.
- Not established: how long a running replica can go without TUF (the signed metadata expires in about a week; the tests lasted minutes), and the behaviour when TUF hangs instead of refusing, on a warm replica.

### A3. No in-cluster TUF mirror (decision 6 settled; owner's decision, 2026-10-10)

Decision 6 left the mirror open ("test it, build it if more than about 1% of cold admissions fail at TUF"). It was tested and **will not be built**. Reasons:
- It works: Kyverno 1.19.1 accepts a plain `http://` mirror (`cosign.tuf.mirror` plus `cosign.tuf.root.data` on the attestor), and with public TUF blocked, fresh replicas still verified through it.
- But with a mirror configured, Kyverno contacts it **on every admission** (about 4 requests each). With the mirror down, every admission was refused in under 2 s, **also on running replicas**, which the default setup survives (A2). A stale mirror does the same: its timestamp metadata expires in about a week (the current copy: 2026-10-16), and clients reject expired metadata.
- So the mirror trades a rare external risk (a replica starting while TUF is down) for an internal one on every request. It would need 2 mirror replicas, a daily sync job, an alert on the expiry date and an alert on job failure: more moving parts than the risk justifies for this project.
- The 1% trigger in decision 6 is withdrawn for this project. What remains: keep the public TUF service, document the risk, and avoid restarting or upgrading Kyverno while Sigstore is known to be down. A mirror stays the answer to "what would production do?" if the risk must be removed; the sync script (`r3/tools/r3e-tuf-sync.py`) and the manifest (`r3/R3e/tuf-mirror-deploy/mirror.yaml`) are kept as the starting point.

### A4. Break-glass recovery (amends decision 10 and the last runbook row)

"Delete the Kyverno webhook configurations by hand; Kyverno recreates them" is **not a recovery** while Kyverno is running: both kinds were deleted in 1.3 s and recreated within 2 s, and 14 plain pod creations over 34 s all failed. The tested procedure:
1. `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=0`. Kyverno removes its webhooks on a clean stop; they were gone in about 5 s and plain pods were admitted again.
2. Repair what is broken.
3. `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=2`. Both replicas were Ready in 45 s and the gate worked again.

**While the controller is scaled to 0 the gate is open: an unsigned image was admitted during the test.** The runbook must say so, and the procedure is for emergencies only. The breakage was simulated (the webhook Service emptied and both containers killed), not a real fault.

Platform namespaces are excluded per policy, not in Kyverno's config: a `namespaceSelector` in each policy's `matchConstraints` (`kubernetes.io/metadata.name NotIn [...]`) is merged with the chart's own exclusions (`kube-system`, `kyverno`) and took effect in under 15 s (unsigned admitted in the excluded namespace, denied in another).

Runbook row, replaced: *Everything is refused, including simple pods* — *Kyverno is down or unreachable and `Fail` is on* — *Check the 2 replicas and wait a few seconds; if it persists, use the emergency procedure above and treat the gate as open until it is scaled back to 2.*

### A5. What `Fail` costs when Kyverno goes down (supports decisions 1 and 4)

Measured with 2 replicas, the PDB and spreading, while two loops tried to create a pod with the unsigned image back to back:

| Failure | Gate closed by `Fail` |
| --- | --- |
| One replica deleted (leader or other), rollout restart, one node stopped | none seen |
| One replica killed for running out of memory | about 6 s |
| Both containers killed at once | about 13 s |
| Both pods deleted at once | about 41 s |

**No unsigned image was admitted in any scenario: 0 of 329 probes.** The closed window is bounded by how fast a replica becomes Ready again (slow here: spinning disk). Two oddities are unexplained: no refusal at all when a node was stopped, and one refusal 3 s before the memory cap was applied in the out-of-memory test. The "nodes" are Docker containers on one machine, so a node failure here is a container stop, not a network cut or a hung machine.

### A6. Two replicas give availability, not burst capacity (supports the fallback rule of decision 2)

R3c item 5 repeated with 2 replicas and the three policies:
- Simultaneous pod creations still time out at 30 s: cold 10 pods 5 of 10 (1 replica: 5 of 10), cold 20 pods 13 of 20 (14), warm 20 pods 10 of 20 (14); only warm 10 improved (10 of 10 admitted). The load did split roughly evenly between the replicas.
- Deployments of 10 and 20 pods rolled out in 79 to 106 s with no failed pod creation (1 replica: 86 to 147 s, 1 failure in 8 runs): a ReplicaSet creates its pods gradually, so a rollout is not a burst.
- Peak per admission replica: 138 MB of the 512 MB limit and 166% of one core; no restart. The cause of the limit (CPU, disk or the network to the registry) was not measured.

The decision does not change. The fallback rule stays and must be checked on the real cluster in Phase 1 (cold p95, a 10-replica rollout, a burst of 10). Only creating many pods at the same instant is a problem; a normal rollout is not.

### Still open after R3e

How long a running replica can go without TUF; a TUF hang (instead of a refusal) on a running replica; a real node loss with a network cut; the background scan under two replicas; the Phase 1 cloud checks listed in the Consequences section.
