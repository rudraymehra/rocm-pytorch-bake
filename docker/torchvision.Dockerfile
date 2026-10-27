# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# torchvision from source against our torch. vLLM's requirements pull timm, which
# needs torchvision; without our own build pip would install PyPI's CUDA
# torchvision (its "torch==2.13.0" requirement accepts our 2.13.0+rpb.<gfx>), whose
# compiled ops do not load against a ROCm torch. vLLM's Dockerfile.rocm_base pairs
# torch 2.13.0 with torchvision 0.28.0 in the same way.

# src torchvision source at VISION_SHA, verified by ADD --checksum
FROM scratch AS src
ARG VISION_REF
ARG VISION_SHA
ADD --checksum=${VISION_SHA} https://github.com/pytorch/vision.git#${VISION_REF} /

# build HIP ops for GPU_ARCH through hipcc and sccache; image decoders are off
FROM torch-core AS build
ARG GPU_ARCH
ARG RPB_GFX
ARG VISION_VERSION
ARG MAX_JOBS
RUN --mount=type=bind,from=src,target=/w/vision,rw \
    --mount=type=cache,id=rpb-sccache-torchvision-${GPU_ARCH},target=/root/.cache/sccache,sharing=locked \
    --mount=type=secret,id=sccache_env,required=false \
    test "${GPU_ARCH}" = "${RPB_GFX}" \
    && cd /w/vision \
    && torch_v=$(python3 -c "import torch; print(torch.__version__)") \
    && export HIP_CLANG_PATH=/opt/sccache-wrappers FORCE_CUDA=1 \
              PYTORCH_ROCM_ARCH="${GPU_ARCH}" MAX_JOBS="${MAX_JOBS}" \
              BUILD_VERSION="${VISION_VERSION}+rpb.${GPU_ARCH}" PYTORCH_VERSION="${torch_v}" \
              TORCHVISION_USE_NVJPEG=0 TORCHVISION_USE_PNG=0 TORCHVISION_USE_JPEG=0 TORCHVISION_USE_WEBP=0 \
              SCCACHE_CACHE_SIZE=5G \
    && rpb-sccache-run torchvision -- python3 setup.py bdist_wheel --dist-dir=/out \
    && ls /out/torchvision-*.whl

FROM scratch AS export
COPY --from=build /out/ /
