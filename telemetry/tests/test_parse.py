import json
from pathlib import Path

import pytest

from telemetry import collect

FIX = Path(__file__).parent / "fixtures"


def test_parse_inspect_reads_steps_and_duration():
    obj = json.loads((FIX / "inspect-torch-wheel.json").read_text())
    got = collect.parse_inspect(obj)
    assert got == {
        "name": "rpb/torch-wheel/gfx942/run1",
        "ref": "k3v0abc",
        "status": "completed",
        "duration_s": 1941.5,
        "steps_total": 20,
        "steps_cached": 15,
        "steps_completed": 20,
        "cached_ratio": 0.75,
        "error": None,
    }


def test_parse_inspect_failed_build_keeps_error_and_zero_steps_ratio():
    got = collect.parse_inspect(
        {"Ref": "x", "Status": "failed", "Error": {"Message": "exit code: 1"},
         "NumTotalSteps": 0, "NumCachedSteps": 0, "NumCompletedSteps": 0}
    )
    assert got["status"] == "failed"
    assert got["error"] == "exit code: 1"
    assert got["cached_ratio"] is None
    assert got["duration_s"] is None


def test_parse_rawjson_dedups_vertices_and_times_steps():
    lines = (FIX / "steps-torch-wheel.jsonl").read_text().splitlines()
    stages = collect.parse_rawjson(lines)
    assert [s["name"] for s in stages] == [
        "[base 1/3] FROM ubuntu",
        "[build 2/3] RUN pip wheel",
        "[export 3/3] COPY /out/ /",
    ]
    assert stages[0]["cached"] is True
    assert stages[1]["cached"] is False
    assert stages[1]["duration_s"] == pytest.approx(1800.25)


def test_time_weighted_hit_ratio_uses_reference_durations():
    ref = [
        {"name": "a", "duration_s": 10.0, "cached": False},
        {"name": "b", "duration_s": 90.0, "cached": False},
    ]
    now = [
        {"name": "a", "duration_s": 10.0, "cached": False},
        {"name": "b", "duration_s": 0.0, "cached": True},
    ]
    assert collect.time_weighted_hit_ratio(now, ref) == pytest.approx(0.9)


def test_time_weighted_hit_ratio_without_overlap_is_none():
    assert collect.time_weighted_hit_ratio([{"name": "x", "duration_s": 1, "cached": True}], []) is None


def test_parse_sccache_counts_per_language_and_level():
    obj = json.loads((FIX / "torch-sccache.json").read_text())
    got = collect.parse_sccache(obj)
    assert got["compile_requests"] == 1200
    assert got["hits"] == {"C/C++": 900, "HIP": 250}
    assert got["misses"] == {"C/C++": 30, "HIP": 10}
    assert got["hit_ratio"] == {"C/C++": pytest.approx(900 / 930), "HIP": pytest.approx(250 / 260)}
    assert got["cache_errors"] == 0
    assert got["unsupported_compiler"] == 0
    assert [lvl["name"] for lvl in got["levels"]] == ["L0 (disk)", "L1 (redis)"]
    assert got["levels"][1]["hits"] == 1100


def test_parse_ninja_log_keeps_last_entry_per_output():
    text = (FIX / "torch-ninja.log").read_text()
    got = collect.parse_ninja_log(text, top=2)
    assert got["edges"] == 3
    assert got["span_s"] == pytest.approx(9.0)
    assert got["longest"][0] == {"output": "attention.hip.o", "seconds": pytest.approx(8.0)}
    assert len(got["longest"]) == 2


def test_parse_time_v():
    got = collect.parse_time_v((FIX / "torch-time.txt").read_text())
    assert got == {"user_s": 50000.5, "system_s": 1200.25, "peak_rss_bytes": 4096 * 1024, "exit_status": 0}
