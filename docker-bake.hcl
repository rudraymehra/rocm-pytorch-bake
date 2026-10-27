# rocm-pytorch-bake: build PyTorch, vLLM and LMCache from source for ONE AMD GPU target.
#
#   docker buildx bake --list=variables            # every knob, typed and described
#   docker buildx bake --print all                 # resolved config; CI uses this as the validator
#   docker buildx bake --var GPU_ARCH=gfx950 all   # --var beats environment variables
#
# Site-specific values (cache registry, Redis secret file, job counts) belong in a
# gitignored docker-bake.override.hcl, which bake merges automatically.
# Requires buildx >= 0.38.0 (bake --jobs) and BuildKit >= 0.17.0.

# ---------------------------------------------------------------- target and toolchain

variable "GPU_ARCH" {
  type        = string
  default     = "gfx942"
  description = "Exactly one AMD GPU target, for example gfx942 or gfx950"
  validation {
    condition     = can(regex("^gfx[0-9a-f]{3,4}$", GPU_ARCH))
    error_message = "GPU_ARCH must be ONE target like gfx942, not a list."
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
  default     = "https://github.com/pytorch/pytorch.git"
  description = "PyTorch source repository; AIC builds from https://github.com/ROCm/pytorch.git (Q1)"
}
variable "TORCH_REF" {
  default = "v2.13.0"
}
variable "TORCH_SHA" {
  default = "cf30153c4c131c8164ee7798e5022d810682e2cb"
}
variable "TORCH_VERSION" {
  default     = "2.13.0"
  description = "Public torch version; the wheel gets a +rpb local suffix"
}
variable "TRITON_REF" {
  default     = "669b31acc1dd1b3fd93286afd5db67f65d9f7557"
  description = "ROCm/triton commit (release/internal/3.8.x), as pinned by vLLM"
}
variable "TRITON_SHA" {
  default = "669b31acc1dd1b3fd93286afd5db67f65d9f7557"
}
variable "AITER_REF" {
  default = "v0.1.26"
}
variable "AITER_SHA" {
  default = "84077b3c0461dac1f0f3f8b9590a9282e2035a2f"
}
variable "AITER_VERSION" {
  default = "0.1.26"
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
  default = "0e60e39473e8df549a20fb5353760f7a65b30e2d"
}
variable "FA_SHA" {
  default = "0e60e39473e8df549a20fb5353760f7a65b30e2d"
}
variable "LMCACHE_REF" {
  default = "v0.5.3"
}
variable "LMCACHE_SHA" {
  default = "140819c9d57a975dbc5678a6459a218e544cb58b"
}
variable "LMCACHE_VERSION" {
  default = "0.5.3"
}
variable "VLLM_REF" {
  default     = "e8ae84bf7e992c63570905fce3073fd7a7de2412"
  description = "vLLM main at the merge of PR #62475 (split attention TUs)"
}
variable "VLLM_SHA" {
  default = "e8ae84bf7e992c63570905fce3073fd7a7de2412"
}
variable "VLLM_VERSION" {
  default     = "0.32.1rc1.dev195+ge8ae84bf7"
  description = "PEP 440 version for the vLLM wheel, as setuptools-scm computes it at VLLM_SHA (docs/PINS.md)"
  validation {
    condition     = VLLM_VERSION != ""
    error_message = "VLLM_VERSION must be set; see docs/PINS.md."
  }
}

variable "_SHAS" {
  default = [TORCH_SHA, TRITON_SHA, AITER_SHA, FA_SHA, LMCACHE_SHA, VLLM_SHA]
  validation {
    condition     = length([for s in _SHAS : s if !can(regex("^[0-9a-f]{40}$", s))]) == 0
    error_message = "Every *_SHA must be a full 40-character lowercase git commit."
  }
}

# ---------------------------------------------------------------- site knobs (override file or --var)

variable "CACHE_REGISTRY" {
  type        = string
  default     = ""
  description = "host:port of the zot layer cache; empty disables registry cache"
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
  description = "Compiler jobs for the torch build"
  validation {
    condition     = MAX_JOBS > 0
    error_message = "MAX_JOBS must be positive."
  }
}
variable "FANOUT_JOBS" {
  type        = number
  default     = 16
  description = "Compiler jobs for EACH downstream target (vLLM, LMCache, AITER, FA run in parallel)"
  validation {
    condition     = FANOUT_JOBS > 0
    error_message = "FANOUT_JOBS must be positive."
  }
}
variable "RUN_ID" {
  type        = string
  default     = "dev"
  description = "Run identifier written into every BuildKit history record name"
}

# ---------------------------------------------------------------- helpers

function "cache_from" {
  params = [name]
  result = CACHE_REGISTRY == "" ? [] : [
    "type=registry,ref=${CACHE_REGISTRY}/rpb/cache:${name}-${GPU_ARCH}",
    "type=registry,ref=${CACHE_REGISTRY}/rpb/cache:${name}-${GPU_ARCH}-ref",
  ]
}

function "cache_to" {
  params = [name]
  result = CACHE_REGISTRY == "" ? [] : [
    "type=registry,ref=${CACHE_REGISTRY}/rpb/cache:${name}-${GPU_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,compression=zstd,compression-level=3,force-compression=true,ignore-error=true",
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
    PYTHON_VERSION   = PYTHON_VERSION
    ROCM_SDK_VERSION = ROCM_SDK_VERSION
  }
  secret = SCCACHE_ENV_FILE == "" ? [] : ["id=sccache_env,src=${SCCACHE_ENV_FILE}"]
}

target "base" {
  inherits    = ["_common"]
  description = "Ubuntu + Python + TheRock rocm-sdk ${ROCM_SDK_VERSION} + sccache, no frameworks"
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
  inherits    = ["_common"]
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
  inherits    = ["_common"]
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

target "torch-dev" {
  inherits    = ["_common"]
  description = "base + our torch and triton wheels installed; parent of every downstream build"
  dockerfile  = "docker/torch-dev.Dockerfile"
  contexts = {
    base         = "target:base"
    torch-wheel  = "target:torch-wheel"
    triton-wheel = "target:triton-wheel"
  }
  args = {
    BUILDKIT_BUILD_NAME = "rpb/torch-dev/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("torch-dev")
  cache-to   = cache_to("torch-dev")
  output     = ["type=cacheonly"]
}

target "aiter-wheel" {
  inherits    = ["_common"]
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
  inherits    = ["_common"]
  description = "FlashAttention (CK backend) wheel; CDNA targets (gfx9xx) only"
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
  inherits    = ["_common"]
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
  inherits    = ["_common"]
  description = "vLLM wheel: native extension stage + Python packaging stage"
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
  inherits    = ["_common"]
  description = "Install every wheel into a clean image and run the no-GPU checks"
  dockerfile  = "docker/test.Dockerfile"
  contexts = {
    base          = "target:base"
    torch-wheel   = "target:torch-wheel"
    triton-wheel  = "target:triton-wheel"
    aiter-wheel   = "target:aiter-wheel"
    fa-wheel      = "target:fa-wheel"
    lmcache-wheel = "target:lmcache-wheel"
    vllm-wheel    = "target:vllm-wheel"
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
  name       = "lint-${df}"
  matrix     = { df = ["base", "torch", "triton", "torch-dev", "aiter", "fa", "lmcache", "vllm", "test"] }
  dockerfile = "docker/${df}.Dockerfile"
  call       = "check"
  contexts = {
    base          = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    torch-dev     = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    torch-wheel   = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    triton-wheel  = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    aiter-wheel   = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    fa-wheel      = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    lmcache-wheel = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
    vllm-wheel    = "docker-image://busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
  }
}

# A tiny linked pair that exercises args, a target: link and the registry cache
# functions on a GitHub-hosted runner in under a minute.
target "smoke-base" {
  inherits          = ["_common"]
  dockerfile-inline = "FROM busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e\nARG GPU_ARCH\nRUN echo \"$GPU_ARCH\" > /arch && sleep 2"
  cache-from        = cache_from("smoke-base")
  cache-to          = cache_to("smoke-base")
  output            = ["type=cacheonly"]
}

target "smoke" {
  inherits          = ["_common"]
  contexts          = { base = "target:smoke-base" }
  dockerfile-inline = "FROM base\nRUN test -s /arch && cat /arch"
  cache-from        = cache_from("smoke")
  cache-to          = cache_to("smoke")
  output            = ["type=cacheonly"]
}

# ---------------------------------------------------------------- groups

group "default" {
  targets = ["wheels"]
}
group "wheels" {
  targets = ["torch-wheel", "triton-wheel", "aiter-wheel", "fa-wheel", "lmcache-wheel", "vllm-wheel"]
}
group "all" {
  targets = ["wheels", "test"]
}
group "downstream" {
  targets = ["aiter-wheel", "fa-wheel", "lmcache-wheel", "vllm-wheel"]
}
