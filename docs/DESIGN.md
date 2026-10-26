# rocm-pytorch-bake: Design Proposal

**Status:** Draft for review
**Author:** Rudray Mehra
**Reviewer:** Stephen Bates
**Last updated:** 27 October 2026

---

## 1. Summary

Build PyTorch, vLLM and LMCache from source for a single AMD GPU target, with the fastest possible cold build, a warm build that reuses nearly everything, and minimal wheels for deployment. The build is driven by one `docker buildx bake` file and uses three caches together: a BuildKit layer cache in a local zot registry, a sccache compile cache shared across machines, and pinned source fetches. Every build emits telemetry (stage times, cache hit rates, wheel sizes) into Prometheus, and the results are benchmarked on EC2 so anyone can reproduce them.

This document lays out the proposed design, the evidence behind each choice, and the questions I need your input on before writing code.

## 2. Goals and non-goals

**Goals**

- G1. Build PyTorch, vLLM and LMCache from source for one gfx target.
- G2. Fast cold builds; warm builds that rebuild only what changed.
- G3. Use several build machines through remote BuildKit builders.
- G4. Minimal wheels, with vLLM and LMCache as separate artifacts.
- G5. Build telemetry in Prometheus: stage times and cache hit rates.
- G6. Reproducible benchmarks on rented EC2 hardware.

**Non-goals (v1)**

- Multi-arch fat wheels.
- Runtime or inference performance; this is about build time and artifact size only.
- Publishing to PyPI (the torch wheel exceeds the 100 MiB per-file limit).
- Replacing AIC. The repo can feed AIC later if useful (see Q6).

## 3. Baseline

Numbers taken from primary sources: CI logs, repository files and pull requests. All are subject to re-measurement on identical hardware (Section 4.8).

| Build | Setup | Cold | Warm |
|---|---|---|---|
| AIC nightly (`main`, run 40298645134) | 9 targets, one node | 99.6 min build phase (torch 1941 s, vLLM wheel 2522 s) | None in practice (see below) |
| `dev/stebates/buildx-bake` | Prebuilt ROCm 10.1 and torch, gfx1201, 128 cores | 29m56s | 12m37s (ccache 47.5% hit) |
| TheRock CI, torch wheel step only | sccache on S3 | 58m58s | 14m00s |

Observations on the current AIC build, which this design addresses:

1. `buildx prune --force` before each build also removes the ccache cache mounts, so every nightly starts cold.
2. The stage that builds vLLM, AITER and FlashAttention starts from the `-full` image, which has no ccache, so those compiles are never cached.
3. AITER, FlashAttention and vLLM build serially in one stage.
4. `BLAS_CACHE_BUST = timestamp()` invalidates a layer on every run.
5. Layer cache lives in one shared `type=local` directory on NFS, which several targets overwrite.
6. No build-time telemetry.

Nobody has published a sccache hit rate or a cold/warm breakdown for a ROCm PyTorch build. Producing that data is one of the main outputs of this project.

## 4. Design

### 4.1 Pins and sources

- All versions live in one file, `pins.hcl`, as bake variables: ROCm, torch, vLLM, LMCache, Triton, AITER, FlashAttention, sccache, BuildKit and buildx.
- Dockerfiles carry no default versions, which removes drift between the bake file and the Dockerfiles.
- Sources are fetched with `ADD --checksum=<sha> <git url>`. The build fails if a tag and SHA disagree, and BuildKit fetches submodules itself. This also covers AIC issue #143 (re-cloning on every build) without git submodules in our repo.
- Each version `ARG` is declared only in the stage that uses it, so changing one pin does not invalidate unrelated stages.
- A single pin hash (versions, patches, build flags and build files) goes into image tags and the run record. It does **not** go into cache refs, so a pin bump still finds the previous cache.
- Patches live under `patches/<package>-<version>/`.
- vLLM is pinned to a commit that includes PR #62475, which splits the slow attention compile into parallel units (547 s on one core down to 72 s wall on 12 cores, gfx950).

### 4.2 Stage graph

