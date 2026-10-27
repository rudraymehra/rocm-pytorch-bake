# 2. sccache with a Redis-protocol shared level

Status: accepted (direction from the reviewer, 26 Oct 2026)

## Decision

sccache v0.19.0 with `SCCACHE_MULTILEVEL_CHAIN=disk,redis` and write policy
`all`; one Valkey node, no persistence, `allkeys-lru`, bounded `maxmemory`.

## Why write policy `all`

With the default `l0`, writes to Redis are detached tasks that are dropped when
the RUN step stops the sccache server, and an unreachable Redis is accepted at
startup. `all` waits for each write and checks Redis at startup, so
`rpb-sccache-run` can tell whether Redis is reachable; it sets `all` and refuses
any other policy.

## Consequences

- Redis down at the start: the step falls back to the local disk level and the
  run records `fallback`.
- Redis lost during a compile: every failing Redis call waits for its timeout, so
  the step is much slower; the run records `degraded`.
- Tests and benchmarks run in strict mode (`RPB_SCCACHE_REQUIRE_REMOTE=1`), where
  both fail the step.
- Losing the cache node costs one cold build. Each builder uses at most 10 Redis
  connections (fixed in sccache's client).
