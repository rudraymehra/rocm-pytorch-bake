#!/usr/bin/env bash
# Bring up zot and Valkey on the cache node.
#
#   sudo CACHE_NODE_IP=10.0.0.5 CACHE_DATA=/nvme/cache SECRETS=secrets infra/cache-node/install.sh
#
# SECRETS is the directory written by make-secrets.sh (users.acl is read from it).
set -euo pipefail

: "${CACHE_NODE_IP:?set CACHE_NODE_IP to the LAN address of this node}"
: "${CACHE_DATA:?set CACHE_DATA to a directory on local NVMe}"
: "${SECRETS:?set SECRETS to the make-secrets.sh output directory}"
here=$(cd "$(dirname "$0")" && pwd)

export VALKEY_CONF_DIR=/etc/valkey
install -d -m 0755 "$VALKEY_CONF_DIR" "$CACHE_DATA/zot"
sed "s/CACHE_NODE_IP/${CACHE_NODE_IP}/" "$here/valkey.conf" > "$VALKEY_CONF_DIR/valkey.conf"
install -m 0644 "$SECRETS/users.acl" "$VALKEY_CONF_DIR/users.acl"

# Valkey's own guidance for hosts that run it with large maxmemory.
sysctl -w vm.overcommit_memory=1
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

export CACHE_DATA
docker compose -f "$here/compose.yaml" up -d

for _ in $(seq 1 30); do
    if curl -fsS "http://${CACHE_NODE_IP}:5000/v2/" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl -fsS "http://${CACHE_NODE_IP}:5000/v2/" >/dev/null
echo "zot: http://${CACHE_NODE_IP}:5000 ok"

# shellcheck source=/dev/null
. "$SECRETS/valkey-admin.env"
docker exec rpb-cache-valkey-1 valkey-cli -h "$CACHE_NODE_IP" --user "$VALKEY_USER" --pass "$VALKEY_PASSWORD" --no-auth-warning ping
docker exec rpb-cache-valkey-1 valkey-cli -h "$CACHE_NODE_IP" --user "$VALKEY_USER" --pass "$VALKEY_PASSWORD" --no-auth-warning config get maxmemory-policy
