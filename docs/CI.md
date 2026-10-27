# CI

| Tier | Trigger | Where | What |
|---|---|---|---|
| T0 static | every PR and push to `main` or `dev` | GitHub-hosted | bake parse and validation, BuildKit checks, hadolint, shellcheck, Python syntax, actionlint, markdownlint, links, typos, telemetry tests on Python 3.10 and 3.12, pin check, buildkitd.toml check, Prometheus config check |
| T1 smoke | every PR and push to `main` or `dev` | GitHub-hosted | a linked bake pair exports its cache to a real zot; after `buildx prune -af` the same builder must reuse it from zot |
| T1 mini-cluster | every PR and push to `main` or `dev` | GitHub-hosted | `make minicluster-test`: two mTLS builders, zot, Valkey, node-exporter and Prometheus; the 7 checks of `dev/minicluster/run.sh` |
| T2 full build | manual or nightly | self-hosted builder | `scripts/rpb build`, results uploaded as an artifact |
| T3 benchmark | manual | EC2 | `bench/run-matrix.sh`, teardown check |

## T2 and the self-hosted runner

GitHub runs `schedule` and offers `workflow_dispatch` only for workflows on the
default branch, so T2 can only run once `full-build.yml` is on that branch.

T2 runs only when the repository variable `RPB_SELF_HOSTED` is `true`, never on
pull requests, and behind the `self-hosted` environment (required reviewer). That
is not enough on its own: in a public repository a fork can open a pull request
that adds its own workflow targeting the runner's labels. Before a runner is
registered:

- Settings, Actions, General: "Require approval for all external contributors",
  so no fork workflow runs before a maintainer has read it.
- Register the runner only for the time of a maintainer-started run (an ephemeral
  runner), or keep it offline otherwise.
- The runner host holds only what a build needs: the builder client certificate
  and the sccache secret.

Repository variables for T2: `RPB_BUILDER`, `RPB_HOST_CLASS`, `RPB_CACHE_REGISTRY`,
`RPB_SCCACHE_ENV_FILE`, `RPB_TEXTFILE_DIR`, and optionally `RPB_MAX_JOBS` and
`RPB_FANOUT_JOBS` (checkout removes untracked files, so site values cannot live
in a file on the runner).
