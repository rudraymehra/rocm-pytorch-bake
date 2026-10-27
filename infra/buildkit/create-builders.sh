#!/usr/bin/env bash
# Register one buildx builder per build machine on THIS client (the host that runs bake).
#
#   CERT_DIR=secrets/certs/client infra/buildkit/create-builders.sh build1.lan build2.lan
#   CERT_DIR=... infra/buildkit/create-builders.sh localhost:12341 localhost:12342   # dev mini-cluster
#
# Creates builders named rpb-<short host name> or rpb-<ip with dashes>, plus -<port>
# when a port is given.
# Each is a separate builder on purpose: buildx picks a node of a multi-node
# builder by platform only, so several amd64 nodes in one builder would all
# receive work on the first node (see docs/DESIGN.md 4.6).
set -euo pipefail

: "${CERT_DIR:?set CERT_DIR to the client certificate directory (ca.pem, cert.pem, key.pem)}"
if [ "$#" -lt 1 ]; then
    echo "usage: CERT_DIR=... $0 <host>[:<port>] [...]" >&2
    exit 2
fi
cert_dir=$(cd "$CERT_DIR" && pwd)   # the remote driver needs absolute paths

# buildx passes this file to every new builder; the remote driver rejects config files.
default_cfg="${BUILDX_CONFIG:-${DOCKER_CONFIG:-$HOME/.docker}/buildx}/buildkitd.default.toml"
if [ -f "$default_cfg" ]; then
    echo "$default_cfg exists and would break 'buildx create --driver remote'. Move it away first." >&2
    exit 1
fi

for spec in "$@"; do
    host=${spec%%:*}
    port=1234
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        name="rpb-${host//./-}"      # 10.0.0.11 -> rpb-10-0-0-11
    else
        name="rpb-${host%%.*}"       # build1.lan -> rpb-build1
    fi
    if [ "$spec" != "$host" ]; then
        port=${spec#*:}
        name="$name-$port"
    fi
    docker buildx rm "$name" >/dev/null 2>&1 || true
    docker buildx create --name "$name" --driver remote \
        --driver-opt "cacert=$cert_dir/ca.pem,cert=$cert_dir/cert.pem,key=$cert_dir/key.pem,servername=$host" \
        "tcp://$host:$port"
    docker buildx inspect --bootstrap "$name"
done
docker buildx ls
