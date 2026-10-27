# Testing

What each part of the repository does, how to check it yourself, and what is not
proven yet. The commands here are the ones CI runs.

## Requirements

- Docker. On a Mac, Docker Desktop with at least 4 GB of memory for its VM.
- buildx v0.38.0 or later. Docker Desktop ships an older one. On a Mac:

  ```sh
  brew install docker-buildx
  # let docker find it before Docker Desktop's bundled copy
  python3 -c 'import json,os; p=os.path.expanduser("~/.docker/config.json"); c=json.load(open(p)); c["cliPluginsExtraDirs"]=["/opt/homebrew/lib/docker/cli-plugins"]; json.dump(c,open(p,"w"),indent=1)'
  docker buildx version    # must print v0.38.0 or later (Homebrew: v0.38.1)
  ```

  To undo, remove the `cliPluginsExtraDirs` key from `~/.docker/config.json`.
  `dev/minicluster/run.sh` refuses to run with an older buildx.
- Python 3.10 or later with `pytest`, Go 1.26, `shellcheck`, `hadolint`.

## 1. Static checks: `make check` (about 2 minutes)

| Step | What it proves |
|---|---|
| `docker buildx bake lint` | BuildKit parses every Dockerfile and its build checks report no warnings |
| `hadolint`, `shellcheck`, `py_compile` | Dockerfile, shell and Python script hygiene |
| `go run .` in `tools/check-buildkitd-config` | `buildkitd.toml` loads with BuildKit's own config code and has no unknown keys (BuildKit ignores unknown keys silently) |
| `promtool check config` | the Prometheus config is valid once its placeholders are filled |
| `pytest telemetry/tests` | the telemetry parsers and the Prometheus output, 31 tests; 4 of them on output captured from real BuildKit and sccache runs; CI runs them on Python 3.10 and 3.12 |
| `docker buildx bake --print all` | the bake file resolves with every variable validated |
| `scripts/check-pins` | every pin points at a real commit, live against the git hosts, and every version string matches its tag |

Expected: no error output, `ok:`/`SUCCESS`/`passed` lines, and exit status 0.

## 2. What `docker-bake.hcl` builds: `scripts/bake-graph`

```text
aiter-wheel        docker/aiter.Dockerfile        from: torch-dev                                                                                             -> out/gfx942/aiter
base               docker/base.Dockerfile         from: -                                                                                                     -> cacheonly
fa-wheel           docker/fa.Dockerfile           from: torch-dev                                                                                             -> out/gfx942/fa
lmcache-wheel      docker/lmcache.Dockerfile      from: torch-dev                                                                                             -> out/gfx942/lmcache
test               docker/test.Dockerfile         from: aiter-wheel, base, fa-wheel, lmcache-wheel, torch-wheel, torchvision-wheel, triton-wheel, vllm-wheel  -> out/gfx942/test
torch-core         docker/torch-dev.Dockerfile    from: base, torch-wheel, triton-wheel                                                                       -> cacheonly
torch-dev          docker/torch-dev.Dockerfile    from: base, torch-wheel, torchvision-wheel, triton-wheel                                                    -> cacheonly
torch-wheel        docker/torch.Dockerfile        from: base                                                                                                  -> out/gfx942/torch
torchvision-wheel  docker/torchvision.Dockerfile  from: torch-core                                                                                            -> out/gfx942/torchvision
triton-wheel       docker/triton.Dockerfile       from: base                                                                                                  -> out/gfx942/triton
vllm-wheel         docker/vllm.Dockerfile         from: torch-dev                                                                                             -> out/gfx942/vllm
```

One bake file defines every wheel and the order between them. Check 7 below runs
the same targets, `target:` links and outputs across two builders, with each
Dockerfile replaced by a busybox stub and `base` replaced by busybox. What that
does **not** prove is that the real Dockerfiles compile; see "Not proven yet".

## 3. The mini-cluster: `make minicluster-test` (about 5 minutes)

Two BuildKit builders with mTLS, zot, Valkey, node-exporter and Prometheus on one
machine, configured from the production files (Valkey gets a smaller `maxmemory`
and Prometheus a 5 s scrape interval). CI runs it on every pull request and on
every push to `main` and `dev`.

```sh
dev/minicluster/run.sh up      # starts from scratch every time
dev/minicluster/run.sh test
dev/minicluster/run.sh down
```

