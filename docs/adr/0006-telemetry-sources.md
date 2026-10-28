# 6. Telemetry from BuildKit history and sccache statistics

Status: accepted

## Decision

Per-target timing and layer hit rate from `docker buildx history inspect` and
`history logs --progress=rawjson`; compile hit rate from sccache JSON statistics
taken in the same RUN step. One `record.json` per run is the source of truth;
Prometheus gauges are derived from it.
