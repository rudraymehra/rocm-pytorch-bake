# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# Install every wheel into a clean base image and run the checks that need no GPU.

# test pip check, imports and the offload-arch check of all wheels installed together
FROM base AS test
ARG GPU_ARCH
RUN --mount=type=bind,from=torch-wheel,target=/wheels/torch \
    --mount=type=bind,from=triton-wheel,target=/wheels/triton \
    --mount=type=bind,from=aiter-wheel,target=/wheels/aiter \
    --mount=type=bind,from=fa-wheel,target=/wheels/fa \
    --mount=type=bind,from=lmcache-wheel,target=/wheels/lmcache \
    --mount=type=bind,from=vllm-wheel,target=/wheels/vllm \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=locked \
    python3 -m pip install /wheels/*/*.whl \
    && python3 -m pip check
COPY --chmod=0755 scripts/rpb-check-offload-arch /usr/local/bin/rpb-check-offload-arch
RUN python3 -c "import torch; assert torch.version.hip, 'not a ROCm torch'; assert '+rpb.' in torch.__version__, torch.__version__; print(torch.__version__, torch.version.hip)" \
    && python3 -c "import triton, lmcache, vllm; print('imports ok')" \
    && python3 -c "import importlib.util as u; assert u.find_spec('aiter') and u.find_spec('flash_attn'); print('aiter and flash_attn installed')" \
    && rpb-check-offload-arch "${GPU_ARCH}" "${SITE_PACKAGES}/torch" "${SITE_PACKAGES}/vllm" "${SITE_PACKAGES}/lmcache" \
    && mkdir -p /out \
    && python3 -m pip list --format=freeze > /out/constraints.txt

# export exact versions of every package in the tested environment, shipped with the wheels.
FROM scratch AS export
COPY --from=test /out/ /
