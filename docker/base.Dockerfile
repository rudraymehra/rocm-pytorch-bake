# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# Toolchain image: OS, Python, TheRock rocm-sdk and sccache. No frameworks.
# Python and rocm-sdk installation mirror vLLM's docker/Dockerfile.rocm_base.

# BASE_IMAGE OS image by digest; scripts/check-pins keeps it equal to the bake default
ARG BASE_IMAGE=ubuntu:22.04@sha256:e0f80c829509ef4df9e76bd8944eb7b8ec25cbb379b112a7f9448b2c77a77c9b
FROM ${BASE_IMAGE} AS base

ARG PYTHON_VERSION
ARG ROCM_SDK_VERSION
ARG ROCM_INDEX_URL
ARG GPU_ARCH
ARG SCCACHE_VERSION
ARG SCCACHE_SHA256

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHON_VERSION=${PYTHON_VERSION} \
    GPU_ARCH=${GPU_ARCH}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,id=rpb-apt-lists,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=rpb-apt-cache,target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        software-properties-common gpg-agent ca-certificates curl git build-essential \
        pkg-config libnuma-dev libdrm-dev libpci-dev liblzma-dev libgfortran5 \
        patchelf time zstd \
    && for _ in 1 2 3; do add-apt-repository -y ppa:deadsnakes/ppa && break || sleep 5; done \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-dev" "python${PYTHON_VERSION}-venv" \
    && update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_VERSION}" 1 \
    && update-alternatives --set python3 "/usr/bin/python${PYTHON_VERSION}" \
    && ln -sf /usr/bin/python3 /usr/bin/python

# pip 26.2.1 from its PyPI wheel, verified by sha256; a pip wheel can install itself.
ADD --checksum=sha256:71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e \
    https://files.pythonhosted.org/packages/f3/6e/1736e5b4ae2b778ef2f81c47d797de9f891d4d8acb047a24ca37a60294dd/pip-26.2.1-py3-none-any.whl /tmp/pip-26.2.1-py3-none-any.whl
RUN python3 /tmp/pip-26.2.1-py3-none-any.whl/pip install --no-index /tmp/pip-26.2.1-py3-none-any.whl \
    && rm /tmp/pip-26.2.1-py3-none-any.whl \
    && python3 --version && python3 -m pip --version

ENV SITE_PACKAGES=/usr/local/lib/python${PYTHON_VERSION}/dist-packages
ENV SDK_DEV=${SITE_PACKAGES}/_rocm_sdk_devel \
    SDK_CORE=${SITE_PACKAGES}/_rocm_sdk_core
ENV ROCM_PATH=${SDK_DEV} \
    ROCM_HOME=${SDK_DEV} \
    HIP_PATH=${SDK_DEV} \
    HIP_DEVICE_LIB_PATH=${SDK_CORE}/lib/llvm/amdgcn/bitcode \
    LD_LIBRARY_PATH=${SDK_DEV}/lib:${SDK_DEV}/lib/rocm_sysdeps/lib:${SDK_CORE}/lib:${SDK_CORE}/lib/rocm_sysdeps/lib \
    PATH=${SDK_DEV}/bin:${SDK_DEV}/lib/llvm/bin:${SDK_CORE}/bin:${PATH} \
    HSA_NO_SCRATCH_RECLAIM=1

RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install -U packaging 'cmake<4' ninja wheel 'setuptools<80' build \
        pybind11==3.0.4 Cython setuptools_scm

RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install --index-url "${ROCM_INDEX_URL}" \
        "rocm[libraries,devel]==${ROCM_SDK_VERSION}" \
        "rocm[device-${GPU_ARCH}]==${ROCM_SDK_VERSION}" \
    && rocm-sdk init \
    && test -x "${SDK_DEV}/lib/llvm/bin/clang++" \
    && test -d "${HIP_DEVICE_LIB_PATH}"

# amdsmi: vLLM detects ROCm through "import amdsmi", and TheRock ships it only as
# sources inside rocm-sdk-core. scripts/rpb-build-amdsmi makes it installable on its
# own (as vLLM's therock_wheels.py does); the wheel is kept in /opt/rpb/wheels and
# exported with the test results.
COPY --chmod=0755 scripts/rpb-build-amdsmi /usr/local/bin/rpb-build-amdsmi
RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    rpb-build-amdsmi "${SDK_CORE}/share/amd_smi" /opt/rpb/wheels \
    && python3 -m pip install --no-deps /opt/rpb/wheels/amdsmi-*.whl \
    && (cd / && python3 -c "import amdsmi")

# TheRock runtime fixes, copied from vLLM's Dockerfile.rocm_base at the pinned commit.
RUN if [ -f "${SITE_PACKAGES}/rocm_sdk/__init__.py" ]; then \
        sed -i 's/rtld_global: bool = True/rtld_global: bool = False/g' "${SITE_PACKAGES}/rocm_sdk/__init__.py"; \
    fi \
    && printf '%s\n%s\n' "${ROCM_PATH}/lib" "${SDK_CORE}/lib" > /etc/ld.so.conf.d/rocm-pip.conf \
    && ldconfig

# sccache: static musl binary, verified by sha256.
ADD --checksum=sha256:${SCCACHE_SHA256} \
    https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz \
    /tmp/sccache.tar.gz
RUN tar -xzf /tmp/sccache.tar.gz -C /tmp \
    && install -m 0755 "/tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" /usr/local/bin/sccache \
    && rm -rf /tmp/sccache.tar.gz "/tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl" \
    && sccache --version

# hipcc calls clang through HIP_CLANG_PATH. Compile steps that go through hipcc
# export HIP_CLANG_PATH=/opt/sccache-wrappers; it is never set as ENV here.
RUN mkdir -p /opt/sccache-wrappers \
    && printf '#!/bin/bash\nexec sccache %s/lib/llvm/bin/clang++ "$@"\n' "${ROCM_PATH}" > /opt/sccache-wrappers/clang++ \
    && printf '#!/bin/bash\nexec sccache %s/lib/llvm/bin/clang "$@"\n' "${ROCM_PATH}" > /opt/sccache-wrappers/clang \
    && chmod 0755 /opt/sccache-wrappers/clang /opt/sccache-wrappers/clang++

# Local sccache level. The shared Redis level is switched on only by the
# sccache_env secret (scripts/rpb-sccache-run).
ENV SCCACHE_DIR=/root/.cache/sccache \
    SCCACHE_DIRECT=false \
    SCCACHE_IDLE_TIMEOUT=0 \
    SCCACHE_C_CUSTOM_CACHE_BUSTER=rocm-sdk-${ROCM_SDK_VERSION}-${GPU_ARCH}

COPY --chmod=0755 scripts/rpb-sccache-run /usr/local/bin/rpb-sccache-run

RUN mkdir -p /out/telemetry /w
WORKDIR /w
