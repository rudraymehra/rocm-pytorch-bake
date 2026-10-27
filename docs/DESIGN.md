# rocm-pytorch-bake: Design

**Status:** v3, matches the code on the `dev` branch (v2 incorporated your six points of 26 Oct; Section 10 lists what changed since)
**Author:** Rudray Mehra
**Reviewer:** Stephen Bates
**Last updated:** 28 October 2026

---

## 1. Summary

Build PyTorch, vLLM and LMCache (with torchvision, Triton, AITER and FlashAttention) from source for a single AMD GPU target, with the fastest possible cold build, a warm build that reuses nearly everything, and minimal wheels for deployment. The build is driven by one top-level `docker-bake.hcl` and runs on remote BuildKit builders, one per machine, each configured by a shared `buildkitd.toml`. Two caches serve the whole cluster: a zot registry on one node for layer caching, and a Redis-backed sccache on one node for compile caching. Timing and cache hit rates come from BuildKit build history (`docker buildx history`) plus sccache statistics, and go into Prometheus. The repo has CI from the first commit, and the results are benchmarked on EC2 so anyone can reproduce them.

This document describes the design as implemented, the evidence behind each choice, and the questions that are still open. No full build of the real wheels has run yet; the end-to-end checks of the infrastructure are listed at the top of `dev/minicluster/run.sh`.

## 2. Goals and non-goals

### Goals

- G1. Build PyTorch, vLLM and LMCache from source for one gfx target.
- G2. Fast cold builds; warm builds that rebuild only what changed.
- G3. Use several build machines through remote BuildKit builders.
- G4. Minimal wheels, with vLLM and LMCache as separate artifacts.
- G5. Build telemetry in Prometheus: stage times and cache hit rates.
- G6. Reproducible benchmarks on rented EC2 hardware.
- G7. CI and documentation from the start.

### Non-goals (v1)

- Multi-arch fat wheels.
- Runtime or inference performance; this is about build time and artifact size only.
- Publishing to PyPI (the torch wheel exceeds the 100 MiB per-file limit).
- Replacing AIC. The repo can feed AIC later if useful (see Q7).

## 3. Baseline

Numbers taken from primary sources: CI logs, repository files and pull requests. All are subject to re-measurement on identical hardware (Section 4.9).

| Build | Setup | Cold | Warm |
|---|---|---|---|
| AIC nightly (`main`, run 40298645134) | 9 targets, one node | 99.6 min build phase (torch 1941 s, vLLM wheel 2522 s) | None in practice (see below) |
| `dev/stebates/buildx-bake` | Prebuilt ROCm 10.1 and torch, gfx1201, 128 cores | 29m56s | 12m37s (ccache 47.5% hit) |
| TheRock CI, torch wheel step only | sccache on S3 | 58m58s | 14m00s |

Observations on the current AIC build, which this design addresses:

1. `buildx prune --force`, and recreating the builder whenever `docker/buildkitd.toml` exists, remove layers, cache mounts and build history before each build, so every nightly starts cold.
2. The stage that builds vLLM, AITER and FlashAttention starts from the `-full` image, which has no ccache, so those compiles are never cached.
3. AITER, FlashAttention and vLLM build serially in one stage.
4. `BLAS_CACHE_BUST = timestamp()` invalidates a layer on every run.
5. Layer cache lives in one shared `type=local` directory on NFS, which several targets overwrite.
6. `docker/buildkitd.toml` sets `[log] max-size = -1`, a key buildkitd does not have. buildkitd ignores unknown keys silently, so the file has no effect. The step-log limit is the daemon env var `BUILDKIT_STEP_LOG_MAX_SIZE`, which `mk/local.mk` already sets correctly. With no GC policy, the default caps the cache at 100 GB and drops idle cache mounts after 48 hours.
7. No build-time telemetry.

Nobody has published a sccache hit rate or a cold/warm breakdown for a ROCm PyTorch build. Producing that data is one of the main outputs of this project.

## 4. Design

### 4.1 Top-level bake file and pins

