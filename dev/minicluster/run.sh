#!/usr/bin/env bash
# End-to-end proof of the build infrastructure on one machine, at zero cost.
#
#   dev/minicluster/run.sh up      # certs, secrets, configs, a copy of the repo, 6 containers, 2 builders
#   dev/minicluster/run.sh test    # the 8 checks below; exits non-zero on the first failure
#   dev/minicluster/run.sh down    # stop and delete everything, including volumes and builders
#
# `up` starts from scratch every time (it runs `down` first). Builds run in a copy of
# the repository under .state/work, so the checks never touch this checkout's out/,
# results/ or .rpb-routes. Logs stay in dev/minicluster/.logs/ until the next `up`.
#
# Each check reads the component itself (Valkey, zot, Prometheus, each daemon's own
# BuildKit history), not only what our scripts report, and most have a negative
# control that breaks the component and must make the check fail.
#
#   1. mTLS and identity: both builders answer with the client certificate and are two
#      different daemons; no certificate, or one from another CA, is refused
#   2. sccache through Redis: builder1 compiles 40 files (40 misses, 40 Redis writes,
#      40 new keys in Valkey); builder2 compiles the same sources with no layer cache
#      and reads all 40 from Redis (Valkey keyspace hits rise by 40); the build is in
#      builder2's own history. Control: a wrong Redis password fails in strict mode
#   3. zot layer cache: an empty builder2 gets the compile step of this run from zot,
#      and zot lists the cache tag. Control: the same build without zot reuses nothing
#   4. Redis down at the start: the build succeeds and records remote=fallback, also in
#      a scripts/rpb record. Control: strict mode fails, for that reason
#   5. Redis lost during the compile: the build finishes and records remote=degraded
#   6. telemetry: scripts/rpb writes a record that agrees with Valkey and with the
#      daemon's history; the real-output parser tests pass on this run's output.
#      Control: a target that fails on purpose is recorded as failed, with its error
#   7. multi-machine: scripts/rpb-cluster pushes torch-dev to zot; each downstream
#      target is built by the daemon it was routed to, from torch-dev@digest (each
#      daemon's own history says so). Control: preset routes are followed
#      (with dev/minicluster/cluster-override.hcl, every build is a busybox step)
#   8. Prometheus: both scrape targets are up, the textfile collector has no errors,
#      every run is visible, and success, Redis state, durations, cached ratios and
#      compile counts equal record.json. Control: with the metric files removed the
#      series disappear, and come back
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
state="$here/.state"
work="$state/work"
logs="$here/.logs"
cd "$repo"
compose=(docker compose -f "$here/compose.yaml")
bake=(docker buildx bake -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl)
b1=rpb-localhost-12341
b2=rpb-localhost-12342
valkey_ip=10.231.0.10
zot_url=http://127.0.0.1:15000
prom_url=http://127.0.0.1:19090

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

preflight() {
    local v
    v=$(docker buildx version | awk '{print $2}' | sed 's/^v//; s/-.*//')
    python3 - "$v" <<'EOF' || fail "buildx $v is too old: v0.38.0 or later is needed (README, Requirements)"
import sys
major, minor = (int(x) for x in sys.argv[1].split(".")[:2])
sys.exit(0 if (major, minor) >= (0, 38) else 1)
EOF
    python3 -c "import pytest" 2>/dev/null || fail "python3 needs pytest (python3 -m pip install pytest)"
}

