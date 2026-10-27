# Testing

What each part of the repository does, how to check it yourself, and what is not
proven yet. Every command here has been run; the outputs shown are real.

## Requirements

- Docker. On a Mac, Docker Desktop with at least 4 GB of memory for its VM.
- buildx v0.38.0 or later. Docker Desktop ships an older one. On a Mac:

  ```sh
  brew install docker-buildx
  # let docker find it before Docker Desktop's bundled copy
  python3 -c 'import json,os; p=os.path.expanduser("~/.docker/config.json"); c=json.load(open(p)); c["cliPluginsExtraDirs"]=["/opt/homebrew/lib/docker/cli-plugins"]; json.dump(c,open(p,"w"),indent=1)'
  docker buildx version    # must print v0.38.1
  ```

  To undo, remove the `cliPluginsExtraDirs` key from `~/.docker/config.json`.
  `dev/minicluster/run.sh` refuses to run with an older buildx.
- Python 3.10 or later with `pytest`, Go 1.26, `shellcheck`, `hadolint`.

## 1. Static checks: `make check` (about 2 minutes)

| Command inside `make check` | What it proves |
|---|---|
| `docker buildx bake lint` | BuildKit parses every Dockerfile and its build checks report no warnings |
| `hadolint`, `shellcheck` | Dockerfile and shell best practice |
| `go run tools/check-buildkitd-config` | `buildkitd.toml` loads with BuildKit's own config code and has no unknown keys (BuildKit ignores unknown keys silently) |
| `promtool check config` | the Prometheus config is valid once its placeholders are filled |
| `pytest telemetry/tests` | the telemetry parsers and the Prometheus output (25 tests, 4 of them on output captured from real BuildKit and sccache runs) |
| `docker buildx bake --print all` | the bake file resolves with every variable validated |
| `scripts/check-pins` | every pinned tag still points at the pinned commit, checked live against git |

Expected: every step prints `ok`, `SUCCESS`, `passed` or `no warnings found`.

## 2. What `docker-bake.hcl` builds: `scripts/bake-graph`

```text
aiter-wheel    docker/aiter.Dockerfile      from: torch-dev                     -> out/gfx942/aiter
base           docker/base.Dockerfile       from: -                             -> cacheonly
fa-wheel       docker/fa.Dockerfile         from: torch-dev                     -> out/gfx942/fa
lmcache-wheel  docker/lmcache.Dockerfile    from: torch-dev                     -> out/gfx942/lmcache
test           docker/test.Dockerfile       from: aiter-wheel, base, fa-wheel, ... -> out/gfx942/test
torch-dev      docker/torch-dev.Dockerfile  from: base, torch-wheel, triton-wheel -> cacheonly
torch-wheel    docker/torch.Dockerfile      from: base                          -> out/gfx942/torch
triton-wheel   docker/triton.Dockerfile     from: base                          -> out/gfx942/triton
vllm-wheel     docker/vllm.Dockerfile       from: torch-dev                     -> out/gfx942/vllm
```

One bake file defines all six wheels and the order between them. Check 6 below
runs this exact graph (same targets, links and outputs) across two builders,
with every Dockerfile replaced by a stub. What that does **not** prove is that
the real Dockerfiles compile; see "Not proven yet".

## 3. The mini-cluster: `make minicluster-test` (about 5 minutes)

Two BuildKit builders with mTLS, zot, Valkey, node-exporter and Prometheus, all on
one machine, using the production config files. CI runs the same on every push.

```sh
dev/minicluster/run.sh up
dev/minicluster/run.sh test
dev/minicluster/run.sh down
```

Every check has a negative control: the component is broken on purpose and the
check must fail. A check that cannot fail proves nothing.

| # | Claim | Checked independently by | Negative control |
|---|---|---|---|
| 1 | Builders accept only our clients (mTLS) | curl with the client certificate gets gRPC's HTTP 415 | no certificate, and a certificate from another CA, are refused |
| 2 | sccache shares objects across builders through Redis | Valkey gains exactly 40 keys; Valkey `keyspace_hits` rise by at least 40 when builder2 compiles | a wrong Redis password fails the build in strict mode |
| 3 | zot holds the layer cache | zot's API lists the cache tag; an empty builder2 reuses steps | the same build without zot reuses 0 steps |
| 4 | A Redis outage does not stop builds, and is never silent | the run records `remote=fallback` | strict mode fails the build with Redis down |
| 5 | Every run is recorded | `record.json` matches the builder's own BuildKit history record | (the strict secret: the run must use Redis) |
| 6 | Several machines share one build | zot serves torch-dev at the recorded digest; each downstream record comes from the builder it was routed to | (records are matched one by one) |
| 7 | Build times and hit rates reach Prometheus | both scrape targets up; node-exporter reports no textfile errors; a duration in Prometheus equals the one in `record.json` | with the metric files removed, the series disappear, then return |

Expected: seven `PASS:` lines and exit status 0.

### Look for yourself

Run `up` and `test`, but not `down`, then:

```sh
open http://127.0.0.1:19090/targets                 # Prometheus: rpb and zot up
open 'http://127.0.0.1:19090/query?g0.expr=rpb_target_duration_seconds'
curl -s http://127.0.0.1:15000/v2/_catalog          # zot: rpb/cache, rpb/torch-dev
ls results/*/record.json                            # one record per run
```

## 4. Fallbacks are never silent

If Redis is unreachable, the build continues on the local disk cache, and the
run records `remote=fallback` in `record.json` and in the Prometheus metric
`rpb_sccache_remote`. Tests and benchmarks run in strict mode
(`RPB_SCCACHE_REQUIRE_REMOTE=1` in the sccache secret), where a fallback fails the
step instead. See `docs/TELEMETRY.md`.

## Not proven yet

| Item | Why | When |
|---|---|---|
| The real Dockerfiles compile torch, Triton, AITER, FlashAttention, LMCache and vLLM | needs an x86_64 builder with 32+ cores and about two hours | the first full build |
| Real cold and warm build times and hit rates | same | same |
| `infra/cache-node/install.sh`, `infra/buildkit/run-buildkitd.sh`, `infra/monitoring/install.sh` on a Linux host | the mini-cluster uses the same config files through Compose, not these scripts | first cluster bring-up |
| `.github/workflows/full-build.yml` | needs a self-hosted builder | first cluster bring-up |
| `infra/ec2/` and `bench/` | they spend money; run only with a budget | benchmark campaign |
