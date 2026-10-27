# Extra targets for the dev mini-cluster. Use together with the top-level file:
#   docker buildx bake -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl <target>

variable "CACHE_PROBE" {
  default     = "1"
  description = "Change to force the compile step to run again while keeping the same sources"
}

target "toy" {
  inherits   = ["_common"]
  dockerfile = "dev/minicluster/toy.Dockerfile"
  target     = "export"
  args = {
    CACHE_PROBE         = CACHE_PROBE
    BUILDKIT_BUILD_NAME = "rpb/toy/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("toy")
  cache-to   = cache_to("toy")
  output     = ["type=local,dest=out/${GPU_ARCH}/toy"]
}