```text
docker-bake.hcl                 the one top-level file: pins, knobs, functions, targets, groups
rpb.env.example                 per-site values as environment variables (zot address, Redis secret file, job counts)
docker/*.Dockerfile             one per component
infra/buildkit/buildkitd.toml   shared builder config (Section 4.5)
infra/cache-node/, infra/monitoring/, infra/certs/, infra/ec2/   the cluster and the EC2 hosts
scripts/, telemetry/            the build wrapper and the run records (Section 4.8)
```

- **One file holds every source pin.** Bake HCL has no include, so pins in a second HCL file would need `-f` (or `BUILDX_BAKE_FILE`) on every run, and a run that forgot it would silently use other versions. Your branch and AIC main already keep pins as variables in the bake file; this follows that. Tool and image pins (BuildKit, zot, Valkey, Prometheus and others) live where they are used; `docs/PINS.md` lists every one.
- **Source pins:** torch, torchvision, Triton, AITER, FlashAttention, LMCache and vLLM, each as a ref plus a full commit SHA; also the ROCm SDK version, the base image by digest, and sccache by version and tarball sha256. Every variable can be set by environment variable or `--var`, which keeps its type and validation (re-declaring it in an override file would not).
- **What makes the file worth reading:**
  - Typed variables with `validation` blocks: `GPU_ARCH` must be exactly one of gfx90a, gfx942 and gfx950 (the targets AITER and FlashAttention support), every SHA must be 40 hex characters, job counts must be positive whole numbers, and `VLLM_VERSION` must match `VLLM_SHA`. A bad value fails at parse time, before anything builds.
  - Functions generate the zot `cache-from` and `cache-to` refs per target, so cache naming is defined in one place.
  - A `matrix` target generates the BuildKit lint checks of every Dockerfile; each build target is written out with its `target:` links (`scripts/bake-graph` prints the graph).
  - `description` on every variable and target, so `docker buildx bake --list=variables` documents the knobs.
  - `lint` and `smoke` targets for CI (Section 4.11).
- **Secrets** (the Redis credentials) enter through the bake `secret` attribute and `RUN --mount=type=secret`, never as `ARG`. They stay out of layers, provenance and cache keys.
- Sources are fetched with `ADD --checksum=<sha> <git url>`. The build fails if a tag and SHA disagree, and BuildKit fetches submodules itself. This also covers AIC issue #143 (re-cloning on every build).
- Each version `ARG` is declared only in the stage that uses it, so changing one pin does not invalidate unrelated stages.
- Cache refs carry the target, gfx target, ROCm SDK and Python versions, but **not** the source pins, so a pin bump still finds the previous cache. The run record carries every pin.
- Patches live under `patches/<package>/` and are applied in file-name order.
- vLLM is pinned to a commit that includes PR #62475, which splits the slow attention compile into parallel units (547 s on one core down to 72 s wall on 12 cores, gfx950).
- Requires buildx v0.38 or later, for `bake --jobs` (Section 4.2).

### 4.2 Stage graph

```text
fetch sources (URL + SHA)
        |
hipify + patches          (does not depend on the ROCm image)
        |
torch compile  -> torch wheel          Triton builds in parallel from the start
        |                                (no torch dependency)
torch-core (torch + Triton installed) -> torchvision wheel
        |
torch-dev image (+ torchvision) ----> pushed to zot, used by other machines
        |
   +----+-------+-----------+-----------+
   |            |           |           |
 vLLM native  AITER   FlashAttention  LMCache
 vLLM Rust frontend (from base, in parallel)
   |
 vLLM python packaging (cheap, reuses native .so)

All wheels exported via FROM scratch stages (type=local)
```

