# rocm-pytorch-bake

Build PyTorch, torchvision, Triton, AITER, FlashAttention, LMCache and vLLM from
source for a single AMD GPU target, with fast cold builds, heavily cached warm
builds and minimal wheels. Driven by one `docker buildx bake` file, with remote
BuildKit builders, a zot layer cache, a Redis-backed sccache compile cache and
Prometheus build telemetry.

**Status:** build definition, infrastructure, telemetry and CI are written and
checked on the `dev` branch (static checks, and the mini-cluster test in CI). No
full build of the real wheels has run yet. `main` only receives code after that
full build passes and is reviewed. Design: [docs/DESIGN.md](docs/DESIGN.md).

## Quickstart

```sh
docker buildx bake --list=variables                        # every variable, typed and described
scripts/bake-graph                                         # what each target builds, from what
docker buildx bake --print all > /dev/null                 # validate the configuration
scripts/rpb build --builder <your-builder> --targets "wheels test"
```

Wheels land in `out/<gfx>/<package>/`; `out/<gfx>/test/` holds `constraints.txt`
(the tested versions of every package) and the amdsmi wheel. Every run is
recorded in `results/<run_id>/record.json`.

| Need | Read |
|---|---|
| Set up builders, zot, Redis and Prometheus | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| Change a version | [docs/PINS.md](docs/PINS.md) |
| Understand the numbers | [docs/TELEMETRY.md](docs/TELEMETRY.md), [docs/BENCHMARKING.md](docs/BENCHMARKING.md) |
| CI tiers | [docs/CI.md](docs/CI.md) |
| Why it is built this way | [docs/adr/](docs/adr/) |

## Requirements

- buildx v0.38.0 or later (`bake --jobs`), BuildKit v0.17.0 or later on the builders.
- Builders: x86_64 Linux, 32+ cores, 4 GiB RAM per core, local NVMe.
- GPU targets: gfx90a, gfx942 (default) or gfx950, one per build.

## License

MIT, see [LICENSE](LICENSE).
