# Contributing

## Ground rules

- All work lands on `dev`. `main` holds only code that has passed a full
  build on real builders and maintainer review, and changes only through a
  pull request from `dev`.
- Every commit carries a `Signed-off-by` line (`git commit -s`), certifying the
  [Developer Certificate of Origin](https://developercertificate.org/).
- Design changes start as an issue or a change to `docs/DESIGN.md`, and every
  accepted decision gets a short record in `docs/adr/`.
- Pins change only in `docker-bake.hcl`, and `scripts/check-pins` must pass.

## Before you push

```sh
make check   # bake validation, BuildKit checks, hadolint, shellcheck, actionlint, tests
```

The same checks run in CI on every pull request. Full builds run only on the
maintainers' self-hosted builders and are started by a maintainer.
