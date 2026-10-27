# rocm-pytorch-bake: build PyTorch, vLLM and LMCache from source for ONE AMD GPU target.
#
#   docker buildx bake --list=variables            # every variable, typed and described
#   docker buildx bake --print all                 # resolved config; CI uses this as the validator
#   docker buildx bake --var GPU_ARCH=gfx950 all   # --var beats environment variables
#
# Site-specific values (cache registry, Redis secret file, job counts) are set as
# environment variables of the same name (see rpb.env.example) or with --var. Both
# keep the type and validation below; re-declaring a variable in an override file
# would replace them.
# Requires buildx >= 0.38.0 (bake --jobs) and BuildKit >= 0.17.0.

# ---------------------------------------------------------------- target and toolchain

variable "GPU_ARCH" {
  type        = string
  default     = "gfx942"
  description = "Exactly one AMD GPU target: gfx90a, gfx942 or gfx950"
  validation {
    # The CDNA targets that AITER, FlashAttention (allowed_archs) and vLLM's ROCm build support.
    condition     = contains(["gfx90a", "gfx942", "gfx950"], GPU_ARCH)
    error_message = "GPU_ARCH must be ONE of gfx90a, gfx942, gfx950 (not a list)."
  }
}

variable "PYTHON_VERSION" {
  type        = string
  default     = "3.12"
  description = "CPython version used for every wheel"
  validation {
    condition     = can(regex("^3\\.[0-9]+$", PYTHON_VERSION))
    error_message = "PYTHON_VERSION must look like 3.12."
  }
}

variable "BASE_IMAGE" {
  type        = string
  default     = "ubuntu:22.04@sha256:e0f80c829509ef4df9e76bd8944eb7b8ec25cbb379b112a7f9448b2c77a77c9b"
  description = "OS base image, pinned by digest (22.04 keeps the wheels at glibc 2.35)"
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", BASE_IMAGE))
    error_message = "BASE_IMAGE must be pinned by digest."
  }
}

variable "ROCM_SDK_VERSION" {
  type        = string
  default     = "10.0.0"
  description = "TheRock rocm-sdk version installed from ROCM_INDEX_URL"
}

variable "ROCM_INDEX_URL" {
  type        = string
  default     = "https://stable.repo.amd.com/rocm/whl-next/"
  description = "Python package index that serves the rocm-sdk wheels"
}

variable "SCCACHE_VERSION" {
  type        = string
  default     = "0.19.0"
  description = "sccache release installed in the base image"
}

variable "SCCACHE_SHA256" {
  type        = string
  default     = "aa73c7270c997894038c0d8f0d297865f57569e1687883322bc431713d4bb9dd"
  description = "sha256 of sccache-v<version>-x86_64-unknown-linux-musl.tar.gz"
}

variable "RUST_TOOLCHAIN" {
  type        = string
  default     = "1.95"
  description = "Rust toolchain for vLLM's Rust frontend (vLLM rust-toolchain.toml)"
}

# ---------------------------------------------------------------- source pins (ref + full commit)

