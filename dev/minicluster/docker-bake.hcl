# Extra targets for the dev mini-cluster. Use together with the top-level file:
#   docker buildx bake -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl <target>

variable "CACHE_PROBE" {
  type        = string
  default     = "1"
  description = "Compiled into every toy source: a new value forces new compiles; fail makes the build fail"
}
variable "TOY_WAIT_REDIS_DOWN" {
  type        = string
  default     = ""
  description = "host:port; when set, the toy compiles only after that address stops answering"
}
variable "TOY_FILES" {
  type        = number
  default     = 40
  description = "Number of C++ files the toy target compiles"
}

target "toy" {
  inherits   = ["_common"]
  dockerfile = "dev/minicluster/toy.Dockerfile"
  target     = "export"
  args = {
    CACHE_PROBE         = CACHE_PROBE
    TOY_FILES           = TOY_FILES
    TOY_WAIT_REDIS_DOWN = TOY_WAIT_REDIS_DOWN
    BUILDKIT_BUILD_NAME = "rpb/toy/${GPU_ARCH}/${RUN_ID}"
  }
  cache-from = cache_from("toy")
  cache-to   = cache_to("toy")
  output     = ["type=local,dest=out/${GPU_ARCH}/toy"]
}
