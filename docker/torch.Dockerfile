# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# PyTorch from source for one gfx target.
#   src      : pinned source with submodules, verified against TORCH_SHA (no ROCm dependency)
#   hipified : hipify + our patches (Python only, so a ROCm bump does not re-hipify)
#   build    : native compile under sccache -> /out/torch-*.whl
#   export   : wheel + telemetry only

# src PyTorch source with submodules at TORCH_SHA, verified by ADD --checksum
FROM scratch AS src
ARG TORCH_GIT_URL
ARG TORCH_REF
ARG TORCH_SHA
# TORCH_GIT_URL is a git URL, which hadolint cannot see through the variable.
# hadolint ignore=DL3020
ADD --checksum=${TORCH_SHA} ${TORCH_GIT_URL}#${TORCH_REF} /

FROM python:3.12-slim-bookworm@sha256:6dd8b6dab6b3adc7812bab69eca5dbdc1a5cc690ad28306d234ffb4ef8ac9753 AS hipified
RUN apt-get update && apt-get install -y --no-install-recommends patch && rm -rf /var/lib/apt/lists/*
COPY --from=src / /w/torch
COPY patches/pytorch/ /patches/
WORKDIR /w/torch
RUN set -eu; \
    for p in /patches/*.patch; do \
        [ -e "$p" ] || continue; \
        echo "applying $p"; \
        patch -p1 --forward --batch < "$p"; \
    done; \
    python3 tools/amd_build/build_amd.py

FROM base AS build
ARG GPU_ARCH
ARG TORCH_VERSION
ARG MAX_JOBS
RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=locked \
    --mount=type=bind,from=hipified,source=/w/torch/requirements.txt,target=/tmp/torch-requirements.txt \
    python3 -m pip install -r /tmp/torch-requirements.txt
RUN --mount=type=bind,from=hipified,source=/w/torch,target=/w/torch,rw \
    --mount=type=cache,id=rpb-sccache-torch-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    cd /w/torch \
    && export USE_ROCM=1 USE_CUDA=0 BUILD_TEST=0 INSTALL_TEST=0 BUILD_DEBUG_INFO=0 USE_CCACHE=0 \
              PYTORCH_ROCM_ARCH="${GPU_ARCH}" MAX_JOBS="${MAX_JOBS}" \
              PYTORCH_BUILD_VERSION="${TORCH_VERSION}+rpb.${GPU_ARCH}" PYTORCH_BUILD_NUMBER=1 \
              CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache \
              CMAKE_HIP_COMPILER_LAUNCHER=sccache \
              SCCACHE_CACHE_SIZE=40G \
    && rpb-sccache-run torch -- \
        python3 -m pip wheel . --no-build-isolation --no-deps -v --wheel-dir /out \
    && cp build/.ninja_log /out/telemetry/torch-ninja.log \
    && ls /out/torch-*.whl

FROM scratch AS export
COPY --from=build /out/ /
