# R3e results — checks before the cloud cluster

Started 2026-10-09. Cluster `forge-r3e` (kind v0.33.0, node `kindest/node:v1.35.8` pinned by digest, 1 control plane + 2 workers), Kyverno app v1.19.1 (chart 3.9.1) with the ADR-002 values, three policies `r3c-split-{sig,sbom,vuln}` (`Fail`, `timeoutSeconds: 30`). Same laptop as R3a to R3c (HDD, 4 cores, home internet), after a system update on 2026-10-09 (Ubuntu 26.04.1, kernel 7.0.0-38, Docker 29.1.3). ADR-002 is not edited by this work; anything that should change it is listed under "Findings for ADR-002" at the end.

Files: tools `r3/tools/r3e-*`, raw data `r3/R3e/`.

## Step 0 — the 3-node cluster with the ADR-002 values (done)

Method: `r3/tools/r3e-up.sh` (kind config `r3e-kind.yaml`, Helm values `r3e-kyverno-values.yaml` = ADR-002 decisions 4 and 5). Then the three split policies, then 3 golden dry-runs and 1 unsigned.

Results:
- Cluster and Kyverno up in about 5 minutes on the quiet HDD (the kind node image is unpacked three times; I/O pressure peaked at 57%). Log: `R3e/step0-up.log`.
- Admission controller: 2 replicas on different workers (`forge-r3e-worker`, `forge-r3e-worker2`). The control plane is tainted, so Kyverno does not run there.
- **The chart creates the PodDisruptionBudget by itself** when replicas > 1 (template condition `enabled or replicas > 1`); with `podDisruptionBudget.minAvailable: 1` it showed `ALLOWED DISRUPTIONS 1`. This answers the ADR's "check whether the chart creates the PDB".
- The chart's default anti-affinity is only *preferred*, so it does not guarantee different nodes. The values use a `topologySpreadConstraints` entry with `DoNotSchedule` (kept in `r3e-kyverno-values.yaml`).
- Resources applied as in the ADR: admission request 250m CPU / 256 MB, limit 512 MB, no CPU limit.
- Sanity: golden dry-run admitted 3 of 3 (14.6, 12.4, 12.3 s; the first is cold), unsigned denied by policy in 6.3 s. These match the laptop numbers of R3c (cold about 14 to 15 s, warm about 13 s).
- The resource validating webhook configuration holds 3 webhooks, one per policy (fine-grained, own timeout).

## Step 1 — spreading and PDB drain (done)

Method: `r3/tools/r3e-step1.sh`. Two probe loops (offset by 2 s) dry-run the UNSIGNED image back to back, a third loop records pod states and whether the Kyverno resource webhook configuration exists. Action 1: `kubectl drain` of the worker that hosts one admission replica. Action 2: while the first node is still cordoned and the replacement replica is Pending, `kubectl drain` of the other worker. Raw: `R3e/step1-timeline.csv`, `R3e/step1.out`.

Results:
- Before: one replica per worker. After the first drain: the evicted replica's replacement stays **Pending** (event: "didn't match pod topology spread constraints", then "unschedulable"); the other replica keeps running. `ALLOWED DISRUPTIONS` falls to 0.
- Gate during the first drain: 25 of 25 unsigned probes denied by policy (max 9.7 s). Webhook configuration present in all 63 samples.
- Second drain (the last Ready replica): **blocked by the PDB** ("Cannot evict pod as it would violate the pod's disruption budget", retried every 5 s, gave up at the 45 s timeout). The last Ready replica was never evicted. Gate during that: 24 of 24 unsigned probes denied (max 10.2 s).
- Side effect: the second drain did evict the single-replica Kyverno controllers on that node (reports, background, cleanup). They have no PDB. Their replacements were Pending while both nodes were cordoned, and came back after `uncordon` (about 2 minutes later). Policy reports are not produced while the reports controller is away.
- After `uncordon` both nodes: the Pending replica started on the freed worker within about 3 minutes of the first drain; 2 Ready replicas on 2 different nodes again.

What this shows: with hard spreading and 2 workers, draining one node leaves one replica (the gate stays up) and the second drain is refused by the PDB. It also shows the cost of hard spreading: **with only 2 schedulable nodes, a drained node leaves the cluster running with 1 replica until the node is back** (the replacement cannot go next to the survivor). With 3 or more workers the replacement would be scheduled elsewhere.

