# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# PyTorch from source for one gfx target.
#   src      : pinned source with submodules, verified against TORCH_SHA (no ROCm dependency)
#   hipified : hipify + our patches (Python only, so a ROCm bump does not re-hipify)
#   build    : native compile under sccache -> /out/torch-*.whl, RPATHs set for
#              TheRock's ROCm pip packages, which the wheel declares as a dependency
#   export   : wheel + telemetry only

# src PyTorch source with submodules at TORCH_SHA, verified by ADD --checksum
FROM scratch AS src
ARG TORCH_GIT_URL
ARG TORCH_REF
ARG TORCH_SHA
# TORCH_GIT_URL is a git URL, which hadolint cannot see through the variable.
# .git is kept so the build records the commit (torch.version.git_version).
# hadolint ignore=DL3020
ADD --keep-git-dir=true --checksum=${TORCH_SHA} ${TORCH_GIT_URL}#${TORCH_REF} /

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
ARG ROCM_SDK_VERSION
ARG MAX_JOBS
# Build requirements only. requirements.txt starts with "--requirement
# requirements-build.txt" (a path relative to itself) and adds development tools.
RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    --mount=type=bind,from=hipified,source=/w/torch/requirements-build.txt,target=/tmp/torch-requirements-build.txt \
    python3 -m pip install -r /tmp/torch-requirements-build.txt
RUN --mount=type=bind,from=hipified,source=/w/torch,target=/w/torch,rw \
    --mount=type=cache,id=rpb-sccache-torch-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    cd /w/torch \
    && export USE_ROCM=1 USE_CUDA=0 BUILD_TEST=0 INSTALL_TEST=0 BUILD_DEBUG_INFO=0 USE_CCACHE=0 \
              PYTORCH_ROCM_ARCH="${GPU_ARCH}" MAX_JOBS="${MAX_JOBS}" \
              PYTORCH_BUILD_VERSION="${TORCH_VERSION}+rpb.${GPU_ARCH}" PYTORCH_BUILD_NUMBER=1 \
              PYTORCH_EXTRA_INSTALL_REQUIREMENTS="rocm[libraries]==${ROCM_SDK_VERSION}" \
              CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache \
              CMAKE_HIP_COMPILER_LAUNCHER=sccache \
              SCCACHE_CACHE_SIZE=40G \
    && rpb-sccache-run torch -- \
        python3 -m pip wheel . --no-build-isolation --no-deps -v --wheel-dir /out \
    && cp build/.ninja_log /out/telemetry/torch-ninja.log \
    && ls /out/torch-*.whl

# RPATHs to TheRock's ROCm packages next to torch, as PyTorch's own TheRock wheels.
COPY --chmod=0755 scripts/rpb-set-rocm-rpath /usr/local/bin/rpb-set-rocm-rpath
RUN --mount=type=tmpfs,target=/tmp/tw \
    set -eu; \
    whl=$(ls /out/torch-*.whl); \
    python3 -m wheel unpack "$whl" -d /tmp/tw; \
    rpb-set-rocm-rpath /tmp/tw/torch-*; \
    rm "$whl"; \
    python3 -m wheel pack /tmp/tw/torch-* -d /out; \
    whl=$(ls /out/torch-*.whl); \
    size=$(stat -c %s "$whl"); \
    if [ "$size" -ge 4294967296 ]; then echo "$whl is over 4 GiB; wheel pack writes a broken ZIP64 header (pypa/wheel#692)" >&2; exit 1; fi; \
    python3 -m zipfile -t "$whl" >/dev/null; \
    ls -l "$whl"

FROM scratch AS export
COPY --from=build /out/ /
