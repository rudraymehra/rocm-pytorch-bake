# Contributing

## Ground rules

- All work lands on `dev`. `main` holds only code that has passed a full
  build on real builders and maintainer review, and changes only through a
  pull request from `dev`.
- Every commit carries a `Signed-off-by` line (`git commit -s`), certifying the
  [Developer Certificate of Origin](https://developercertificate.org/).
- Design changes start as an issue or a change to `docs/DESIGN.md`, and every
  accepted decision gets a short record in `docs/adr/`.
- Source pins change in `docker-bake.hcl`, and `scripts/check-pins` must pass.
  Pins of tools and images live elsewhere; [docs/PINS.md](docs/PINS.md) lists them all.

## Before you push

```sh
make check            # bake validation, BuildKit checks, hadolint, shellcheck, Python
                      # syntax, buildkitd.toml and Prometheus config checks, telemetry
                      # tests, pin check
make minicluster-test # the 7 end-to-end checks (about 5 minutes, needs Docker)
```

CI runs the same, and also actionlint, markdownlint, a link check and a spelling
check ([docs/CI.md](docs/CI.md)). Full builds run only on the maintainers'
self-hosted builders and are started by a maintainer.
