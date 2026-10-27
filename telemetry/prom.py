"""Render a record.json as Prometheus text for the node-exporter textfile collector.

All values are gauges describing the latest finished run for a (scenario, config,
host_class, gpu_arch) combination. run_id and pins appear only on rpb_run_info.

Usage: python3 -m telemetry.prom results/<run_id>/record.json /var/lib/node_exporter/textfile/rpb.prom
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

HELP = {
    "rpb_run_duration_seconds": "Wall time of the whole bake run.",
    "rpb_run_success": "1 if the run finished with status ok, else 0.",
    "rpb_run_last_success_timestamp_seconds": "Unix time when the last successful run ended.",
    "rpb_run_info": "Run metadata; value is always 1.",
    "rpb_target_duration_seconds": "BuildKit duration of one bake target.",
    "rpb_buildkit_steps": "BuildKit steps of one bake target, by state.",
    "rpb_buildkit_cached_ratio": "Cached steps divided by total steps (unweighted).",
    "rpb_sccache_compiles": "sccache compile results inside one compile unit.",
    "rpb_sccache_hit_ratio": "sccache hits / (hits + misses) per language.",
    "rpb_cpu_seconds": "CPU time of one compile unit, by mode.",
    "rpb_peak_rss_bytes": "Largest resident set of any process in one compile unit.",
    "rpb_ninja_longest_edge_seconds": "Longest single ninja edge in one compile unit.",
    "rpb_wheel_size_bytes": "Size of an exported wheel.",
}

COMMON = ("config", "gpu_arch", "host_class", "scenario")


def _label_value(v) -> str:
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _package(wheel_name: str) -> str:
    return re.split(r"-\d", wheel_name, maxsplit=1)[0]


class _Out:
    def __init__(self, common: dict):
        self.common = common
        self.series: dict[str, list[str]] = {}

    def add(self, name: str, value, **labels):
        if value is None:
            return
        merged = {**self.common, **labels}
        body = ",".join(f'{k}="{_label_value(merged[k])}"' for k in sorted(merged))
        self.series.setdefault(name, []).append(f"{name}{{{body}}} {value}")

    def text(self) -> str:
        out = []
        for name in sorted(self.series):
            out.append(f"# HELP {name} {HELP[name]}")
            out.append(f"# TYPE {name} gauge")
            out.extend(self.series[name])
        return "\n".join(out) + "\n"


def render(rec: dict) -> str:
    o = _Out({k: rec.get(k, "") for k in COMMON})
    ok = rec.get("status") == "ok"
    if rec.get("t_start") is not None and rec.get("t_end") is not None:
        o.add("rpb_run_duration_seconds", float(rec["t_end"]) - float(rec["t_start"]))
    o.add("rpb_run_success", 1 if ok else 0)
    if ok and rec.get("t_end") is not None:
        o.add("rpb_run_last_success_timestamp_seconds", float(rec["t_end"]))
    pins = rec.get("pins") or {}
    o.add("rpb_run_info", 1, run_id=rec.get("run_id", ""), **{f"pin_{k}": v for k, v in sorted(pins.items())})

    for target, t in sorted((rec.get("targets") or {}).items()):
        bk = t["buildkit"]
        o.add("rpb_target_duration_seconds", bk["duration_s"], target=target)
        o.add("rpb_buildkit_steps", bk["steps_total"], target=target, state="total")
        o.add("rpb_buildkit_steps", bk["steps_cached"], target=target, state="cached")
        o.add("rpb_buildkit_cached_ratio", bk["cached_ratio"], target=target)

    for unit, u in sorted((rec.get("compile_units") or {}).items()):
        sc = u["sccache"]
        for lang in sorted(set(sc["hits"]) | set(sc["misses"])):
            o.add("rpb_sccache_compiles", sc["hits"].get(lang, 0), unit=unit, lang=lang, result="hit")
            o.add("rpb_sccache_compiles", sc["misses"].get(lang, 0), unit=unit, lang=lang, result="miss")
            o.add("rpb_sccache_hit_ratio", sc["hit_ratio"].get(lang), unit=unit, lang=lang)
        o.add("rpb_sccache_compiles", sc["cache_errors"], unit=unit, lang="all", result="error")
        tm = u.get("time") or {}
        o.add("rpb_cpu_seconds", tm.get("user_s"), unit=unit, mode="user")
        o.add("rpb_cpu_seconds", tm.get("system_s"), unit=unit, mode="system")
        o.add("rpb_peak_rss_bytes", tm.get("peak_rss_bytes"), unit=unit)
        nj = u.get("ninja") or {}
        if nj.get("longest"):
            o.add("rpb_ninja_longest_edge_seconds", nj["longest"][0]["seconds"], unit=unit)

    for wheel, size in sorted((rec.get("wheels") or {}).items()):
        o.add("rpb_wheel_size_bytes", size, package=_package(wheel))
    return o.text()


def write_textfile(text: str, target: Path) -> None:
    """Write atomically, as the textfile collector may read at any moment."""
    target = Path(target)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=".rpb.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, target)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: python3 -m telemetry.prom <record.json> <out.prom>", file=sys.stderr)
        return 2
    rec = json.loads(Path(argv[1]).read_text())
    write_textfile(render(rec), Path(argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
