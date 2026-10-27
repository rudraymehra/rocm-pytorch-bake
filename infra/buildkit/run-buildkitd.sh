#!/usr/bin/env bash
# Start (or restart) the BuildKit daemon on THIS build machine.
#
#   sudo ZOT_ADDR=zot.lan:5000 STATE_DIR=/nvme/buildkit CERT_DIR=secrets/certs/daemon/$(hostname -f) \
#        infra/buildkit/run-buildkitd.sh
#
# The daemon runs as the pinned moby/buildkit image, rootful, on the host network
# (so build steps can reach zot and Redis on the LAN), with its state on local NVMe.
set -euo pipefail

: "${ZOT_ADDR:?set ZOT_ADDR to the zot host:port, e.g. zot.lan:5000}"
: "${STATE_DIR:?set STATE_DIR to a directory on local NVMe (not NFS)}"
: "${CERT_DIR:?set CERT_DIR to the daemon certificate directory of this host}"

IMAGE=moby/buildkit:v0.34.1@sha256:99368f3e46177c6405b9740e4461d91cee004128daeecca78d4ceac50ec1da5c
here=$(cd "$(dirname "$0")" && pwd)
conf_dir=/etc/buildkit

for f in cert.pem key.pem ca.pem; do
    [ -f "$CERT_DIR/$f" ] || { echo "missing $CERT_DIR/$f" >&2; exit 1; }
done
fstype=$(df --output=fstype "$STATE_DIR" | tail -1)
case "$fstype" in
    nfs*|cifs|smb*|fuse*) echo "STATE_DIR is on $fstype; BuildKit state must be on a local filesystem" >&2; exit 1 ;;
esac

install -d -m 0755 "$conf_dir" "$conf_dir/certs"
install -m 0644 "$CERT_DIR/cert.pem" "$conf_dir/certs/cert.pem"
install -m 0600 "$CERT_DIR/key.pem" "$conf_dir/certs/key.pem"
install -m 0644 "$CERT_DIR/ca.pem" "$conf_dir/certs/ca.pem"
sed "s/ZOT_ADDR/${ZOT_ADDR}/" "$here/buildkitd.toml" > "$conf_dir/buildkitd.toml"

docker rm -f buildkitd >/dev/null 2>&1 || true
docker run -d --name buildkitd --restart=always \
    --privileged --network host \
    -v "$STATE_DIR:/var/lib/buildkit" \
    -v "$conf_dir:/etc/buildkit:ro" \
    -e BUILDKIT_STEP_LOG_MAX_SIZE=-1 \
    -e BUILDKIT_STEP_LOG_MAX_SPEED=-1 \
    "$IMAGE" --config /etc/buildkit/buildkitd.toml

for _ in $(seq 1 30); do
    # Read the log into a variable: grep -q on a pipe can SIGPIPE docker logs, and
    # pipefail would turn that into a false "not started".
    logs=$(docker logs buildkitd 2>&1)
    if grep -q "running server on" <<< "$logs"; then
        docker exec buildkitd buildctl --version
        echo "buildkitd is up on tcp://$(hostname -f):1234"
        exit 0
    fi
    sleep 1
done
docker logs buildkitd >&2
echo "buildkitd did not start within 30 s" >&2
exit 1
