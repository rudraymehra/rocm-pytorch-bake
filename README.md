# rocm-pytorch-bake

Build PyTorch, vLLM and LMCache from source for a single AMD GPU target, with fast cold builds, heavily cached warm builds and minimal wheels. Driven by `docker buildx bake`, with a zot layer cache, a shared sccache compile cache, remote BuildKit builders and Prometheus build telemetry.

**Status:** design phase. No code yet.

- Design proposal: [docs/DESIGN.md](docs/DESIGN.md)

Comments and questions are welcome as GitHub issues or review comments on the design doc.
