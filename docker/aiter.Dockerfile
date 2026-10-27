# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# AITER from source against our torch. Build flags mirror vLLM's Dockerfile.rocm_base.

# src AITER source at AITER_SHA, verified by ADD --checksum
FROM scratch AS src
ARG AITER_REF
ARG AITER_SHA
ADD --keep-git-dir=true --checksum=${AITER_SHA} https://github.com/ROCm/aiter.git#${AITER_REF} /

FROM torch-dev AS build
ARG GPU_ARCH
ARG AITER_VERSION
ARG AITER_PREBUILD
ARG MAX_JOBS
RUN --mount=type=bind,from=src,source=/requirements.txt,target=/tmp/aiter-requirements.txt \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=locked \
    python3 -m pip install -r /tmp/aiter-requirements.txt pyyaml
RUN --mount=type=bind,from=src,target=/w/aiter,rw \
    --mount=type=cache,id=rpb-sccache-aiter-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    cd /w/aiter \
    && export HIP_CLANG_PATH=/opt/sccache-wrappers \
              PREBUILD_KERNELS="${AITER_PREBUILD}" AITER_USE_SYSTEM_TRITON=1 \
              GPU_ARCHS="${GPU_ARCH}" MAX_JOBS="${MAX_JOBS}" \
              SETUPTOOLS_SCM_PRETEND_VERSION="${AITER_VERSION}" \
              SCCACHE_CACHE_SIZE=20G \
    && rpb-sccache-run aiter -- python3 setup.py bdist_wheel --dist-dir=/out \
    && ls /out/*.whl

FROM scratch AS export
COPY --from=build /out/ /
