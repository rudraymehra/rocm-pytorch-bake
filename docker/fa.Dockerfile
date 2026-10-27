# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# FlashAttention (CK backend) from source against our torch. CDNA targets only.
# Build flags mirror vLLM's Dockerfile.rocm_base.

# src FlashAttention source at FA_SHA, verified by ADD --checksum
FROM scratch AS src
ARG FA_REF
ARG FA_SHA
ADD --keep-git-dir=true --checksum=${FA_SHA} https://github.com/Dao-AILab/flash-attention.git#${FA_REF} /

FROM torch-dev AS build
ARG GPU_ARCH
ARG MAX_JOBS
RUN --mount=type=bind,from=src,target=/w/flash-attention,rw \
    --mount=type=cache,id=rpb-sccache-fa-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    case "${GPU_ARCH}" in gfx9*) ;; *) echo "fa-wheel supports CDNA (gfx9xx) targets only, got ${GPU_ARCH}" >&2; exit 1;; esac \
    && cd /w/flash-attention \
    && export HIP_CLANG_PATH=/opt/sccache-wrappers GPU_ARCHS="${GPU_ARCH}" MAX_JOBS="${MAX_JOBS}" \
              SCCACHE_CACHE_SIZE=20G \
    && rpb-sccache-run fa -- python3 setup.py bdist_wheel --dist-dir=/out \
    && ls /out/flash_attn-*.whl

FROM scratch AS export
COPY --from=build /out/ /