up() {
    preflight
    down >/dev/null 2>&1 || true
    rm -rf "$logs"
    mkdir -p "$state/buildkit/certs" "$state/valkey" "$state/textfile" "$state/prometheus" "$logs"
    infra/certs/make-certs.sh "$state/certs" localhost,127.0.0.1 >/dev/null 2>&1
    # A second, unrelated CA for the negative mTLS control.
    infra/certs/make-certs.sh "$state/rogue" localhost >/dev/null 2>&1
    cp "$state/certs/daemon/localhost/"{cert,key,ca}.pem "$state/buildkit/certs/"
    sed 's/ZOT_ADDR/zot:5000/' infra/buildkit/buildkitd.toml > "$state/buildkit/buildkitd.toml"
    infra/cache-node/make-secrets.sh "$valkey_ip" "$state/secrets" >/dev/null   # fixed in compose.yaml
    # Valkey runs as its own user in the container; Linux enforces the file mode (Docker Desktop does not).
    install -m 0644 "$state/secrets/users.acl" "$state/valkey/users.acl"
    # strict: a Redis fallback fails the step; badpw: strict with a wrong password
    { cat "$state/secrets/sccache.env"; echo "RPB_SCCACHE_REQUIRE_REMOTE=1"; } > "$state/secrets/sccache-strict.env"
    sed 's/^SCCACHE_REDIS_PASSWORD=.*/SCCACHE_REDIS_PASSWORD=wrong/' "$state/secrets/sccache-strict.env" \
        > "$state/secrets/sccache-badpw.env"
    sed -e 's/^bind CACHE_NODE_IP 127.0.0.1$/bind * -::*/' -e 's/^maxmemory 32gb$/maxmemory 512mb/' \
        -e 's/^io-threads 4$/io-threads 1/' infra/cache-node/valkey.conf > "$state/valkey/valkey.conf"
    sed -e 's/RPB_CLIENT_TARGETS/"node-exporter:9100"/' -e 's/ZOT_ADDR/zot:5000/' \
        -e 's/^  scrape_interval: 15s$/  scrape_interval: 5s/' infra/monitoring/prometheus.yml > "$state/prometheus/prometheus.yml"
    # The builds run in a copy, so this checkout's out/, results/ and routes stay untouched.
    mkdir -p "$work"
    tar -C "$repo" --exclude ./dev/minicluster/.state --exclude ./dev/minicluster/.logs \
        --exclude ./out --exclude ./results --exclude ./.rpb-routes -cf - . | tar -C "$work" -xf -
    "${compose[@]}" up -d
    CERT_DIR="$state/certs/client" infra/buildkit/create-builders.sh localhost:12341 localhost:12342
}

down() {
    docker buildx rm "$b1" >/dev/null 2>&1 || true
    docker buildx rm "$b2" >/dev/null 2>&1 || true
    "${compose[@]}" down -v
    rm -rf "$state"
}

# vk <valkey-cli args...>: valkey-cli as the admin user; the password is passed in
# the environment, not on the command line
vk() {
    # shellcheck source=/dev/null
    . "$state/secrets/valkey-admin.env"
    VALKEYCLI_AUTH=$VALKEY_PASSWORD docker exec -e VALKEYCLI_AUTH rpb-mini-valkey-1 valkey-cli --user "$VALKEY_USER" "$@"
}
vk_keys() {
    local keys
    keys=$(vk --scan --pattern 'rpb/v1/*') || fail "Valkey not reachable as admin"
    printf '%s\n' "$keys" | grep -c -v -e 'sccache_check$' -e '^$' || true
}
vk_hits() { vk info stats | tr -d '\r' | awk -F: '$1 == "keyspace_hits" {print $2}'; }
valkey_start() {
    "${compose[@]}" start valkey >/dev/null
    for _ in $(seq 1 30); do
        [ "$(vk ping 2>/dev/null | tr -d '\r')" = "PONG" ] && return 0
        sleep 1
    done
    fail "Valkey did not come back"
}

