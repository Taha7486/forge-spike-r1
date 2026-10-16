# forge-spike-r1

> **Closed.** Phase 0 evidence for risk R1 (and R3). Nothing here is maintained; the product code is in `forge-infra`, `forge-factory` and `forge-gitops`.

Phase 0 spike for Forge, risk R1: does cosign 3.x's default bundle format work with Kyverno 1.19.1's `ImageValidatingPolicy`, on a registry with the native Referrers API (Docker Hub) and on one with the tag-schema fallback (GHCR)?

**Outcome: Green.** Decision in ADR-001 (Accepted; kept in the private Forge docs repo, `docs/decisions/`), evidence per test in [RESULTS.md](RESULTS.md). R3 (Sigstore egress, latency, failurePolicy) reused this repo's images; it is closed, with the decision in ADR-002 (Accepted; same place) and the evidence in `r3/`.

## Layout

| Path | What |
| --- | --- |
| `.github/workflows/r1-sign-golden.yml` | Builds, signs and attests variants (inputs: `variant`, `sign`, `sbom`, `signing_config`, `sbom_image`). Its path and branch are the trusted signer identity |
| `.github/workflows/r1-variants.yml`, `r1-other-workflow.yml` | Identity and variant fixtures for T3, T5, T8 |
| `.github/workflows/p1-*, p2-*` | Prerequisite checks (cosign version, first push) |
| `policies/r1-ivp.yaml` | The `ImageValidatingPolicy`: signature, SBOM, vuln verified, vuln fresh, with dynamic deny messages |
| `policies/r1-registry-allowlist.yaml` | Separate `ValidatingPolicy` (an IVP skips images it does not match) |
| `signing-config/` | Pinned cosign signing configs: `rekor-v1-only.json` (used) and `rekor-v2-only.json` (T15) |
| `tests/` | One Pod manifest per test and leg (`r1-t<N>-…-hub|ghcr.yaml`) |
| `Dockerfile` | The thin image the variants are built from (pinned podinfo plus `LABEL variant`) |
| `RESULTS.md` | R1 evidence per test |
| `r3/` | R3 work: results (`R3a` to `R3e`), the pre-study, the extra policies in `policies/r3*`, raw data, and `tools/` (latency loop, failure tests, cluster scripts). Start with `r3/README.md` |

The lookalike signer for T7 lives in the sibling repo `forge-spike-r1-lookalike`.

## Versions

Exact pins and digests are in ADR-001. In short: cosign v3.1.3, Kyverno app v1.19.1 (chart 3.9.1), kind v0.33.0 on `kindest/node:v1.35.8` (digest-pinned), helm v3.22.0 (3.x on purpose, to keep chart variables down), oras v1.3.4, Syft v1.51.1, Trivy v0.74.0. Actions are pinned by commit SHA, not tag.

## Notes

- `gh` is intentionally not installed: the repos were created in the web UI and no token lives on the laptop. Workflows are started from the Actions page.
- Images stay public on GHCR and Docker Hub on purpose (no credentials needed to pull).
- The Docker Hub tokens were deleted at R1 close. `r1-sign-golden.yml` and the lookalike workflow log in to Docker Hub unconditionally, so new runs fail until a new token and the `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets exist.
- Golden and the variants carry vuln scans from 2026-10-02, outside the policy's 168h window from about 2026-10-09. Freshness is renewed by rebuilding, not by re-attesting (ADR-001).

## Running a test

1. `kubectl apply -f policies/r1-ivp.yaml`, then `kubectl get ivpol | cat` must show Ready.
2. `kubectl apply --dry-run=server -f tests/<pod>.yaml | cat` runs admission without creating the pod.
3. Count a result only if the message names the expected cause. Confirm it in the admission controller log (`kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller`): a webhook timeout, a TUF or DNS error, or a registry rate limit is not a deny.

## Environment traps (this laptop, kind on a spinning disk)

- The snap-installed `kubectl` prints nothing in a non-interactive shell unless its output is piped: append `| cat` to every kubectl command, and never redirect kubectl output straight to a file (an empty CoreDNS config once broke cluster DNS that way).
- The first admissions after boot or after a policy change often hit the 30 s webhook timeout; retry.
- Home-router DNS sometimes drops the A record for `tuf-repo-cdn.sigstore.dev`; CoreDNS caches the bad answer for 30 s. Wait and retry.
- Kind clusters do not auto-start (`docker update --restart=no`). Start them on a quiet machine (I/O pressure avg10 well under 8: `awk '/^some/' /proc/pressure/io`) and expect minutes.
- The R3e cluster `forge-r3e` (kind, 1 control plane + 2 workers, Kyverno 1.19.1 with the ADR-002 values) was deleted on 2026-10-11. Rebuild: `r3/tools/r3e-up.sh`. `r3/tools/cluster-up.sh` and `cluster-down.sh` still name the old, deleted `forge-spike` cluster.

## Moved out

The runbook for confusing refusals from the gate (ADR-002) and the scope tripwires (R5) are live project rules, not spike evidence. They moved to the `forge-gitops` repo: [RUNBOOK.md](https://github.com/Taha7486/forge-gitops/blob/main/RUNBOOK.md) and [PARKED.md](https://github.com/Taha7486/forge-gitops/blob/main/PARKED.md). Terraform and its tool pins are in `forge-infra`.
