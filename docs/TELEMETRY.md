# Telemetry

Every `scripts/rpb build` writes `results/<run_id>/`. The run id is
`<UTC time>-<repo commit>-<builder>-<4 random hex digits>`.

| File | Source |
|---|---|
| `bake-print.json`, `pins.json` | `docker buildx bake --print` before the build |
| `meta.json` | scenario, config, host class, builder, target set, times, exit status, pins |
| `bake.log` | the build output |
| `bake-metadata.json` | `bake --metadata-file`; lists only the targets that finished |
| `history-ls.json`, `refs.tsv` | `docker buildx history ls`, and each target's history record (found by name, so failed targets are included) |
| `inspect/<target>.json` | `docker buildx history inspect --format json` |
| `steps/<target>.jsonl` | `docker buildx history logs --progress=rawjson` |
| `telemetry/<unit>-sccache.json` | `sccache --show-stats --stats-format=json`, same RUN step as the compile |
| `telemetry/<unit>-sccache-remote.txt` | `redis`, `none`, `fallback` or `degraded` (below) |
| `telemetry/<unit>-started.txt` | Unix time the compile step started |
| `telemetry/<unit>-time.txt` | `/usr/bin/time -v` around the compile |
| `telemetry/<unit>-ninja.log` | `.ninja_log` from torch and vLLM |
| `wheels.json` | size of every exported wheel |
| `record.json` | all of the above joined by `python3 -m telemetry.collect` (`schema_version` 1) |

A missing or broken input (a failed `history inspect`, an empty stats file) is
recorded as an error in `record.json`; it never stops the record or changes the
run's exit status.

## Compile units from cached layers

The telemetry files of a compile unit live in the layer that compiled it. When
that layer is a cache hit, the files come back from the earlier run that built
it. `record.json` keeps them with `"fresh": false` (the step started before this
run), and Prometheus leaves them out, so a no-op rebuild never reports the cold
build's compile counts as its own.

## Two hit rates, never merged

- **Layer hit rate:** cached steps / total steps from BuildKit
  (`rpb_buildkit_cached_ratio`). Every step counts the same.
- **Compile hit rate:** sccache hits / (hits + misses) per language
  (`rpb_sccache_hit_ratio`). BuildKit cannot see it.

A run where every layer misses but every compile hits Redis shows 0 and 1.

## Fallbacks are never silent

If Redis is unreachable, `rpb-sccache-run` keeps the build going on the local disk
level, so a cache outage does not stop a nightly. That is recorded, not hidden:
`compile_units.<unit>.remote` in `record.json` and `rpb_sccache_remote{state=...}`
in Prometheus are `redis` (shared level used without errors), `none` (no shared
level configured), `fallback` (configured but unreachable when the step started),
`degraded` (Redis failed during the compile: sccache counted read, write or timeout
errors), or `unknown` (a run recorded before this file existed). A degraded step is
much slower, because sccache waits for every failing Redis call to time out;
`degraded` is how such a slow run is explained. `fallback` is detected through
sccache's server startup, which gives up after 10 seconds (fixed in sccache), so a
Redis that is up but takes longer than that to answer is also recorded as `fallback`. `rpb-sccache-run` sets sccache's write policy to `all`, which makes
sccache check Redis at startup; it refuses any other policy, since it could not
tell whether Redis is reachable. Alert on `rpb_sccache_remote{state!="redis"} == 1`
for runs that must use the shared cache. Tests and benchmarks add
`RPB_SCCACHE_REQUIRE_REMOTE=1` to the sccache secret, which turns the fallback into
a failed step.

## Prometheus

`record.json` is the source of truth; Prometheus is a view of it. With
`RPB_TEXTFILE_DIR` set (a directory the user running `scripts/rpb` can write),
`scripts/rpb` runs `python3 -m telemetry.prom record.json <textfile-dir>`, which
writes `rpb_<scenario>_<config>_<gpu_arch>_<builder>_<targets>.prom` for the
node-exporter textfile collector. Each slot keeps its own file, so the phases of
`scripts/rpb-cluster` do not overwrite each other. A failed run keeps the slot's
previous `rpb_run_last_success_timestamp_seconds`. A slot that is no longer used
keeps its last file until it is deleted by hand.

`infra/monitoring/` runs node-exporter on every client and Prometheus on the
monitoring host, which scrapes those and zot's own `/metrics`. Valkey and BuildKit
metrics are not collected yet. The mini-cluster (`dev/minicluster/run.sh test`,
check 7) queries a real Prometheus for these series.

### Metrics

`rpb_run_duration_seconds`, `rpb_run_success`, `rpb_run_last_success_timestamp_seconds`,
`rpb_run_info` (labels `run_id` and `pin_<NAME>` for every pin), `rpb_target_duration_seconds`,
`rpb_buildkit_steps`, `rpb_buildkit_cached_ratio`, `rpb_sccache_compiles`,
`rpb_sccache_hit_ratio`, `rpb_sccache_remote`, `rpb_cpu_seconds`, `rpb_peak_rss_bytes`,
`rpb_ninja_longest_edge_seconds`, `rpb_wheel_size_bytes`. Labels on every series:
`scenario`, `config`, `host_class`, `gpu_arch`, `builder`, `target_set`; plus
`target`, `unit`, `lang`, `result`, `state`, `mode` or `package` where they apply.

Example queries:

```promql
rpb_sccache_hit_ratio{scenario="nightly"}                 # compile hit rate per unit and language
rpb_buildkit_cached_ratio{scenario="nightly"}             # layer hit rate per target
rpb_target_duration_seconds{target="torch-wheel"}         # build time per target
time() - rpb_run_last_success_timestamp_seconds > 86400   # no successful run for a day
```