## Step 2 — namespace exclusion and break-glass recovery (done)

Method: dry-runs and real creates in `kube-system`, `kyverno`, `platform-tools`, `app-demo` with the UNSIGNED image and with plain pods (`nginx`, `pause`). Raw output was read live; the rehearsal commands are in this section. Policy exclusion by `kubectl patch` of `spec.matchConstraints.namespaceSelector` on the three policies.

Exclusion results:
- Chart default: unsigned admitted in `kube-system` and `kyverno` (excluded), denied in `platform-tools` and `app-demo`.
- A policy-level `namespaceSelector` (`kubernetes.io/metadata.name NotIn [platform-tools]`) on all three policies is **merged with the chart's exclusions** in each webhook configuration (the webhooks then list three NotIn rules). Result: unsigned admitted in `platform-tools`, still denied in `app-demo`. It took under 15 s to take effect. So decision 10 can be implemented per policy, in the policy files, without touching Kyverno's own config.

Break-glass rehearsal. How I broke Kyverno: NetworkPolicy is not enforced by this cluster's kindnet (tested: no effect), so I emptied the endpoints of `kyverno-svc` (changed its selector) and killed both admission containers to reset the API server's kept-alive connections (without the kill the API server kept talking to the old connections and nothing failed). The webhook configurations stay present, as in a crash. This is a simulation of "Kyverno up but unreachable", not a real fault.
- Broken state: every pod create is refused, **including plain `nginx` and `pause` pods in an application namespace** (message: "failed calling webhook ... connection refused"), within 1 s. This confirms the last runbook row ("everything is refused, including simple pods").
- **Deleting the webhook configurations does not recover while Kyverno is running**: both kinds were deleted in 1.3 s and Kyverno re-created them within 2 s; 14 consecutive plain-pod creates over 34 s all failed.
- **What works: stop the admission controller first.** `kubectl scale deploy kyverno-admission-controller --replicas=0` removed the resource webhook configuration within about 5 s of the command (the first create 1 s after still failed); from then on 9 of 9 plain creates succeeded for 34 s, and an UNSIGNED image was also admitted (the gate is open while Kyverno is scaled down, by design of the recovery).
- Restore: fix the Service selector, scale back to 2: both replicas Ready in 45 s, webhook configuration back, gate verified again (unsigned denied in 7.3 s, golden admitted in 13.8 s, plain pod admitted in 0.4 s).

Consequence for the break-glass text: "delete the Kyverno webhook configurations (Kyverno recreates them)" is incomplete. The tested procedure is **scale the admission controller to 0 (this removes the webhooks), do the repair, scale back to 2**, and know that the gate is open during that time. Deleting the configurations by hand only helps if Kyverno cannot recreate them (for example when no admission controller is running).

## Step 3 — two admission replicas under failure (done)

Method: `r3/tools/r3e-step3.sh <part>`. Two probe loops (offset 2 s) dry-run the UNSIGNED image back to back, a state loop records pod states and the presence of the resource webhook configuration every 2 s. Outcomes: `denied-by-policy` = gate up; `admitted` = gate OPEN (a failure); `webhook-failure` = gate down, closed by `Fail`. Raw: `R3e/step3-timeline.csv`, `R3e/step3-*.out`.

### Part 1: delete the leader, delete the other replica, rollout restart (2 replicas, PDB, hard spread)
- Delete leader: 30 of 30 probes denied by policy (max 9.5 s). Delete the non-leader: 31 of 31 denied (max 10.1 s). Rollout restart: 36 of 36 denied (max 11.5 s). The webhook configuration was present in every state sample. **97 of 97 unsigned probes denied, no gap, no refusal window** (same result as R3c item 3b with a manual PDB).

### Finding A: hard spreading on 2 workers stalled the rollout (and how it was fixed)
- During the rollout-restart run, the new ReplicaSet's pod stayed **Pending for the whole run (9+ minutes; the rollout never finished)**: events "2 node(s) didn't match pod topology spread constraints, 1 node(s) had untolerated taint(s)". The Deployment strategy is `maxSurge: 1`, `maxUnavailable: 40%` (= 0 for 2 replicas), so a third pod must be placed before any old one is removed, and it cannot be. The gate stayed up (the two old replicas kept serving), but **any Helm upgrade or `rollout restart` would hang**.
- Cause (inferred from the fix working): with the default `nodeTaintsPolicy: Ignore`, the tainted control-plane node counts as a topology domain with 0 pods, so putting a third pod on a worker gives a skew of 2 against the empty control plane.
- Fix tested: add `nodeTaintsPolicy: Honor` to the constraint (kept in `r3/tools/r3e-kyverno-values.yaml`). `helm upgrade` then completed in 82 s with one replica per worker. Verified by the repeat run below (`rollout-restart-fixed`).
- With `Honor`, the constraint still forbids two replicas on one node, as wanted; so on a cluster with exactly 2 schedulable nodes a node drain or failure still leaves 1 replica until the node returns (step 1). Needs 3 workers for a replacement to be placed.

