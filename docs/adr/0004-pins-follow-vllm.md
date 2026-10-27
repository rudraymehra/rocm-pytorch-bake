# 4. Default pins follow vLLM's tested ROCm combination

Status: accepted until the reviewer answers Q1–Q3

## Decision

ROCm SDK, torch version, Triton, AITER, FlashAttention and LMCache defaults are
copied from vLLM's ROCm Dockerfiles at the pinned vLLM commit. Torch is built
from source at the matching upstream tag.

## Consequences

AIC builds torch from the ROCm/pytorch fork; switching is one variable
(`TORCH_GIT_URL`) plus a new `TORCH_REF`/`TORCH_SHA`.
