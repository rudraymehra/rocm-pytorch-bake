# Local entry points. `make check` runs the build-definition and code checks of the static CI job;
# CI also runs actionlint, markdownlint, lychee and typos (docs/CI.md).
.PHONY: check test lint-docker lint-shell check-config check-prometheus minicluster-test

check: lint-docker lint-shell check-config check-prometheus test
	docker buildx bake --print all > /dev/null
	python3 scripts/check-pins

lint-docker:
	docker buildx bake lint
	hadolint --config .hadolint.yaml docker/*.Dockerfile dev/minicluster/toy.Dockerfile

lint-shell:
	shellcheck scripts/rpb scripts/rpb-cluster scripts/rpb-sccache-run scripts/rpb-check-offload-arch scripts/rpb-set-rocm-rpath infra/*/*.sh bench/*.sh dev/minicluster/run.sh
	python3 -m py_compile scripts/check-pins scripts/rpb-write-constraints scripts/rpb-build-amdsmi scripts/bake-graph

check-config:
	cd tools/check-buildkitd-config && go run . ../../infra/buildkit/buildkitd.toml

check-prometheus:
	sed -e 's/RPB_CLIENT_TARGETS/"client:9100"/' -e 's/ZOT_ADDR/zot:5000/' infra/monitoring/prometheus.yml \
		| docker run --rm -i --entrypoint promtool prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e check config /dev/stdin

test:
	python3 -m pytest -q telemetry/tests

# The cluster is always removed, also when a check fails; the failing check names
# its log in dev/minicluster/.logs/, which stays until the next `up`.
minicluster-test:
	dev/minicluster/run.sh up && dev/minicluster/run.sh test; status=$$?; dev/minicluster/run.sh down; exit $$status
