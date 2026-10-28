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
    (run / "telemetry" / "torch-sccache-remote.txt").write_text("redis\n")
    (run / "meta.json").write_text(json.dumps({
        "run_id": "run1", "scenario": "C0", "config": "rpb", "host_class": "m7a.16xlarge",
        "gpu_arch": "gfx942", "t_start": 1000.0, "t_end": 3000.0, "status": "ok",
        "builder": "rpb-build1", "target_set": "torch-wheel",
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
    assert unit["remote"] == "redis"


def test_main_writes_record_atomically(tmp_path):
    run = make_run(tmp_path)
    assert collect.main(["collect", str(run)]) == 0
    assert json.loads((run / "record.json").read_text())["run_id"] == "run1"
    assert not (run / "record.json.tmp").exists()


COMMON = {"builder": "rpb-build1", "config": "rpb", "gpu_arch": "gfx942", "host_class": "m7a.16xlarge",
          "scenario": "C0", "target_set": "torch-wheel"}


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
    assert series("rpb_sccache_remote", 1, unit="torch", state="redis") in lines
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


def test_slots_get_their_own_file_and_never_share_a_series(tmp_path):
    # scripts/rpb-cluster: phase A and phase C run on the same builder and scenario.
    rec_a = collect.build_record(make_run(tmp_path))
    rec_c = {**rec_a, "target_set": "test", "targets": {}, "compile_units": {}, "wheels": {}}
    assert prom.textfile_name(rec_a) == "rpb_C0_rpb_gfx942_rpb-build1_torch-wheel.prom"
    assert prom.textfile_name({**rec_a, "target_set": "aiter-wheel,fa-wheel"}) == \
        "rpb_C0_rpb_gfx942_rpb-build1_aiter-wheel_fa-wheel.prom"
    assert prom.textfile_name({**rec_a, "gpu_arch": "gfx950"}) != prom.textfile_name(rec_a)
    assert prom.textfile_name(rec_a) != prom.textfile_name(rec_c)

    def samples(rec):
        return {l.rsplit(" ", 1)[0] for l in prom.render(rec).splitlines() if l and not l.startswith("#")}

    assert not samples(rec_a) & samples(rec_c)


def test_main_writes_into_the_textfile_dir(tmp_path):
    run = make_run(tmp_path)
    collect.main(["collect", str(run)])
    out = tmp_path / "textfile"
    out.mkdir()
    assert prom.main(["prom", str(run / "record.json"), str(out)]) == 0
    assert [p.name for p in out.iterdir()] == ["rpb_C0_rpb_gfx942_rpb-build1_torch-wheel.prom"]


def test_missing_remote_file_is_reported_as_unknown(tmp_path):
    run = make_run(tmp_path)
    (run / "telemetry" / "torch-sccache-remote.txt").unlink()
    rec = collect.build_record(run)
    assert rec["compile_units"]["torch"]["remote"] is None
    assert series("rpb_sccache_remote", 1, unit="torch", state="unknown") in prom.render(rec).splitlines()


def test_failed_run_keeps_the_last_success_time(tmp_path):
    run = make_run(tmp_path)
    collect.main(["collect", str(run)])
    out = tmp_path / "textfile"
    out.mkdir()
    prom.main(["prom", str(run / "record.json"), str(out)])
    failed = json.loads((run / "record.json").read_text())
    failed.update(status="failed", t_start=5000.0, t_end=6000.0)
    (run / "record.json").write_text(json.dumps(failed))
    prom.main(["prom", str(run / "record.json"), str(out)])
    lines = next(out.iterdir()).read_text().splitlines()
    assert series("rpb_run_success", 0) in lines
    assert series("rpb_run_last_success_timestamp_seconds", 3000.0) in lines


def test_telemetry_from_a_cached_layer_is_not_reported_as_this_run(tmp_path):
    run = make_run(tmp_path)  # meta t_start = 1000
    (run / "telemetry" / "torch-started.txt").write_text("400\n")
    rec = collect.build_record(run)
    assert rec["compile_units"]["torch"]["fresh"] is False
    assert "rpb_sccache_compiles" not in prom.render(rec)
    (run / "telemetry" / "torch-started.txt").write_text("1001\n")
    rec = collect.build_record(run)
    assert rec["compile_units"]["torch"]["fresh"] is True
    assert "rpb_sccache_compiles" in prom.render(rec)


def test_broken_inputs_do_not_stop_the_record(tmp_path):
    run = make_run(tmp_path)
    (run / "telemetry" / "torch-sccache.json").write_text("")      # stats call failed
    (run / "inspect" / "torch-wheel.json").write_text("ERROR: x")  # history inspect failed
    rec = collect.build_record(run)
    assert rec["compile_units"]["torch"]["sccache"] is None
    assert "torch-sccache.json" in rec["compile_units"]["torch"]["error"]
    assert rec["targets"]["torch-wheel"]["buildkit"]["status"] == "unknown"
    text = prom.render(rec)
    assert series("rpb_run_success", 1) in text.splitlines()
    assert "rpb_target_duration_seconds" not in text
