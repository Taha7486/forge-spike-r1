# forge-spike-r1

Phase 0 spike for Forge, risk R1: does cosign 3.x's default bundle format work with Kyverno 1.19.1's `ImageValidatingPolicy`, on a registry with the native Referrers API (Docker Hub) and on one with the tag-schema fallback (GHCR)?

**Outcome: Green.** Decision in [ADR-001-signing-format.md](ADR-001-signing-format.md) (Accepted), evidence per test in [RESULTS.md](RESULTS.md). R3 (Sigstore egress, latency, failurePolicy) reuses this repo's images and cluster.

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

- After a node restart, reapply the IPv6 workaround: `docker exec forge-spike-control-plane sysctl -w net.ipv6.conf.eth0.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1`. Never set `.all`: it breaks the API server's own webhook calls.
- The first admissions after boot or after a policy change often hit the 30 s webhook timeout; retry.
- Home-router DNS sometimes drops the A record for `tuf-repo-cdn.sigstore.dev`; CoreDNS caches the bad answer for 30 s. Wait and retry.
- The cluster does not auto-start any more (`docker update --restart=no`). Start it on a quiet machine and expect minutes.

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

Any one of these means stop and write the idea in [PARKED.md](PARKED.md) instead:

- A `package.json`, `.html`, `.css`, `.tsx`, `.jsx`, `.vue` or `.svelte` file outside a vendored upstream directory.
- `conformity` gaining `http.ListenAndServe`, `html/template` or a `--serve` flag (HTTP client calls, to Rekor for instance, are fine).
- A Grafana plugin instead of a dashboard JSON.
- Anything Backstage.
- A fifth repository beyond the four in spec §3.2.
- Notes saying "portal", "frontend for" or "my dashboard".

**Phase 1 task:** when Phase 1 creates the repos, each gets a CI job that fails on the file patterns of the first tripwire. Exclude the vendored upstream path (podinfo and Juice Shop ship HTML, CSS and `package.json`, so the check fails on day one without the exclusion).
