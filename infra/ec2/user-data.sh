#!/usr/bin/env bash
# EC2 user data for a rocm-pytorch-bake benchmark host (Ubuntu 22.04, x86_64).
# Installs Docker and buildx v0.38.1, mounts the data volume at /nvme, and arms
# two dead-man switches so a forgotten instance cannot run up a bill:
#   1. a hard power-off after MAX_HOURS (shutdown behaviour is "terminate")
#   2. a power-off when /run/rpb/heartbeat is older than 30 minutes; scripts/rpb and
#      bench/run-matrix.sh touch it every minute while they run and remove it when they
#      finish, so this fires only when a build or the harness dies. There is no file
#      at boot, so setting up the host is not timed.
# infra/ec2/launch.sh replaces the MAX_HOURS line with its own value.
set -euo pipefail
MAX_HOURS=5

shutdown -h "+$((MAX_HOURS * 60))" "rpb: hard session limit"

# /run/rpb is writable by every user, so scripts/rpb can keep the heartbeat as any user.
mkdir -p /run/rpb && chmod 1777 /run/rpb
cat > /usr/local/bin/rpb-heartbeat-check <<'SH'
#!/bin/sh
f=/run/rpb/heartbeat
[ -f "$f" ] || exit 0
age=$(( $(date +%s) - $(stat -c %Y "$f") ))
[ "$age" -gt 1800 ] && /sbin/shutdown -h now "rpb: heartbeat older than 30 min"
exit 0
SH
chmod 0755 /usr/local/bin/rpb-heartbeat-check
cat > /etc/systemd/system/rpb-heartbeat.service <<'UNIT'
[Unit]
Description=Power off when the rpb benchmark harness stops reporting
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpb-heartbeat-check
UNIT
cat > /etc/systemd/system/rpb-heartbeat.timer <<'UNIT'
[Unit]
Description=Check the rpb heartbeat every 5 minutes
[Timer]
OnBootSec=35min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now rpb-heartbeat.timer

# Data volume: the largest disk that does not hold the root filesystem.
root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
dev=$(lsblk -dnbo NAME,SIZE,TYPE | awk -v r="$root_disk" '$3=="disk" && $1!=r {print $2, $1}' | sort -n | tail -1 | cut -d' ' -f2)
[ -n "$dev" ] || { echo "no data disk found" >&2; exit 1; }
mkfs.xfs -f "/dev/$dev"
mkdir -p /nvme
mount -o noatime "/dev/$dev" /nvme

apt-get update
apt-get install -y --no-install-recommends docker.io docker-compose-v2 git python3 python3-pip jq curl
install -d /usr/local/lib/docker/cli-plugins
curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
    https://github.com/docker/buildx/releases/download/v0.38.1/buildx-v0.38.1.linux-amd64
echo "e25d5cd675092bb5d1d03632fdc46cdf3fede7b514dc5f023a105e00d3ce5ad4  /usr/local/lib/docker/cli-plugins/docker-buildx" | sha256sum -c -
chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx
systemctl enable --now docker
usermod -aG docker ubuntu
docker buildx version
touch /run/rpb/ready
