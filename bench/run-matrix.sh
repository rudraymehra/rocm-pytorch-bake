#!/usr/bin/env bash
# Run one benchmark scenario on this host and record every run in results/.
#
#   bench/run-matrix.sh <scenario> <reps> <aic-checkout> <builder> <gfx>
#
#   C0   full cold                        reset BK,SC,RG,OS   rpb and AIC, ABBA order
#   C1a  new builder, warm sccache        reset BK,RG,OS      rpb and AIC, ABBA order
#   C1b  new builder, warm zot            reset BK,OS         rpb and AIC, ABBA order
#   W0   no-op rebuild                    no reset            rpb and AIC, ABBA order
#   W1a/W1b/W2/W3  one-file patch (bench/make-patches.sh)    rpb only; after each patched
#        run the patch is removed and a "<scenario>-revert" run must be fully cached.
# Run C0 first: the other scenarios start from the caches it leaves behind.
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
    C1b) reset=BK,OS ;;
    W0) ;;
    W1a|W1b|W2|W3) configs=rpb ;;
    *) echo "unknown scenario $scenario" >&2; exit 2 ;;
esac

rpb_build() { # rpb_build <scenario-label>
    "$repo/scripts/rpb" build --builder "$builder" --scenario "$1" --config rpb \
        --targets "wheels test" -- --var "GPU_ARCH=$gfx" \
        --var "CACHE_REGISTRY=$ZOT_ADDR" --var "SCCACHE_ENV_FILE=$SECRETS/sccache.env" || true
}

run_one() { # run_one <config>
    touch /run/rpb/heartbeat 2>/dev/null || true
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
            pkg=$(basename "$(dirname "$patch_file")")
            cp "$patch_file" "$repo/patches/$pkg/"
            rpb_build "$scenario"
            rm -f "$repo/patches/$pkg/$(basename "$patch_file")"
            rpb_build "$scenario-revert"
            ;;
        *) rpb_build "$scenario" ;;
    esac
}

for rep in $(seq 1 "$reps"); do
    if [ $((rep % 2)) -eq 1 ]; then order=$configs; else order=$(echo "$configs" | awk '{for (i = NF; i > 0; i--) printf "%s ", $i}'); fi
    for config in $order; do
        echo "=== scenario $scenario rep $rep config $config"
        run_one "$config"
    done
done