variable "TORCH_GIT_URL" {
  type        = string
  default     = "https://github.com/pytorch/pytorch.git"
  description = "PyTorch source repository; AIC builds from https://github.com/ROCm/pytorch.git (Q1)"
}
variable "TORCH_REF" {
  type        = string
  default     = "v2.13.0"
  description = "PyTorch tag or branch to build"
}
variable "TORCH_SHA" {
  type        = string
  default     = "cf30153c4c131c8164ee7798e5022d810682e2cb"
  description = "Commit TORCH_REF must resolve to (checked by ADD --checksum and scripts/check-pins)"
}
variable "TORCH_VERSION" {
  type        = string
  default     = "2.13.0"
  description = "Public torch version; the wheel is versioned <this>+rpb.<GPU_ARCH>"
}
variable "TRITON_REF" {
  type        = string
  default     = "669b31acc1dd1b3fd93286afd5db67f65d9f7557"
  description = "ROCm/triton commit (release/internal/3.8.x), as pinned by vLLM"
}
variable "TRITON_SHA" {
  type        = string
  default     = "669b31acc1dd1b3fd93286afd5db67f65d9f7557"
  description = "Commit TRITON_REF must resolve to"
}
variable "VISION_REF" {
  type        = string
  default     = "v0.28.0"
  description = "torchvision tag; vLLM's ROCm base pairs torch 2.13.0 with torchvision 0.28.0"
}
variable "VISION_SHA" {
  type        = string
  default     = "8fb87713a24951e639c494b0f2a8a81b5f8e33a6"
  description = "Commit VISION_REF must resolve to"
}
variable "VISION_VERSION" {
  type        = string
  default     = "0.28.0"
  description = "Public torchvision version; the wheel is versioned <this>+rpb.<GPU_ARCH>"
}
variable "AITER_REF" {
  type        = string
  default     = "v0.1.26"
  description = "AITER tag, as pinned by vLLM"
}
variable "AITER_SHA" {
  type        = string
  default     = "84077b3c0461dac1f0f3f8b9590a9282e2035a2f"
  description = "Commit AITER_REF must resolve to"
}
variable "AITER_VERSION" {
  type        = string
  default     = "0.1.26"
  description = "Version written into the AITER wheel (setuptools-scm)"
}
variable "AITER_PREBUILD" {
  type        = string
  default     = "1"
  description = "AITER PREBUILD_KERNELS value: 0 = JIT at runtime, 1 = prebuild (vLLM upstream default)"
  validation {
    condition     = contains(["0", "1", "2", "3"], AITER_PREBUILD)
    error_message = "AITER_PREBUILD must be 0, 1, 2 or 3."
  }
}
variable "FA_REF" {
  type        = string
  default     = "0e60e39473e8df549a20fb5353760f7a65b30e2d"
  description = "FlashAttention commit, as pinned by vLLM"
}
variable "FA_SHA" {
  type        = string
  default     = "0e60e39473e8df549a20fb5353760f7a65b30e2d"
  description = "Commit FA_REF must resolve to"
}
variable "LMCACHE_REF" {
  type        = string
  default     = "v0.5.3"
  description = "LMCache tag, as pinned by vLLM"
}
variable "LMCACHE_SHA" {
  type        = string
  default     = "140819c9d57a975dbc5678a6459a218e544cb58b"
  description = "Commit LMCACHE_REF must resolve to"
}
variable "LMCACHE_VERSION" {
  type        = string
  default     = "0.5.3"
  description = "Version written into the LMCache wheel (setuptools-scm)"
}
variable "VLLM_REF" {
  type        = string
  default     = "e8ae84bf7e992c63570905fce3073fd7a7de2412"
  description = "vLLM main at the merge of PR #62475 (split attention TUs)"
}
variable "VLLM_SHA" {
  type        = string
  default     = "e8ae84bf7e992c63570905fce3073fd7a7de2412"
  description = "Commit VLLM_REF must resolve to"
}
variable "VLLM_VERSION" {
  type        = string
  default     = "0.32.1rc1.dev195+ge8ae84bf7"
  description = "PEP 440 version of the vLLM wheel, as vLLM's setup.py computes it at VLLM_SHA (setuptools-scm keeps 9 hex digits; docs/PINS.md)"
  validation {
    condition     = can(regex("\\+g${substr(VLLM_SHA, 0, 9)}$", VLLM_VERSION))
    error_message = "VLLM_VERSION must end in +g<first 9 hex digits of VLLM_SHA>; see docs/PINS.md."
  }
}

variable "_SHAS" {
  default     = [TORCH_SHA, TRITON_SHA, VISION_SHA, AITER_SHA, FA_SHA, LMCACHE_SHA, VLLM_SHA]
  description = "Internal: every *_SHA, for the validation below"
  validation {
    condition     = length([for s in _SHAS : s if !can(regex("^[0-9a-f]{40}$", s))]) == 0
    error_message = "Every *_SHA must be a full 40-character lowercase git commit."
  }
}

# ---------------------------------------------------------------- site knobs (environment variable or --var)

