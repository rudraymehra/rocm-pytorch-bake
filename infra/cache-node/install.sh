#!/usr/bin/env bash
# Bring up zot and Valkey on the cache node.
#
#   sudo CACHE_NODE_IP=10.0.0.5 CACHE_DATA=/nvme/cache SECRETS=secrets [VALKEY_MAXMEMORY=32gb] \
#        infra/cache-node/install.sh
#
# SECRETS is the directory written by make-secrets.sh (users.acl is read from it).
# Re-running applies changed settings: the containers are recreated.
set -euo pipefail

: "${CACHE_NODE_IP:?set CACHE_NODE_IP to the LAN address of this node}"
: "${CACHE_DATA:?set CACHE_DATA to a directory on local NVMe}"
: "${SECRETS:?set SECRETS to the make-secrets.sh output directory}"
here=$(cd "$(dirname "$0")" && pwd)
docker compose version >/dev/null 2>&1 || { echo "needs Docker Compose v2 (\"docker compose\"), see docs/OPERATIONS.md" >&2; exit 1; }

maxmemory=${VALKEY_MAXMEMORY:-32gb}
[[ "$maxmemory" =~ ^[0-9]+(mb|gb)$ ]] || { echo "VALKEY_MAXMEMORY must look like 32gb or 512mb" >&2; exit 2; }
# Keep at least 20% of this host's RAM free of Valkey: with vm.overcommit_memory=1
# (below) the kernel kills processes instead of refusing memory. On a host that also
# compiles, choose much less (docs/OPERATIONS.md, "One small host").
mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
case "$maxmemory" in *gb) want_kib=$(( ${maxmemory%gb} * 1024 * 1024 )) ;; *mb) want_kib=$(( ${maxmemory%mb} * 1024 )) ;; esac
if [ "$want_kib" -gt $(( mem_kib * 4 / 5 )) ]; then
    echo "VALKEY_MAXMEMORY=$maxmemory is more than 80% of this host's $(( mem_kib / 1024 / 1024 )) GiB; set it lower" >&2
    exit 2
fi

export VALKEY_CONF_DIR=/etc/valkey
install -d -m 0755 "$VALKEY_CONF_DIR" "$CACHE_DATA/zot"
sed -e "s/CACHE_NODE_IP/${CACHE_NODE_IP}/" -e "s/^maxmemory 32gb$/maxmemory ${maxmemory}/" \
    "$here/valkey.conf" > "$VALKEY_CONF_DIR/valkey.conf"
grep -q "^maxmemory ${maxmemory}$" "$VALKEY_CONF_DIR/valkey.conf"
install -m 0644 "$SECRETS/users.acl" "$VALKEY_CONF_DIR/users.acl"

# Valkey's own guidance for hosts that run it with large maxmemory, applied now and
# on every boot (the containers restart on boot too).
echo "vm.overcommit_memory = 1" > /etc/sysctl.d/90-rpb-valkey.conf
sysctl -w vm.overcommit_memory=1
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo "w /sys/kernel/mm/transparent_hugepage/enabled - - - - never" > /etc/tmpfiles.d/90-rpb-valkey-thp.conf
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

export CACHE_DATA
# --force-recreate: changed config files and ACLs are bind mounts, which a plain
# "up -d" does not pick up.
docker compose -f "$here/compose.yaml" up -d --force-recreate

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
# The password goes through the environment, not the command line (visible in ps).
export VALKEYCLI_AUTH=$VALKEY_PASSWORD
for _ in $(seq 1 30); do
    if [ "$(docker exec -e VALKEYCLI_AUTH rpb-cache-valkey-1 valkey-cli -h "$CACHE_NODE_IP" --user "$VALKEY_USER" ping 2>/dev/null)" = PONG ]; then
        break
    fi
    sleep 1
done
docker exec -e VALKEYCLI_AUTH rpb-cache-valkey-1 valkey-cli -h "$CACHE_NODE_IP" --user "$VALKEY_USER" ping
docker exec -e VALKEYCLI_AUTH rpb-cache-valkey-1 valkey-cli -h "$CACHE_NODE_IP" --user "$VALKEY_USER" config get maxmemory-policy
