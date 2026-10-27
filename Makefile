# Local entry points. CI runs the same commands (.github/workflows/pr.yml).
.PHONY: check test lint-docker lint-shell check-config minicluster-test

check: lint-docker lint-shell check-config test
	docker buildx bake --print all > /dev/null
	python3 scripts/check-pins

lint-docker:
	docker buildx bake lint
	hadolint --config .hadolint.yaml docker/*.Dockerfile dev/minicluster/toy.Dockerfile

lint-shell:
	shellcheck scripts/rpb scripts/rpb-cluster scripts/rpb-sccache-run scripts/rpb-check-offload-arch infra/*/*.sh bench/*.sh dev/minicluster/run.sh

check-config:
	cd tools/check-buildkitd-config && go run . ../../infra/buildkit/buildkitd.toml

test:
	python3 -m pytest -q telemetry/tests

minicluster-test:
	dev/minicluster/run.sh up
	dev/minicluster/run.sh test
	dev/minicluster/run.sh down