- The native vLLM compile is keyed on the two ROCm requirement files and the native sources only (vLLM's own `csrc-build` pattern), so a Python-only edit or a version-string change does not recompile kernels.
- Inside each stage: stable, expensive steps first; patches and scripts last; narrow `COPY` paths.
- `bake --jobs=defer-error`, so that when one target fails, the others still finish and save their cache. No `parallel=N` limit: buildx rejects limited parallelism when targets are linked through `target:` contexts.
- Concurrency per machine is bounded twice: BuildKit's `max-parallelism` limits concurrent build steps (Section 4.5), and each target gets an explicit job count for the compiler threads inside its step (`MAX_JOBS` for torch, `FANOUT_JOBS` for each other target). Job counts are part of the layer cache key, so every builder of one host class uses the same values.
- **One Dockerfile per component, linked by `target:` contexts.** Your branch uses a single multi-stage Dockerfile, which Docker's docs also prefer. Separate files let each component's cache and owner be independent and let the torch-dev image be handed between machines through zot. Either works with this design (Q4).
- Estimated cold time on one 32 to 64 core builder: **40 to 75 minutes**, with torch taking 50 to 80% of it. This is an estimate until measured, and it assumes no AITER kernel prebuild.
- If AITER kernel prebuild is required, AITER, not torch, may set the critical path. AIC's own patch notes measure 61 minutes for about 107 modules on 128 cores, with a three-module tail running over 85 minutes on its own (`patches/aiter/03-aiter-prebuild-threads.py`, PR #186).

### 4.3 Compile cache: sccache on Redis

```text
builder 1 ──┐
builder 2 ──┼── sccache: L0 local disk (BuildKit cache mount) → L1 Redis on one node
builder 3 ──┘
```

- **Tool:** sccache v0.19.0. ccache is kept only as a comparison arm, to reproduce your prototype's numbers.
- **Chain:** `SCCACHE_MULTILEVEL_CHAIN=disk,redis`. A per-target BuildKit cache mount is the fast local level; one Redis node is the shared level for the whole cluster.
- **Write policy `all`, not the default** (set by `scripts/rpb-sccache-run`, which refuses any other). Under the default `l0` policy, writes to Redis are detached background tasks (`src/cache/multilevel.rs`, `tokio::spawn`). Each `RUN` step stops the sccache server when it ends, so pending writes can be lost and Redis fills more slowly than it should. With `SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY=all`, each compile waits for its Redis write, and sccache checks Redis at startup. When Redis is down, the `RUN` step falls back to disk-only sccache with a warning and records `fallback` in the run record and in Prometheus; with `RPB_SCCACHE_REQUIRE_REMOTE=1` (tests and benchmarks) it fails instead.
- **Redis server** (Valkey 9.1, the BSD-licensed Redis fork, as proposed default; plain Redis works the same, Q5):
  - `maxmemory` set explicitly (start at 32 GB, resize after the first cold build) with `allkeys-lru` eviction, so the cache can never exhaust the node.
  - No persistence (`save ""`, `appendonly no`). Snapshots fork the process and can briefly need up to twice the RAM; losing the cache costs one cold build.
  - No `SCCACHE_REDIS_EXPIRATION`: the TTL is set on write and is not refreshed by hits, so hot entries would expire. LRU eviction does the job instead.
  - Bound to the LAN address only, default user disabled, and an ACL user for sccache limited to its key prefix.
  - Key prefix per cache generation (`rpb/v1`), so a deliberate reset is a prefix change, not a flush.
- **Sizing, an estimate to be measured in E1:** about 3 to 8 GB in Redis for one full torch, vLLM, LMCache and AITER build for one gfx target, and about 10 to 25 GB to keep three source versions warm. No public measurement exists; `INFO memory` after the first cold build gives the real number.
- **Known limits:**
  - Each builder's sccache talks to Redis over at most 10 connections (OpenDAL's fixed pool, not configurable in sccache). A slow Redis shows up as compile stalls, which telemetry will catch.
  - Single node, no durable tier. A later `disk,redis,s3` chain is possible if wanted.
  - TLS (`rediss://`) needs a CA trusted inside the builder image; the `#insecure` suffix in sccache's docs is ignored by the code.
- **Hooked at clang, never at hipcc:**
  - torch: `CMAKE_C/CXX/HIP_COMPILER_LAUNCHER=sccache`, with `USE_CCACHE=0`.
  - vLLM: picked up automatically by its `setup.py`.
  - LMCache, AITER, FlashAttention and torchvision: hipcc finds clang through `HIP_CLANG_PATH`, which these steps point at two wrapper scripts (`/opt/sccache-wrappers`) that call clang through sccache. (`HIP_CLANG_LAUNCHER` would do the same but is ignored silently by hipcc before ROCm 7.13.)
  - vLLM's Rust frontend: `RUSTC_WRAPPER=sccache`, as upstream.
