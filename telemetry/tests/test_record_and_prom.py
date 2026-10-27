import json
import shutil
from pathlib import Path

from telemetry import collect, prom

FIX = Path(__file__).parent / "fixtures"


def make_run(tmp_path: Path) -> Path:
    run = tmp_path / "run1"
    (run / "inspect").mkdir(parents=True)
    (run / "steps").mkdir()
    (run / "telemetry").mkdir()
    shutil.copy(FIX / "inspect-torch-wheel.json", run / "inspect" / "torch-wheel.json")
    shutil.copy(FIX / "steps-torch-wheel.jsonl", run / "steps" / "torch-wheel.jsonl")
    for name in ("torch-sccache.json", "torch-time.txt", "torch-ninja.log"):
        shutil.copy(FIX / name, run / "telemetry" / name)
    (run / "meta.json").write_text(json.dumps({
        "run_id": "run1", "scenario": "C0", "config": "rpb", "host_class": "m7a.16xlarge",
        "gpu_arch": "gfx942", "t_start": 1000.0, "t_end": 3000.0, "status": "ok",
        "pins": {"torch": "v2.13.0", "vllm": "e8ae84bf"},
    }))
    (run / "wheels.json").write_text(json.dumps({"torch-2.13.0+rpb.gfx942-cp312-cp312-linux_x86_64.whl": 123}))
    return run


def test_build_record_joins_all_sources(tmp_path):
    rec = collect.build_record(make_run(tmp_path))
    assert rec["schema_version"] == 1
    assert rec["run_id"] == "run1"
    assert rec["targets"]["torch-wheel"]["buildkit"]["cached_ratio"] == 0.75
    assert len(rec["targets"]["torch-wheel"]["stages"]) == 3
    unit = rec["compile_units"]["torch"]
    assert unit["sccache"]["hits"]["HIP"] == 250
    assert unit["time"]["peak_rss_bytes"] == 4096 * 1024
    assert unit["ninja"]["longest"][0]["output"] == "attention.hip.o"


def test_main_writes_record_atomically(tmp_path):
    run = make_run(tmp_path)
    assert collect.main(["collect", str(run)]) == 0
    assert json.loads((run / "record.json").read_text())["run_id"] == "run1"
    assert not (run / "record.json.tmp").exists()


COMMON = {"config": "rpb", "gpu_arch": "gfx942", "host_class": "m7a.16xlarge", "scenario": "C0"}


def series(name, value, **labels):
    merged = {**COMMON, **labels}
    body = ",".join(f'{k}="{merged[k]}"' for k in sorted(merged))
    return f"{name}{{{body}}} {value}"


def test_prom_output_has_expected_series(tmp_path):
    rec = collect.build_record(make_run(tmp_path))
    lines = prom.render(rec).splitlines()
    assert series("rpb_run_duration_seconds", 2000.0) in lines
    assert series("rpb_target_duration_seconds", 1941.5, target="torch-wheel") in lines
    assert series("rpb_buildkit_steps", 15, target="torch-wheel", state="cached") in lines
    assert series("rpb_buildkit_cached_ratio", 0.75, target="torch-wheel") in lines
    assert series("rpb_sccache_compiles", 250, unit="torch", lang="HIP", result="hit") in lines
    assert series("rpb_peak_rss_bytes", 4194304, unit="torch") in lines
    assert series("rpb_wheel_size_bytes", 123, package="torch") in lines
    assert series("rpb_run_success", 1) in lines
    assert any(l.startswith("rpb_run_info{") and 'run_id="run1"' in l for l in lines)
    # every metric name has exactly one TYPE line, and every label set is unique
    names = {l.split("{")[0] for l in lines if l and not l.startswith("#")}
    for n in names:
        assert lines.count(f"# TYPE {n} gauge") == 1
    samples = [l.rsplit(" ", 1)[0] for l in lines if l and not l.startswith("#")]
    assert len(samples) == len(set(samples))


def test_prom_escapes_label_values():
    assert prom._label_value('a"b\\c\nd') == 'a\\"b\\\\c\\nd'


def test_write_textfile_is_atomic(tmp_path):
    target = tmp_path / "rpb.prom"
    prom.write_textfile("x 1\n", target)
    assert target.read_text() == "x 1\n"
    assert [p.name for p in tmp_path.iterdir()] == ["rpb.prom"]
