# Benchmarking

## Scenarios

| Code | Meaning | Reset before each run |
|---|---|---|
| C0 | Full cold | BK, SC, RG, OS |
| C1a | New builder, warm shared compile cache only | BK, RG, OS |
| C1b | New builder, warm zot layer cache only | BK, SC, OS |
| W0 | No-op rebuild | none |
| W1a | vLLM Python-only patch | none |
| W1b | vLLM one-file C++/HIP patch | none |
| W2 | LMCache one-file patch | none |
| W3 | torch one-file patch | none |

Reset levels (`bench/reset.sh`, each prints proof that it took effect):
BK = BuildKit state, SC = the shared sccache level in Valkey, RG = zot,
OS = page cache. Run C0 first: C1a and C1b depend on the caches C0 leaves behind.

Each W patch (`bench/make-patches.sh`) adds a new function to one file, not a
comment, because sccache hashes the preprocessed source. `bench/run-matrix.sh`
gives the function a new name on every run, so each patched run is a real
compile miss and never a hit from an earlier repetition. After each patched run
the patch is removed and a `<scenario>-revert` run must be fully cached.

## Method

- AIC and rpb run on the same host, gfx target and builder, alternating in ABBA
  order (`bench/run-matrix.sh`). AIC keeps its own fail-fast bake; its runs are
  recorded in the same layout, including failed ones.
- An A/A run, rpb against rpb, measures the noise floor before any comparison:
  `RPB_AA=1 bench/run-matrix.sh ...` replaces AIC with a second rpb configuration
  (`rpb-aa`).
- Every raw point is published with the median and the min–max range.
- No claim smaller than 5%; significance claims need 4–5 repetitions per side.
- On EC2, `bench/run-matrix.sh` touches the dead-man heartbeat every minute while
  it runs; if the harness dies, the host powers itself off 30 minutes later.
