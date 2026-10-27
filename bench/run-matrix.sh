#!/usr/bin/env bash
# Run one benchmark scenario on this host and record every run in results/.
#
#   bench/run-matrix.sh <scenario> <reps> <aic-checkout> <builder> <gfx>
#   RPB_AA=1 bench/run-matrix.sh ...    # A/A: rpb against itself (config rpb-aa), the noise floor
#
#   C0   full cold                        reset BK,SC,RG,OS   rpb and AIC, ABBA order
#   C1a  new builder, warm sccache only   reset BK,RG,OS      rpb and AIC, ABBA order
#   C1b  new builder, warm zot only       reset BK,SC,OS      rpb and AIC, ABBA order
#   W0   no-op rebuild                    no reset            rpb and AIC, ABBA order
#   W1a/W1b/W2/W3  one-file patch (bench/make-patches.sh)    rpb only; after each patched
#        run the patch is removed and a "<scenario>-revert" run must be fully cached.
#        Every run gets a new marker name in the patch, so each patched run is a real
#        miss, not a hit from an earlier repetition.
# Run C0 first: the other scenarios start from the caches it leaves behind.
# While it runs, the EC2 heartbeat (/run/rpb/heartbeat) is touched every minute.
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <scenario> <reps> <aic-checkout> <builder> <gfx>" >&2
    exit 2
fi
scenario=$1 reps=$2 aic=$3 builder=$4 gfx=$5
: "${ZOT_ADDR:?}" "${SECRETS:?}"
repo=$(cd "$(dirname "$0")/.." && pwd)

reset="" configs="rpb aic"
case "$scenario" in
    C0) reset=BK,SC,RG,OS ;;
    C1a) reset=BK,RG,OS ;;
    C1b) reset=BK,SC,OS ;;
    W0) ;;
    W1a|W1b|W2|W3) configs=rpb ;;
    *) echo "unknown scenario $scenario" >&2; exit 2 ;;
esac
if [ "${RPB_AA:-0}" = 1 ] && [ "$configs" = "rpb aic" ]; then
    configs="rpb rpb-aa"
fi

heartbeat=/run/rpb/heartbeat
applied=""
cleanup() {
    if [ -n "$applied" ]; then
        rm -f "$applied"
        echo "removed $applied" >&2
    fi
    if [ -n "${beat_pid:-}" ]; then
        kill "$beat_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -e "$heartbeat" ]; then
    touch "$heartbeat" || { echo "cannot touch $heartbeat; the dead-man switch would power the host off" >&2; exit 1; }
    ( while sleep 60; do touch "$heartbeat"; done ) &
    beat_pid=$!
fi

rpb_build() { # rpb_build <config> <scenario-label>
    "$repo/scripts/rpb" build --builder "$builder" --scenario "$2" --config "$1" \
        --targets "wheels test" -- --var "GPU_ARCH=$gfx" \
        --var "CACHE_REGISTRY=$ZOT_ADDR" --var "SCCACHE_ENV_FILE=$SECRETS/sccache.env" || true
}

run_one() { # run_one <config>
    if [ -n "$reset" ]; then
        "$repo/bench/reset.sh" "$reset"
    fi
    if [ "$1" = aic ]; then
        "$repo/bench/aic-build.sh" "$aic" "$builder" "$gfx" "$scenario" || true
        return
    fi
    case "$scenario" in
        W1a|W1b|W2|W3)
            patch_file=$(find "$repo/bench/patches/$scenario" -name '*.patch' | head -1)
            [ -n "$patch_file" ] || { echo "no patch for $scenario; run bench/make-patches.sh" >&2; exit 1; }
            pkg=$(basename "$(dirname "$patch_file")")
            applied="$repo/patches/$pkg/$(basename "$patch_file")"
            # A new marker name per run: the same patch twice would be a cache hit.
            sed "s/_marker(/_marker_$(date +%s)(/" "$patch_file" > "$applied"
            rpb_build "$1" "$scenario"
            rm -f "$applied"
            applied=""
            rpb_build "$1" "$scenario-revert"
            ;;
        *) rpb_build "$1" "$scenario" ;;
    esac
}

for ((rep = 1; rep <= reps; rep++)); do
    if [ $((rep % 2)) -eq 1 ]; then order=$configs; else order=$(echo "$configs" | awk '{for (i = NF; i > 0; i--) printf "%s ", $i}'); fi
    for config in $order; do
        echo "=== scenario $scenario rep $rep config $config"
        run_one "$config"
    done
done