### Part 2: rollout restart again with the fix, both replicas down, node stop, out-of-memory kill
Same probes and state loop. "Window" = from the first to the last probe that got a webhook failure (the gate was closed by `Fail`). In no scenario was an unsigned image admitted: **0 of 329 probes in all of step 3**. The webhook configuration was present in every state sample of every scenario (also after the graceful deletion of both pods).

| Scenario (2 replicas, PDB, hard spread with `Honor`) | Unsigned probes | Refusal window (gate closed) |
| --- | --- | --- |
| Rollout restart (with the fix) | 37 denied, 0 failures | none; the rollout completed |
| Delete BOTH pods at once (graceful) | 23 denied, 28 webhook failures | about 41 s (from the delete until the new pods were Ready); one probe waited 31 s (the 30 s webhook cap) |
| Kill BOTH containers (crash, no graceful stop) | 27 denied, 28 webhook failures | about 13 s; failures are fast ("connection refused", up to 4 s) |
| Stop the node that hosts a replica (`docker stop -t 0`, node down for 3 min, then started) | 52 denied, 0 failures | none seen. Node marked NotReady about 40 s after the stop; probes took up to 16 s (normal 6 to 13 s) |
| Out-of-memory kill of one replica (cgroup `memory.max` capped to 40 MB; `lastState=OOMKilled`) | 29 denied, 8 webhook failures | about 6 s around the kill; the killed replica needed more than 20 s to be Ready again, the gate stayed up on the other replica |

Notes and limits:
- Both-down scenarios close the gate for 13 to 41 s under `Fail`: this is the real cost of `Fail` that decision 1 accepts; it is bounded by how fast the replicas come back (HDD node, so slow here).
- The graceful deletion of both pods did **not** remove the webhook configurations (state samples: present all the time), unlike scaling the deployment to 0 (step 2). So pod deletion is a refusal window, not an open gate.
- Node stop: no refusals were seen even though a replica's pod IP became unreachable for the whole 3 minutes. I do not know why the API server never hit the dead endpoint (likely it kept using its connection to the healthy replica); do not generalize from one run.
- OOM: the 8 failures start about 3 s before the cap command was issued (one 2.4 s refusal at 23:03:13), so at least one is not caused by the kill; the cause of that early one is unknown (the restore step of the previous scenario had just finished). The OOM was produced by capping the container's cgroup, not by a real memory leak. Kyverno's `restarts` counters include the earlier scenarios.
- Kyverno's leader changes when its pod goes away; no effect on admission was visible (admission is served by all replicas).
- The 3 nodes are Docker containers on one machine, so "node failure" here is a container stop, not a network partition or a hung kubelet.

## Step 4 — cache and TUF blocked after a warm-up (done; the result is not what ADR-002 assumes)

Question (R3e item 6, supports the answer to spec section 11): is an image that was verified before still admitted when TUF becomes unreachable?

