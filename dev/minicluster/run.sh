#!/usr/bin/env bash
# End-to-end proof of the build infrastructure on one laptop, at zero cost.
#
#   dev/minicluster/run.sh up      # certs, secrets, configs, start the 6 containers, register builders
#   dev/minicluster/run.sh test    # the 7 checks below; exits non-zero on the first failure
#   dev/minicluster/run.sh down    # stop and delete everything, including volumes and builders
#
# Every check has three parts: the positive result, an independent look at the
# component itself (Valkey, zot, Prometheus, BuildKit history), and a negative
# control that breaks the component and must make the check fail. A check that
# cannot fail proves nothing.
#
#   1. mTLS: both builders answer with the client certificate; a client without a
#      certificate and a client with a certificate from another CA are refused
#   2. sccache through Redis: builder1 compiles 40 files (40 misses, 40 Redis writes,
#      40 new keys in Valkey); builder2 compiles the same sources with no layer cache
#      and reads all 40 from Redis (Valkey keyspace hits go up by 40).
#      Control: a wrong Redis password must fail the build in strict mode
#   3. zot layer cache: builder2 with an empty local cache reuses steps from zot; zot
#      lists the cache tag. Control: the same build without zot reuses no steps
#   4. Redis down: the build still succeeds and records remote=fallback.
#      Control: in strict mode the same build must fail
#   5. telemetry: scripts/rpb writes a complete record.json whose BuildKit record and
#      sccache state agree with the builder's own history and the remote state
#   6. multi-machine: scripts/rpb-cluster pushes torch-dev to zot (zot serves the same
#      digest), builds the four downstream targets on both builders from
#      torch-dev@digest, then tests; every target has its own record
#      (with dev/minicluster/cluster-override.hcl, every build is a busybox step)
#   7. Prometheus: both scrape targets are up, the textfile collector has no errors,
#      all 5 runs of checks 5 and 6 are visible and match record.json.
#      Control: with the textfiles removed the series disappear, and come back
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
state="$here/.state"
cd "$repo"
compose=(docker compose -f "$here/compose.yaml")
bake=(docker buildx bake -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl)
b1=rpb-localhost-12341
b2=rpb-localhost-12342
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
}

up() {
    preflight
    mkdir -p "$state/buildkit/certs" "$state/valkey" "$state/textfile" "$state/prometheus" "$state/logs"
    infra/certs/make-certs.sh "$state/certs" localhost,127.0.0.1 >/dev/null 2>&1
    # A second, unrelated CA for the negative mTLS control.
    infra/certs/make-certs.sh "$state/rogue" localhost >/dev/null 2>&1
    cp "$state/certs/daemon/localhost/"{cert,key,ca}.pem "$state/buildkit/certs/"
    sed 's/ZOT_ADDR/zot:5000/' infra/buildkit/buildkitd.toml > "$state/buildkit/buildkitd.toml"
    infra/cache-node/make-secrets.sh 10.231.0.10 "$state/secrets" >/dev/null   # valkey, fixed in compose.yaml
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
    "${compose[@]}" up -d
    CERT_DIR="$state/certs/client" infra/buildkit/create-builders.sh localhost:12341 localhost:12342
}

down() {
    docker buildx rm "$b1" >/dev/null 2>&1 || true
    docker buildx rm "$b2" >/dev/null 2>&1 || true
    "${compose[@]}" down -v
    rm -rf "$state" out/gfx942/toy
}

# vk <valkey-cli args...>: run valkey-cli as the admin user
vk() {
    # shellcheck source=/dev/null
    . "$state/secrets/valkey-admin.env"
    docker exec rpb-mini-valkey-1 valkey-cli --user "$VALKEY_USER" --pass "$VALKEY_PASSWORD" --no-auth-warning "$@"
}
vk_keys() { vk --scan --pattern 'rpb/v1/*' | grep -vc 'sccache_check$' || true; }
vk_hits() { vk info stats | tr -d '\r' | awk -F: '$1 == "keyspace_hits" {print $2}'; }
wait_valkey() {
    for _ in $(seq 1 30); do
        [ "$(vk ping 2>/dev/null | tr -d '\r')" = "PONG" ] && return 0
        sleep 1
    done
    fail "Valkey did not come back"
}

