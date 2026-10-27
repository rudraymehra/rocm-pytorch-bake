"""Parse output captured from a real BuildKit / sccache run (dev/minicluster/run.sh test).

The committed fixtures guard against format drift in buildx history inspect,
history logs --progress=rawjson and sccache stats JSON. dev/minicluster/run.sh test
runs these tests again on the output of its own run (RPB_REAL_FIXTURES).
"""
import json
import os
from pathlib import Path

import pytest

from telemetry import collect, runmeta

REAL = Path(os.environ.get("RPB_REAL_FIXTURES") or Path(__file__).parent / "fixtures" / "real")
pytestmark = pytest.mark.skipif(not (REAL / "inspect-toy.json").exists(), reason="no real fixtures captured yet")


def test_real_inspect():
    got = collect.parse_inspect(json.loads((REAL / "inspect-toy.json").read_text()))
    assert got["status"] == "completed"
    assert got["steps_total"] > 0
    assert got["duration_s"] and got["duration_s"] > 0


def test_real_rawjson_has_timed_steps():
    stages = collect.parse_rawjson((REAL / "steps-toy.jsonl").read_text().splitlines())
    assert stages
    assert any(s["duration_s"] is not None for s in stages)


def test_real_sccache_stats():
    got = collect.parse_sccache(json.loads((REAL / "toy-sccache.json").read_text()))
    assert got["compile_requests"] >= 40
    assert [lvl["name"] for lvl in got["levels"]]


def test_real_history_ls_finds_the_record_by_run_id():
    inspect = json.loads((REAL / "inspect-toy.json").read_text())
    run_id = inspect["Name"].split("/")[3]
    refs = runmeta.refs_from_history_ls((REAL / "history-ls.json").read_text(), run_id=run_id)
    assert refs == {"toy": inspect["Ref"]}
