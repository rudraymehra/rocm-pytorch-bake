# Local entry points. CI runs the same commands (.github/workflows/pr.yml).
.PHONY: check test lint-docker lint-shell check-config check-prometheus minicluster-test

check: lint-docker lint-shell check-config check-prometheus test
	docker buildx bake --print all > /dev/null
	python3 scripts/check-pins

lint-docker:
	docker buildx bake lint
	hadolint --config .hadolint.yaml docker/*.Dockerfile dev/minicluster/toy.Dockerfile

lint-shell:
	shellcheck scripts/rpb scripts/rpb-cluster scripts/rpb-sccache-run scripts/rpb-check-offload-arch infra/*/*.sh bench/*.sh dev/minicluster/run.sh

check-config:
	cd tools/check-buildkitd-config && go run . ../../infra/buildkit/buildkitd.toml

check-prometheus:
	sed -e 's/RPB_CLIENT_TARGETS/"client:9100"/' -e 's/ZOT_ADDR/zot:5000/' infra/monitoring/prometheus.yml \
		| docker run --rm -i --entrypoint promtool prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e check config /dev/stdin

test:
	python3 -m pytest -q telemetry/tests

minicluster-test:
	dev/minicluster/run.sh up
	dev/minicluster/run.sh test
	dev/minicluster/run.sh down
