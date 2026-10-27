# Pins

## Source pins: `docker-bake.hcl`

Every source that is compiled has a `_REF` (tag or commit) and a `_SHA` (full
commit) in `docker-bake.hcl`: PyTorch, Triton, torchvision, AITER, FlashAttention,
LMCache and vLLM. `ADD --checksum=<SHA>` fails the build if the ref no longer
points at the SHA. `scripts/check-pins` (in CI) also checks, against the git hosts:

- a tag ref resolves to its SHA;
- a commit ref equals its SHA and the commit exists in the repository;
- `TORCH_VERSION`, `VISION_VERSION`, `AITER_VERSION` and `LMCACHE_VERSION` equal
  their tag without `v`, and `VLLM_VERSION` ends in `+g` and the first 9 hex
  digits of `VLLM_SHA`;
- the `BASE_IMAGE` fallback in `docker/base.Dockerfile` equals the bake default.

The bake file also holds `ROCM_SDK_VERSION`, `PYTHON_VERSION`, `BASE_IMAGE` (by
digest), `SCCACHE_VERSION` with its tarball sha256, and `RUST_TOOLCHAIN`.

## Where the default pins come from

The defaults are the combination vLLM itself builds and tests for ROCm at the
pinned vLLM commit (`docker/Dockerfile.rocm_base` and `docker/Dockerfile.rocm`
at `VLLM_SHA`): ROCm SDK, torch version, torchvision, Triton, AITER,
FlashAttention and LMCache. Using a tested combination avoids debugging version
skew we created ourselves. See [ADR 0004](adr/0004-pins-follow-vllm.md).

## Pins outside the bake file

Tools and service images are pinned where they are used, by digest or checksum.
`scripts/check-pins` does not cover them; Dependabot covers only the GitHub
Actions and the Go module. The rest is bumped by hand, with the same version in
every file listed.

| Pin | Files |
|---|---|
| `docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b` | first line of every Dockerfile |
| `python:3.12-slim-bookworm@sha256:6dd8b6dab6b3adc7812bab69eca5dbdc1a5cc690ad28306d234ffb4ef8ac9753` | `docker/torch.Dockerfile`, `docker/vllm.Dockerfile` |
| pip 26.2.1 wheel (sha256), rustup-init 1.29.1 (sha256), `pybind11==3.0.4` | `docker/base.Dockerfile`, `docker/vllm.Dockerfile` |
| `moby/buildkit:v0.34.1@sha256:99368f3e46177c6405b9740e4461d91cee004128daeecca78d4ceac50ec1da5c` | `infra/buildkit/run-buildkitd.sh`, `dev/minicluster/compose.yaml` |
| `ghcr.io/project-zot/zot:v2.1.22@sha256:96cda11459ce6f8c60da3b03f03e9f67fd11b3ae2d82c4c04c92b3c608996080` | `infra/cache-node/compose.yaml`, `dev/minicluster/compose.yaml`, `.github/workflows/pr.yml` |
| `valkey/valkey:9.1.2@sha256:418652cfb58ef879d4978c33553735d7147016032d5aefaa14c828e611eb9dfd` | `infra/cache-node/compose.yaml`, `dev/minicluster/compose.yaml` |
| `prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` | `infra/monitoring/compose.yaml`, `dev/minicluster/compose.yaml`, `Makefile`, `.github/workflows/pr.yml` |
| `prom/node-exporter:v1.12.1@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0` | `infra/monitoring/compose.yaml`, `dev/minicluster/compose.yaml` |
| buildx v0.38.1 (sha256) | `infra/ec2/user-data.sh`, `.github/workflows/pr.yml` |
| `busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e` | `docker-bake.hcl` (lint and smoke targets), `dev/minicluster/cluster-override.hcl` |
| `debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8`, sccache 0.19.0 tarballs (sha256) | `dev/minicluster/toy.Dockerfile` |
| `rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667`, `pytest==9.1.1`, GitHub Actions by commit | `.github/workflows/pr.yml`, `.github/workflows/full-build.yml` |
| Go 1.26.8, BuildKit v0.34.1 module | `tools/check-buildkitd-config/go.mod` |

New pins are taken at least two weeks after their release.

## Downloads the upstream builds make themselves

Some components fetch more during their own compile step. These are pinned by the
upstream source at our pinned commit, not by this repository, and the builders
need internet access for them:

| Component | Fetches | Pinned by |
|---|---|---|
| Triton | prebuilt LLVM (about 370 MB), nlohmann/json, NVIDIA toolchain archives for the CUDA backend | `python/build_helpers.py` and the JSON files next to it; LLVM is checked against `llvm-info.json`. Kept in the `rpb-triton-downloads` cache mount. C++ unit tests (googletest) are switched off |
| torch | AOTriton: the kernel images for the target gfx (sha256 in `cmake/External/aotriton.cmake`), and the AOTriton runtime source, which is built from source because torch has no prebuilt runtime for the SDK's HIP 7.15; that build installs its Python requirements unpinned | `cmake/External/aotriton.cmake` |
| ROCm SDK | `rocm==<version>` is a source package built at install time; the SDK wheels are pinned by version, not hash | `ROCM_SDK_VERSION` |

Python packages that no constraint names (build tools in `base`, vLLM and LMCache
requirements, the test stage) resolve to the newest release at build time, so two
builds a week apart can differ. `test/constraints.txt` records what was used.

## Bumping a source pin

1. Change `<NAME>_REF` and `<NAME>_SHA` together (and `<NAME>_VERSION` where it exists).
2. For vLLM, recompute `VLLM_VERSION` the way vLLM's `setup.py` does: in a clone at
   the new SHA, `git describe --tags --long --abbrev=40 --match 'v[0-9]*'` gives
   `v<last tag>-<n>-g<40-char sha>`, and setuptools-scm turns that into
   `<next version>.dev<n>+g<first 9 hex digits>` (check with
   `python -c "from setuptools_scm import get_version; print(get_version(git_describe_command=['git','describe','--dirty','--tags','--long','--abbrev=40','--match','v[0-9]*']))"`;
   at `e8ae84bf…` that prints `0.32.1rc1.dev195+ge8ae84bf7`).
3. Run `make check`.
4. Run a full build (`full-build` workflow) and record it.
