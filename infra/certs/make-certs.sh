#!/usr/bin/env bash
# Create the mTLS material for remote BuildKit builders: one CA, one server
# certificate per builder, one client certificate.
#
#   infra/certs/make-certs.sh <out-dir> <host>[,<ip>...] [<host>[,<ip>...] ...]
#   e.g. infra/certs/make-certs.sh secrets/certs build1.lan,10.0.0.11 build2.lan,10.0.0.12
#
# Re-running keeps the existing CA and client certificate and (re)issues the
# server certificates named on the command line. Keep <out-dir> out of git.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <out-dir> <host>[,<ip>...] [...]" >&2
    exit 2
fi
out=$1
shift
days=825
umask 077
mkdir -p "$out/ca" "$out/client" "$out/daemon"

if [ ! -f "$out/ca/key.pem" ]; then
    openssl req -x509 -newkey rsa:4096 -sha256 -days "$days" -nodes \
        -subj "/CN=rocm-pytorch-bake buildkit CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$out/ca/key.pem" -out "$out/ca/cert.pem"
fi

issue() { # issue <dir> <cn> <extfile-content>
    local dir=$1 cn=$2 ext=$3
    mkdir -p "$dir"
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$cn" \
        -keyout "$dir/key.pem" -out "$dir/csr.pem"
    openssl x509 -req -sha256 -days "$days" -in "$dir/csr.pem" \
        -CA "$out/ca/cert.pem" -CAkey "$out/ca/key.pem" -CAcreateserial \
        -extfile <(printf '%s\n' "$ext") -out "$dir/cert.pem"
    rm -f "$dir/csr.pem"
    cp "$out/ca/cert.pem" "$dir/ca.pem"
    openssl verify -CAfile "$dir/ca.pem" "$dir/cert.pem"
}

if [ ! -f "$out/client/cert.pem" ]; then
    issue "$out/client" "rpb-client" \
        "$(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth')"
fi

for spec in "$@"; do
    IFS=, read -r -a parts <<< "$spec"
    host=${parts[0]}
    san="DNS:$host"
    for ip in "${parts[@]:1}"; do
        san="$san,IP:$ip"
    done
    issue "$out/daemon/$host" "$host" \
        "$(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s' "$san")"
done

echo "certificates in $out: ca/, client/, daemon/<host>/"
