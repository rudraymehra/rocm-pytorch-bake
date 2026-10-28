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


def test_parse_rawjson_reads_nanosecond_timestamps_and_skips_text_lines():
    # BuildKit writes 9 fractional digits; Python 3.10 accepts at most 6.
    lines = [
        "ERROR: something buildx printed",
        '{"vertexes":[{"digest":"sha256:a","name":"x","started":"2026-10-27T14:53:41.324758833Z",'
        '"completed":"2026-10-27T14:53:43.824758999+00:00"}]}',
    ]
    stages = collect.parse_rawjson(lines)
    assert len(stages) == 1
    assert stages[0]["duration_s"] == pytest.approx(2.5)


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


def test_parse_ninja_log_skips_a_truncated_last_line():
    text = "# ninja log v5\n0\t1500\t0\ta.o\tdeadbeef\n2000\t25"
    assert collect.parse_ninja_log(text)["edges"] == 1


@pytest.mark.parametrize("value, micro", [
    ("2026-10-27T14:53:41Z", 0),
    ("2026-10-27T14:53:41.5Z", 500000),
    ("2026-10-27T14:53:41.123+00:00", 123000),
    ("2026-10-27T14:53:41.324758833Z", 324758),
])
def test_timestamps_parse_with_any_number_of_fractional_digits(value, micro):
    assert collect._ts(value).microsecond == micro
