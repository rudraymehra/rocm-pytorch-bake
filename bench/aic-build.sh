#!/usr/bin/env bash
# Build the AIC baseline the way AIC's own `make build` does (mk/local.mk), on the
# same builder and with the same single gfx target, and record it in results/ in
# the same layout scripts/rpb uses, so the two are compared like for like.
# AIC keeps its own fail-fast bake (that is how AIC builds). Its BuildKit history
# records are found by start time, so a failed AIC run is recorded too.
#
#   bench/aic-build.sh <aic-checkout> <builder> <gfx> <scenario>
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <aic-checkout> <builder> <gfx> <scenario>" >&2
    exit 2
fi
aic=$(cd "$1" && pwd)
builder=$2 gfx=$3 scenario=$4
repo=$(cd "$(dirname "$0")/.." && pwd)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-aic-$(git -C "$aic" rev-parse --short HEAD)-$builder-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
res="$repo/results/$run_id"
mkdir -p "$res/inspect" "$res/steps"

now() { python3 -c "import time; print(time.time())"; }
t_start=$(now)
status=0
(cd "$aic" && BUILDX_BAKE_ENTITLEMENTS_FS=0 ROCM_ARCH="$gfx" BUILD_JOBS="$(nproc)" \
    docker buildx bake --builder "$builder" --progress plain \
        --metadata-file "$res/bake-metadata.json" -f docker/docker-bake.hcl default) \
    2>&1 | tee "$res/bake.log" || status=$?
t_end=$(now)

cd "$repo"
set +e   # from here on only warnings: the exit status is the bake's
docker buildx history ls --builder "$builder" --format json --no-trunc --filter "startedAt>24h" > "$res/history-ls.json"
# The builder runs nothing else during a benchmark, so every record created since
# t_start belongs to this run (a 5 s margin covers clock rounding).
python3 -m telemetry.runmeta refs-since "$res/history-ls.json" "$(python3 -c "print($t_start - 5)")" > "$res/refs.tsv"
while IFS=$'\t' read -r target ref; do
    docker buildx history inspect --builder "$builder" "$ref" --format json > "$res/inspect/$target.json" \
        || echo "aic-build: history inspect $target failed" >&2
    docker buildx history logs --builder "$builder" --progress=rawjson "$ref" 2> "$res/steps/$target.jsonl" >/dev/null \
        || echo "aic-build: history logs $target failed" >&2
done < "$res/refs.tsv"

python3 - "$res" "$run_id" "$scenario" "$gfx" "$t_start" "$t_end" "$status" "$(git -C "$aic" rev-parse HEAD)" <<'PY'
import json, os, sys
res, run_id, scenario, gfx, t0, t1, status, aic_sha = sys.argv[1:]
meta = {"run_id": run_id, "scenario": scenario, "config": "aic-main", "gpu_arch": gfx,
        "host_class": os.environ.get("RPB_HOST_CLASS", "local"),
        "t_start": float(t0), "t_end": float(t1), "status": "ok" if status == "0" else "failed",
        "exit_code": int(status), "pins": {"AIC_SHA": aic_sha}}
json.dump(meta, open(os.path.join(res, "meta.json"), "w"), indent=2, sort_keys=True)
PY
python3 -m telemetry.collect "$res" || echo "aic-build: telemetry.collect failed; raw files are in $res" >&2
exit "$status"
