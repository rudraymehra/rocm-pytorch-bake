# Replaces every real build with a tiny busybox step that has the same name,
# stages, contexts and outputs, so scripts/rpb-cluster can be exercised end to end
# on the dev mini-cluster in seconds:
#   scripts/rpb-cluster --builders "..." --registry zot:5000 -- \
#       -f docker-bake.hcl -f dev/minicluster/cluster-override.hcl

target "torch-wheel" {
  dockerfile-inline = "FROM base AS build\nRUN mkdir -p /out && echo torch > /out/torch-0.0.0-py3-none-any.whl\nFROM scratch AS export\nCOPY --from=build /out/ /"
  contexts          = { base = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" }
}

target "triton-wheel" {
  dockerfile-inline = "FROM base AS build\nRUN mkdir -p /out && echo triton > /out/triton-0.0.0-py3-none-any.whl\nFROM scratch AS export\nCOPY --from=build /out/ /"
  contexts          = { base = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" }
}

target "torch-dev" {
  dockerfile-inline = "FROM base AS torch-dev\nCOPY --from=torch-wheel / /wheels/torch/\nCOPY --from=triton-wheel / /wheels/triton/"
  contexts          = { base = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" }
}

target "aiter-wheel" {
  dockerfile-inline = "FROM torch-dev AS build\nRUN test -s /wheels/torch/torch-0.0.0-py3-none-any.whl && mkdir -p /out && echo aiter > /out/aiter-0.0.0-py3-none-any.whl\nFROM scratch AS export\nCOPY --from=build /out/ /"
}

target "fa-wheel" {
  dockerfile-inline = "FROM torch-dev AS build\nRUN test -s /wheels/torch/torch-0.0.0-py3-none-any.whl && mkdir -p /out && echo fa > /out/fa-0.0.0-py3-none-any.whl\nFROM scratch AS export\nCOPY --from=build /out/ /"
}

target "lmcache-wheel" {
  dockerfile-inline = "FROM torch-dev AS build\nRUN test -s /wheels/torch/torch-0.0.0-py3-none-any.whl && mkdir -p /out && echo lmcache > /out/lmcache-0.0.0-py3-none-any.whl\nFROM scratch AS export\nCOPY --from=build /out/ /"
}

target "vllm-wheel" {
  dockerfile-inline = "FROM torch-dev AS build\nRUN test -s /wheels/torch/torch-0.0.0-py3-none-any.whl && mkdir -p /out && echo vllm > /out/vllm-0.0.0-py3-none-any.whl\nFROM scratch AS export\nCOPY --from=build /out/ /"
}

target "test" {
  dockerfile-inline = "FROM base AS test\nCOPY --from=torch-wheel / /w/torch/\nCOPY --from=triton-wheel / /w/triton/\nCOPY --from=aiter-wheel / /w/aiter/\nCOPY --from=fa-wheel / /w/fa/\nCOPY --from=lmcache-wheel / /w/lmcache/\nCOPY --from=vllm-wheel / /w/vllm/\nRUN test \"$(ls /w/*/*.whl | wc -l)\" -eq 6 && ls /w/*/*.whl > /w/tested.txt\nFROM scratch AS export\nCOPY --from=test /w/tested.txt /"
  contexts          = { base = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" }
}
