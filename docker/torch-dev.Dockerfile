# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# base + our torch and triton wheels. Every downstream build starts from this image,
# and it is the image handed between machines through zot.

# torch-dev base plus our torch and triton wheels, with pip constrained to them
FROM base AS torch-dev
COPY --chmod=0755 scripts/rpb-write-constraints /usr/local/bin/rpb-write-constraints
RUN --mount=type=bind,from=torch-wheel,target=/wheels/torch \
    --mount=type=bind,from=triton-wheel,target=/wheels/triton \
    --mount=type=cache,id=rpb-pip,target=/root/.cache/pip,sharing=locked \
    python3 -m pip install /wheels/torch/torch-*.whl /wheels/triton/triton-*.whl \
    && rpb-write-constraints /etc/rpb-constraints.txt
ENV PIP_CONSTRAINT=/etc/rpb-constraints.txt
