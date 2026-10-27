# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# base + our torch, triton and torchvision wheels. Every downstream build starts
# from torch-dev, and it is the image handed between machines through zot.
#   torch-core : base + torch + triton (torchvision is built on top of this)
#   torch-dev  : torch-core + torchvision, with pip constrained to all three

# torch-core base plus our torch and triton wheels
FROM base AS torch-core
COPY --chmod=0755 scripts/rpb-write-constraints /usr/local/bin/rpb-write-constraints
RUN --mount=type=bind,from=torch-wheel,target=/wheels/torch \
    --mount=type=bind,from=triton-wheel,target=/wheels/triton \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install /wheels/torch/torch-*.whl /wheels/triton/triton-*.whl \
    && rpb-write-constraints /etc/rpb-constraints.txt
ENV PIP_CONSTRAINT=/etc/rpb-constraints.txt

# torch-dev torch-core plus our torchvision, so no dependency can pull a CUDA torchvision from PyPI
FROM torch-core AS torch-dev
RUN --mount=type=bind,from=torchvision-wheel,target=/wheels/torchvision \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=shared \
    python3 -m pip install --no-deps /wheels/torchvision/torchvision-*.whl \
    && rpb-write-constraints /etc/rpb-constraints.txt
