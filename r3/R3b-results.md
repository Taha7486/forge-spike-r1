# R3b — Admission latency (2026-10-07)

Method: `kubectl apply --dry-run=server -f <manifest>`, timed wall-clock. 20 valid samples per case. Raw data: `R3b-raw.csv` (every attempt, with cause for non-admitted ones); first discarded attempt: `R3b-discarded-attempts.csv`.

## Environment
- kind cluster `forge-spike` (k8s v1.35.8), single node, spinning HDD. Kyverno admission controller limit 768 Mi (raised from Helm default), others 512 Mi.
- Wait for I/O pressure avg10 < 8 before each sample. `failurePolicy: Fail`, `timeoutSeconds: 30` (the Kubernetes maximum).
- Cold = `rollout restart` of the admission controller, 20 s settle, I/O wait, then one call. Image: golden `sha256:f5eb8b57...` unless noted. Policies: `r3b-sigonly.yaml`, `r3b-nosigcheck.yaml`, `r3-ivp.yaml` (full), `r1-registry-allowlist` and `p3-deny-test-label` live throughout.
- Sanity: `unsigned` is denied on dry-run (no valid signature).

## Results (admitted samples only; p50 / p95 by linear interpolation)

| Case | Policy | n | p50 | p95 | min-max | Non-admitted attempts |
| --- | --- | --- | --- | --- | --- | --- |
| 1. baseline | none | 20 | 0.30 s | 0.36 s | 0.29-0.43 | 0 |
| 2. signature only, cold | r3b-sigonly | 20 | 14.48 s | 15.79 s | 13.41-15.84 | 6 denied (TUF init) of 26 |
| 2b. attestations only, cold | r3b-nosigcheck | 20 | 25.77 s | 29.16 s | 23.47-29.44 | 4 denied (TUF init), 2 timeout, of 26 |
| 3. full, warm | r3-ivp | 20 | 23.79 s | 24.87 s | 22.24-25.70 | priming call: 20 timeout, 3 denied (TUF init) |
| 4. full, cold (golden) | r3-ivp | 0 | - | - | - | 27 timeout (30.3-30.5 s), 3 denied (TUF init) of 30 |
| 5. full, cold, bigsbom (3 bundles) | r3-ivp | 20 | 27.97 s | 29.91 s | 27.40-30.16 | 1 timeout of 21 |

Case 3 protocol: restart, one priming call (every one timed out at 30 s or hit TUF init), 45 s pause so the server-side verification completes, then the timed warm call. A TUF-init denial on the priming call invalidates the attempt (cache not filled).

## Findings
1. Cold full-policy admission on golden does not complete within 30 s (0 of 30 attempts). After any admission-controller restart, the first pod with a signed image is rejected or times out (`failurePolicy: Fail`). True cold time is above the cap and cannot be read from the client timer.
2. Warm is not fast: ~24 s. The signature result is cached (ttl 1h) but the two attestations are re-verified on every admission. Close to the 30 s cap.
3. Cost is dominated by attestation verification, not the signature: signature only 14.5 s cold; attestations only 25.8 s cold; both above 30 s cold.
4. Dropping `verifyImageSignatures` (redundant under ADR-001 decision 4) saves little in the full policy: attestation-only cold is 25.8 s, near the cap and with 2 timeouts in 26 attempts.
5. Bundle count matters: bigsbom (3 bundles, 1.5 MB SBOM) completes cold in ~28 s, golden (5 bundles) does not. The 1.5 MB SBOM was not the dominant cost.
6. TUF init failure on a fresh controller: 13 of 56 cold attempts in cases 2 and 2b (23%), plus 3 of 30 in case 4 and 3 of 23 in case 3 priming. Denied in about 2 s with a message worded "no valid signature ..."; the real cause is only in the controller log (`failed to initialize TUF client (mirror=https://tuf-repo-cdn.sigstore.dev)`). Runbook input: misleading message; transient; retry succeeds. Not investigated further (cause of the transient failure unknown).
7. Latency numbers are for this machine (HDD, kind); treat them as relative, not absolute.

## Open for R3c / ADR-002
- `cosign.trustedRoot` to remove the TUF dependency (also may remove finding 6).
- Ways to fit the 30 s cap: fewer/lighter attestations, fewer bundles, or checking attestations outside admission.
- Whether `failurePolicy: Ignore` changes timeout and TUF-denial outcomes (carried from R3a).
