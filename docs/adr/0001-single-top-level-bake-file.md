# 1. One top-level bake file holds every pin

Status: accepted

## Context

`docker buildx bake` reads only `docker-bake.hcl` and `docker-bake.override.hcl`
automatically, and bake HCL has no include. A separate pins file would silently
drop out of any run that forgets `-f`.

## Decision

All pins and knobs are variables in `docker-bake.hcl`, validated at parse time.
Site-specific values go in a gitignored `docker-bake.override.hcl`.

## Consequences

`docker buildx bake --print all` is the configuration validator, and CI runs it.
