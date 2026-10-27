import json

from telemetry import runmeta


def test_refs_from_metadata_file():
    meta = {
        "torch-wheel": {"buildx.build.ref": "rpb-build1/rpb-build10/k3v0abc"},
        "vllm-wheel": {"buildx.build.ref": "rpb-build1/rpb-build10/zz9"},
        "buildx.build.warnings": [],
    }
    assert runmeta.refs_from_metadata(meta) == {"torch-wheel": "k3v0abc", "vllm-wheel": "zz9"}


def test_refs_from_history_ls_accepts_json_lines_and_arrays():
    rows = [
        {"ref": "rpb-build1/rpb-build10/aaa", "name": "rpb/torch-wheel/gfx942/run1", "status": "completed"},
        {"ref": "rpb-build1/rpb-build10/bbb", "name": "rpb/vllm-wheel/gfx942/run1", "status": "failed"},
        {"ref": "rpb-build1/rpb-build10/ccc", "name": "rpb/vllm-wheel/gfx942/run0", "status": "completed"},
        {"ref": "rpb-build1/rpb-build10/ddd", "name": "something-else", "status": "completed"},
    ]
    as_lines = "\n".join(json.dumps(r) for r in rows)
    as_array = json.dumps(rows)
    for text in (as_lines, as_array):
        assert runmeta.refs_from_history_ls(text, "run1") == {"torch-wheel": "aaa", "vllm-wheel": "bbb"}


def test_pins_from_bake_print_collects_ref_and_sha_args():
    printed = {
        "target": {
            "torch-wheel": {"args": {"TORCH_REF": "v2.13.0", "TORCH_SHA": "cf30", "GPU_ARCH": "gfx942", "MAX_JOBS": "64"}},
            "base": {"args": {"ROCM_SDK_VERSION": "10.0.0", "SCCACHE_VERSION": "0.19.0", "BASE_IMAGE": "ubuntu@sha256:e0"}},
            "vllm-wheel": {"args": {"VLLM_SHA": "e8ae", "VLLM_VERSION": "0.32.1rc1"}},
        }
    }
    assert runmeta.pins_from_bake_print(printed) == {
        "BASE_IMAGE": "ubuntu@sha256:e0",
        "GPU_ARCH": "gfx942",
        "ROCM_SDK_VERSION": "10.0.0",
        "SCCACHE_VERSION": "0.19.0",
        "TORCH_REF": "v2.13.0",
        "TORCH_SHA": "cf30",
        "VLLM_SHA": "e8ae",
        "VLLM_VERSION": "0.32.1rc1",
    }


def test_local_outputs_only_local_dests():
    printed = {"target": {
        "torch-wheel": {"output": [{"type": "local", "dest": "out/gfx942/torch"}]},
        "torch-dev": {"output": [{"type": "cacheonly"}]},
        "push": {"output": [{"type": "image", "name": "zot:5000/x", "push": "true"}]},
    }}
    assert runmeta.local_outputs(printed) == ["out/gfx942/torch"]


def test_wheel_sizes_reads_only_given_dirs(tmp_path):
    torch_dir = tmp_path / "torch"
    (torch_dir / "telemetry").mkdir(parents=True)
    (torch_dir / "torch-2.13.0+rpb.gfx942-cp312-cp312-linux_x86_64.whl").write_bytes(b"x" * 10)
    (torch_dir / "telemetry" / "torch-sccache.json").write_text("{}")
    other = tmp_path / "vllm"
    other.mkdir()
    (other / "vllm-0.1-py3-none-any.whl").write_bytes(b"y")
    assert runmeta.wheel_sizes([torch_dir]) == {"torch-2.13.0+rpb.gfx942-cp312-cp312-linux_x86_64.whl": 10}