The builds run in a copy of the repository (`dev/minicluster/.state/work`), so the
test never touches this checkout's `out/`, `results/` or `.rpb-routes`. Each step's
log is in `dev/minicluster/.logs/` until the next `up`. The cluster uses the
subnet `10.231.0.0/24` and ports 12341, 12342, 15000 and 19090.

Each check reads the component itself, not only what our scripts report:

| # | Claim | Checked against | Negative control (must fail) |
|---|---|---|---|
| 1 | Builders accept only our clients, and are two daemons | each daemon's own host name; curl with the client certificate gets gRPC's HTTP 415 | no certificate, and a certificate from another CA |
| 2 | sccache shares objects across builders through Redis | Valkey gains exactly 40 keys; Valkey `keyspace_hits` rise by at least 40 when builder2 compiles; the build is in builder2's own history | a wrong Redis password, in strict mode |
| 3 | zot holds the layer cache | an emptied builder2 gets this run's source and compile steps (they embed a new value each run) from zot, per its own build history; zot's API lists the tag | the same build without zot reuses neither step |
| 4 | Redis down at the start does not stop builds, and is never silent | `remote=fallback` in the step's output and in a `scripts/rpb` record | strict mode fails, with the strict-mode message |
| 5 | Redis lost during the compile is never silent | the record says `remote=degraded` | (the build is held until Valkey is gone, so the loss always happens mid-compile) |
| 6 | Every run is recorded | `record.json` matches the daemon's own history record and Valkey's key count; the parser tests pass on this run's real output | a target that fails on purpose is recorded as failed, with its error |
| 7 | Several machines share one build | each downstream target is in the history of the daemon it was routed to, and that record says it was built from the `torch-dev@digest` zot serves | routes preset to the opposite of what load balancing picks are followed |
| 8 | Build times and hit rates reach Prometheus | both scrape targets up; no textfile errors; success, Redis state, duration, cached ratio, step count, misses and hit ratio equal `record.json` | with the metric files removed the series disappear, then return |

Expected: eight `PASS:` lines and exit status 0.

The checks themselves were tested by breaking one thing at a time; each mutation
below made the named check fail:

| Mutation | Fails at |
|---|---|
| builder2's name points at builder1's daemon | check 1 |
| compile without sccache | check 2 |
| cache export to zot removed | check 3 |
| run records always say `redis` | check 4 |
| Redis errors during the compile not detected | check 5 |
| failed targets dropped from the record | check 6 |
| downstream builds not from `torch-dev@digest`; sticky routes ignored | check 7 |
| hit ratio not exported to Prometheus | check 8 |

### Look for yourself

Run `up` and `test`, but not `down`, then:

```sh
open http://127.0.0.1:19090/targets                 # Prometheus: rpb and zot up
open 'http://127.0.0.1:19090/query?g0.expr=rpb_target_duration_seconds'
curl -s http://127.0.0.1:15000/v2/_catalog          # zot: rpb/cache, rpb/torch-dev
ls dev/minicluster/.state/work/results/*/record.json
```

## 4. Fallbacks are never silent

If Redis is unreachable, the build continues on the local disk cache and records
`remote=fallback`; if Redis fails during a compile, it records `remote=degraded`.
Both reach `record.json` and the Prometheus metric `rpb_sccache_remote`. Tests and
benchmarks run in strict mode (`RPB_SCCACHE_REQUIRE_REMOTE=1` in the sccache
secret), where both fail the step. See `docs/TELEMETRY.md`.

## Not proven yet

Parts of the build already run for real on linux/amd64: `docker/base.Dockerfile` up to
Python 3.12 and the pinned pip; the amdsmi wheel built and imported against the real
`rocm-sdk-core` 10.0.0; the torch RPATH repair on test libraries that load only after it.

| Item | Why | When |
|---|---|---|
| The real Dockerfiles compile torch, torchvision, Triton, AITER, FlashAttention, LMCache and vLLM | needs an x86_64 builder with 32+ cores; the full build is estimated at 40 to 75 minutes | the first full build |
| Real cold and warm build times and hit rates | same | same |
| `infra/cache-node/install.sh`, `infra/buildkit/run-buildkitd.sh`, `infra/monitoring/install.sh` on a Linux host | the mini-cluster uses the same config files through Compose, not these scripts | first cluster bring-up |
| `.github/workflows/full-build.yml` | needs a self-hosted builder, and the workflow on the default branch | first cluster bring-up |
| `infra/ec2/` and `bench/` | they spend money; `teardown-check.sh` is tested against simulated AWS failures only | benchmark campaign |
