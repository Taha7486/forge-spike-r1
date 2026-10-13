# forge-spike-r1

Phase 0 spike for Forge, risk R1: does cosign 3.x's default bundle format work with Kyverno 1.19.1's `ImageValidatingPolicy`, on a registry with the native Referrers API (Docker Hub) and on one with the tag-schema fallback (GHCR)?

**Outcome: Green.** Decision in [ADR-001-signing-format.md](ADR-001-signing-format.md) (Accepted), evidence per test in [RESULTS.md](RESULTS.md). R3 (Sigstore egress, latency, failurePolicy) reused this repo's images; it is closed, with the decision in [ADR-002-failure-policy.md](ADR-002-failure-policy.md) (Accepted) and the evidence in `r3/`.

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
| `ADR-001-signing-format.md`, `ADR-002-failure-policy.md` | The two decisions of Phase 0 |
| `RESULTS.md` | R1 evidence per test |
| `r3/` | R3 work: results (`R3a` to `R3e`), the pre-study, the extra policies in `policies/r3*`, raw data, and `tools/` (latency loop, failure tests, cluster scripts) |

The lookalike signer for T7 lives in the sibling repo `forge-spike-r1-lookalike`.

## Versions

Exact pins and digests are in ADR-001. In short: cosign v3.1.3, Kyverno app v1.19.1 (chart 3.9.1), kind v0.33.0 on `kindest/node:v1.35.8` (digest-pinned), helm v3.22.0 (3.x on purpose, to keep chart variables down), oras v1.3.4, Syft v1.51.1, Trivy v0.74.0. Actions are pinned by commit SHA, not tag.

Phase 1 tools (installed 2026-10-11 in `~/.local/bin`, downloads checked against the publisher's signature): Terraform v1.16.5 (official HashiCorp binary; the unpinned, self-updating snap was removed), AWS CLI v2.37.12 (installed under `~/.local/aws-cli`), tflint v0.64.0 (checksums file verified with cosign keyless; its AWS ruleset plugin 0.49.0 is pinned in `.tflint.hcl` of the separate public repo `forge-infra`, where the Terraform lives).

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
- The R3e cluster `forge-r3e` (kind, 1 control plane + 2 workers, context `kind-forge-r3e`, Kyverno 1.19.1 with the ADR-002 values) is STOPPED. Resume: `docker start forge-r3e-control-plane forge-r3e-worker forge-r3e-worker2`, wait for Ready, then `kubectl --context kind-forge-r3e -n kyverno get pods | cat`. Stop: `docker stop -t 180` on the three nodes (exit 130 is normal). Rebuild: `r3/tools/r3e-up.sh`. `r3/tools/cluster-up.sh` and `cluster-down.sh` still name the old, deleted `forge-spike` cluster.

## Runbook: confusing refusals (ADR-002, decision 11 and Addendum 1)

| What you see | What it really means | What to do |
| --- | --- | --- |
| "no valid signature" or "missing or unverified attestation", in about 2 s | Most likely Sigstore's TUF service was unreachable (DNS failure or refused connection) for an admission controller that **just started**, not a bad image. Running replicas keep verifying while TUF is down. | Read the admission controller log; if it names the TUF address or DNS, retry once |
| The same message after about 30 s | The TUF service is hanging | Check the service; new or restarted replicas stay blocked until it recovers, running pods are fine |
| "error: failed to evaluate policy ... dial tcp ..." | The registry or its download servers are unreachable | Check registry access and the egress allowlist |
| "no valid signature" after about 8 s on a new image | The image really is not signed by the pipeline | Fix it in CI |
| Any refusal | The policy named is only the first of the three to answer, not necessarily the only reason | Read the log for the full cause |
| Everything is refused, including simple pods ("failed calling webhook ... connection refused") | Kyverno is down or unreachable and `Fail` is on | Check the 2 admission replicas and wait a few seconds. If it persists, use the emergency procedure below |

Emergency procedure (tested in R3e): deleting the Kyverno webhook configurations does **not** help while Kyverno runs (they come back in 2 s).
1. `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=0` (the webhooks disappear in about 5 s).
2. Repair what is broken.
3. `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=2` (Ready in about 45 s).

**The gate is open while the controller is scaled to 0: unsigned images are admitted.** Emergency use only, and scale back to 2 as soon as possible.

## Scope tripwires (R5)

Any one of these means stop and write the idea in [PARKED.md](https://github.com/Taha7486/forge-gitops/blob/main/PARKED.md) (moved to the `forge-gitops` repo in Phase 1) instead:

- A `package.json`, `.html`, `.css`, `.tsx`, `.jsx`, `.vue` or `.svelte` file outside a vendored upstream directory.
- `conformity` gaining `http.ListenAndServe`, `html/template` or a `--serve` flag (HTTP client calls, to Rekor for instance, are fine).
- A Grafana plugin instead of a dashboard JSON.
- Anything Backstage.
- A fifth repository beyond the four in spec §3.2.
- Notes saying "portal", "frontend for" or "my dashboard".

These are written rules checked by hand. A CI check for the first tripwire was considered and dropped on 2026-10-10.
