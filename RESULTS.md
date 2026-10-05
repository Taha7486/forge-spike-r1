# R1 results — cosign 3.1.3 bundles vs Kyverno 1.19.1

Date: 2026-10-02. Environment: kind v0.33.0 (node kindest/node v1.35.8), Kyverno chart 3.9.1 = app v1.19.1, policy API `policies.kyverno.io/v1`, `failurePolicy: Fail`, `timeoutSeconds: 30`. Signing: cosign v3.1.3 defaults (new bundle format), keyless, GitHub Actions OIDC.

Leg A = GHCR (tag-schema fallback). Leg B = Docker Hub (native Referrers API).

## Proposed outcome

Green. All of T1–T16 now have results on both legs where the plan asks for it; the former deviations are closed (struck through below). T1–T13 pass with cosign 3.1.3 defaults and no fallback flags; T14–T16 are recorded. The deviations are not failures but they limit what is proven, so ADR-001 should repeat them.

Deviations from the plan's "primary leg is B":

- ~~T7 ran on leg A only~~ closed 2026-10-06: the lookalike workflow now also pushes and signs to Docker Hub; re-run on leg B.
- ~~T13 passed on leg B only~~ closed 2026-10-06: retried on GHCR with the clean 3-bundle bigsbom variant, admitted with the digest appended. (The earlier timeout was golden's 5 bundles.)
- ~~T14 and T15 ran on leg A only~~ closed 2026-10-06: both re-run and admitted on Docker Hub after adding a read-only Docker Hub token as a Secret (`credentials.secrets: [dockerhub-ro]`).
- ~~T12's message could not tell "stale" from "unverified"~~ closed 2026-10-06: vuln check split into two validations; re-run on both legs.

## Matrix

| ID | Variant | Result | Evidence (deny messages are the API message; the cause is from the controller log where stated) |
| --- | --- | --- | --- |
| T1 | golden | Pass, both legs | `cosign verify` and `verify-attestation` (cyclonedx, vuln) rc=0; transparency log verified offline from the bundle |
| T2 | golden | Pass, both legs (Gate 1 green) | Admitted; log "verifying cosign image signature" |
| T3 | unsigned | Pass, both legs | Controller log: `failed to verify cosign signatures: no signatures found`. The API message at the time was static, which is why the policy now builds dynamic messages |
| T4 | docker.io nginx | Pass | `image is outside the allowed registries (docker.io/taha7486/forge-spike-r1, ghcr.io/taha7486/forge-spike-r1); denied by r1-registry-allowlist`. The IVP skips images its `matchImageReferences` does not match, so a separate allowlist policy is required |
| T5 | other-workflow | Pass, leg B | Signed by `r1-other-workflow.yml@main` (confirmed). Log: `no matching CertificateIdentity found` |
| T6 | branch | Pass, leg B | Signed by `r1-sign-golden.yml@refs/heads/spike/branch` (confirmed). Same log cause |
| T7 | lookalike | Pass, both legs | GHCR (first session, signature-only policy): exact subject denied, `no matching CertificateIdentity`; unanchored `subjectRegExp` (`…forge-spike-r1.*r1-sign-golden.yml@refs/heads/main`, no slash after the repo name) ADMITTED the lookalike; exact subject restored, lookalike denied, golden admitted. Docker Hub (2026-10-06, full policy): lookalike `sha256:bc86a3fd…536df` (same digest on both registries, one signature bundle each) signed by `…/forge-spike-r1-lookalike/.github/workflows/r1-sign-golden.yml@refs/heads/main`. Exact subject: denied, `no valid signature from the forge-spike-r1 signing workflow for: <image>`, log `no matching CertificateIdentity found … expected SAN …/Taha7486/forge-spike-r1/.github/…, got …/Taha7486/forge-spike-r1-lookalike/.github/…`. Loosened regex: the signature validation passed (message changed to `missing or invalid CycloneDX SBOM attestation`, log `required predicate type https://cyclonedx.org/bom not found, found [https://sigstore.dev/cosign/sign/v1]`), so the loose regex let the impostor's signature through and the test bites; the full policy still denied it only because the lookalike carries no SBOM or vuln attestation. Exact subject restored: lookalike denied again, golden admitted (20 s warm) |
| T8 | keysigned | Pass, both legs | Log: `failed to verify log inclusion: transparency log certificate does not match`. Controller restarts 0 before and after (no #16435 crash on 1.19.1). The wording mentions attestations for a signature check, but the class of cause is right |
| T9 | golden | Pass, both legs | Payload path is `extractPayload(...).predicate.bomFormat` (the plan's form without `.predicate` fails with "no such key") |
| T10 | golden | Pass, both legs | Path `.predicate.metadata.scanFinishedOn`; `duration('168h')` compiles |
| T11 | nosbom | Pass, both legs | `missing or invalid CycloneDX SBOM attestation for: <image>`. Variant `nosbom2` (signed by the trusted workflow); the first `nosbom` was signed by the wrong workflow and was discarded |
| T12 | golden | Pass, both legs (re-run after the policy split) | First run (ambiguous message): `missing, unverified or stale (older than 10m) vulnerability attestation for: <image>`. Policy then split into `vulnunverified` and `vulnstale`. Re-run 2026-10-06 with `duration('10m')`, GHCR and Docker Hub: `stale vulnerability attestation (scanFinishedOn older than 10m) for: <image>`; the "missing or unverified" validation did not fire. Restored 168h: golden admitted on both legs (GHCR 24 s, Hub 20 s warm). Split added no verifications (one vuln verification line in the log). `duration('7d')` is rejected at policy admission: `invalid duration argument` |
| T13 | golden / bigsbom by tag | Pass, both legs | Hub (golden): admitted spec image `docker.io/taha7486/forge-spike-r1:golden@sha256:f5eb8b57…c7c7d5` (tag kept, digest appended, equals golden's). GHCR (retried 2026-10-06 on the clean 3-bundle variant): `ghcr.io/taha7486/forge-spike-r1:bigsbom@sha256:ad28f1db…c91d3b`, equals bigsbom's digest; 31 s cold, 20 s warm. The first GHCR attempt on golden (5 bundles) timed out in validate at about 32 s, a latency result, not a verdict. A cold tag call can exceed 30 s because the mutate webhook (about 2 s) runs before the validate webhook, each with its own timeout |
| T14 | bigsbom | Pass, both legs | SBOM from Juice Shop v20.2.0 = 1,507,804 bytes; bundle blobs SBOM 2,021,553 B, vuln 276,388 B, signature 10,894 B. Rekor v1 accepted it. GHCR: 26 s cold, 18 s second run. Docker Hub (with the read-only credentials Secret): 26 s cold, 16 s second run |
| T15 | rekor-v2 | Pass, both legs | Signed and attested into Rekor v2 with a TSA timestamp; admitted. GHCR 25 s; Docker Hub 23 s cold, 15 s second run |
| T16 | attest-only | Recorded, leg B | No `sign/v1` bundle (confirmed with `oras discover`), SBOM and vuln bundles only: ADMITTED. In the new bundle format an attestation counts as a signature for Kyverno and for `cosign verify` |

## Recorded, not judged

### Storage path per leg

- Leg A (GHCR): referrers API answers 404; `oras` reports "unsupported". Tag-schema fallback (`sha256-<digest>` tag index). Works with cosign 3.1.3 and Kyverno 1.19.1 (T2).
- Leg B (Docker Hub): referrers endpoint returns 200, native API.
- Fallback index read 2026-10-05 (`sha256-<golden digest>` tag on GHCR): an OCI image index with 5 descriptors, each with `artifactType: application/vnd.dev.sigstore.bundle.v0.3+json`, identical to Docker Hub's native listing. So the artifact-type gap reported in cosign #4641 does not occur with cosign 3.1.3. (The index object itself has no artifactType, which is normal.)

### Signer identity and issuer (policy constants)

- Subject: `https://github.com/Taha7486/forge-spike-r1/.github/workflows/r1-sign-golden.yml@refs/heads/main`
- Issuer: `https://token.actions.githubusercontent.com`
- predicateType SBOM: `https://cyclonedx.org/bom`
- predicateType vuln: `https://cosign.sigstore.dev/attestation/vuln/v1`
- In the new bundle format the verify output leaves `.optional.Subject/Issuer` null; read the signer from the certificate or by exact-match probing.

### Transparency log evidence (from the bundles)

| | golden (Rekor v1, default) | rekor-v2 |
| --- | --- | --- |
| Entry kind and version | dsse 0.0.1 | hashedrekord 0.0.2 |
| Log origin | `rekor.sigstore.dev - 1193050959916656506` | `log2025-1.rekor.sigstore.dev` |
| Inclusion proof | yes | yes |
| Inclusion promise (SET) | yes | no |
| RFC 3161 timestamp | 1 per bundle | 1 per bundle |

The public-good default signing config was still Rekor v1 only on 2026-10-02. Forge pins Rekor v1 explicitly (`signing-config/rekor-v1-only.json`, exactly one log); decision recorded in ADR-001.

### Latency (indicative; home laptop to US/EU registries)

- Root cause measured with `cosign verify -d` on the host: cosign lists referrers, then fetches every bundle (manifest, blob, CDN redirect) sequentially, about 125 ms per round trip. golden (5 bundles): 34 requests, about 6 s per verification. nosbom2 (2 bundles): 16 requests, 3.5–4.4 s.
- The policy runs three separate verifications (signature, SBOM, vuln) with no reuse: about 20–25 s per admission. On GHCR, 3-bundle and 5-bundle images both took about 25 s, so bundle count is not the whole story; R3b will measure properly.
- SBOM size is not the driver: the 1.5 MB SBOM image took 18–26 s, the same as small ones.
- Webhook split: `ivpol.mutate` only resolves tag to digest (about 2 s, no verification); `ivpol.validate` does all verification.
- Not explained: the digest-form pod logged only the SBOM and vuln verification lines, with no "image signature" line. To check with verbose logs.

### Environment faults that produced false denials (none counted as a pass or a fail)

- After a node restart, IPv6 egress from the kind node hangs; Kyverno then times out at 30 s on every image call. Worked around with `sysctl net.ipv6.conf.eth0.disable_ipv6=1` and `net.ipv6.conf.default.disable_ipv6=1` inside the node (not `all`: it removes `::1` and breaks the API server's webhook calls). Not persistent.
- The home router's DNS intermittently returns only the AAAA record for `tuf-repo-cdn.sigstore.dev`. With node IPv6 disabled, Kyverno's TUF client then fails (`network is unreachable`), CoreDNS caches the bad answer for 30 s, and the policy denies with a static "no valid signature" message while the real cause is only in the controller log.
- Docker Hub's anonymous pull limit (`TOOMANYREQUESTS`) blocks Kyverno's tag resolution on leg B after many runs; a read-only Hub token as a Secret in the `kyverno` namespace is needed for more leg B work.

## Findings that change Phase 2

1. Deny messages must be built dynamically from the verification result (CEL `messageExpression`); a static message hides the cause. Implemented in `policies/r1-ivp.yaml`.
2. Anchor identity regexes (`^…$`) and include the slash after the repo name (T7).
3. Attestation counts as signature in the new bundle format (T16): "signed" does not prove the pipeline ran, so keep the SBOM and vuln checks as the gate.
4. Do not re-sign or re-attest a digest that already has bundles; each extra bundle adds round trips to every admission (golden has 5 bundles after the T-series re-runs).
5. `duration('7d')` is invalid; write hours.
6. The allowlist matches raw image strings, so short names such as `nginx:1.27` can bypass a `startsWith` on a full prefix; fine under deny-by-default, revisit in Phase 2.
7. Webhook timeout headroom is nil: 30 s is the Kubernetes maximum and admission takes 18–26 s here. Re-measure on in-region ACR.
8. Golden's vuln attestations are dated 2026-10-02; with the 168h window golden is denied from about 2026-10-09 unless `r1-sign-golden` is re-run with `variant=golden` (which adds bundles, see 4).
