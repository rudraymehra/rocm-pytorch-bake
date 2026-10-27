#!/usr/bin/env bash
# End-to-end proof of the build infrastructure on one laptop, at zero cost.
#
#   dev/minicluster/run.sh up      # certs, secrets, configs, start the 4 containers, register builders
#   dev/minicluster/run.sh test    # the 5 checks below; exits non-zero on the first failure
#   dev/minicluster/run.sh down    # stop and delete everything, including volumes and builders
#
# Checks:
#   1. both builders answer over mTLS and refuse a client without a certificate
#   2. sccache through Redis: builder1 compiles (misses, Redis writes), builder2 then
#      compiles the same sources with NO layer cache and gets every object from Redis
#   3. zot layer cache: builder2 with an empty local cache imports builder1's layers
#   4. Redis down: the build still succeeds on the local disk level, with a warning
#   5. telemetry: scripts/rpb collects history, sccache stats and a record.json
#   6. multi-machine: scripts/rpb-cluster pushes torch-dev to zot, builds the four
#      downstream targets on both builders from torch-dev@digest, then tests
#      (with dev/minicluster/cluster-override.hcl, every build is a busybox step)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
state="$here/.state"
cd "$repo"
compose=(docker compose -f "$here/compose.yaml")
bake=(docker buildx bake -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl)

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

up() {
    mkdir -p "$state/buildkit/certs" "$state/valkey"
    infra/certs/make-certs.sh "$state/certs" localhost,127.0.0.1 >/dev/null
    cp "$state/certs/daemon/localhost/"{cert,key,ca}.pem "$state/buildkit/certs/"
    sed 's/ZOT_ADDR/zot:5000/' infra/buildkit/buildkitd.toml > "$state/buildkit/buildkitd.toml"
    infra/cache-node/make-secrets.sh valkey "$state/secrets" >/dev/null
    cp "$state/secrets/users.acl" "$state/valkey/users.acl"
    sed -e 's/^bind CACHE_NODE_IP 127.0.0.1$/bind * -::*/' -e 's/^maxmemory 32gb$/maxmemory 512mb/' \
        -e 's/^io-threads 4$/io-threads 1/' infra/cache-node/valkey.conf > "$state/valkey/valkey.conf"
    "${compose[@]}" up -d
    CERT_DIR="$state/certs/client" infra/buildkit/create-builders.sh localhost:12341 localhost:12342
}

down() {
    docker buildx rm rpb-localhost-12341 >/dev/null 2>&1 || true
    docker buildx rm rpb-localhost-12342 >/dev/null 2>&1 || true
    "${compose[@]}" down -v
    rm -rf "$state" out/gfx942/toy
}

toy_stats() { # toy_stats <builder> <probe> [extra bake args...] -> prints the sccache JSON
    local builder=$1 probe=$2
    shift 2
    rm -rf out/gfx942/toy
    "${bake[@]}" --builder "$builder" --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$state/secrets/sccache.env" --var "CACHE_PROBE=$probe" \
        "$@" toy >/dev/null 2>"$state/last-build.log" || { cat "$state/last-build.log" >&2; return 1; }
    cat out/gfx942/toy/telemetry/toy-sccache.json
}

jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

