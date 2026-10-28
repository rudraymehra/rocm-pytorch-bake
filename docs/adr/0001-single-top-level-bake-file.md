# 1. One top-level bake file holds every source pin

Status: accepted

## Context

Bake HCL has no include. Pins in a second HCL file would have to be named with
`-f` (or `BUILDX_BAKE_FILE`) on every run, and a run that forgot it would build
other versions without any error.

## Decision

Every source pin and build knob is a typed, validated variable in
`docker-bake.hcl`. Site-specific values are set as environment variables of the
same name (`rpb.env.example`) or with `--var`; both keep the variable's type and
validation, which re-declaring it in an override file would replace.

## Consequences

`docker buildx bake --print all` is the configuration validator, and CI runs it.
Pins of tools and service images live where they are used; `docs/PINS.md` lists
them.
