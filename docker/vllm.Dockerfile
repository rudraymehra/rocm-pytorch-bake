# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# vLLM from source against our torch. The stage split mirrors vLLM's docker/Dockerfile.rocm
# at the pinned commit:
#   deps       : Python requirements from requirements/common.txt and rocm.txt only
#   rust-build : the vllm-rs frontend, compiled through sccache (RUSTC_WRAPPER)
#   csrc-build : native HIP/C++ extension, keyed on deps plus the native sources only
#                (not on VLLM_VERSION or the Python sources)
#   build      : Python packaging that reuses the native wheel (VLLM_USE_PRECOMPILED=1)

# src vLLM source at VLLM_SHA, verified by ADD --checksum
FROM scratch AS src
ARG VLLM_REF
ARG VLLM_SHA
ADD --checksum=${VLLM_SHA} https://github.com/vllm-project/vllm.git#${VLLM_REF} /

# patched our patches applied in file-name order; every later stage reads this tree
FROM python:3.12-slim-bookworm@sha256:6dd8b6dab6b3adc7812bab69eca5dbdc1a5cc690ad28306d234ffb4ef8ac9753 AS patched
RUN apt-get update && apt-get install -y --no-install-recommends patch && rm -rf /var/lib/apt/lists/*
COPY --from=src / /w/vllm
COPY patches/vllm/ /patches/
RUN set -eu; \
    cd /w/vllm; \
    for p in /patches/*.patch; do \
        [ -e "$p" ] || continue; \
        echo "applying $p"; \
        patch -p1 --forward --batch < "$p"; \
    done

FROM scratch AS triton-kernels
ARG TRITON_SHA
ADD --checksum=${TRITON_SHA} https://github.com/ROCm/triton.git#${TRITON_SHA}:python/triton_kernels/triton_kernels /

FROM torch-dev AS deps
# GPU_ARCH (ENV) comes from the torch-dev image, RPB_GFX from this bake: a torch-dev
# image built for another target (TORCH_DEV_IMAGE) must not be used.
ARG RPB_GFX
RUN test "${GPU_ARCH}" = "${RPB_GFX}" \
    || { echo "torch-dev is for ${GPU_ARCH}, this build is for ${RPB_GFX}" >&2; exit 1; }
ENV VLLM_TARGET_DEVICE=rocm
WORKDIR /w/vllm
# Only the two files the ROCm install reads (rocm.txt includes common.txt), as
# vLLM's Dockerfile.rocm does, so other requirement edits do not rebuild csrc.
COPY --from=patched /w/vllm/requirements/common.txt /w/vllm/requirements/rocm.txt requirements/
RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install -r requirements/rocm.txt

FROM base AS rust-build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG RUST_TOOLCHAIN
ARG VLLM_VERSION
ARG MAX_JOBS
ENV CARGO_HOME=/root/.cargo RUSTUP_HOME=/root/.rustup CARGO_NET_RETRY=10
ENV PATH=/root/.cargo/bin:${PATH}
# rustup-init 1.29.1, verified by sha256 (static.rust-lang.org/rustup/archive/1.29.1/.../rustup-init.sha256)
ADD --chmod=0755 --checksum=sha256:dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71 \
    https://static.rust-lang.org/rustup/archive/1.29.1/x86_64-unknown-linux-gnu/rustup-init /tmp/rustup-init
RUN /tmp/rustup-init -y --no-modify-path --default-toolchain none \
    && rm /tmp/rustup-init \
    && rustup toolchain install "${RUST_TOOLCHAIN}" \
    && rustup default "${RUST_TOOLCHAIN}" \
    && rustc --version
WORKDIR /w/vllm
COPY --from=patched /w/vllm/requirements/build/rust.txt requirements/build/rust.txt
RUN --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install -r requirements/build/rust.txt
COPY --from=patched /w/vllm/rust rust
COPY --from=patched /w/vllm/rust-toolchain.toml rust-toolchain.toml
COPY --from=patched /w/vllm/tools/build_rust.py tools/build_rust.py
COPY --from=patched /w/vllm/tools/build_rust.sh tools/build_rust.sh
# target/ is not cached, as upstream: stale cargo metadata can outlive source changes.
RUN --mount=type=cache,id=rpb-cargo-registry,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,id=rpb-cargo-git,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,id=rpb-sccache-vllm-rs,target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    export SETUPTOOLS_SCM_PRETEND_VERSION="${VLLM_VERSION}" RUSTC_WRAPPER=sccache \
           CARGO_BUILD_JOBS="${MAX_JOBS}" SCCACHE_CACHE_SIZE=5G \
    && mkdir -p /out/telemetry \
    && rpb-sccache-run vllm-rs -- bash tools/build_rust.sh \
    && test -x vllm/vllm-rs

FROM deps AS csrc-build
ARG GPU_ARCH
ARG MAX_JOBS
COPY --from=triton-kernels / /opt/rocm-triton-kernels
ENV TRITON_KERNELS_SRC_DIR=/opt/rocm-triton-kernels
COPY --from=patched /w/vllm/setup.py /w/vllm/CMakeLists.txt ./
COPY --from=patched /w/vllm/tools/build_rust.py tools/build_rust.py
COPY --from=patched /w/vllm/cmake cmake/
COPY --from=patched /w/vllm/csrc csrc/
COPY --from=patched /w/vllm/vllm/envs.py vllm/envs.py
COPY --from=patched /w/vllm/vllm/__init__.py vllm/__init__.py
RUN --mount=type=bind,from=patched,source=/w/vllm/pyproject.toml,target=/w/vllm/pyproject.toml \
    --mount=type=cache,id=rpb-sccache-vllm-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    export SETUPTOOLS_SCM_PRETEND_VERSION="0.0.0+rocm.csrc.build" CMAKE_BUILD_TYPE=Release \
           PYTORCH_ROCM_ARCH="${GPU_ARCH}" MAX_JOBS="${MAX_JOBS}" SCCACHE_CACHE_SIZE=10G \
    && rpb-sccache-run vllm -- python3 setup.py bdist_wheel --dist-dir=dist \
    && ls dist/*.whl \
    && find build -name .ninja_log -exec cp {} /out/telemetry/vllm-ninja.log \; -quit

FROM deps AS build
ARG VLLM_VERSION
RUN test -n "${VLLM_VERSION}" || { echo "VLLM_VERSION is empty: see docs/PINS.md" >&2; exit 1; }
COPY --from=patched /w/vllm /w/vllm
COPY --from=csrc-build /w/vllm/dist /precompiled-wheels
COPY --from=rust-build /w/vllm/vllm/vllm-rs /w/vllm/vllm/vllm-rs
COPY --from=rust-build /w/vllm/vllm/_rust_*.so /w/vllm/vllm/
COPY --from=csrc-build /out/telemetry/ /out/telemetry/
COPY --from=rust-build /out/telemetry/ /out/telemetry/
RUN native_wheel=$(ls /precompiled-wheels/*.whl) \
    && export SETUPTOOLS_SCM_PRETEND_VERSION="${VLLM_VERSION}" \
              VLLM_USE_PRECOMPILED=1 \
              VLLM_PRECOMPILED_WHEEL_LOCATION="${native_wheel}" \
              VLLM_DOCKER_BUILD_CONTEXT=1 \
    && python3 setup.py bdist_wheel --dist-dir=/out \
    && ls /out/vllm-*.whl

FROM scratch AS export
COPY --from=build /out/ /
