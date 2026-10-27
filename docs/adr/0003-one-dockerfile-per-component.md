# 3. One Dockerfile per component, linked by bake contexts

Status: proposed (reviewer question Q4)

## Decision

`docker/<component>.Dockerfile` per component; bake links them with `target:`
contexts, or with `docker-image://` when torch-dev comes from zot.

## Consequences

Components can be built on different machines. `bake --jobs` cannot take a
`parallel=N` limit with linked targets, so concurrency is bounded by BuildKit
`max-parallelism` and the job counts `MAX_JOBS` and `FANOUT_JOBS` instead.
