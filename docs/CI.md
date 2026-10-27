# CI

| Tier | Trigger | Where | What |
|---|---|---|---|
| T0 static | every PR and push to `main` or `dev` | GitHub-hosted | bake parse and validation, BuildKit checks, hadolint, shellcheck, actionlint, markdownlint, links, typos, telemetry tests, pin check, buildkitd.toml check |
| T1 smoke | every PR and push to `main` or `dev` | GitHub-hosted | a linked bake pair exports its cache to a real zot, then an empty builder must reuse it |
| T2 full build | manual or nightly | self-hosted builder | `scripts/rpb build`, results uploaded as an artifact |
| T3 benchmark | manual | EC2 | `bench/run-matrix.sh`, teardown check |

T2 runs only when the repository variable `RPB_SELF_HOSTED` is `true`, never on
pull requests, and behind the `self-hosted` environment (required reviewer).
Public repositories must not run untrusted code on self-hosted runners.

Repository variables for T2: `RPB_BUILDER`, `RPB_HOST_CLASS`, `RPB_CACHE_REGISTRY`,
`RPB_SCCACHE_ENV_FILE`, `RPB_TEXTFILE_DIR`.
