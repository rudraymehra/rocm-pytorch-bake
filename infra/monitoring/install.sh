#!/usr/bin/env bash
# Bring up Prometheus on the monitoring host (normally the cache node).
#
#   sudo ZOT_ADDR=10.0.0.5:5000 RPB_CLIENTS="10.0.0.20 10.0.0.21" PROM_DATA=/nvme/prometheus \
#        infra/monitoring/install.sh
#
# RPB_CLIENTS are the hosts running scripts/rpb with node-exporter (profile "client").
set -euo pipefail

: "${ZOT_ADDR:?set ZOT_ADDR to the zot host:port}"
: "${RPB_CLIENTS:?set RPB_CLIENTS to the space-separated hosts that run scripts/rpb}"
: "${PROM_DATA:?set PROM_DATA to a data directory}"
here=$(cd "$(dirname "$0")" && pwd)
docker compose version >/dev/null 2>&1 || { echo "needs Docker Compose v2 (\"docker compose\"), see docs/OPERATIONS.md" >&2; exit 1; }

targets=""
for h in $RPB_CLIENTS; do targets="${targets:+$targets, }\"$h:9100\""; done

export PROM_CONF_DIR=/etc/rpb-prometheus PROM_DATA
install -d -m 0755 "$PROM_CONF_DIR"
# The Prometheus image runs as nobody (65534).
install -d -m 0755 -o 65534 -g 65534 "$PROM_DATA"
sed -e "s/RPB_CLIENT_TARGETS/$targets/" -e "s/ZOT_ADDR/$ZOT_ADDR/" "$here/prometheus.yml" > "$PROM_CONF_DIR/prometheus.yml"

# --force-recreate: a changed prometheus.yml is a bind mount that "up -d" does not pick up.
docker compose -f "$here/compose.yaml" --profile server up -d --force-recreate
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl -fsS http://127.0.0.1:9090/-/ready
