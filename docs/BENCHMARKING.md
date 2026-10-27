# Benchmarking

## Scenarios

| Code | Meaning | Reset before each run |
|---|---|---|
| C0 | Full cold | BK, SC, RG, OS |
| C1a | New builder, warm shared compile cache | BK, RG, OS |
| C1b | New builder, warm zot layer cache | BK, OS |
| W0 | No-op rebuild | none |
| W1a | vLLM Python-only patch | none |
| W1b | vLLM one-file C++/HIP patch | none |
| W2 | LMCache one-file patch | none |
| W3 | torch one-file patch | none |

Reset levels are in `bench/reset.sh`; each prints proof that it took effect.
Run C0 first: C1a and C1b depend on the caches C0 leaves behind.

## Method

- AIC and rpb run on the same host, gfx target and builder, alternating in ABBA
  order (`bench/run-matrix.sh`).
- An A/A run (rpb against rpb) measures the noise floor before any comparison.
- Every raw point is published with the median and the min–max range.
- No claim smaller than 5%; significance claims need 4–5 repetitions per side.