# toy <label> <builder> <probe> <env-file> [extra bake args...]: build the toy target;
# the client log goes to .logs/<label>.log; returns the bake's exit status
toy() {
    local label=$1 builder=$2 probe=$3 env=$4
    shift 4
    rm -rf out/gfx942/toy
    "${bake[@]}" --builder "$builder" --progress plain --allow "fs.read=$state/secrets" \
        --var CACHE_REGISTRY=zot:5000 --var "RUN_ID=$label-$probe" \
        --var "SCCACHE_ENV_FILE=$env" --var "CACHE_PROBE=$probe" "$@" toy >"$logs/$label.log" 2>&1
}
stats() { python3 -c "import json,sys; d=json.load(open('out/gfx942/toy/telemetry/toy-sccache.json'))['stats']; print(eval(sys.argv[1]))" "$1"; }
level() { stats "[l for l in d['multi_level'] or [] if l['name'] == '$1'][0]['$2']"; }
remote() { cat out/gfx942/toy/telemetry/toy-sccache-remote.txt; }
node_of() { docker buildx inspect --bootstrap "$1" | awk -F': *' '$1 ~ /org.mobyproject.buildkit.worker.hostname/ {print $2; exit}'; }
# ref_of <builder> <record name>: the id of that record in the daemon's own history
ref_of() {
    docker buildx history ls --builder "$1" --format json --no-trunc | python3 -c '
import json, sys
for line in sys.stdin:
    r = json.loads(line)
    if r.get("name") == sys.argv[1]:
        print(r["ref"].rsplit("/", 1)[-1]); break' "$2"
}
# step_cached <builder> <ref> <text>: "true" if the step whose name contains text was cached
step_cached() {
    docker buildx history logs --builder "$1" --progress=rawjson "$2" 2>&1 >/dev/null | python3 -c '
import json, sys
cached = None
for line in sys.stdin:
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    for v in obj.get("vertexes") or []:
        if sys.argv[1] in v.get("name", ""):
            cached = bool(v.get("cached")) or bool(cached)
print("true" if cached else "false")' "$3"
}
# rpb_run <run-dir-file> <scripts/rpb build args...>: one scripts/rpb run, log in .logs
rpb_run() {
    local dir_file=$1
    shift
    RPB_HOST_CLASS=laptop RPB_RUN_DIR_FILE="$dir_file" scripts/rpb build "$@"
}