# toy <label> <builder> <probe> <env-file> [extra bake args...]: build the toy target;
# the client log goes to $state/logs/<label>.log; returns the bake's exit status
toy() {
    local label=$1 builder=$2 probe=$3 env=$4
    shift 4
    rm -rf out/gfx942/toy
    "${bake[@]}" --builder "$builder" --progress plain --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$env" --var "CACHE_PROBE=$probe" "$@" toy >"$state/logs/$label.log" 2>&1
}
stats() { python3 -c "import json,sys; d=json.load(open('out/gfx942/toy/telemetry/toy-sccache.json'))['stats']; print(eval(sys.argv[1]))" "$1"; }
level() { stats "[l for l in d['multi_level'] or [] if l['name'] == '$1'][0]['$2']"; }
remote() { cat out/gfx942/toy/telemetry/toy-sccache-remote.txt; }
last_cached() { docker buildx history inspect --builder "$1" --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["NumCachedSteps"])'; }

test_all() {
    preflight
    local strict="$state/secrets/sccache-strict.env" lenient="$state/secrets/sccache.env"
    local certs="$state/certs/client" rogue="$state/rogue/client"

    # 1. mTLS
    docker buildx inspect --bootstrap "$b1" >/dev/null || fail "builder1 not reachable over mTLS"
    docker buildx inspect --bootstrap "$b2" >/dev/null || fail "builder2 not reachable over mTLS"
    # With the client certificate the TLS handshake succeeds and BuildKit's gRPC
    # server answers a plain HTTPS request with 415.
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
    pass "1 mTLS: both builders answer with the client certificate; no certificate and a foreign CA are refused"

    # 2. sccache through Redis, across builders
    probe=$(date +%s)
    keys0=$(vk_keys)
    toy 2-builder1 "$b1" "$probe" "$strict" || fail "toy build on builder1 (log: $state/logs/2-builder1.log)"
    [ "$(remote)" = "redis" ] || fail "builder1 did not use the Redis level: remote=$(remote)"
    [ "$(stats 'd["cache_misses"]["counts"].get("C/C++", 0)')" -eq 40 ] || fail "builder1: expected 40 misses"
    [ "$(level 'L1 (redis)' writes)" -eq 40 ] || fail "builder1: expected 40 Redis writes (write policy must be 'all')"
    keys1=$(vk_keys)
    [ $((keys1 - keys0)) -eq 40 ] || fail "Valkey: expected 40 new keys, got $((keys1 - keys0))"
    hits0=$(vk_hits)
    toy 2-builder2 "$b2" "$probe" "$strict" --set toy.no-cache=true || fail "toy build on builder2 (log: $state/logs/2-builder2.log)"
    [ "$(remote)" = "redis" ] || fail "builder2 did not use the Redis level: remote=$(remote)"
    [ "$(level 'L0 (disk)' hits)" -eq 0 ] || fail "builder2: the local disk level should be empty"
    [ "$(level 'L1 (redis)' hits)" -eq 40 ] || fail "builder2: expected 40 Redis hits, got $(level 'L1 (redis)' hits)"
    hits1=$(vk_hits)
    [ $((hits1 - hits0)) -ge 40 ] || fail "Valkey: keyspace_hits rose by $((hits1 - hits0)), expected at least 40"
    if toy 2-badpw "$b1" "$((probe + 10))" "$state/secrets/sccache-badpw.env"; then
        fail "control: a wrong Redis password did not fail the build in strict mode"
    fi
    grep -q "RPB_SCCACHE_REQUIRE_REMOTE=1; failing" "$state/logs/2-badpw.log" \
        || fail "control: the build failed, but not because Redis was refused (see $state/logs/2-badpw.log)"
    pass "2 sccache: builder1 wrote 40 objects (Valkey +$((keys1 - keys0)) keys), builder2 read all 40 from Redis (Valkey hits +$((hits1 - hits0))); a wrong password fails"

    # 3. zot layer cache
    tags=$(curl -fsS "$zot_url/v2/rpb/cache/tags/list") || fail "zot API not reachable"
    echo "$tags" | grep -q '"toy-gfx942"' || fail "zot has no toy-gfx942 cache tag: $tags"
    docker buildx prune --builder "$b2" -af >/dev/null
    toy 3-nozot "$b2" "$probe" "$strict" --var CACHE_REGISTRY= || fail "toy build on builder2 without zot"
    nozot=$(last_cached "$b2")
    [ "$nozot" -eq 0 ] || fail "control: an empty builder without zot reused $nozot steps; the zot result below would prove nothing"
    docker buildx prune --builder "$b2" -af >/dev/null
    toy 3-zot "$b2" "$probe" "$strict" || fail "toy build on builder2 with zot"
    cached=$(last_cached "$b2")
    [ "$cached" -gt 0 ] || fail "builder2 imported no cached steps from zot"
    pass "3 zot: empty builder2 reused $cached steps from zot (0 without zot); zot lists the cache tag"

    # 4. Redis down
    "${compose[@]}" stop valkey >/dev/null
    toy 4-down "$b1" "$((probe + 1))" "$lenient" || { "${compose[@]}" start valkey >/dev/null; fail "build failed while Redis was down"; }
    down_remote=$(remote)
    if toy 4-down-strict "$b1" "$((probe + 2))" "$strict"; then
        "${compose[@]}" start valkey >/dev/null
        fail "control: strict mode did not fail with Redis down"
    fi
    "${compose[@]}" start valkey >/dev/null
    wait_valkey
    [ "$down_remote" = "fallback" ] || fail "Redis was down but the build recorded remote=$down_remote"
    pass "4 fallback: with Redis down the build succeeded and recorded remote=fallback; strict mode failed"

    # 5. telemetry end to end (every scripts/rpb run from here on also feeds Prometheus)
    export RPB_TEXTFILE_DIR="$state/textfile"
    RPB_HOST_CLASS=laptop scripts/rpb build --builder "$b1" --scenario dev --targets toy -- \
        -f docker-bake.hcl -f dev/minicluster/docker-bake.hcl --var CACHE_REGISTRY=zot:5000 \
        --var "SCCACHE_ENV_FILE=$strict" --var "CACHE_PROBE=$((probe + 3))" >"$state/logs/5-rpb.log" 2>&1 \
        || fail "scripts/rpb build (log: $state/logs/5-rpb.log)"
    rec=$(printf "%s\n" results/*-"$b1"/record.json | sort | tail -1)   # run ids start with a UTC timestamp
    ref=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"]["toy"]["buildkit"]["ref"])' "$rec")
    docker buildx history inspect --builder "$b1" "$ref" --format json > "$state/logs/5-inspect.json" \
        || fail "the record's ref $ref is not in builder1's history"
    python3 - "$rec" "$state/logs/5-inspect.json" "$RPB_TEXTFILE_DIR" <<'EOF' || fail "record.json incomplete or inconsistent"
import json, os, sys
r = json.load(open(sys.argv[1]))
h = json.load(open(sys.argv[2]))
t = r["targets"]["toy"]["buildkit"]
assert t["status"] == "completed" and t["steps_total"] > 0, t
assert t["name"] == f"rpb/toy/gfx942/{r['run_id']}", t["name"]
# the record agrees with BuildKit's own history record, read independently
assert (t["steps_total"], t["steps_cached"]) == (h["NumTotalSteps"], h["NumCachedSteps"]), (t, h)
assert r["targets"]["toy"]["stages"], "no per-step timings from history logs"
u = r["compile_units"]["toy"]
assert u["remote"] == "redis", u["remote"]
assert u["sccache"]["compile_requests"] == 40, u["sccache"]["compile_requests"]
assert [l["name"] for l in u["sccache"]["levels"]] == ["L0 (disk)", "L1 (redis)"], u["sccache"]["levels"]
prom = os.path.join(sys.argv[3], "rpb_dev_rpb-localhost-12341_toy.prom")
assert os.path.exists(prom), prom
print("record ok:", sys.argv[1])
EOF
    pass "5 telemetry: $rec matches builder1's history; remote=redis; Prometheus textfile written"
    mkdir -p telemetry/tests/fixtures/real
    cp "$(dirname "$rec")/inspect/toy.json" telemetry/tests/fixtures/real/inspect-toy.json
    head -c 200000 "$(dirname "$rec")/steps/toy.jsonl" > telemetry/tests/fixtures/real/steps-toy.jsonl
    cp "$(dirname "$rec")/telemetry/toy-sccache.json" telemetry/tests/fixtures/real/toy-sccache.json
    cp "$(dirname "$rec")/history-ls.json" telemetry/tests/fixtures/real/history-ls.json

    # 6. multi-machine routing and torch-dev hand-off through zot
    rm -f .rpb-routes
    before=$(date -u +%Y%m%dT%H%M%SZ)
    scripts/rpb-cluster --builders "$b1 $b2" --registry zot:5000 -- \
        -f docker-bake.hcl -f dev/minicluster/cluster-override.hcl >"$state/logs/6-cluster.log" 2>&1 \
        || fail "scripts/rpb-cluster (log: $state/logs/6-cluster.log)"
    [ "$(awk '{print $2}' .rpb-routes | sort -u | wc -l)" -eq 2 ] || fail "downstream targets were not routed to both builders"
    image=$(sed -n 's/^torch-dev: //p' "$state/logs/6-cluster.log")
    digest=${image##*@}
    served=$(curl -fsS -o /dev/null -D - \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "$zot_url/v2/rpb/torch-dev/manifests/$digest" | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')
    [ "$served" = "$digest" ] || fail "zot does not serve torch-dev at $digest (got '$served')"
    # Every downstream target must have its own record, from the builder it was routed to.
    python3 - "$before" <<'EOF' || fail "downstream records do not match the routes"
import glob, json, os, sys
routes = dict(line.split() for line in open(".rpb-routes"))
seen = {}
for path in glob.glob("results/*/record.json"):
    if os.path.basename(os.path.dirname(path)) < sys.argv[1]:
        continue
    r = json.load(open(path))
    for t, v in r["targets"].items():
        if t in routes:
            assert v["buildkit"]["status"] == "completed", (t, v["buildkit"])
            seen[t] = r["builder"]
assert seen == routes, (seen, routes)
EOF
    pass "6 cluster: zot serves torch-dev@${digest:0:19}...; downstream records match the routes on both builders; test passed"

    # 7. Prometheus
    python3 - "$prom_url" "$rec" "$RPB_TEXTFILE_DIR" <<'EOF' || fail "Prometheus check (see the message above)"
import glob, json, os, sys, time, urllib.parse, urllib.request
prom, rec_path, textfile = sys.argv[1:]

def get(path):
    return json.load(urllib.request.urlopen(prom + path, timeout=5))["data"]

def q(expr):
    return get("/api/v1/query?" + urllib.parse.urlencode({"query": expr}))["result"]

def value(expr):
    r = q(expr)
    return float(r[0]["value"][1]) if r else None

def wait(expr, want, what):
    deadline = time.time() + 60
    while time.time() < deadline:
        if value(expr) == want:
            return
        time.sleep(2)
    raise SystemExit(f"{what}: {expr} is {value(expr)}, expected {want}")

health = {t["labels"]["job"]: t["health"] for t in get("/api/v1/targets")["activeTargets"]}
assert health == {"rpb": "up", "zot": "up"}, health
wait("count(rpb_run_success)", 5, "runs of checks 5 and 6")
assert value("node_textfile_scrape_error") == 0, "node-exporter could not parse a textfile"
assert value("min(rpb_run_success)") == 1, q("rpb_run_success")
assert value("count(count by (builder) (rpb_target_duration_seconds))") == 2, "targets from both builders"
assert value('rpb_sccache_remote{unit="toy",state="redis"}') == 1, q("rpb_sccache_remote")
assert not q('rpb_sccache_remote{state!="redis"}'), q("rpb_sccache_remote")
# the same number, two independent paths: record.json vs file -> node-exporter -> Prometheus
rec = json.load(open(rec_path))
want = rec["targets"]["toy"]["buildkit"]["duration_s"]
got = value('rpb_target_duration_seconds{target="toy"}')
assert abs(got - want) < 1e-6, (got, want)

# control: without the textfiles the series must disappear, then come back.
# The files move, not the directory: the bind mount follows the directory itself.
off = textfile + ".off"
os.makedirs(off, exist_ok=True)
files = [os.path.basename(f) for f in glob.glob(os.path.join(textfile, "*.prom"))]
for f in files:
    os.rename(os.path.join(textfile, f), os.path.join(off, f))
try:
    deadline = time.time() + 60
    while time.time() < deadline and q("rpb_run_success"):
        time.sleep(2)
    assert not q("rpb_run_success"), "control: rpb series still present without the textfiles"
finally:
    for f in files:
        os.rename(os.path.join(off, f), os.path.join(textfile, f))
    os.rmdir(off)
wait("count(rpb_run_success)", 5, "series after restoring the textfiles")
print(f"  toy took {got:.2f} s in Prometheus and in record.json")
EOF
    pass "7 prometheus: targets up, no textfile errors, 5 runs from 2 builders, values match record.json; series vanish without the files"
}

case "${1:-}" in
    up) up ;;
    test) test_all ;;
    down) down ;;
    *) sed -n '2,6p' "$0" >&2; exit 2 ;;
esac
