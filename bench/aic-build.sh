#!/usr/bin/env bash
# Build the AIC baseline the way AIC's own `make build` does (mk/local.mk), on the
# same builder and with the same single gfx target, and record it in results/ in
# the same layout scripts/rpb uses, so the two are compared like for like.
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
run_id="$(date -u +%Y%m%dT%H%M%SZ)-aic-$(git -C "$aic" rev-parse --short HEAD)"
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
python3 -m telemetry.runmeta refs "$res/bake-metadata.json" /dev/null "$run_id" > "$res/refs.tsv"
while IFS=$'\t' read -r target ref; do
    docker buildx history inspect --builder "$builder" "$ref" --format json > "$res/inspect/$target.json"
    docker buildx history logs --builder "$builder" --progress=rawjson "$ref" 2> "$res/steps/$target.jsonl" >/dev/null || true
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
python3 -m telemetry.collect "$res"
exit "$status"
