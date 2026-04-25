# MaaS + Praxis Phase 2 — Request-Admission Controls

Phase 2 extends Praxis from routing-only to request-admission
enforcement on Praxis-owned routes.

## Status

Not started. See [praxxis-planning.md](../../../praxxis-planning.md)
for the full Phase 2 execution plan.

## Phase 1 Checkpoint

Phase 1 (ext-proc/BBR replacement) is frozen at:

| Artifact | Reference |
|---|---|
| Praxis branch | [`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers) |
| Praxis tag | [`phase1-complete`](https://github.com/nerdalert/praxis/releases/tag/phase1-complete) |
| Pingora branch | [`feat/streambuffer-initial-send`](https://github.com/nerdalert/pingora/tree/feat/streambuffer-initial-send) |
| Pingora tag | [`phase1-complete`](https://github.com/nerdalert/pingora/releases/tag/phase1-complete) |
| Image | `ghcr.io/nerdalert/praxis:maas-phase1` |
| Demo | [`demos/maas-praxis/`](../maas-praxis/) |
| Phase 1 report | [`demos/maas-praxis/phase-1-completion.md`](../maas-praxis/phase-1-completion.md) |

## Phase 2 Artifacts

| Artifact | Reference |
|---|---|
| Praxis branch | [`feat/maas-phase2`](https://github.com/nerdalert/praxis/tree/feat/maas-phase2) |
| Image tag | `ghcr.io/nerdalert/praxis:maas-phase2` (not yet built) |
| Demo | `demos/maas-praxis-phase2/` (this directory) |

## Planned PRs

Based on the Phase 2 execution plan in `praxxis-planning.md`:

| Order | PR | Issue | Prerequisite |
|-------|---|-------|-------------|
| 1 | `HttpFilterContext` metadata/identity bag | New issue | — |
| 2 | Prometheus metrics endpoint + basic counters | #8 | — |
| 3 | Per-filter failure modes (fail-open/fail-closed) | #48 | — |
| 4 | Descriptor-based local request limiter | New issue | PR 1 |
| 5 | Demo validation for descriptor isolation | — | PR 4 |
| 6 | Bridge-mode trusted header projection for MaaS descriptors | — | PR 4 |
| 7 | ext-auth filter for `maas-api` validation | #14 | PR 1 |
| 8 | Shared Redis/Valkey limiter backend | New issue | PR 4 |
| 9 | MaaS config adapter | — | PR 6, PR 7 |

## Upstream PRs (Phase 1)

These should be opened against `praxis-proxy/praxis` before
Phase 2 work begins:

| PR | What | Source |
|----|------|--------|
| DNS hostname resolution for upstream endpoints | `ToSocketAddrs` fallback in `upstream_peer.rs` | `9888295` |
| Request header `set/remove` | `request_set` + `request_remove` on `HeaderFilter` | `9888295` |
| StreamBuffer body forwarding fix | Remove `!released` guard on `buffer.push()` | `e7744c2` |
