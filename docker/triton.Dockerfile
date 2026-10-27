# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# ROCm Triton from source. Host C++ only; LLVM comes as Triton's own pinned
# prebuilt download (see ADR on prebuilt inputs).

# src ROCm Triton source at TRITON_SHA, verified by ADD --checksum
FROM scratch AS src
ARG TRITON_REF
ARG TRITON_SHA
ADD --keep-git-dir=true --checksum=${TRITON_SHA} https://github.com/ROCm/triton.git#${TRITON_REF} /

FROM base AS build
ARG GPU_ARCH
ARG MAX_JOBS
RUN --mount=type=bind,from=src,target=/w/triton,rw \
    --mount=type=cache,id=rpb-sccache-triton-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=cache,id=rpb-triton-downloads,target=/root/.triton,sharing=locked \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    cd /w/triton \
    && if [ ! -f setup.py ]; then cd python; fi \
    && export TRITON_BUILD_WITH_CCACHE=OFF MAX_JOBS="${MAX_JOBS}" \
              CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache \
              SCCACHE_CACHE_SIZE=10G \
    && rpb-sccache-run triton -- python3 setup.py bdist_wheel --dist-dir=/out \
    && ls /out/triton-*.whl

# Most of libtriton.so is debug info (624 of 835 MiB in the measured ROCm wheel).
# Strip debug sections only (symbols stay), then repack so RECORD hashes match.
RUN --mount=type=tmpfs,target=/tmp/tw \
    set -eu; \
    whl=$(ls /out/triton-*.whl); \
    python3 -m wheel unpack "$whl" -d /tmp/tw; \
    find /tmp/tw -name 'libtriton*.so' -exec strip --strip-debug {} +; \
    rm "$whl"; \
    python3 -m wheel pack /tmp/tw/triton-* -d /out; \
    ls -l /out/triton-*.whl

FROM scratch AS export
COPY --from=build /out/ /