```
fetch sources (URL + SHA)
        |
hipify + patches          (does not depend on the ROCm image)
        |
torch compile  -> torch wheel
        |
install-torch image  ----> pushed to zot, used by other machines
        |
   +----+-------+-----------+-----------+
   |            |           |           |
 vLLM native  AITER   FlashAttention  LMCache
   |
 vLLM python packaging (cheap, reuses native .so)

Triton builds in parallel from the start (no torch dependency)

All wheels exported via FROM scratch stages (type=local)
```

- The native vLLM compile is keyed only on native inputs (vLLM's own `csrc-build` pattern), so a Python-only edit does not recompile kernels.
- Inside each stage: stable, expensive steps first; patches and scripts last; narrow `COPY` paths.
- `bake --jobs=defer-error`, so that when one target fails, the others still finish and save their cache. No `parallel=N` limit: buildx rejects limited parallelism when targets are linked through `target:` contexts.
- Each parallel target gets an explicit `MAX_JOBS` share, to avoid oversubscribing CPU and RAM.
- Estimated cold time on one 32 to 64 core builder: **40 to 75 minutes**, with torch taking 50 to 80% of it. This is an estimate until measured, and it assumes no AITER kernel prebuild.
- If AITER kernel prebuild is required, AITER, not torch, may set the critical path. AIC's own patch notes measure 61 minutes for about 107 modules on 128 cores, with a three-module tail running over 85 minutes on its own (`patches/aiter/03-aiter-prebuild-threads.py`, PR #186).

### 4.3 Compile cache (sccache)

- **Tool:** sccache v0.19.0. ccache is kept only as a comparison arm, to reproduce your prototype's numbers.
- **Two levels** (`SCCACHE_MULTILEVEL_CHAIN=disk,s3`):
  - A per-target BuildKit cache mount as the fast local level.
  - A shared S3-compatible store: SeaweedFS or Garage on the LAN (the MinIO repo is archived), and same-region S3 on EC2.
- **Hooked at clang, never at hipcc:**
  - torch: `CMAKE_C/CXX/HIP_COMPILER_LAUNCHER=sccache`, with `USE_CCACHE=0`.
  - vLLM: picked up automatically by its `setup.py`.
  - LMCache, AITER and FlashAttention: `HIP_CLANG_LAUNCHER=sccache`. This needs hipcc from ROCm 7.13 or later; on the 7.2.x line it is ignored silently, so wrapper scripts are used instead.
- **Settings that matter for HIP:**
  - `SCCACHE_DIRECT=false`. PyTorch main adds `--offload-compress` to every HIP compile, which makes sccache's direct mode fail the compile (sccache #2762; fix #2788 still open).
  - `SCCACHE_IDLE_TIMEOUT=0`, because some files compile for over 10 minutes.
  - An identical `WORKDIR` on every builder, instead of `SCCACHE_BASEDIRS` (open correctness bug #2863).
  - The ROCm image pinned by digest. Cache keys include the compiler hash, so every builder must use the same image.
  - Backend credentials passed through `--mount=type=secret`, never as `ARG` or `ENV`.

### 4.4 Layer cache (zot)

- zot v2.1.22 on local NVMe, plain HTTP, reachable only on the LAN or VPC.
- One repository, with `dedupe: false` set explicitly. Dedupe is on by default and takes a store-wide write lock on blob checks (#4582).
- GC with a 2-hour delay, and retention by tag count (zot has no size-based eviction).
- Cache export settings:
  - One cache ref per target and arch, with `mode=max` and `ignore-error=true`.
  - zstd level 3 everywhere, and never mixed compression (mixing it is linked to BuildKit #6088, out of memory on export).
- A reference cache ref written only by baseline-pin builds, listed as a fallback in every `cache-from`.
- No `buildx prune` by default and no NFS cache directories.
- Fallback registry if zot underperforms: distribution v3.

### 4.5 Multiple machines

`buildx create --append` picks a node by platform only. When every node is linux/amd64, all work goes to the first node. I confirmed this in `build/resolver/driver.go`. The proposal:

- One remote `buildkitd` per machine, with mTLS, and BuildKit and buildx versions pinned.
- A thin wrapper that runs separate `bake --builder` invocations. Each target goes back to the machine that built it last, where its cache is warmest (the CloudBuild pattern). Work moves between machines through zot (the install-torch image) and the shared sccache.
- The wrapper works under Slurm as well: Slurm allocates nodes, the wrapper schedules builds.

**Expected effect, stated plainly.** The chain base → torch → downstream cannot be split, so routing whole targets to more machines speeds up a single cold build by about 1.05× at most (Amdahl estimate). The gains from more machines come from running builds concurrently and from sharing a warm cache. sccache-dist could add roughly 1.15 to 1.2× on 3 machines if HIP compiles cannot be distributed, and 1.36 to 1.47× if they can. It goes in only if a two-host HIP test passes and it cuts torch cold time by 25% or more.

### 4.6 Minimal wheels

- ROCm is never bundled into our wheels. For gfx942 the ROCm runtime is about 2.4 GiB, mostly hipBLASLt kernels, which is far larger than torch's own device code (about 51 MiB).
- **Two flavours:**
  - Depend on a pinned TheRock `rocm-sdk`.
  - Assume a system ROCm already installed on the node.
- **Trims:**
  - Single arch.
  - `BUILD_TEST=0`.
  - vLLM built with `CMAKE_BUILD_TYPE=Release`.
  - Strip Triton: 624 MiB of its 835 MiB `libtriton.so` is debug info. Also drop Triton's NVIDIA backend (92 MiB compressed); that needs a patch and has to be tested.
  - Keep torch headers, which AITER needs to JIT-compile.
- **Separate wheels:**
  - Our torch gets a unique local version, pinned exactly by both vLLM and LMCache.
  - Our Triton is pinned in torch's metadata at build time.
  - We ship `constraints.txt` and `pylock.toml`.
  - LMCache's NVIDIA-only requirements (`cufile-python`, `nvtx`) are removed from its metadata.
- **Expected download size for gfx942 (estimates):**

| Setup | Size |
|---|---|
| Today (vLLM index plus official torch) | ~6.5 GiB, measured |
| Our build with ROCm from pip | ~2.8 GiB |
| Our build with ROCm already on the node | ~0.44 GiB |

### 4.7 Telemetry

- One JSON record per run is the source of truth, with a `schema_version`, kept as an append-only results file.
- **On your machines:** a `.prom` file written into the node-exporter textfile directory your AIC monitoring stack already reads, plus a Grafana dashboard alongside the AIC ones.
- **On EC2:** a local Prometheus whose data is shipped with the results at teardown.
- No Pushgateway; its series never expire on their own.

| Metric | Source |
|---|---|
| Stage and total wall time | `buildx history inspect --format json` |
| Steps total / cached | BuildKit history |
| sccache hits / misses / errors per language and per level | `sccache --show-stats --stats-format=json`, captured in the same `RUN` step |
| Slowest translation units | `.ninja_log` |
| Registry bytes pulled and pushed | zot metrics |
| CPU, RAM and disk saturation, peak RSS | node_exporter, `/usr/bin/time -v` |
| Wheel sizes | export stage |
| Critical path ÷ (CPU-seconds / cores) | derived |

### 4.8 Benchmark method

- **Five scripted wipe levels**, from "nothing cached" up to "everything cached". A run only counts if the reset is verified.
- **Scenarios:**
  - Full cold.
  - New machine with a warm shared cache.
  - No-op rebuild.
  - One-file vLLM patch.
  - LMCache-only patch.
  - torch version bump.
- **Fairness:** AIC and this build run on the same instance type, gfx target and pins. The cold headline runs on 3 instances in parallel, each alternating the two builds in ABBA order. This follows the cloud-benchmarking literature: Laaber et al. (EMSE 2019) and the ATC 2023 "ordering trap" paper.
- **Statistics:**
  - One A/A run to measure the noise floor.
  - Raw points published along with the median and min–max.
  - No claims smaller than 5%.
  - 4 to 5 repetitions for any significance claim.

### 4.9 EC2 plan and cost

- **Region:** us-east-2. On-demand prices match us-east-1, and AWS's Spot Instance Advisor rates m7a.16xlarge interruptions at under 5% there, versus 10 to 15% in us-east-1.
- **Builders:** m7a.16xlarge spot, with 64 physical cores and 256 GiB RAM. The spot price was $1.30 per hour on 27 Oct 2026, against $3.71 on demand.
- **Cache hosts:** a c7a.xlarge running zot, and S3 for sccache.
- **Guardrails:** self-terminate timers on every instance, AWS Budgets alerts, tags, and a scripted all-region teardown check.
- **Budget:** run it in two phases.
  - **Phase 1 (about $15):** experiments E1, E2 and E5. These measure the real build times.
  - **Phase 2 (the benchmark matrix), estimated at about $45 on spot.** That makes about $60 for the whole campaign, or about $90 with a 50% allowance for reruns. The estimate rests on guessed build times and gets re-costed once Phase 1 has measured them. Some runs on AMD machines would cut it (Q5).
- All development happens locally first. EC2 is used only for the benchmark campaign.

## 5. Success criteria (proposed)

Measured against AIC on identical hardware, gfx target and pins:

| Criterion | Target |
|---|---|
| Full cold build | ≤ 0.8× AIC |
| New machine, warm shared cache | ≤ 0.3× our cold time, with sccache hit rate ≥ 95% |
| No-op rebuild | ≤ 2 min |
| One-file vLLM patch | ≤ 6 min |
| LMCache-only patch | Rebuilds nothing in vLLM, judged by cached-step count |
| Telemetry | Hit rates and stage times published for every run |

Expectation to set up front: with torch built from source, our cold build will be slower than your prebuilt-torch prototype (about 30 min). The comparison that matters is like for like.

## 6. Risks

| Risk | Mitigation |
|---|---|
| sccache gets low hit rates on HIP | Measure first (E1); ccache comparison arm kept |
| Large `mode=max` exports trigger BuildKit export bugs | `ignore-error`, uniform compression, per-run timeout, daemon restart between runs |
| zot slows down with tens of GB of cache | Throughput test (E4); distribution v3 as fallback |
| Pin drift between torch, vLLM and LMCache | One pin file, bake checks, and a stage that fails when torch versions disagree |
| EC2 cost overrun | Spot, self-terminate timers, phased budget re-costed after Phase 1, teardown check |
| AITER prebuild dominates the critical path | Measure it separately; confirm whether prebuild is needed (Q4) |

## 7. Experiments before implementation

None of these need a GPU.

| ID | Experiment | Purpose |
|---|---|---|
| E1a | sccache direct mode with `--offload-compress` on one HIP file | Confirm the failure and the `SCCACHE_DIRECT=false` fix |
| E1 | Cross-machine sccache hit rate, gfx942-only torch and vLLM | Two fresh builders should reach ~100% |
| E2 | Cores vs wall time and peak RSS at 32, 64 and 96 cores | Find the critical path and the RAM per job |
| E3 | sccache-dist with clang HIP, one file, two hosts | Decide whether compile distribution is viable |
| E4 | zot push/pull throughput and GC at tens of GB | Validate the registry choice |
| E5 | Wheel size waterfall, one trim step at a time, smoke test after each | Confirm the size estimates |

## 8. Milestones

1. You review this document and answer the questions below.
2. Run E1a, E1, E3 and E4 locally or on one small instance.
3. Build the pins file, stage graph and wheel exports for one gfx target.
4. Add the telemetry harness and Grafana dashboard.
5. Run the EC2 benchmark campaign; publish raw data and a short report.

## 9. Questions for you

1. **Torch from source:** Do you need torch built from source because you carry PyTorch patches? If so, where do they live? `patches/pytorch/` in AIC is currently empty.
2. **ROCm base:** TheRock `rocm-sdk` (as in your `buildx-bake` branch) or `/opt/rocm` 7.14 (as in AIC main)? This decides the wheel model and whether `HIP_CLANG_LAUNCHER` is available.
3. **Target and machines:** Which gfx target? What do your build machines look like: cores, RAM, NVMe, network, and Docker/BuildKit versions?
4. **Patches and AITER:** Which vLLM and LMCache patches must we carry? Is AITER kernel prebuild required? AIC measured about 61 minutes for it, which would put it ahead of torch on the critical path.
5. **Success and hardware:** Do the targets in Section 5 match what you want to show? Are spot instances acceptable for published numbers? Could some runs use AMD machines?
6. **Relationship to AIC:** Should this stay a standalone study, or should AIC consume these wheels?
7. **Smoke tests:** Would a tiered smoke test (a no-GPU static check, then a smoke test, then inference) be useful?

---

*Supporting research notes, with sources for every number above, are available on request.*