Method: 1 admission replica (the verify cache is per replica). TUF is blocked in CoreDNS (NXDOMAIN for `tuf-repo-cdn.sigstore.dev`, with the `log` plugin to see the queries), so the controller is **not** restarted (a restart would empty both the verify cache and the pod's local TUF data). Scripts `r3/tools/r3e-step4.sh` (3 policies, then signature only) and `r3e-step4b.sh` (positive control). Raw: `R3e/step4a-*`, `R3e/step4b-*`.

Run 1 was discarded (`R3e/step4-DISCARDED-run1-*`): my script saved an empty CoreDNS config (the snap `kubectl` prints nothing when its output is redirected to a file without `| cat`, the known trap) and applied it, which took all cluster DNS down; the denials in that run were a total DNS outage, not a TUF block. CoreDNS was restored from the saved kind default and the script now refuses an empty or changed Corefile.

Results (step 4a, 3 policies, then signature only; step 4b, repeated with a positive control):
- Warm replica (pod already verified once on the open network), TUF blocked: **golden admitted (12.1 s, 12.8 s, 13.0 s) and a never-verified image (`rekor-v2`) admitted (11.2 s, 12.2 s)**, with all three checks. The CoreDNS log shows **no query at all for the TUF host** during these admissions. Signature-only policy: golden 1.7 to 1.8 s (signature cache hit), new image 9.8 s, admitted.
- Positive control: a **fresh** replica (rollout restart, empty local state) under the same block: golden and the new image both denied in 1.7 to 2.1 s; the controller log says `failed to initialize TUF client (mirror="https://tuf-repo-cdn.sigstore.dev")`; CoreDNS shows the queries answered NXDOMAIN. After unblocking, golden admitted again (14.9 s). So the block works, and the warm replica really did not need TUF.

What this means (tested here; limits below):
- **The TUF dependency is at controller start, not at every cold verification.** A running admission controller that has initialised its TUF data once keeps verifying (signature and both attestations, also for images it has never seen) while TUF is unreachable. A replica that starts during a TUF outage (restart, rollout, scale-up, rescheduling after a node failure) denies every image-policy pod until TUF is reachable. This differs from R3a / R3c, which tested with freshly restarted controllers and concluded "required on every cold verification".
- The sentence in the R3c section 11 draft ("images already verified and still cached are admitted without contacting TUF") is **true but too narrow**: with a warm replica, even unseen images pass.
- Not established: how long a replica keeps working without TUF (the signed TUF metadata expires in about a week; the pod keeps it in memory or in an `emptyDir`, I did not look; my warm-pod tests lasted a few minutes after initialization; the cluster has pods that will be much older by the end of R3e, see the final long-pod check if it was run). Not tested: a TUF hang (as opposed to a DNS refusal) on a warm replica, which is the other R3c failure type.

## Step 5 — in-cluster TUF mirror (done; the mirror works but changes the dependency instead of removing it)

Method: `r3/tools/r3e-tuf-sync.py` copies the public-good TUF repository (15 root versions, timestamp, snapshot, targets, 11 target files; 192 KB; takes 4.6 s) into a directory, checking the sha256 and length of every target against the signed `targets.json`. An nginx pod (`nginx:1.27-alpine`, namespace `tuf-mirror`, files in a ConfigMap, manifests in `R3e/tuf-mirror-deploy/mirror.yaml`) serves it as `http://tuf-mirror.tuf-mirror.svc`. The policies `r3e-mirror-{sig,sbom,vuln}` set `cosign.tuf.mirror` and `cosign.tuf.root.data` (root version 15, base64) on the attestor. Script `r3e-step5.sh`, raw `R3e/step5-raw.csv`, `R3e/step5.out`.

Results:
- **Kyverno 1.19.1 accepts a plain `http://` in-cluster mirror** (`tuf.mirror` + `tuf.root.data`): golden admitted (12.7 s), unsigned denied (3.8 s). The nginx log shows the controllers fetching `timestamp.json`, `166.snapshot.json`, `14.targets.json` and `trusted_root.json` with the user agent `sigstore-go`. `trusted_root.json` is fetched through the mirror, so no other host is needed for the trust material.
- Public TUF blocked in DNS and both controllers restarted (empty local state): golden admitted twice (12.2 s, 10.7 s), unsigned denied (4.0 s), **0 DNS queries for the public TUF host**. This is the case that is denied without the mirror (step 4b).
- **Mirror DOWN, controllers already warm: golden, a never-seen image and unsigned were all denied in 1.5 to 1.8 s.** Mirror down and controllers restarted: also denied (cause in the log: `failed to initialize TUF client (mirror="http://tuf-mirror.tuf-mirror.svc")`). Mirror back: the same pods admitted golden at once (11.0 s), fresh pods too (12.2 s).
- **With a configured mirror the mirror is contacted on every admission**: 4 `timestamp.json` requests per golden admission (twice in a row: +4, +4) and 6 for the unsigned one; none while idle (0 in 60 s). The warm-controller tolerance of step 4 (no TUF contact at all) belongs to the default configuration without a `tuf` block; a policy with `tuf.mirror` re-checks the metadata on every verification (observed; why is not known).
- Refresh: the TUF *timestamp* metadata is what expires. Upstream today: timestamp v804 expires in 6 days 19 h (2026-10-16), snapshot and targets expire in 2036 and 2036. A re-sync after about 1 hour returned an identical copy, so upstream re-signs the timestamp rarely; a daily sync is more than enough. When the mirror's timestamp expires, every client rejects it (TUF rule) and, by the observation above, every admission would be refused at once. This expiry was not simulated (I cannot forge a signed file).
- Sync does not verify TUF signatures (the client does, against the root it was given); it checks hashes. A refresh job needs: a daily CronJob running this sync into the ConfigMap or a volume, an alert on `timestamp_expires` less than 3 days away, and an alert on job failure. The job itself and its alerts were not built.

Consequence: the mirror removes the dependency on the public TUF service (also for fresh controllers during a Sigstore TUF outage) but makes the mirror an always-needed dependency of every admission: it needs at least 2 replicas, its own monitoring and the refresh job, and a stale mirror closes the gate for everything. Without a mirror, a warm replica survives a TUF outage (step 4) and only new or restarted replicas are affected. Which of the two is safer for the demo is a decision for the project owner; the measured facts are above.

## Step 6 — load with 2 admission replicas, design A (done)

Method: `r3/tools/r3e-step6.sh` (repeat of R3c item 5 on the 3-node cluster, 2 admission replicas, the three split policies, public TUF). L1: N simultaneous server-side dry-runs of golden (distinct names), cold = both replicas restarted just before, warm = 6 priming calls first (they spread over both replicas, so "warm" is partial: each replica has its own cache). L2: a Deployment of golden with N replicas, cold (controllers restarted, Deployment created with N) and warm (created with 1, then scaled to N). Per replica: validating reviews handled (each pod's metrics) and peak memory/CPU (`crictl stats` every 2 s). Raw: `R3e/step6-l1-raw.csv`, `step6-l1-meta.csv`, `step6-l2-meta.csv`, `step6-l2-timeline.csv`, `step6-stats.csv`, `step6-rerun-*`.

L1, simultaneous creations (R3c numbers for 1 replica, design A, in brackets):

| Mode, N | Admitted | Webhook timeouts | Other | Admitted p50 / max |
| --- | --- | --- | --- | --- |
| cold 5 | 5 | 0 | | 23.5 / 26.2 s |
| cold 10 | 5 | 5 (re-run) | | 26.1 / 30.7 s  [R3c: 5 of 10 timed out] |
| cold 20 | 7 | 13 | | 23.7 / 33.3 s  [R3c: 14 of 20 timed out] |
| warm 5 | 4 | 0 | 1 denied | 16.7 / 20.5 s  [R3c: 2 of 10 timed out in a warm 10] |
| warm 10 | 10 | 0 | | 21.4 / 28.4 s |
| warm 20 | 10 | 10 | | 23.4 / 30.4 s  [R3c: 14 of 20 timed out] |

- The first cold N=10 run is invalid: all 10 calls were denied in 4 s (the "failed to initialize TUF client" pattern of R3c item 1; the logs of that moment were lost with the pod restart, so the cause is not confirmed). It was re-run (`R3e/step6-rerun-*`): 5 admitted, 5 timed out.
- One "denied" in warm 5 is an unexplained denial (not read from the log in time).
- **Two replicas do not remove the burst problem**: from about 10 simultaneous creations (cold) and 20 (warm) a share of the webhooks still time out at 30 s, as with one replica; only the warm 10 case improved (10 of 10 against a few timeouts before). The work was split about evenly: validating reviews per replica 13/23, 36/30, 15/24, 36/36, 10/15 (the API server alternates between endpoints). Each replica has its own cache, so a "warm" burst is only half warm.
- Peak use per admission replica: memory 138 MB (the highest of all runs; the ADR value 512 MB limit leaves 3.7 times headroom), CPU peak 166% of one core (cold 20 on one replica). No restart, no OOM during the load.

L2, Deployments (R3c, 1 replica, design A: rollouts took 86 to 147 s, 1 FailedCreate in 8 rollouts):

| Run | First pod Ready | All pods Ready | FailedCreate events | Reviews A / B |
| --- | --- | --- | --- | --- |
| cold 10 | 86.4 s | 90.6 s | 0 | 13 / 23 |
| cold 20 | 97.2 s | 105.6 s | 0 | 36 / 30 |
| warm 10 | 71.6 s | 79.4 s | 0 | 15 / 24 |
| warm 20 | 12.9 s | 104.5 s | 0 | 36 / 36 |

- All 4 rollouts completed with 0 FailedCreate (R3c: 1 of 8), in 79 to 106 s: a little faster than the 86 to 147 s with one replica, but the same order of magnitude. The ReplicaSet creates pods gradually (timeline: 1, 2, 8, 16 pods over the first 85 s in warm 20), which is why rollouts do not hit the burst limit.
- The "first pod Ready 71.6 s" in warm 10 is odd for a Deployment that already had one running pod (the prime pod); not investigated.
- The background-scan cost was not repeated (it belongs to R3c item 5 and nothing in the two-replica setup changes it: the reports controller is a single replica).

Conclusion for the fallback rule (ADR-002 decision 2): measured on this laptop, the three-policy design with 2 replicas still shows webhook timeouts from 10 to 20 simultaneous pod creations and 79 to 106 s rollouts of 10 to 20 pods. A real cluster has faster disks and a closer registry; the rule says to measure there.

## Summary: what R3e changes for ADR-002 (nothing was edited in the ADR; for the project owner to decide)

What held up, as tested on the 3-node cluster with the ADR values: 2 replicas + PDB + spreading; no unsigned image was admitted in any failure scenario (0 of 329 probes in step 3, plus step 1); PDB blocks the drain of the last Ready replica; the Helm resource values survived all loads (peak 138 MB of 512 MB).

What the results contradict or add:
1. **Decision 4 (spreading):** `topologySpreadConstraints` with `DoNotSchedule` on 2 workers **stalls every rollout** (surge pod unschedulable, `maxUnavailable` rounds to 0) unless `nodeTaintsPolicy: Honor` is set (tested, in `r3e-kyverno-values.yaml`). The chart creates the PDB by itself for replicas > 1. With only 2 schedulable nodes a node drain or loss leaves 1 replica until the node returns (the replacement cannot sit next to the survivor); 3 or more workers avoid that.
2. **Context and decision 6 (TUF):** the dependency is at **controller start**, not on every cold verification. With the default configuration, a warm replica verified everything, also an image it had never seen, with TUF blocked; only fresh replicas (restart, rollout, scale-up, reschedule) are denied. The wording "needed on every cold verification" and the first sentence of the section 11 answer should say so. Open: how long a warm replica keeps working (not tested beyond minutes).
3. **Decision 6 (mirror):** an in-cluster `http://` mirror works in Kyverno 1.19.1, but with `tuf.mirror` configured **every admission contacts the mirror** (about 4 requests per admission), so a mirror outage or an expired mirror timestamp denies everything, warm replicas included. The mirror trades the external dependency for an internal one that needs 2 replicas, a daily sync and an expiry alert; the 1% trigger should be weighed against that. The sync script and the nginx manifest exist (`r3e-tuf-sync.py`, `R3e/tuf-mirror-deploy/mirror.yaml`); the refresh CronJob and alerts do not.
4. **Decision 10 and runbook (break-glass):** deleting the Kyverno webhook configurations does **not** recover a blocked cluster while Kyverno is running (re-created within 2 s). What worked: `kubectl scale deploy kyverno-admission-controller --replicas=0` (webhooks gone in about 5 s, all pods admitted, unsigned ones too), repair, scale back to 2 (Ready in 45 s). A per-policy `namespaceSelector` merges with the chart's exclusions and works for platform namespaces. The last runbook row ("Everything is refused") needs this recovery text.
5. **Decision 1 (cost of `Fail`):** with both replicas down, the gate is closed for 13 s (crash) to 41 s (graceful deletion of both pods) on this machine; one replica lost (delete, node stop, rollout, OOM kill): no refusal, or about 6 s for the OOM kill.
6. **Decision 2 (fallback rule):** two replicas do not fix bursts: cold 10 simultaneous creations still timed out 5 of 10, cold 20 13 of 20, warm 20 10 of 20 (R3c with one replica: 5/10, 14/20, 14/20). Rollouts of 10 to 20 pods took 79 to 106 s with no FailedCreate. Phase 1 must still measure on the real cluster.

Not done or not established: the long-lived warm replica without TUF (hours, metadata expiry), a TUF hang (rather than a DNS refusal) on a warm replica, expired mirror timestamp, real node failure with network partition, the mirror refresh job, the background scan under two replicas, and one unexplained denial each in warm 5 (step 6) and a 2.4 s refusal 3 s before the OOM cap (step 3).
