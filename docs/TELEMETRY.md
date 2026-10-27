# Telemetry

Every `scripts/rpb build` writes `results/<run_id>/`:

| File | Source |
|---|---|
| `bake-print.json`, `pins.json` | `docker buildx bake --print` before the build |
| `bake.log` | the build output |
| `bake-metadata.json` | `bake --metadata-file` (only when the bake finished) |
| `inspect/<target>.json` | `docker buildx history inspect --format json` |
| `steps/<target>.jsonl` | `docker buildx history logs --progress=rawjson` |
| `telemetry/<unit>-sccache.json` | `sccache --show-stats --stats-format=json`, same RUN step as the compile |
| `telemetry/<unit>-time.txt` | `/usr/bin/time -v` around the compile |
| `telemetry/<unit>-ninja.log` | `.ninja_log` from torch and vLLM |
| `record.json` | all of the above joined by `python3 -m telemetry.collect` (`schema_version` 1) |

`record.json` is the source of truth. Prometheus is a view of it:
`python3 -m telemetry.prom record.json <textfile-dir>/rpb.prom` writes gauges for
the node-exporter textfile collector.

## Two hit rates, never merged

- **Layer hit rate:** cached steps / total steps from BuildKit
  (`rpb_buildkit_cached_ratio`). Every step counts the same.
- **Compile hit rate:** sccache hits / (hits + misses) per language
  (`rpb_sccache_hit_ratio`). BuildKit cannot see it.

A run where every layer misses but every compile hits Redis shows 0 and 1.

## Metrics

`rpb_run_duration_seconds`, `rpb_run_success`, `rpb_run_last_success_timestamp_seconds`,
`rpb_run_info`, `rpb_target_duration_seconds`, `rpb_buildkit_steps`,
`rpb_buildkit_cached_ratio`, `rpb_sccache_compiles`, `rpb_sccache_hit_ratio`,
`rpb_cpu_seconds`, `rpb_peak_rss_bytes`, `rpb_ninja_longest_edge_seconds`,
`rpb_wheel_size_bytes`. Labels: `scenario`, `config`, `host_class`, `gpu_arch`,
plus `target`, `unit`, `lang`, `result`, `state`, `mode` or `package`.
