# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# LMCache from source against our torch, as a wheel separate from vLLM.
# Requirement edits, build flags and the code-object check mirror vLLM's Dockerfile.rocm.

# src LMCache source at LMCACHE_SHA, verified by ADD --checksum
FROM scratch AS src
ARG LMCACHE_REF
ARG LMCACHE_SHA
ADD --checksum=${LMCACHE_SHA} https://github.com/LMCache/LMCache.git#${LMCACHE_REF} /

FROM torch-dev AS prepared
# GPU_ARCH (ENV) comes from the torch-dev image, RPB_GFX from this bake: a torch-dev
# image built for another target (TORCH_DEV_IMAGE) must not be used.
ARG RPB_GFX
RUN test "${GPU_ARCH}" = "${RPB_GFX}" \
    || { echo "torch-dev is for ${GPU_ARCH}, this build is for ${RPB_GFX}" >&2; exit 1; }
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=src / /w/lmcache
COPY patches/lmcache/ /patches/
# Our patches, applied in file-name order (patch comes with build-essential).
RUN set -eu; \
    cd /w/lmcache \
    && for p in /patches/*.patch; do \
        [ -e "$p" ] || continue; \
        echo "applying $p"; \
        patch -p1 --forward --batch < "$p"; \
    done
# Drop NVIDIA-only requirements and relax numpy exactly as vLLM's Dockerfile.rocm does,
# and pin the CuPy that BUILD_WITH_HIP=1 adds to the wheel (unpinned upstream).
# The test lines fail the build if upstream changes these lines.
ARG LMCACHE_CUPY_VERSION
RUN cd /w/lmcache \
    && test "$(grep -Ec '^(cufile-python|nvtx)([<=>[:space:]]|$)' requirements/common.txt)" -eq 2 \
    && test "$(grep -Fxc 'numpy<=2.2.6' requirements/common.txt)" -eq 1 \
    && test "$(grep -Fxc 'cupy-rocm-7-0' requirements/rocm_core.txt)" -eq 1 \
    && sed -i -E \
        -e '/^(cufile-python|nvtx)([<=>[:space:]]|$)/d' \
        -e 's/^numpy<=2\.2\.6$/numpy<=2.3.5/' \
        requirements/common.txt \
    && sed -i "s/^cupy-rocm-7-0\$/cupy-rocm-7-0==${LMCACHE_CUPY_VERSION}/" requirements/rocm_core.txt \
    && grep -Fx "cupy-rocm-7-0==${LMCACHE_CUPY_VERSION}" requirements/rocm_core.txt
RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install -r /w/lmcache/requirements/build.txt

FROM prepared AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG GPU_ARCH
ARG LMCACHE_VERSION
ARG LMCACHE_CUPY_VERSION
ARG MAX_JOBS
RUN --mount=type=cache,id=rpb-sccache-lmcache-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    cd /w/lmcache \
    && export HIP_CLANG_PATH=/opt/sccache-wrappers \
              SETUPTOOLS_SCM_PRETEND_VERSION="${LMCACHE_VERSION}" \
              PYTORCH_ROCM_ARCH="${GPU_ARCH}" \
              HIPCC_COMPILE_FLAGS_APPEND="--offload-arch=${GPU_ARCH}" \
              BUILD_WITH_HIP=1 CXX=hipcc MAX_JOBS="${MAX_JOBS}" \
              SCCACHE_CACHE_SIZE=5G \
    && rpb-sccache-run lmcache -- python3 setup.py bdist_wheel --dist-dir=/out \
    && test "$(find /out -maxdepth 1 -name 'lmcache-*.whl' | wc -l)" -eq 1 \
    && python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); m = next(n for n in z.namelist() if n.endswith(".dist-info/METADATA")); print(z.read(m).decode())' /out/lmcache-*.whl \
        | grep -Fx "Requires-Dist: cupy-rocm-7-0==${LMCACHE_CUPY_VERSION}"

# The extension must contain code for exactly GPU_ARCH and nothing else.
RUN --mount=type=tmpfs,target=/tmp/lmcache-wheel \
    set -eu; \
    python3 -m zipfile -e /out/lmcache-*.whl /tmp/lmcache-wheel; \
    test "$(find /tmp/lmcache-wheel -type f -name 'c_ops*.so' | wc -l)" -eq 1; \
    c_ops="$(find /tmp/lmcache-wheel -type f -name 'c_ops*.so')"; \
    actual="$(llvm-objdump --offloading "${c_ops}" | grep -oE 'gfx[0-9a-z]+' | sort -u)"; \
    if [ "${actual}" != "${GPU_ARCH}" ]; then \
        printf 'LMCache code objects mismatch\nexpected: %s\nactual:\n%s\n' "${GPU_ARCH}" "${actual}" >&2; \
        exit 1; \
    fi

FROM scratch AS export
COPY --from=build /out/ /