variable "CACHE_REGISTRY" {
  type        = string
  default     = ""
  description = "host:port of the zot layer cache, the same string as ZOT_ADDR on the builders; empty disables registry cache"
}
variable "CACHE_TAG_SUFFIX" {
  type        = string
  default     = ""
  description = "Set to -ref only for baseline-pin builds that refresh the reference cache"
}
variable "SCCACHE_ENV_FILE" {
  type        = string
  default     = ""
  description = "Path to the sccache secret env file (Redis endpoint and credentials); empty = local disk only"
}
variable "TORCH_DEV_IMAGE" {
  type        = string
  default     = ""
  description = "Prebuilt torch-dev image ref@digest from zot; empty builds torch-dev in this bake"
}
variable "MAX_JOBS" {
  type        = number
  default     = 64
  description = "Compiler jobs for the torch build. Part of the layer cache key: use one value per host class"
  validation {
    condition     = MAX_JOBS > 0 && floor(MAX_JOBS) == MAX_JOBS
    error_message = "MAX_JOBS must be a positive whole number."
  }
}
variable "FANOUT_JOBS" {
  type        = number
  default     = 16
  description = "Compiler jobs for each of Triton, torchvision, AITER, FA, LMCache and vLLM (several run in parallel)"
  validation {
    condition     = FANOUT_JOBS > 0 && floor(FANOUT_JOBS) == FANOUT_JOBS
    error_message = "FANOUT_JOBS must be a positive whole number."
  }
}
variable "RUN_ID" {
  type        = string
  default     = "dev"
  description = "Run identifier written into every BuildKit history record name"
}

# ---------------------------------------------------------------- helpers

# Cache tags carry everything that changes every layer: target, ROCm and Python.
function "cache_tag" {
  params = [name]
  result = "${CACHE_REGISTRY}/rpb/cache:${name}-${GPU_ARCH}-rocm${ROCM_SDK_VERSION}-py${PYTHON_VERSION}"
}

function "cache_from" {
  params = [name]
  result = CACHE_REGISTRY == "" ? [] : [
    "type=registry,ref=${cache_tag(name)}",
    "type=registry,ref=${cache_tag(name)}-ref",
  ]
}

function "cache_to" {
  params = [name]
  result = CACHE_REGISTRY == "" ? [] : [
    "type=registry,ref=${cache_tag(name)}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,compression=zstd,compression-level=3,force-compression=true,ignore-error=true",
  ]
}

function "torch_dev_context" {
  params = []
  result = TORCH_DEV_IMAGE == "" ? "target:torch-dev" : "docker-image://${TORCH_DEV_IMAGE}"
}

# ---------------------------------------------------------------- targets

target "_common" {
  context = "."
  args = {
    GPU_ARCH         = GPU_ARCH
    RPB_GFX          = GPU_ARCH
    PYTHON_VERSION   = PYTHON_VERSION
    ROCM_SDK_VERSION = ROCM_SDK_VERSION
  }
  secret = SCCACHE_ENV_FILE == "" ? [] : ["id=sccache_env,src=${SCCACHE_ENV_FILE}"]
}

# Every real build is x86_64: the ROCm wheels and the sccache binary exist only for it.
target "_amd64" {
  inherits  = ["_common"]
  platforms = ["linux/amd64"]
}

