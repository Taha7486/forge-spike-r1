# PARKED

Ideas that tripped a scope tripwire. Each entry: the need, the date, which installed tool almost covers it. Read this file only after Phase 2 ships. It moves to `forge-gitops` in Phase 1.

## Rekor-monitoring mode for `conformity` (spec §12)

- **Date:** 2026-10-06 (carried over from the spec).
- **Need:** notice unexpected transparency-log entries made with Forge's signing identity.
- **Almost covered by:** the bundle attached to each image already carries its log entry and inclusion proof (ADR-001). Check Sigstore's own `rekor-monitor` before building anything.
- **Constraint:** Rekor v2 has no search index, and Forge pins Rekor v1 for now; a monitor would have to rely on whatever the pinned log supports.