- **Settings that matter for HIP:**
  - `SCCACHE_DIRECT=false`. PyTorch main adds `--offload-compress` to every HIP compile, which makes sccache's direct mode fail the compile (sccache #2762; fix #2788 still open).
  - `SCCACHE_IDLE_TIMEOUT=0`, because some files compile for over 10 minutes.
  - `SCCACHE_CACHE_SIZE` caps the local disk level, which BuildKit's GC depends on (Section 4.5).
  - An identical `WORKDIR` on every builder, instead of `SCCACHE_BASEDIRS` (open correctness bug #2863).
  - The ROCm image pinned by digest. Cache keys include the compiler hash, so every builder must use the same image.
  - The Redis endpoint and credentials come from one BuildKit secret file. sccache's cache key does not include them, and as a secret they do not enter BuildKit's.

### 4.4 Layer cache: zot on one node

- zot v2.1.22 on local NVMe, plain HTTP, reachable only on the LAN or VPC. Each builder's `buildkitd.toml` marks it `http = true`.
- Two repositories: `rpb/cache` (layer cache, every tag kept) and `rpb/torch-dev` (the image handed between machines, three newest tags kept). `dedupe: false` is set explicitly: dedupe is on by default and takes a store-wide write lock on blob checks (#4582).
- GC with a 2-hour delay, and retention by tag count (zot has no size-based eviction).
- HTTP read and write timeouts of 30 minutes; zot's default of 60 seconds cuts off multi-GB layer transfers.
- Cache export settings:
  - One cache ref per target, gfx target, ROCm SDK and Python version, generated by the bake functions, with `mode=max` and `ignore-error=true`.
  - zstd level 3 everywhere, and never mixed compression (mixing it is linked to BuildKit #6088, out of memory on export).
- A reference cache ref written only by baseline-pin builds, listed as a fallback in every `cache-from`.
- No `buildx prune` and no builder recreation between builds, and no NFS cache directories.
- Fallback registry if zot underperforms: distribution v3.

### 4.5 Builders: remote buildkitd and `buildkitd.toml`

One `buildkitd` per machine, run as the pinned `moby/buildkit:v0.34.1` image (by digest), rootful, host network, state on local NVMe, started with `--config /etc/buildkit/buildkitd.toml`. Clients attach with `docker buildx create --driver remote` and mTLS certificates. The remote driver does not accept `--buildkitd-config`, so the TOML lives on each machine and is installed from this repo.

What the shared `buildkitd.toml` sets, and why:

| Section | Setting | Why |
|---|---|---|
| `[grpc]`, `[grpc.tls]` | TCP listener with `cert`, `key` and `ca` | Setting `ca` enforces client certificates. Build steps share the host network and could otherwise reach the daemon API. |
| `[worker.oci]` | `max-parallelism = 8`, overlayfs | Caps concurrent build steps across all targets on the machine; compiler threads are set separately by `MAX_JOBS`. |
| `[[worker.oci.gcpolicy]]` | Ordered rules, sized for the actual NVMe | Default GC caps the cache at 100 GB and drops idle cache mounts after 48 h. Ordered rules: git checkouts and contexts unused for 3 days; layers unused for 14 days (zot can restore them); cache mounts (sccache local level, pip) unused for 30 days; then a size backstop over every record at 75% and 80% of the disk, least recently used first. |
| `[registry."<zot>"]` | `http = true` | zot is plain HTTP on the LAN. (`insecure = true` means HTTPS with an untrusted certificate, a different thing.) |
| `[history]` | `maxAge = "336h"`, `maxEntries = 200` | Build records are the source for timing and hit rates (Section 4.8). Both must be set: a `[history]` section with one field missing treats it as zero. Default without the section is 48 h / 50 records. Records keep full step logs outside the build-cache GC, so both limits stay moderate. |
| `[log]` | `format = "json"` | Step-log limits are the daemon env vars `BUILDKIT_STEP_LOG_MAX_SIZE` and `BUILDKIT_STEP_LOG_MAX_SPEED`, set to unlimited for verbose kernel compiles. |
| `[grpc] debugAddress` | Optional, management network only | Exposes BuildKit's own `/metrics` to Prometheus. Unauthenticated, so firewalled. |

One dependency to note: in BuildKit GC, each rule's size limit is compared with the **total** cache, but the rule deletes only the entries its filter matches. A size limit on the layer rule would therefore delete every layer whenever cache mounts alone pass that size. So the filtered rules expire by age only, size is handled by the backstop rules over every record, and the local sccache level is also capped by sccache itself (`SCCACHE_CACHE_SIZE`).

### 4.6 Multiple machines

`buildx create --append` picks a node by platform only. When every node is linux/amd64, all work goes to the first node. I confirmed this in `build/resolver/driver.go`. The proposal:

- One builder per machine (Section 4.5), with BuildKit and buildx versions pinned.
- A thin wrapper that runs separate `bake --builder` invocations. Each target goes back to the machine that built it last, where its cache is warmest. Work moves between machines through zot (the torch-dev image) and the shared Redis sccache.
- The wrapper works under Slurm as well: Slurm allocates nodes, the wrapper schedules builds.

**Expected effect, stated plainly.** The chain base → torch → downstream cannot be split, so routing whole targets to more machines speeds up a single cold build by about 1.05× at most (Amdahl estimate). The gains from more machines come from running builds concurrently and from sharing a warm cache: a new machine, or a target landing on a different machine, compiles almost nothing. sccache-dist could add roughly 1.15 to 1.2× on 3 machines if HIP compiles cannot be distributed, and 1.36 to 1.47× if they can. It goes in only if a two-host HIP test passes and it cuts torch cold time by 25% or more.

### 4.7 Minimal wheels

- ROCm is never bundled into our wheels. For gfx942 the ROCm runtime is about 2.4 GiB, mostly hipBLASLt kernels, which is far larger than torch's own device code (about 51 MiB).
- **Two flavours:**
  - Depend on a pinned TheRock `rocm-sdk` (implemented): the torch wheel declares `rocm[libraries]==<ROCM_SDK_VERSION>` and its shared objects find the ROCm libraries next to torch through RPATH, as PyTorch's own TheRock wheels do.
  - Assume a system ROCm already installed on the node (not implemented yet).
- **Trims:**
  - Single arch.
  - `BUILD_TEST=0`.
  - vLLM built with `CMAKE_BUILD_TYPE=Release`.
  - Strip Triton: 624 MiB of its 835 MiB `libtriton.so` is debug info. Also drop Triton's NVIDIA backend (92 MiB compressed); that needs a patch and has to be tested.
  - Keep torch headers, which AITER needs to JIT-compile.
- **Separate wheels:**
  - Our torch and torchvision get a unique local version (`+rpb.<gfx>`). vLLM's and LMCache's metadata are not edited; the shipped `constraints.txt` (exact versions of the tested environment) pins everything, and `PIP_CONSTRAINT` protects torch, Triton and torchvision during the build.
  - torchvision is built from source against our torch: vLLM's requirements pull it in (through `timm`), and PyPI's build would be a CUDA one whose ops do not load against a ROCm torch.
  - torch does not declare Triton; `constraints.txt` pins it.
  - Only the torch and torchvision wheel names carry the gfx target; the other wheels have the same file name for every target and are kept apart by their output directory, `out/<gfx>/<package>/`.
  - amdsmi, which vLLM uses to detect ROCm, is built from the sources TheRock ships in `rocm-sdk-core` and shipped next to `constraints.txt`.
  - LMCache's NVIDIA-only requirements (`cufile-python`, `nvtx`) are removed from its metadata.
- **Expected download size for gfx942 (estimates):**

| Setup | Size |
|---|---|
| Today (vLLM index plus official torch) | ~6.5 GiB, measured |
| Our build with ROCm from pip | ~2.8 GiB |
| Our build with ROCm already on the node | ~0.44 GiB |

### 4.8 Telemetry: build history, sccache stats, Prometheus

**Per run, three sources, all captured automatically:**

1. **BuildKit build history** (`docker buildx history`), one record per bake target:
   - Each target sets `BUILDKIT_BUILD_NAME` to `rpb/<target>/<gfx>/<run-id>`, so records name themselves.
   - `history ls --format json` finds every record of the run by that name, including failed targets; `bake --metadata-file`, which lists only the targets that finished, adds their exact refs.
   - `history inspect <ref> --format json` gives the target's duration, error, build args, and total versus cached step counts.
   - `history logs <ref> --progress=rawjson` replays every step with start, end and cached flag. Stage durations come from this; `inspect` alone has only the whole-target duration.
2. **sccache stats** (`sccache --show-stats --stats-format=json`), captured in the same `RUN` step as the compile: hits, misses and errors per language and per cache level.
3. **`.ninja_log`** from torch and vLLM, for the slowest translation units.

**Two hit rates, reported separately, never merged:**

- *Layer hit rate:* cached steps ÷ total steps from BuildKit. Every step counts the same, so a cached `COPY` weighs as much as a cached torch compile; the per-step durations in the record show which steps the hits saved.
- *Compile hit rate:* from sccache. BuildKit cannot see it; when a layer misses but every compile hits Redis, only this number shows it.

**Storage and display:**

- One JSON record per run is the source of truth, with a `schema_version`, kept as an append-only results file.
- A `.prom` file per run slot written into the node-exporter textfile directory; `infra/monitoring/` runs node-exporter and a Prometheus that scrapes it and zot's metrics, and fits next to your AIC monitoring stack. A Grafana dashboard is planned.
- No Pushgateway; its series never expire on their own.

| Metric | Source |
|---|---|
| Target and stage wall time | `history inspect` and `history logs --progress=rawjson` |
| Steps total / cached | BuildKit history |
| sccache hits / misses / errors per language and level, and whether Redis was used | sccache JSON stats, `rpb-sccache-run` |
| Slowest translation units | `.ninja_log` |
| Registry requests and storage | zot metrics |
| CPU time and peak RSS per compile unit | `/usr/bin/time -v` |
| Wheel sizes | export stage |

Planned, not collected yet: Valkey `INFO` (memory, evictions), CPU, RAM and disk saturation of the builders (node-exporter on the builders), BuildKit's `/metrics`, and the critical path ÷ (CPU-seconds / cores) ratio.

### 4.9 Benchmark method

- **Four scripted reset levels** (BuildKit state, the shared compile cache, zot, the page cache), combined per scenario. A run only counts if the reset is verified.
- **Scenarios:**
  - Full cold.
  - New machine with only the shared compile cache warm, and with only zot warm.
  - No-op rebuild.
  - One-file vLLM patch (Python only, and one HIP file).
  - LMCache one-file patch.
  - torch one-file patch.
- **Fairness:** AIC and this build run on the same instance type, gfx target and pins, alternating in ABBA order (`bench/run-matrix.sh`). The cold headline is meant to run on 3 instances in parallel, one matrix per instance. This follows the cloud-benchmarking literature: Laaber et al. (EMSE 2019) and the ATC 2023 "ordering trap" paper.
- **Statistics:**
  - One A/A run to measure the noise floor.
  - Raw points published along with the median and min–max.
  - No claims smaller than 5%.
  - 4 to 5 repetitions for any significance claim.

### 4.10 EC2 plan and cost

- **Region:** us-east-2. On-demand prices match us-east-1, and AWS's Spot Instance Advisor rates m7a.16xlarge interruptions at under 5% there, versus 10 to 15% in us-east-1.
- **Builders:** m7a.16xlarge spot, with 64 physical cores and 256 GiB RAM. The spot price was $1.30 per hour on 27 Oct 2026, against $3.71 on demand.
- **Cache node:** one small memory-optimised instance running zot and Redis, sized after E1 measures the Redis footprint. This mirrors the "one node" layout on your cluster, so the EC2 numbers transfer.
- **Guardrails:** self-terminate timers on every instance, AWS Budgets alerts, tags, and a scripted all-region teardown check.
- **Budget:** run it in two phases.
  - **Phase 1 (about $15):** experiments E1, E2 and E5. These measure the real build times.
  - **Phase 2 (the benchmark matrix), estimated at about $45 on spot.** That makes about $60 for the whole campaign, or about $90 with a 50% allowance for reruns. The estimate rests on guessed build times and gets re-costed once Phase 1 has measured them. Some runs on AMD machines would cut it (Q6).
- All development happens locally first. EC2 is used only for the benchmark campaign.

### 4.11 CI and documentation

GitHub-hosted runners have 4 vCPUs, 16 GB RAM and about 14 GB of free disk, so a full build cannot run there. CI is tiered:

| Tier | Trigger | Runner | What runs |
|---|---|---|---|
| T0 static | Every PR and push | GitHub-hosted | `bake --print` (parse and variable validation), `bake --list`, `bake --call check` (Dockerfile build checks), hadolint, shellcheck, actionlint, markdownlint, link check, spelling, telemetry tests, the `buildkitd.toml` and Prometheus config checks, and a pin check against the git hosts |
| T1 smoke | Every PR and push | GitHub-hosted | A tiny linked bake pair that exercises args, `target:` contexts and the zot cache refs, in under a minute |
| T1 mini-cluster | Every PR and push | GitHub-hosted | Two mTLS builders, zot, Valkey, node-exporter and Prometheus on one runner; 8 end-to-end checks (`dev/minicluster/run.sh`) |
| T2 full build | Manual or nightly | Your cluster: an ephemeral self-hosted runner, or a GitHub runner driving a remote builder over mTLS | `bake --jobs=defer-error all`, wheel export, cache push to zot, telemetry record, import test of the wheels |
| T3 benchmark | Manual only | EC2, with a teardown step | The ABBA campaign of Section 4.9 |

- T2 never runs on pull requests from forks. GitHub warns against self-hosted runners on public repositories, so the runner is ephemeral and the trigger is maintainer-only, the same pattern AIC uses.
- **Documentation**, plain Markdown in `docs/`:
  - `README.md`: what it is, a quickstart, requirements and supported GPU targets.
  - `docs/DESIGN.md`: this document.
  - `docs/OPERATIONS.md`: setting up builders, zot and Redis, certificates, teardown.
  - `docs/PINS.md`: how to bump a pin.
  - `docs/TELEMETRY.md`, `docs/BENCHMARKING.md`, and `docs/CI.md`.
  - `docs/adr/`: one short record per design decision.
  - `CONTRIBUTING.md` with DCO sign-off, `CODEOWNERS`, and a license matching AIC's MIT.

## 5. Success criteria (proposed)

Measured against AIC on identical hardware, gfx target and pins:

| Criterion | Target |
|---|---|
| Full cold build | ≤ 0.8× AIC |
| New machine, warm shared cache | ≤ 0.3× our cold time, with sccache hit rate ≥ 95% |
| No-op rebuild | ≤ 2 min |
| One-file vLLM patch | ≤ 6 min |
| LMCache-only patch | Rebuilds nothing in vLLM, judged by cached-step count |
| Telemetry | Layer and compile hit rates and stage times published for every run |

Expectation to set up front: with torch built from source, our cold build will be slower than your prebuilt-torch prototype (about 30 min). The comparison that matters is like for like.

## 6. Risks

| Risk | Mitigation |
|---|---|
| sccache gets low hit rates on HIP | Measure first (E1); ccache comparison arm kept |
| Redis node fills up or goes down | `maxmemory` with LRU eviction; disk-only fallback in every `RUN`; memory and evictions in telemetry |
| Redis connection pool (10 per builder) stalls compiles | Measured in E1; fall back to a disk-only build for that machine |
| BuildKit GC evicts layers or cache mounts unexpectedly | Ordered GC rules sized for the disk; sccache local level capped by `SCCACHE_CACHE_SIZE` |
| Large `mode=max` exports trigger BuildKit export bugs | `ignore-error`, uniform compression, per-run timeout, daemon restart between runs |
| zot slows down with tens of GB of cache | Throughput test (E4); distribution v3 as fallback |
| Pin drift between torch, vLLM and LMCache | One bake file, variable validation, and a stage that fails when torch versions disagree |
| EC2 cost overrun | Spot, self-terminate timers, phased budget re-costed after Phase 1, teardown check |
| AITER prebuild dominates the critical path | Measure it separately; confirm whether prebuild is needed (Q3) |

## 7. Experiments before implementation

None of these need a GPU.

| ID | Experiment | Purpose |
|---|---|---|
| E1a | sccache direct mode with `--offload-compress` on one HIP file | Confirm the failure and the `SCCACHE_DIRECT=false` fix |
| E1 | Cross-machine sccache hit rate through Redis, gfx942-only torch and vLLM | Two fresh builders should reach ~100%; measure Redis memory and connection-pool waits |
| E2 | Cores vs wall time and peak RSS at 32, 64 and 96 cores | Find the critical path and the RAM per job |
| E3 | sccache-dist with clang HIP, one file, two hosts | Decide whether compile distribution is viable |
| E4 | zot push/pull throughput and GC at tens of GB | Validate the registry choice |
| E5 | Wheel size waterfall, one trim step at a time, smoke test after each | Confirm the size estimates |
| E6 | Replay timestamps of `history logs --progress=rawjson` | Confirm stage durations can be recovered after the build |

## 8. Milestones

1. You review this document and answer the questions below.
2. Done on `dev`: the bake file, all Dockerfiles, `buildkitd.toml`, the cache node, the telemetry harness with Prometheus, CI tiers T0 and T1 (including the mini-cluster), and the docs.
3. Next: the first full build on one x86 builder (with E1a, E1, E2, E5 and E6), then E3 and E4.
4. Enable T2 on your cluster; add the Grafana dashboard.
5. Run the EC2 benchmark campaign; publish raw data and a short report.
6. Only then: merge `dev` into `main` and tag v1.0.0.

## 9. Questions still to be answered

1. **Torch source:** AIC builds torch from the ROCm/pytorch fork (commit `ec5f3b1`, 2.13 series), while our default is upstream `v2.13.0`, the version vLLM pins for ROCm. Which source should we build, and do you carry patches on top of it? `patches/pytorch/` in AIC is currently empty.
2. **ROCm base:** TheRock `rocm-sdk` (as in your `buildx-bake` branch) or `/opt/rocm` 7.14 (as in AIC main)? This decides the wheel model and whether `HIP_CLANG_LAUNCHER` is available.
3. **Target, patches and AITER:** Which gfx target? Which vLLM and LMCache patches must we carry? Is AITER kernel prebuild required? AIC measured about 61 minutes for it, which would put it ahead of torch on the critical path.
4. **Bake file layout:** One Dockerfile per component linked by `target:` contexts, or your single multi-stage Dockerfile? Should we adopt your variable names (`GPU_ARCH`, `CACHE`, `REGISTRY`) so the two projects match?
5. **Cache node:** How much RAM and what NIC speed does the Redis/zot node have? Is losing the compile cache on a reboot acceptable (no persistence)? Is Valkey fine, or do you prefer Redis itself or an existing Redis service?
6. **Build machines and CI:** Cores, RAM and NVMe size per machine? Is a rootful, privileged `buildkitd` container with host networking acceptable? Can we have an ephemeral self-hosted runner, or a remote builder endpoint, on your cluster for the T2 full build? Could some benchmark runs use AMD machines?
7. **Relationship to AIC:** Should this stay a standalone study, or should AIC consume these wheels?
8. **Success targets:** Do the targets in Section 5 match what you want to show? Are spot instances acceptable for published numbers?

## 10. Changes since v2

- torchvision is built from source (Section 4.7), and torch-dev now holds torch, Triton and torchvision.
- The torch wheel declares its ROCm dependency and sets RPATHs to TheRock's packages; amdsmi is built and shipped.
- `GPU_ARCH` is limited to gfx90a, gfx942 and gfx950; every build is pinned to linux/amd64.
- Site values move from an override file to environment variables, which keep validation.
- GC rules expire by age, with size handled only by the backstop rules (Section 4.5); history limits are smaller.
- zot gets 30-minute HTTP timeouts; cache refs include the ROCm and Python versions.
- Redis fallbacks are recorded in every run record and in Prometheus; tests and benchmarks run in strict mode.
- Telemetry: failed targets keep their records, compile units from cached layers are marked, and the time-weighted hit rate is dropped until it is implemented.

---

*Supporting research notes, with sources for every number above, are available on request.*
