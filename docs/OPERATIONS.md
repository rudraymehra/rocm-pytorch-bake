# Operations

How to stand up and run the build cluster. Everything here is scripted; this
page says which script to run, where, and how to check it worked. The mini-cluster
(`dev/minicluster/run.sh`) runs `make-certs.sh`, `make-secrets.sh` and
`create-builders.sh` and the same config files, but starts the daemons through its
own Compose file. The install scripts have run in Ubuntu 24.04 test hosts, not yet
on a real cluster.

## Prerequisites

| Host | Needs |
|---|---|
| Every host | Linux x86_64, Docker Engine with Docker Compose v2 (`docker compose version`; on Ubuntu `docker.io` plus `docker-compose-v2`; Debian 12's own packages are too old, use Docker CE), `curl` |
| Admin host | `openssl` |
| Client | buildx v0.38.0 or later (`docker buildx version`; Ubuntu 24.04 ships 0.30, install the release binary as `infra/ec2/user-data.sh` does), `python3` 3.10 or later, `git` |

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

zot, node-exporter and Prometheus have no authentication of their own on this
LAN setup, and Valkey only has passwords: the firewall is the access control. On
each host, allow SSH first, then only the listed sources (example with ufw,
builders 10.0.0.11-12, clients 10.0.0.20-21, cache and monitoring node 10.0.0.5,
admin workstation 10.0.0.2):

```sh
sudo ufw allow OpenSSH
# cache node
sudo ufw allow from 10.0.0.11 to any port 5000,6379 proto tcp
sudo ufw allow from 10.0.0.12 to any port 5000,6379 proto tcp
sudo ufw allow from 10.0.0.2 to any port 9090 proto tcp
# each builder
sudo ufw allow from 10.0.0.20 to any port 1234 proto tcp
# each client
sudo ufw allow from 10.0.0.5 to any port 9100 proto tcp
# then, on every host
sudo ufw enable
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

`STATE_DIR` is created if missing. `CERT_DIR` is the directory named after the
host as it was given to `make-certs.sh`. Expected: `buildctl github.com/moby/buildkit v0.34.1 …`, then
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

## One small host (EC2)

When only one machine is available, every role runs on it: cache node, builder,
client and monitoring, with `10.0.0.5`, `build1.lan` and the client addresses
above all replaced by the host's private IP. This is also the benchmark layout
(`bench/reset.sh` expects zot, Valkey and buildkitd on the same host).

```sh
KEY_NAME=... SUBNET_ID=... SG_ID=... MARKET=on-demand MAX_HOURS=12 \
    infra/ec2/launch.sh m7a.2xlarge 400
```

- **Quota.** Spot and on-demand have separate vCPU quotas (Service Quotas, EC2:
  "All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests", L-34B43A08,
  and "Running On-Demand Standard ... instances", L-1216C47A). `MARKET` must name
  a market whose quota covers the instance. On an 8-vCPU quota, m7a.2xlarge
  (32 GiB) or r7a.2xlarge (64 GiB, room for `MAX_JOBS=8`) fit; AMD m7a and r7a
  give 8 real cores, where an 8-vCPU Intel instance has 4 cores with two threads
  each.
- **Security group.** Only SSH (22) from your address. Nothing else has to be
  reachable from outside on a single host.
- **Job counts and memory.** Leave room for Valkey: `VALKEY_MAXMEMORY=4gb` for
  the cache node install, and in `rpb.env` `MAX_JOBS=6` and `FANOUT_JOBS=2`
  (about 2.5 GiB per compiler job). Leave `AITER_PREBUILD` at 0 on the first build.
- **Time.** A cold build on 8 cores is an estimated 3 to 10 hours (not measured
  yet). The host powers itself off after `MAX_HOURS` (default 5) and terminates,
  which deletes its disks: copy `results/` and `out/` off the host before then.
- **Dead-man switch.** `scripts/rpb` and `bench/run-matrix.sh` keep
  `/run/rpb/heartbeat` fresh while they run and remove it at the end. If a build
  is killed and the file goes 30 minutes without an update, the host powers off.
  Setting up the host is not timed.
- **Login user.** `user-data.sh` adds `ubuntu` to the `docker` group (log in again
  after the first boot). Run `bench/run-matrix.sh` with `sudo -E`: the BK and OS
  reset levels need root.

## Teardown (EC2)

`infra/ec2/teardown-check.sh` must print `clean` at the end of every session. It
exits 2, never `clean`, when any AWS call fails. It searches every region, so the
AWS CLI needs a default region (`AWS_REGION` or `aws configure`) only for its first
call.
