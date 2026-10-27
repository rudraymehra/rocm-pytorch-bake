# rocm-pytorch-bake

Build PyTorch, vLLM and LMCache from source for a single AMD GPU target, with
fast cold builds, heavily cached warm builds and minimal wheels. Driven by one
`docker buildx bake` file, with remote BuildKit builders, a zot layer cache, a
Redis-backed sccache compile cache and Prometheus build telemetry.

**Status:** build definition, infrastructure, telemetry and CI are written and
statically validated on the `dev` branch; no full build has run on real builders
yet. `main` only receives code after that full build passes and is reviewed.
Design: [docs/DESIGN.md](docs/DESIGN.md).

## Quickstart

```sh
docker buildx bake --list=variables                        # every knob, typed and described
docker buildx bake --print all > /dev/null                 # validate the configuration
scripts/rpb build --builder <your-builder> --targets "wheels test"
```

Wheels land in `out/<gfx>/<package>/`, and every run is recorded in
`results/<run_id>/record.json`.

| Need | Read |
|---|---|
| Set up builders, zot and Redis | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| Change a version | [docs/PINS.md](docs/PINS.md) |
| Understand the numbers | [docs/TELEMETRY.md](docs/TELEMETRY.md), [docs/BENCHMARKING.md](docs/BENCHMARKING.md) |
| CI tiers | [docs/CI.md](docs/CI.md) |
| Why it is built this way | [docs/adr/](docs/adr/) |

## Requirements

- buildx v0.38.0 or later (`bake --jobs`), BuildKit v0.17.0 or later on the builders.
- Builders: x86_64 Linux, 32+ cores, 4 GiB RAM per core, local NVMe.

## License

MIT, see [LICENSE](LICENSE).