test_all() {
    preflight
    [ -d "$work" ] || fail "run 'dev/minicluster/run.sh up' first"
    cd "$work"
    # Valkey is stopped by checks 4 and 5; whatever happens, it is started again.
    trap 'docker start rpb-mini-valkey-1 >/dev/null 2>&1 || true' EXIT
    local strict="$state/secrets/sccache-strict.env" lenient="$state/secrets/sccache.env"
    local certs="$state/certs/client" rogue="$state/rogue/client"
    export RPB_TEXTFILE_DIR="$state/textfile"
    local rdf="$state/run-dir"

    # 1. mTLS and identity
    node1=$(node_of "$b1") node2=$(node_of "$b2")
    [ -n "$node1" ] && [ -n "$node2" ] || fail "could not read the daemons' host names"
    [ "$node1" != "$node2" ] || fail "both builder names reach the same daemon ($node1)"
    [ "$node1" = "$(docker inspect -f '{{.Config.Hostname}}' rpb-mini-builder1-1)" ] || fail "builder1 is not the builder1 container"
    [ "$node2" = "$(docker inspect -f '{{.Config.Hostname}}' rpb-mini-builder2-1)" ] || fail "builder2 is not the builder2 container"
    for port in 12341 12342; do
        code=$(curl -s --http2 --max-time 5 --cacert "$certs/ca.pem" --cert "$certs/cert.pem" --key "$certs/key.pem" \
            -o /dev/null -w '%{http_code}' "https://localhost:$port" || true)
        [ "$code" = "415" ] || fail "builder on $port with the client certificate: expected HTTP 415 from gRPC, got '$code'"
        if curl -s --http2 --max-time 5 --cacert "$certs/ca.pem" -o /dev/null "https://localhost:$port"; then
            fail "builder on $port accepted a client without a certificate"
        fi
        if curl -s --http2 --max-time 5 --cacert "$certs/ca.pem" --cert "$rogue/cert.pem" --key "$rogue/key.pem" \
            -o /dev/null "https://localhost:$port"; then
            fail "builder on $port accepted a client certificate from another CA"
        fi
    done
    pass "1 mTLS: two different daemons ($node1, $node2) answer with the client certificate; no certificate and a foreign CA are refused"

    # 2. sccache through Redis, across builders
    probe=$(date +%s)
    keys0=$(vk_keys)
    toy c2-b1 "$b1" "$probe" "$strict" || fail "toy build on builder1 (log: $logs/c2-b1.log)"
    [ "$(remote)" = "redis" ] || fail "builder1 did not use the Redis level: remote=$(remote)"
    [ "$(stats 'd["cache_misses"]["counts"].get("C/C++", 0)')" -eq 40 ] || fail "builder1: expected 40 misses"
    [ "$(level 'L1 (redis)' writes)" -eq 40 ] || fail "builder1: expected 40 Redis writes (write policy must be 'all')"
    keys1=$(vk_keys)
    [ $((keys1 - keys0)) -eq 40 ] || fail "Valkey: expected 40 new keys, got $((keys1 - keys0))"
    hits0=$(vk_hits)
    toy c2-b2 "$b2" "$probe" "$strict" --set toy.no-cache=true || fail "toy build on builder2 (log: $logs/c2-b2.log)"
    [ "$(remote)" = "redis" ] || fail "builder2 did not use the Redis level: remote=$(remote)"
    [ "$(level 'L1 (redis)' hits)" -eq 40 ] || fail "builder2: expected 40 Redis hits, got $(level 'L1 (redis)' hits)"
    hits1=$(vk_hits)
    [ $((hits1 - hits0)) -ge 40 ] || fail "Valkey: keyspace_hits rose by $((hits1 - hits0)), expected at least 40"
    [ -n "$(ref_of "$b2" "rpb/toy/gfx942/c2-b2-$probe")" ] || fail "the builder2 build is not in builder2's own history"
    if toy c2-badpw "$b1" "$((probe + 10))" "$state/secrets/sccache-badpw.env"; then
        fail "control: a wrong Redis password did not fail the build in strict mode"
    fi
    grep -q "RPB_SCCACHE_REQUIRE_REMOTE=1; failing" "$logs/c2-badpw.log" \
        || fail "control: the build failed, but not because Redis was refused (see $logs/c2-badpw.log)"
    pass "2 sccache: builder1 wrote 40 objects (Valkey +$((keys1 - keys0)) keys), builder2 read all 40 (Valkey hits +$((hits1 - hits0))); a wrong password fails"

    # 3. zot layer cache: the compile step of THIS run (its sources embed this probe)
    tags=$(curl -fsS "$zot_url/v2/rpb/cache/tags/list") || fail "zot API not reachable"
    echo "$tags" | grep -q '"toy-gfx942-rocm10.0.0-py3.12"' || fail "zot has no toy cache tag: $tags"
    docker buildx prune --builder "$b2" -af >/dev/null
    toy c3-nozot "$b2" "$probe" "$strict" --var CACHE_REGISTRY= || fail "toy build on builder2 without zot"
    nozot=$(step_cached "$b2" "$(ref_of "$b2" "rpb/toy/gfx942/c3-nozot-$probe")" "rpb-sccache-run toy")
    [ "$nozot" = false ] || fail "control: an empty builder without zot reused the compile step; the zot result below would prove nothing"
    docker buildx prune --builder "$b2" -af >/dev/null
    toy c3-zot "$b2" "$probe" "$strict" || fail "toy build on builder2 with zot"
    ref=$(ref_of "$b2" "rpb/toy/gfx942/c3-zot-$probe")
    [ "$(step_cached "$b2" "$ref" "rpb-sccache-run toy")" = true ] || fail "empty builder2 did not get this run's compile step from zot"
    [ "$(step_cached "$b2" "$ref" "seq 1")" = true ] || fail "empty builder2 did not get this run's source step from zot"
    pass "3 zot: empty builder2 took this run's source and compile steps from zot (not without zot); zot lists the cache tag"

    # 4. Redis down at the start
    "${compose[@]}" stop valkey >/dev/null
    toy c4-down "$b1" "$((probe + 1))" "$lenient" || fail "build failed while Redis was down (log: $logs/c4-down.log)"
    [ "$(remote)" = "fallback" ] || fail "Redis was down but the build recorded remote=$(remote)"
    if toy c4-strict "$b1" "$((probe + 2))" "$strict"; then
        fail "control: strict mode did not fail with Redis down"
    fi
    grep -q "RPB_SCCACHE_REQUIRE_REMOTE=1; failing" "$logs/c4-strict.log" \
        || fail "control: strict mode failed, but not because Redis was down (see $logs/c4-strict.log)"
    rpb_run "$rdf" --builder "$b1" --scenario fallback --targets toy -- \
        -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$lenient" --var "CACHE_PROBE=$((probe + 3))" >"$logs/c4-rpb.log" 2>&1 \
        || fail "scripts/rpb with Redis down (log: $logs/c4-rpb.log)"
    rec_fallback="$(cat "$rdf")/record.json"
    python3 -c 'import json,sys; u=json.load(open(sys.argv[1]))["compile_units"]["toy"]; assert u["remote"] == "fallback", u["remote"]' \
        "$rec_fallback" || fail "the scripts/rpb record does not say remote=fallback"
    valkey_start
    pass "4 Redis down: the build succeeded and recorded remote=fallback (also in record.json); strict mode failed for that reason"

    # 5. Redis lost during the compile. The toy waits until Valkey is unreachable before
    #    it compiles, so the loss always happens after sccache has started with Redis.
    rpb_run "$rdf" --builder "$b1" --scenario degraded --targets toy -- \
        -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$lenient" --var "CACHE_PROBE=$((probe + 4))" --var TOY_FILES=2 \
        --var "TOY_WAIT_REDIS_DOWN=$valkey_ip:6379" >"$logs/c5-rpb.log" 2>&1 &
    rpb_pid=$!
    for _ in $(seq 1 120); do
        grep -q "toy: waiting for Redis to go away" "$logs/c5-rpb.log" 2>/dev/null && break
        sleep 1
    done
    grep -q "toy: waiting for Redis to go away" "$logs/c5-rpb.log" || { kill "$rpb_pid" 2>/dev/null; fail "check 5 never reached the compile (log: $logs/c5-rpb.log)"; }
    "${compose[@]}" stop valkey >/dev/null
    wait "$rpb_pid" || fail "the build with Redis lost during the compile failed (log: $logs/c5-rpb.log)"
    rec_degraded="$(cat "$rdf")/record.json"
    python3 -c 'import json,sys; u=json.load(open(sys.argv[1]))["compile_units"]["toy"]; assert u["remote"] == "degraded", u["remote"]' \
        "$rec_degraded" || fail "Redis was lost during the compile but the record does not say remote=degraded"
    valkey_start
    pass "5 Redis lost during the compile: the build finished and recorded remote=degraded"

    # 6. telemetry end to end
    keys0=$(vk_keys)
    rpb_run "$rdf" --builder "$b1" --scenario dev --targets toy -- \
        -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$strict" --var "CACHE_PROBE=$((probe + 5))" >"$logs/c6-rpb.log" 2>&1 \
        || fail "scripts/rpb build (log: $logs/c6-rpb.log)"
    keys1=$(vk_keys)
    res=$(cat "$rdf")
    rec="$res/record.json"
    ref=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"]["toy"]["buildkit"]["ref"])' "$rec")
    docker buildx history inspect --builder "$b1" "$ref" --format json > "$state/c6-inspect.json" \
        || fail "the record's ref $ref is not in builder1's history"
    python3 - "$rec" "$state/c6-inspect.json" "$((keys1 - keys0))" "$node1" <<'EOF' || fail "record.json incomplete or inconsistent"
import json, sys
r = json.load(open(sys.argv[1]))
h = json.load(open(sys.argv[2]))
t = r["targets"]["toy"]["buildkit"]
assert t["status"] == "completed" and t["steps_total"] > 0, t
assert t["name"] == f"rpb/toy/gfx942/{r['run_id']}", t["name"]
assert (t["steps_total"], t["steps_cached"]) == (h["NumTotalSteps"], h["NumCachedSteps"]), (t, h)
assert r["builder_node"] == sys.argv[4], r["builder_node"]
assert r["targets"]["toy"]["stages"], "no per-step timings from history logs"
u = r["compile_units"]["toy"]
assert u["remote"] == "redis" and u["fresh"] is True, u
redis = [l for l in u["sccache"]["levels"] if l["name"] == "L1 (redis)"][0]
# independent: Valkey itself counted the new objects
assert redis["writes"] == 40 == int(sys.argv[3]), (redis, sys.argv[3])
EOF
    mkdir -p "$state/fixtures"
    cp "$res/inspect/toy.json" "$state/fixtures/inspect-toy.json"
    cp "$res/steps/toy.jsonl" "$state/fixtures/steps-toy.jsonl"
    cp "$res/telemetry/toy-sccache.json" "$state/fixtures/toy-sccache.json"
    cp "$res/history-ls.json" "$state/fixtures/history-ls.json"
    RPB_REAL_FIXTURES="$state/fixtures" python3 -m pytest -q -p no:cacheprovider telemetry/tests/test_real_fixtures.py \
        >"$logs/c6-pytest.log" 2>&1 || fail "the parsers fail on this run's real output (log: $logs/c6-pytest.log)"
    grep -q "4 passed" "$logs/c6-pytest.log" || fail "the real-output tests did not all run (log: $logs/c6-pytest.log)"
    if rpb_run "$rdf" --builder "$b1" --scenario failtest --targets toy -- \
        -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$strict" --var CACHE_PROBE=fail >"$logs/c6-fail.log" 2>&1; then
        fail "control: a target that fails on purpose made scripts/rpb exit 0"
    fi
    rec_failed="$(cat "$rdf")/record.json"
    python3 - "$rec_failed" <<'EOF' || fail "the failed run's record does not show the failed target"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["status"] == "failed" and r["exit_code"] != 0, (r["status"], r["exit_code"])
t = r["targets"]["toy"]["buildkit"]
assert t["status"] == "failed" and t["error"], t
EOF
    pass "6 telemetry: the record matches builder1's history and Valkey (+40 keys); real-output parser tests pass; a failing target is recorded as failed"

    # 7. multi-machine: routing and the torch-dev hand-off through zot
    rm -f .rpb-routes
    scripts/rpb-cluster --builders "$b1 $b2" --registry zot:5000 -- \
        -f docker-bake.hcl -f dev/minicluster/cluster-override.hcl >"$logs/c7-cluster.log" 2>&1 \
        || fail "scripts/rpb-cluster (log: $logs/c7-cluster.log)"
    check_cluster() { # check_cluster <log>: every downstream target ran where it was routed, from torch-dev@digest
        local image digest served
        image=$(sed -n 's/^torch-dev: //p' "$1")
        digest=${image##*@}
        served=$(curl -fsS -o /dev/null -D - \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "$zot_url/v2/rpb/torch-dev/manifests/$digest" | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')
        [ "$served" = "$digest" ] || fail "zot does not serve torch-dev at $digest (got '$served')"
        while read -r target builder; do
            # scripts/rpb ends with "run <run_id>: status ..."; records are named rpb/<target>/<gfx>/<run_id>
            run_id=$(sed -n 's/^run \([^:]*\): status.*/\1/p' "results/.phase-b-$builder.log" | tail -1)
            [ -n "$run_id" ] || fail "no run id in results/.phase-b-$builder.log"
            ref=$(ref_of "$builder" "rpb/$target/gfx942/$run_id")
            [ -n "$ref" ] || fail "$target is not in the history of $builder, where it was routed"
            ctx=$(docker buildx history inspect --builder "$builder" "$ref" --format json \
                | python3 -c 'import json,sys; print({c["Name"]: c["Value"] for c in json.load(sys.stdin).get("NamedContexts") or []}.get("torch-dev", ""))')
            [ "$ctx" = "docker-image://$image" ] || fail "$target on $builder was built from '$ctx', not docker-image://$image"
        done < .rpb-routes
    }
    [ "$(awk '{print $2}' .rpb-routes | sort -u | wc -l)" -eq 2 ] || fail "downstream targets were not routed to both builders"
    check_cluster "$logs/c7-cluster.log"
    # control: preset routes (the opposite of what load balancing picks) must be followed
    awk -v a="$b1" -v b="$b2" '{print $1, ($2 == a ? b : a)}' .rpb-routes > "$state/routes.preset"
    cp "$state/routes.preset" .rpb-routes
    scripts/rpb-cluster --builders "$b1 $b2" --registry zot:5000 -- \
        -f docker-bake.hcl -f dev/minicluster/cluster-override.hcl >"$logs/c7-cluster2.log" 2>&1 \
        || fail "scripts/rpb-cluster with preset routes (log: $logs/c7-cluster2.log)"
    sort .rpb-routes | diff - <(sort "$state/routes.preset") >/dev/null || fail "preset routes were not followed"
    check_cluster "$logs/c7-cluster2.log"
    pass "7 cluster: each downstream target ran on the daemon it was routed to, from the torch-dev@digest that zot serves; preset routes are followed"

    # 8. Prometheus
    python3 - "$prom_url" "$RPB_TEXTFILE_DIR" "$rec" "$rec_fallback" "$rec_degraded" "$rec_failed" <<'EOF' || fail "Prometheus check (see the message above)"
import glob, json, os, sys, time, urllib.parse, urllib.request
sys.path.insert(0, ".")
from telemetry import prom as rpb_prom
prom, textfile, rec_ok, rec_fallback, rec_degraded, rec_failed = sys.argv[1:]

def get(path):
    return json.load(urllib.request.urlopen(prom + path, timeout=5))["data"]

def q(expr):
    return get("/api/v1/query?" + urllib.parse.urlencode({"query": expr}))["result"]

def value(expr):
    r = q(expr)
    return float(r[0]["value"][1]) if r else None

def wait(expr, want, what, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if value(expr) == want:
            return
        time.sleep(2)
    raise SystemExit(f"{what}: {expr} is {value(expr)}, expected {want}")

def sel(rec, **extra):
    labels = {"scenario": rec["scenario"], "builder": rec["builder"], "target_set": rec["target_set"], **extra}
    return "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"

health = {t["labels"]["job"]: t["health"] for t in get("/api/v1/targets")["activeTargets"]}
assert health == {"rpb": "up", "zot": "up"}, health
files = len(glob.glob(os.path.join(textfile, "*.prom")))
wait("count(rpb_run_success)", files, f"one series per textfile ({files})")
assert value("node_textfile_scrape_error") == 0, "node-exporter could not parse a textfile"

for path, success, state in [(rec_ok, 1, "redis"), (rec_fallback, 1, "fallback"),
                             (rec_degraded, 1, "degraded"), (rec_failed, 0, None)]:
    rec = json.load(open(path))
    wait(f"rpb_run_success{sel(rec)}", success, f"success of {rec['scenario']}")
    if state:
        wait(f"rpb_sccache_remote{sel(rec, unit='toy', state=state)}", 1, f"Redis state of {rec['scenario']}")
# the same numbers on two independent paths: record.json vs file -> node-exporter -> Prometheus
rec = json.load(open(rec_ok))
bk = rec["targets"]["toy"]["buildkit"]
sc = rec["compile_units"]["toy"]["sccache"]
wait(f"rpb_target_duration_seconds{sel(rec, target='toy')}", bk["duration_s"], "toy duration")
wait(f"rpb_buildkit_cached_ratio{sel(rec, target='toy')}", bk["cached_ratio"], "toy cached ratio")
wait(f"rpb_buildkit_steps{sel(rec, target='toy', state='total')}", bk["steps_total"], "toy steps")
wait(f"rpb_sccache_compiles{sel(rec, unit='toy', lang='C/C++', result='miss')}", sc["misses"]["C/C++"], "toy misses")
wait(f"rpb_sccache_hit_ratio{sel(rec, unit='toy', lang='C/C++')}", sc["hit_ratio"]["C/C++"], "toy hit ratio")
assert value("count(count by (builder) (rpb_target_duration_seconds))") == 2, "targets from both builders"

# control: without the textfiles the series must disappear, then come back.
# The files move, not the directory: the bind mount follows the directory itself.
off = textfile + ".off"
os.makedirs(off, exist_ok=True)
names = [os.path.basename(f) for f in glob.glob(os.path.join(textfile, "*.prom"))]
for f in names:
    os.rename(os.path.join(textfile, f), os.path.join(off, f))
try:
    deadline = time.time() + 60
    while time.time() < deadline and q("rpb_run_success"):
        time.sleep(2)
    assert not q("rpb_run_success"), "control: rpb series still present without the textfiles"
finally:
    for f in names:
        os.rename(os.path.join(off, f), os.path.join(textfile, f))
    os.rmdir(off)
wait("count(rpb_run_success)", files, "series after restoring the textfiles")
print(f"  {files} runs in Prometheus; toy took {bk['duration_s']:.2f} s in both")
EOF
    pass "8 prometheus: targets up, no textfile errors, every run visible; success, Redis states, durations, cached ratios and compile counts equal record.json; series vanish without the files"
}

case "${1:-}" in
    up) up ;;
    test) test_all ;;
    down) down ;;
    *) sed -n '2,6p' "$0" >&2; exit 2 ;;
esac
