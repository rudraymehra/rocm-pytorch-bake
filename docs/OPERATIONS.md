# Operations

How to stand up and run the build cluster. Everything here is scripted; this
page says which script to run, where, and how to check it worked. These scripts
have not yet run on a real cluster; the mini-cluster (`docs/TESTING.md`) uses the
same config files through Compose, not these scripts.

## Layout

| Role | Runs | Script |
|---|---|---|
| Cache node (one) | zot on port 5000, Valkey on port 6379 | `infra/cache-node/install.sh` |
| Builder (one per machine) | `buildkitd` on port 1234, mTLS | `infra/buildkit/run-buildkitd.sh` |
| Client (any host that runs bake) | `docker buildx bake`, `scripts/rpb`, node-exporter on port 9100 | `infra/buildkit/create-builders.sh` |
| Monitoring (the cache node) | Prometheus on port 9090 | `infra/monitoring/install.sh` |

Use one address form for zot everywhere: `ZOT_ADDR` on the builders and
`CACHE_REGISTRY` on the clients must be the same `host:port` string (both IP or
both name), because `buildkitd.toml` marks exactly that registry as plain HTTP.

## Security

zot, Valkey's admin user, node-exporter and Prometheus have no authentication of
their own on this LAN setup: the firewall is the access control. On each host,
allow only the listed sources (example with ufw, builders 10.0.0.11-12, clients
10.0.0.20-21, cache and monitoring node 10.0.0.5):

```sh
# cache node
sudo ufw allow from 10.0.0.11 to any port 5000,6379 proto tcp
sudo ufw allow from 10.0.0.12 to any port 5000,6379 proto tcp
# each builder
sudo ufw allow from 10.0.0.20 to any port 1234 proto tcp
# each client
sudo ufw allow from 10.0.0.5 to any port 9100 proto tcp
```

BuildKit itself requires a client certificate signed by the cluster CA (mTLS).

## 1. Secrets and certificates (once, on an admin host)

```sh
infra/certs/make-certs.sh secrets/certs build1.lan,10.0.0.11 build2.lan,10.0.0.12
infra/cache-node/make-secrets.sh 10.0.0.5 secrets
```

`secrets/` is gitignored. Copy `secrets/certs/daemon/<host>/` to each builder,
`secrets/users.acl` and `secrets/valkey-admin.env` to the cache node, and
`secrets/certs/client/` plus `secrets/sccache.env` to each client. A builder given
only as an IP address (`10.0.0.11`) gets an IP subject name.

## 2. Cache node

```sh
sudo CACHE_NODE_IP=10.0.0.5 CACHE_DATA=/nvme/cache SECRETS=secrets infra/cache-node/install.sh
```

Expected, last four lines:

```text
zot: http://10.0.0.5:5000 ok
PONG
maxmemory-policy
allkeys-lru
```

## 3. Each builder

```sh
sudo ZOT_ADDR=10.0.0.5:5000 STATE_DIR=/nvme/buildkit \
     CERT_DIR=secrets/certs/daemon/build1.lan infra/buildkit/run-buildkitd.sh
```

Expected: `buildctl github.com/moby/buildkit v0.34.1 …`, then
`buildkitd is up on tcp://<this host's FQDN>:1234`.

## 4. Each client

```sh
CERT_DIR=secrets/certs/client infra/buildkit/create-builders.sh build1.lan build2.lan
cp rpb.env.example rpb.env              # then edit the values
set -a; . ./rpb.env; set +a
```

Expected: one `rpb-<host>` builder per machine in `docker buildx ls`, each
`running` with BuildKit `v0.34.1`.

## 5. Telemetry in Prometheus

On each client, so every `scripts/rpb` run is exported. The textfile directory
must be writable by the user that runs `scripts/rpb`:

```sh
sudo install -d -m 0755 -o "$(id -un)" /var/lib/rpb/textfile
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

After the first cold build, read `used_memory_dataset` from `INFO memory`, then
re-run the cache node install with `maxmemory` at about three times that value,
keeping 20% of the host RAM free:

```sh
sudo CACHE_NODE_IP=10.0.0.5 CACHE_DATA=/nvme/cache SECRETS=secrets VALKEY_MAXMEMORY=48gb \
     infra/cache-node/install.sh
```

The containers are recreated with the new value. Valkey keeps no data on disk, so
the shared compile cache starts empty again.

## Teardown (EC2)

`infra/ec2/teardown-check.sh` must print `clean` at the end of every session. It
exits 2, never `clean`, when any AWS call fails.
