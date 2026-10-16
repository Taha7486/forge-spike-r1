# r3/ — evidence for risk R3

R3 asked what the admission gate depends on, how long it takes and what happens when a dependency fails. The decisions are in ADR-002 (kept in the private Forge docs repo, `docs/decisions/`). This folder is the evidence behind them. Read the `*-results.md` files; the rest is raw data they cite by file name, so nothing here is renamed or moved.

## Where to start

| File | What it answers |
| --- | --- |
| `R3a-results.md` | What Kyverno contacts at admission (TUF, the registry and its blob CDN; not Rekor or Fulcio) |
| `R3-prestudy.md` | Where the time goes in a cold admission (steps 1 to 9, including the trusted root file) |
| `R3b-results.md` | Admission latency, 20 samples per case |
| `R3c-results.md` | Items 1 to 6: the TUF-init denials, latency of the candidate designs, failure modes, observability, load, conclusions. Long; item 6 is the summary |
| `R3e-results.md` | Steps 0 to 6 on a 3-node cluster: spreading, break-glass, two replicas under failure, cache with TUF blocked, in-cluster TUF mirror, load; closes with what changes for ADR-002 |

## Raw data, by prefix

| Files | Belong to |
| --- | --- |
| `R3b-raw.csv`, `R3b-discarded-attempts.csv` | R3b |
| `R3-prestudy-step7.csv`, `Corefile.r3a`, `coredns-orig.yaml`, `trusted_root.2026-10-08.json` | R3a and the pre-study (DNS config and the trusted root fixture) |
| `R3c-item1*` (and `R3c-item1-dns/`, `R3c-item1-logs/`) | R3c item 1: TUF-init denials and the DNS cause |
| `R3c-item2*` | R3c item 2: latency of the candidate designs |
| `R3c-item3*`, `R3c-item3b*` | R3c item 3 and 3b: failure modes, real hang and crash |
| `R3c-item4/` | R3c item 4: denial observability |
| `R3c-item5*` | R3c item 5: load (l1 simultaneous admissions, l2 rollouts and background scan) |
| `R3e/` | R3e steps 0 to 6, including `tuf-mirror/` and `tuf-mirror-deploy/` (the in-cluster TUF mirror) |
| `tools/` | The scripts that produced the data: cluster scripts, latency loop, one script per R3c item and R3e step, `r3e-kyverno-values.yaml` (the ADR-002 values) |

Files with `DISCARDED` or `discarded` in the name are runs thrown away on purpose; the results file says why.

`tools/cluster-up.sh` and `cluster-down.sh` still name the old `forge-spike` cluster, which no longer exists. `tools/r3e-up.sh` builds the cluster used for R3e.
