# 2. sccache with a Redis-protocol shared level

Status: accepted (direction from the reviewer, 26 Oct 2026)

## Decision

sccache v0.19.0 with `SCCACHE_MULTILEVEL_CHAIN=disk,redis` and write policy
`all`; one Valkey node, no persistence, `allkeys-lru`, bounded `maxmemory`.

## Why write policy `all`

With the default `l0`, writes to Redis are detached tasks that are dropped when
the RUN step stops the sccache server. `all` waits for each write. The cost is
that sccache will not start if Redis is down, so `rpb-sccache-run` falls back to
the local disk level.

## Consequences

Losing the cache node costs one cold build. Each builder uses at most 10 Redis
connections (fixed in sccache's client).
