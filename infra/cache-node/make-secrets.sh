#!/usr/bin/env bash
# Generate the Valkey ACL file for the cache node and the sccache secret file for
# the clients (bake sends it to the build steps as a BuildKit secret). Passwords never enter git, a Dockerfile, a build arg or a layer.
#
#   infra/cache-node/make-secrets.sh <cache-node-ip> <out-dir>
#
# Writes <out-dir>/users.acl        -> /etc/valkey/users.acl on the cache node
#        <out-dir>/sccache.env      -> SCCACHE_ENV_FILE for docker buildx bake
#        <out-dir>/valkey-admin.env -> admin credentials for telemetry and resets
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <cache-node-ip> <out-dir>" >&2
    exit 2
fi
ip=$1
out=$2
umask 077
mkdir -p "$out"

pw() { openssl rand -hex 32; }
sha() { printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1; }

sccache_pw=$(pw)
admin_pw=$(pw)

cat > "$out/users.acl" <<ACL
user default off
user sccache on #$(sha "$sccache_pw") ~rpb/* resetchannels -@all +get +set +setex +exists +strlen +getrange +del +ping +select
user admin on #$(sha "$admin_pw") ~* &* +@all
ACL

cat > "$out/sccache.env" <<ENV
SCCACHE_MULTILEVEL_CHAIN=disk,redis
SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY=all
SCCACHE_REDIS_ENDPOINT=redis://$ip:6379
SCCACHE_REDIS_USERNAME=sccache
SCCACHE_REDIS_PASSWORD=$sccache_pw
SCCACHE_REDIS_KEY_PREFIX=rpb/v1
ENV

cat > "$out/valkey-admin.env" <<ENV
VALKEY_HOST=$ip
VALKEY_USER=admin
VALKEY_PASSWORD=$admin_pw
ENV

echo "wrote $out/users.acl, $out/sccache.env, $out/valkey-admin.env"
