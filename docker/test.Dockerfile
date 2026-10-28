# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# Install every wheel into a clean base image and run the checks that need no GPU.

# test pip check, imports and the offload-arch check of all wheels installed together
FROM base AS test
ARG GPU_ARCH
RUN --mount=type=bind,from=torch-wheel,target=/wheels/torch \
    --mount=type=bind,from=triton-wheel,target=/wheels/triton \
    --mount=type=bind,from=torchvision-wheel,target=/wheels/torchvision \
    --mount=type=bind,from=aiter-wheel,target=/wheels/aiter \
    --mount=type=bind,from=fa-wheel,target=/wheels/fa \
    --mount=type=bind,from=lmcache-wheel,target=/wheels/lmcache \
    --mount=type=bind,from=vllm-wheel,target=/wheels/vllm \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install /wheels/*/*.whl \
    && python3 -m pip check
# As in a user's environment, without this image's ROCm loader path: torch must load
# its ROCm libraries itself (torch/_rocm_init.py and RPATH), and LMCache's CuPy
# (cupy-rocm-7-0, built for ROCm 7.0) must then load against this SDK. Calling the
# HIP runtime binds its symbols; with no GPU it reports hipErrorNoDevice.
RUN set -eu; \
    mv /etc/ld.so.conf.d/rocm-pip.conf /tmp/rocm-pip.conf; ldconfig; \
    status=0; \
    env -u LD_LIBRARY_PATH python3 -c "import torch, lmcache; import cupy_backends.cuda.api.runtime as rt, cupy.cuda.stream, cupy.cuda.memory, cupy_backends.cuda.libs.cublas, cupy_backends.cuda.libs.nccl; print('torch', torch.__version__, 'with LMCache CuPy on HIP', rt.runtimeGetVersion())" \
        || status=$?; \
    mv /tmp/rocm-pip.conf /etc/ld.so.conf.d/rocm-pip.conf; ldconfig; \
    exit "$status"
COPY --chmod=0755 scripts/rpb-check-offload-arch /usr/local/bin/rpb-check-offload-arch
RUN python3 -c "import torch; assert torch.version.hip, 'not a ROCm torch'; assert '+rpb.' in torch.__version__, torch.__version__; print(torch.__version__, torch.version.hip, torch.version.git_version)" \
    && python3 -c "import torchvision; assert '+rpb.' in torchvision.__version__, torchvision.__version__; print('torchvision', torchvision.__version__)" \
    && python3 -c "import triton, lmcache, vllm, amdsmi; print('imports ok')" \
    && python3 -c "import importlib.util as u; assert u.find_spec('aiter') and u.find_spec('flash_attn'); print('aiter and flash_attn installed')" \
    && rpb-check-offload-arch "${GPU_ARCH}" "${SITE_PACKAGES}/torch" "${SITE_PACKAGES}/torchvision" \
        "${SITE_PACKAGES}/vllm" "${SITE_PACKAGES}/lmcache" "${SITE_PACKAGES}/aiter" "${SITE_PACKAGES}/flash_attn" \
        "${SITE_PACKAGES}"/flash_attn_2_cuda*.so \
    && mkdir -p /out \
    && python3 -m pip list --format=freeze > /out/constraints.txt \
    && cp /opt/rpb/wheels/amdsmi-*.whl /out/

# export exact versions of every package in the tested environment, shipped with the
# wheels, and the amdsmi wheel built from rocm-sdk-core (it is not on any index).
FROM scratch AS export
COPY --from=test /out/ /
