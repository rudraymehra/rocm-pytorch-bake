# Operations

How to stand up and run the build cluster. Everything here is scripted; this
page says which script to run, where, and how to check it worked.

## Layout

| Role | Runs | Script |
|---|---|---|
| Cache node (one) | zot on port 5000, Valkey on port 6379 | `infra/cache-node/install.sh` |
| Builder (one per machine) | `buildkitd` on port 1234, mTLS | `infra/buildkit/run-buildkitd.sh` |
| Client (any host) | `docker buildx bake`, `scripts/rpb`, node-exporter on port 9100 | `infra/buildkit/create-builders.sh` |
| Monitoring (the cache node) | Prometheus on port 9090 | `infra/monitoring/install.sh` |

Firewall: 5000/tcp and 6379/tcp open from the builders only; 1234/tcp open from
the clients only; 9100/tcp from the Prometheus host only.

## 1. Secrets and certificates (once, on an admin host)

```sh
infra/certs/make-certs.sh secrets/certs build1.lan,10.0.0.11 build2.lan,10.0.0.12
infra/cache-node/make-secrets.sh 10.0.0.5 secrets
```

`secrets/` is gitignored. Copy `secrets/certs/daemon/<host>/` to each builder,
`secrets/users.acl` and `secrets/valkey-admin.env` to the cache node, and
`secrets/certs/client/` plus `secrets/sccache.env` to each client.

## 2. Cache node

```sh
sudo CACHE_NODE_IP=10.0.0.5 CACHE_DATA=/nvme/cache SECRETS=secrets infra/cache-node/install.sh
```

Expected: `zot: http://10.0.0.5:5000 ok`, `PONG`, and `maxmemory-policy allkeys-lru`.

## 3. Each builder

```sh
sudo ZOT_ADDR=10.0.0.5:5000 STATE_DIR=/nvme/buildkit \
     CERT_DIR=secrets/certs/daemon/build1.lan infra/buildkit/run-buildkitd.sh
```

Expected: `buildkitd is up on tcp://build1.lan:1234`.

## 4. Each client

```sh
CERT_DIR=secrets/certs/client infra/buildkit/create-builders.sh build1.lan build2.lan
cp docker-bake.override.hcl.example docker-bake.override.hcl   # then edit the values
```

## 5. Telemetry in Prometheus

On each client, so every `scripts/rpb` run is exported:

```sh
sudo install -d -m 0755 /var/lib/rpb/textfile
docker compose -f infra/monitoring/compose.yaml --profile client up -d
export RPB_TEXTFILE_DIR=/var/lib/rpb/textfile
```

On the monitoring host:

```sh
sudo ZOT_ADDR=10.0.0.5:5000 RPB_CLIENTS="10.0.0.20 10.0.0.21" PROM_DATA=/nvme/prometheus \
     infra/monitoring/install.sh
```

Expected: `Prometheus Server is Ready.` Then `http://<monitoring-host>:9090/targets`
shows the `rpb` and `zot` jobs as up. Queries are in `docs/TELEMETRY.md`.

## Resizing Valkey

After the first cold build, read `used_memory_dataset` from `INFO memory` and set
`maxmemory` in `/etc/valkey/valkey.conf` to about three times that value, keeping
20% of the host RAM free.

## Teardown (EC2)

`infra/ec2/teardown-check.sh` must print `clean` at the end of every session.
