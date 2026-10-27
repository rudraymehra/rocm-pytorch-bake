# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# Mini-cluster probe: compiles generated C++ files under rpb-sccache-run, so the
# same wiring as the real builds (secret, Unix socket, disk+redis chain, telemetry).

# toy 40 C++ files compiled through sccache, with the stats exported for checks
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS toy
ARG SCCACHE_VERSION=0.19.0
ARG SCCACHE_SHA256_AARCH64=3e47fc4a71b1ddd1b4294a0de9d34498922fdf41e3cd0bda5df3954e3d6deb9d
RUN apt-get update && apt-get install -y --no-install-recommends g++ time && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:${SCCACHE_SHA256_AARCH64} \
    https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-aarch64-unknown-linux-musl.tar.gz \
    /tmp/sccache.tar.gz
RUN tar -xzf /tmp/sccache.tar.gz -C /tmp \
    && install -m 0755 /tmp/sccache-v${SCCACHE_VERSION}-aarch64-unknown-linux-musl/sccache /usr/local/bin/sccache
COPY --chmod=0755 scripts/rpb-sccache-run /usr/local/bin/rpb-sccache-run
ENV SCCACHE_DIR=/root/.cache/sccache SCCACHE_DIRECT=false SCCACHE_IDLE_TIMEOUT=0
WORKDIR /w/toy
# Every source embeds the probe: a new value gives 40 new cache keys, and the same
# value on another builder gives 40 identical keys.
# CACHE_PROBE value compiled into every generated source
ARG CACHE_PROBE=1
RUN for i in $(seq 1 40); do printf '#include <map>\n#include <string>\nint f%d(){std::map<std::string,int> m; m["k"]=%d; return m["k"] + %s;}\n' "$i" "$i" "${CACHE_PROBE}" > "f$i.cpp"; done
# The single quotes are intended: the loop runs inside rpb-sccache-run.
# hadolint ignore=SC2016
RUN --mount=type=cache,id=toy-sccache,target=/root/.cache/sccache \
    --mount=type=secret,id=sccache_env,required=false \
    rpb-sccache-run toy -- sh -c 'for f in *.cpp; do sccache g++ -O1 -c "$f" -o "${f%.cpp}.o" || exit 1; done'

FROM scratch AS export
COPY --from=toy /out/ /
