#!/usr/bin/env bash
# Reset caches to a known state before a benchmark run, and print proof.
#
#   bench/reset.sh <levels>      e.g. bench/reset.sh BK,SC,RG,OS   (full cold)
#
# Runs on the benchmark host, where buildkitd, zot and Valkey all run.
#   BK  BuildKit state: layers, cache mounts (sccache local level, pip) and history
#   SC  shared sccache level: FLUSHALL on Valkey
#   RG  zot: every stored layer-cache blob and manifest
#   OS  page cache (sync + drop_caches)
# Needs: STATE_DIR, CACHE_DATA, SECRETS, ZOT_ADDR, CERT_DIR (same values as at install time).
set -euo pipefail

: "${STATE_DIR:?}" "${CACHE_DATA:?}" "${SECRETS:?}" "${ZOT_ADDR:?}" "${CERT_DIR:?}"
repo=$(cd "$(dirname "$0")/.." && pwd)
IFS=, read -r -a levels <<< "${1:?usage: bench/reset.sh BK,SC,RG,OS}"

for level in "${levels[@]}"; do
    case "$level" in
        BK)
            docker rm -f buildkitd >/dev/null
            find "$STATE_DIR" -mindepth 1 -delete
            echo "BK proof: $(du -sh "$STATE_DIR" | cut -f1) in $STATE_DIR"
            "$repo/infra/buildkit/run-buildkitd.sh" >/dev/null
            ;;
        SC)
            # shellcheck source=/dev/null
            . "$SECRETS/valkey-admin.env"
            cli=(docker exec rpb-cache-valkey-1 valkey-cli -h "$VALKEY_HOST" --user "$VALKEY_USER" --pass "$VALKEY_PASSWORD" --no-auth-warning)
            "${cli[@]}" flushall >/dev/null
            echo "SC proof: dbsize=$("${cli[@]}" dbsize)"
            ;;
        RG)
            docker compose -f "$repo/infra/cache-node/compose.yaml" stop zot >/dev/null
            find "$CACHE_DATA/zot" -mindepth 1 -delete
            docker compose -f "$repo/infra/cache-node/compose.yaml" start zot >/dev/null
            for _ in $(seq 1 30); do curl -fsS "http://$ZOT_ADDR/v2/" >/dev/null 2>&1 && break; sleep 1; done
            echo "RG proof: $(curl -fsS "http://$ZOT_ADDR/v2/_catalog")"
            ;;
        OS)
            sync
            echo 3 > /proc/sys/vm/drop_caches
            echo "OS proof: page cache dropped"
            ;;
        *)
            echo "unknown level $level" >&2
            exit 2
            ;;
    esac
done
