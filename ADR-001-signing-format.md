# ADR-001: Signing format and verification policy shape

Status: Accepted (2026-10-06) by the project owner; proposed 2026-10-02. Evidence: [RESULTS.md](RESULTS.md).

## Context

Forge signs images and attests an SBOM and a vulnerability scan in CI, and Kyverno must admit only what the pipeline produced. Risk R1 asked whether cosign 3.x's default bundle format works with Kyverno 1.19.1's `ImageValidatingPolicy`, on a registry with the native Referrers API and on one with only the tag-schema fallback.

## Decision

1. **Format: cosign 3.1.3 defaults.** Keyless signing from GitHub Actions (`id-token: write`), new bundle format, signatures and attestations stored as OCI referrers. No fallback flags (`--new-bundle-format=false`) and no cosign 2.x are needed. The amber and red outcomes of the spike plan are not triggered.
2. **Transparency log: Rekor v1, pinned explicitly.** Signing passes `--signing-config signing-config/rekor-v1-only.json` (Sigstore's `signing_config.v0.2.json` target, Rekor `https://rekor.sigstore.dev` v1 only, exactly one log, TSA `https://timestamp.sigstore.dev/api/v1/timestamp`). Reason: the public-good default can flip to Rekor v2 without a client upgrade, and that should not silently change what Forge signs into. Kyverno 1.19.1 admits both (T15), so this is a policy choice, not a compatibility one.
3. **Verification: one `ImageValidatingPolicy` plus a separate allowlist.**
   - Keyless attestor with an exact `subject` and `issuer`; no regex.
   - Four validations, each with a `messageExpression` that names the failing image and the cause: signature, CycloneDX SBOM (`extractPayload(...).predicate.bomFormat == 'CycloneDX'`), vulnerability attestation verified, and vulnerability scan fresh within `duration('168h')` (`extractPayload(...).predicate.metadata.scanFinishedOn`). Verified and fresh are separate validations so a deny says "stale" or "missing or unverified", never both (T12).
   - Registry credentials: `credentials.secrets: [dockerhub-ro]`, a read-only Docker Hub token in a `dockerconfigjson` Secret in the `kyverno` namespace (avoids the anonymous pull limit; same mechanism R2 needs for ACR). Whether the credential is actually used was not separately proven (no wrong-password control).
- `failurePolicy: Fail`, `timeoutSeconds: 30` for the spike; the final values belong to ADR-002 (R3).
   - A separate `ValidatingPolicy` denies registries outside the allowlist, because an IVP skips images that its `matchImageReferences` does not match (T4).
4. **Keep the SBOM and vuln checks as the gate.** In the new bundle format an attestation satisfies `verifyImageSignatures` (T16), so "signed" does not prove the full pipeline ran.

## Pinned versions (as tested)

| Component | Version |
| --- | --- |
| cosign | v3.1.3 (via `sigstore/cosign-installer` v4.1.2, `cosign-release: v3.1.3`) |
| Kyverno | app v1.19.1, Helm chart kyverno-3.9.1, namespace `kyverno`, chart defaults |
| Kubernetes (kind node) | `kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0` |
| kind / helm / oras | v0.33.0 / v3.22.0 / v1.3.4 |
| Syft / Trivy | v1.51.1 / v0.74.0 (SHA-256 verified in the workflow) |
| Base image | podinfo 6.15.0, pinned by digest, plus `LABEL variant` |
| GitHub Actions | `actions/checkout` v7.0.1, `sigstore/cosign-installer` v4.1.2, both pinned by commit SHA |

## Policy constants (owned by the future `forge-factory`)

- Subject: `https://github.com/Taha7486/forge-spike-r1/.github/workflows/r1-sign-golden.yml@refs/heads/main`
- Issuer: `https://token.actions.githubusercontent.com`
- SBOM predicateType: `https://cyclonedx.org/bom`
- Vuln predicateType: `https://cosign.sigstore.dev/attestation/vuln/v1` (copied from what cosign wrote; the Kyverno docs' vuln example omits `https://`)

## Storage path per leg

- GHCR: tag-schema fallback (referrers endpoint returns 404). Works with cosign 3.1.3 and Kyverno 1.19.1. Each descriptor in the fallback index carries `artifactType: application/vnd.dev.sigstore.bundle.v0.3+json` (read 2026-10-05), so the cosign #4641 gap does not occur with 3.1.3.
- Docker Hub: native Referrers API (200).
- Consequence for R2: GHCR is a viable fallback registry for this bundle format; ACR is expected to use the native path, to be confirmed in R2.

## Transparency log observed

- Rekor v1 (golden, bigsbom): `dsse` 0.0.1, inclusion proof and inclusion promise present, one RFC 3161 timestamp per bundle.
- Rekor v2 (rekor-v2): `hashedrekord` 0.0.2, log `log2025-1.rekor.sigstore.dev`, inclusion proof present, no inclusion promise, one RFC 3161 timestamp per bundle.
- The public-good default signing config was Rekor v1 only on 2026-10-02.

## Consequences and debts

- **Latency is tight.** Admission takes 18–26 s against a 30 s maximum webhook timeout, because cosign makes many sequential round trips and the policy runs three verifications. Mitigations to decide in R3b and ADR-002: dropping `verifyImageSignatures` (redundant given decision 4), never re-signing an existing digest, and re-measuring against in-region ACR. This is the main risk carried into Phase 1.
- **Deny messages must stay dynamic.** A static message cannot tell a missing signature from a wrong identity or an infrastructure error; the controller log is the only place the real cause shows for some failures.
- **Identity patterns:** keep exact subjects; if a regex is ever needed, anchor it (`^…$`) and include the slash after the repo name (T7).
- **Freshness:** the 168h window makes long-lived images deniable. Freshness is renewed by rebuilding the image (new digest, fresh attestations), never by re-attesting an existing digest; re-attesting piles bundles onto the same digest and slows every admission.
- **Rekor v1 is a dependency on a log Sigstore may retire.** Spec demo 5 and `conformity` must read the entry from the bundle attached to the image, not search the log.
- **Environment (spike only):** node IPv6 egress, router DNS and the Docker Hub anonymous limit caused false denials (see RESULTS.md). Not properties of the design.

## Revisit triggers

- A new Kyverno minor (1.20 expected around November 2026): re-run T1–T13 first.
- Rekor v1 deprecation or a Sigstore change that makes pinning v1 unsupported: repeat T15 and move the pin to `rekor-v2-only.json`.
- Any cosign v4 release (removes the deprecated flags; none are used here).
- R2/R3 results that change the registry, the `timeoutSeconds` or the number of verifications.