target "base" {
  inherits    = ["_amd64"]
  description = "Ubuntu + Python + TheRock rocm-sdk ${ROCM_SDK_VERSION} + sccache + amdsmi, no frameworks"
  dockerfile  = "docker/base.Dockerfile"
  args = {
    BASE_IMAGE          = BASE_IMAGE
    ROCM_INDEX_URL      = ROCM_INDEX_URL
    SCCACHE_VERSION     = SCCACHE_VERSION
    SCCACHE_SHA256      = SCCACHE_SHA256
    BUILDKIT_BUILD_NAME = "rpb/base/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("base")
  cache-to   = cache_to("base")
}

target "torch-wheel" {
  inherits    = ["_amd64"]
  description = "PyTorch ${TORCH_REF} wheel for ${GPU_ARCH}"
  dockerfile  = "docker/torch.Dockerfile"
  target      = "export"
  contexts    = { base = "target:base" }
  args = {
    TORCH_GIT_URL       = TORCH_GIT_URL
    TORCH_REF           = TORCH_REF
    TORCH_SHA           = TORCH_SHA
    TORCH_VERSION       = TORCH_VERSION
    MAX_JOBS            = MAX_JOBS
    BUILDKIT_BUILD_NAME = "rpb/torch-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("torch")
  cache-to   = cache_to("torch")
  output     = ["type=local,dest=out/${GPU_ARCH}/torch"]
}

target "triton-wheel" {
  inherits    = ["_amd64"]
  description = "ROCm Triton wheel (no torch dependency, starts right after base)"
  dockerfile  = "docker/triton.Dockerfile"
  target      = "export"
  contexts    = { base = "target:base" }
  args = {
    TRITON_REF          = TRITON_REF
    TRITON_SHA          = TRITON_SHA
    MAX_JOBS            = FANOUT_JOBS
    BUILDKIT_BUILD_NAME = "rpb/triton-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("triton")
  cache-to   = cache_to("triton")
  output     = ["type=local,dest=out/${GPU_ARCH}/triton"]
}

target "torch-core" {
  inherits    = ["_amd64"]
  description = "base + our torch and triton wheels installed; torchvision is built on it"
  dockerfile  = "docker/torch-dev.Dockerfile"
  target      = "torch-core"
  contexts = {
    base         = "target:base"
    torch-wheel  = "target:torch-wheel"
    triton-wheel = "target:triton-wheel"
  }
  args = {
    BUILDKIT_BUILD_NAME = "rpb/torch-core/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("torch-core")
  cache-to   = cache_to("torch-core")
  output     = ["type=cacheonly"]
}

target "torchvision-wheel" {
  inherits    = ["_amd64"]
  description = "torchvision ${VISION_REF} wheel built against our torch"
  dockerfile  = "docker/torchvision.Dockerfile"
  target      = "export"
  contexts    = { torch-core = "target:torch-core" }
  args = {
    VISION_REF          = VISION_REF
    VISION_SHA          = VISION_SHA
    VISION_VERSION      = VISION_VERSION
    MAX_JOBS            = FANOUT_JOBS
    BUILDKIT_BUILD_NAME = "rpb/torchvision-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("torchvision")
  cache-to   = cache_to("torchvision")
  output     = ["type=local,dest=out/${GPU_ARCH}/torchvision"]
}

target "torch-dev" {
  inherits    = ["_amd64"]
  description = "base + our torch, triton and torchvision installed; parent of every downstream build"
  dockerfile  = "docker/torch-dev.Dockerfile"
  target      = "torch-dev"
  contexts = {
    base              = "target:base"
    torch-wheel       = "target:torch-wheel"
    triton-wheel      = "target:triton-wheel"
    torchvision-wheel = "target:torchvision-wheel"
  }
  args = {
    BUILDKIT_BUILD_NAME = "rpb/torch-dev/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("torch-dev")
  cache-to   = cache_to("torch-dev")
  output     = ["type=cacheonly"]
}

target "aiter-wheel" {
  inherits    = ["_amd64"]
  description = "AITER ${AITER_REF} wheel, PREBUILD_KERNELS=${AITER_PREBUILD}"
  dockerfile  = "docker/aiter.Dockerfile"
  target      = "export"
  contexts    = { torch-dev = torch_dev_context() }
  args = {
    AITER_REF           = AITER_REF
    AITER_SHA           = AITER_SHA
    AITER_VERSION       = AITER_VERSION
    AITER_PREBUILD      = AITER_PREBUILD
    MAX_JOBS            = FANOUT_JOBS
    BUILDKIT_BUILD_NAME = "rpb/aiter-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("aiter")
  cache-to   = cache_to("aiter")
  output     = ["type=local,dest=out/${GPU_ARCH}/aiter"]
}

target "fa-wheel" {
  inherits    = ["_amd64"]
  description = "FlashAttention (CK backend) wheel for gfx90a, gfx942 or gfx950"
  dockerfile  = "docker/fa.Dockerfile"
  target      = "export"
  contexts    = { torch-dev = torch_dev_context() }
  args = {
    FA_REF              = FA_REF
    FA_SHA              = FA_SHA
    MAX_JOBS            = FANOUT_JOBS
    BUILDKIT_BUILD_NAME = "rpb/fa-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("fa")
  cache-to   = cache_to("fa")
  output     = ["type=local,dest=out/${GPU_ARCH}/fa"]
}

target "lmcache-wheel" {
  inherits    = ["_amd64"]
  description = "LMCache ${LMCACHE_REF} wheel, separate from vLLM"
  dockerfile  = "docker/lmcache.Dockerfile"
  target      = "export"
  contexts    = { torch-dev = torch_dev_context() }
  args = {
    LMCACHE_REF         = LMCACHE_REF
    LMCACHE_SHA         = LMCACHE_SHA
    LMCACHE_VERSION     = LMCACHE_VERSION
    MAX_JOBS            = FANOUT_JOBS
    BUILDKIT_BUILD_NAME = "rpb/lmcache-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("lmcache")
  cache-to   = cache_to("lmcache")
  output     = ["type=local,dest=out/${GPU_ARCH}/lmcache"]
}

target "vllm-wheel" {
  inherits    = ["_amd64"]
  description = "vLLM wheel: native extension stage + Rust frontend + Python packaging stage"
  dockerfile  = "docker/vllm.Dockerfile"
  target      = "export"
  contexts    = { torch-dev = torch_dev_context() }
  args = {
    VLLM_REF            = VLLM_REF
    VLLM_SHA            = VLLM_SHA
    VLLM_VERSION        = VLLM_VERSION
    TRITON_SHA          = TRITON_SHA
    RUST_TOOLCHAIN      = RUST_TOOLCHAIN
    MAX_JOBS            = FANOUT_JOBS
    BUILDKIT_BUILD_NAME = "rpb/vllm-wheel/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("vllm")
  cache-to   = cache_to("vllm")
  output     = ["type=local,dest=out/${GPU_ARCH}/vllm"]
}

target "test" {
  inherits    = ["_amd64"]
  description = "Install every wheel into a clean image and run the no-GPU checks"
  dockerfile  = "docker/test.Dockerfile"
  contexts = {
    base              = "target:base"
    torch-wheel       = "target:torch-wheel"
    triton-wheel      = "target:triton-wheel"
    torchvision-wheel = "target:torchvision-wheel"
    aiter-wheel       = "target:aiter-wheel"
    fa-wheel          = "target:fa-wheel"
    lmcache-wheel     = "target:lmcache-wheel"
    vllm-wheel        = "target:vllm-wheel"
  }
  target = "export"
  args = {
    BUILDKIT_BUILD_NAME = "rpb/test/${GPU_ARCH}/${RUN_ID}"
  }
  output = ["type=local,dest=out/${GPU_ARCH}/test"]
}

# ---------------------------------------------------------------- CI-only targets

# Dockerfile build checks without building. Named contexts point at a tiny pinned
# image so the check never builds or pulls the real parents.
target "lint" {
  name        = "lint-${df}"
  description = "BuildKit build checks of docker/${df}.Dockerfile (CI)"
  matrix      = { df = ["base", "torch", "triton", "torch-dev", "torchvision", "aiter", "fa", "lmcache", "vllm", "test"] }
  dockerfile  = "docker/${df}.Dockerfile"
  call        = "check"
  # The check still validates ADD flags, and "sha256:" with an empty value is rejected.
  args = { SCCACHE_SHA256 = SCCACHE_SHA256 }
  contexts = {
    base              = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    torch-core        = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    torch-dev         = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    torch-wheel       = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    triton-wheel      = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    torchvision-wheel = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    aiter-wheel       = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    fa-wheel          = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    lmcache-wheel     = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    vllm-wheel        = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
  }
}

# A tiny linked pair that exercises args, a target: link and the registry cache
# functions on a GitHub-hosted runner in under a minute. No sccache secret.
target "smoke-base" {
  inherits          = ["_common"]
  description       = "CI smoke test: first half of a linked pair, exported to the registry cache"
  dockerfile-inline = "FROM busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e\nARG GPU_ARCH\nRUN echo \"$GPU_ARCH\" > /arch && sleep 2"
  cache-from        = cache_from("smoke-base")
  cache-to          = cache_to("smoke-base")
  output            = ["type=cacheonly"]
}

target "smoke" {
  inherits          = ["_common"]
  description       = "CI smoke test: second half, built from smoke-base through a target: link"
  contexts          = { base = "target:smoke-base" }
  dockerfile-inline = "FROM base\nRUN test -s /arch && cat /arch"
  cache-from        = cache_from("smoke")
  cache-to          = cache_to("smoke")
  output            = ["type=cacheonly"]
}

# ---------------------------------------------------------------- groups

group "default" {
  description = "Every wheel"
  targets     = ["wheels"]
}
group "wheels" {
  description = "Every wheel"
  targets     = ["torch-wheel", "triton-wheel", "torchvision-wheel", "aiter-wheel", "fa-wheel", "lmcache-wheel", "vllm-wheel"]
}
group "all" {
  description = "Every wheel, then the install-and-test check"
  targets     = ["wheels", "test"]
}
group "downstream" {
  description = "The wheels built from torch-dev (scripts/rpb-cluster phase B)"
  targets     = ["aiter-wheel", "fa-wheel", "lmcache-wheel", "vllm-wheel"]
}
