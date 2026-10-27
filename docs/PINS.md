# Pins

Every version lives in `docker-bake.hcl`. Each source has a `_REF` (tag or
commit) and a `_SHA` (full commit); the build fails if they disagree, and
`scripts/check-pins` checks them against the git hosts in CI.

## Where the default pins come from

The defaults are the combination vLLM itself builds and tests for ROCm at the
pinned vLLM commit (`docker/Dockerfile.rocm_base` and `docker/Dockerfile.rocm`
at `VLLM_SHA`): ROCm SDK, torch version, Triton, AITER, FlashAttention and
LMCache. Using a tested combination avoids debugging version skew we created
ourselves. See [ADR 0004](adr/0004-pins-follow-vllm.md).

## Bumping a pin

1. Change `<NAME>_REF` and `<NAME>_SHA` together.
2. For vLLM, recompute `VLLM_VERSION`: `git describe --tags --long --abbrev=40 --match 'v[0-9]*' <sha>`
   in a clone, then turn it into the PEP 440 form setuptools-scm prints
   (`python -c "from setuptools_scm import get_version; print(get_version())"` in a clean checkout).
3. Run `make check`.
4. Run a full build (`full-build` workflow) and record it.