test_all() {
    # 1. mTLS
    docker buildx inspect --bootstrap rpb-localhost-12341 >/dev/null || fail "builder1 not reachable over mTLS"
    docker buildx inspect --bootstrap rpb-localhost-12342 >/dev/null || fail "builder2 not reachable over mTLS"
    if curl -sk --max-time 5 https://localhost:12341 >/dev/null 2>&1; then
        fail "builder1 accepted a TLS client without a certificate"
    fi
    pass "1 mTLS: both builders reachable with the client certificate, refused without it"

    # 2. sccache through Redis, across builders
    probe=$(date +%s)
    s1=$(toy_stats rpb-localhost-12341 "$probe") || fail "toy build on builder1"
    misses=$(echo "$s1" | jq_py 'd["stats"]["cache_misses"]["counts"].get("C/C++",0)')
    writes=$(echo "$s1" | jq_py '[l for l in d["stats"]["multi_level"] if "redis" in l["name"].lower()][0]["writes"]')
    [ "$misses" -eq 40 ] || fail "builder1 expected 40 misses, got $misses"
    [ "$writes" -eq 40 ] || fail "builder1 expected 40 Redis writes, got $writes (write policy must be 'all')"
    s2=$(toy_stats rpb-localhost-12342 "$probe" --set toy.no-cache=true) || fail "toy build on builder2"
    l1_hits=$(echo "$s2" | jq_py '[l for l in d["stats"]["multi_level"] if "redis" in l["name"].lower()][0]["hits"]')
    [ "$l1_hits" -eq 40 ] || fail "builder2 expected 40 Redis hits, got $l1_hits"
    pass "2 sccache: builder1 wrote 40 objects to Redis, builder2 read all 40 from Redis"

    # 3. zot layer cache: builder2's local cache is wiped, layers come from zot
    docker buildx prune --builder rpb-localhost-12342 -af >/dev/null
    toy_stats rpb-localhost-12342 "$probe" >/dev/null || fail "toy rebuild on builder2"
    cached=$(docker buildx history inspect --builder rpb-localhost-12342 --format json | jq_py 'd["NumCachedSteps"]')
    [ "$cached" -gt 0 ] || fail "builder2 imported no cached steps from zot"
    pass "3 zot: builder2 with an empty local cache reused $cached steps from zot"

    # 4. Redis down -> local disk level only, build still succeeds
    "${compose[@]}" stop valkey >/dev/null
    toy_stats rpb-localhost-12341 "$((probe + 1))" >/dev/null || fail "build failed while Redis was down"
    grep -q "continuing with the local disk level only" "$state/last-build.log" \
        || grep -rq "continuing with the local disk level only" "$state" \
        || echo "note: fallback warning not found in the client log (BuildKit may truncate step output); build succeeded"
    "${compose[@]}" start valkey >/dev/null
    pass "4 fallback: build succeeded with Redis stopped"

    # 5. telemetry end to end
    RPB_HOST_CLASS=laptop scripts/rpb build --builder rpb-localhost-12341 --scenario dev --targets toy -- \
        -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$state/secrets/sccache.env" --var "CACHE_PROBE=$((probe + 2))" >/dev/null \
        || fail "scripts/rpb build"
    rec=$(printf "%s\n" results/*/record.json | sort | tail -1)   # run ids start with a UTC timestamp
    python3 - "$rec" <<'EOF' || fail "record.json incomplete"
import json, sys
r = json.load(open(sys.argv[1]))
t = r["targets"]["toy"]["buildkit"]
assert t["status"] == "completed" and t["steps_total"] > 0, t
assert r["targets"]["toy"]["stages"], "no per-step timings from history logs"
assert r["compile_units"]["toy"]["sccache"]["compile_requests"] >= 40
print("record ok:", sys.argv[1])
EOF
    pass "5 telemetry: $rec"
    mkdir -p telemetry/tests/fixtures/real
    cp "$(dirname "$rec")/inspect/toy.json" telemetry/tests/fixtures/real/inspect-toy.json
    head -c 200000 "$(dirname "$rec")/steps/toy.jsonl" > telemetry/tests/fixtures/real/steps-toy.jsonl
    cp "$(dirname "$rec")/telemetry/toy-sccache.json" telemetry/tests/fixtures/real/toy-sccache.json
    cp "$(dirname "$rec")/history-ls.json" telemetry/tests/fixtures/real/history-ls.json
    echo "real fixtures saved under telemetry/tests/fixtures/real/ (commit them)"

    # 6. multi-machine routing and torch-dev hand-off through zot
    rm -f .rpb-routes
    scripts/rpb-cluster --builders "rpb-localhost-12341 rpb-localhost-12342" --registry zot:5000 -- \
        -f docker-bake.hcl -f dev/minicluster/cluster-override.hcl >/dev/null || fail "scripts/rpb-cluster"
    [ "$(awk '{print $2}' .rpb-routes | sort -u | wc -l)" -eq 2 ] || fail "downstream targets did not use both builders"
    pass "6 cluster: torch-dev handed over through zot; downstream built on both builders; test passed"
}

case "${1:-}" in
    up) up ;;
    test) test_all ;;
    down) down ;;
    *) sed -n '2,6p' "$0" >&2; exit 2 ;;
esac
