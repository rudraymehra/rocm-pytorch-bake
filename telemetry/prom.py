"""Render a record.json as Prometheus text for the node-exporter textfile collector.

All values are gauges describing the latest finished run of one slot: a scenario,
builder and set of targets. Each slot has its own file, so the phases of
scripts/rpb-cluster do not overwrite each other, and the builder and target_set
labels keep the series of different files apart (node-exporter rejects duplicates).
run_id and pins appear only on rpb_run_info.

A failed run keeps the slot's previous rpb_run_last_success_timestamp_seconds, so
"no success for a day" alerts keep working. Compile units whose telemetry came back
inside a cached layer (fresh is false) are left out.

Usage: python3 -m telemetry.prom results/<run_id>/record.json <textfile-dir>
       writes <textfile-dir>/rpb_<scenario>_<config>_<gpu_arch>_<builder>_<targets>.prom
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
    "rpb_sccache_remote": "1 for the state of the shared Redis level: redis, none or fallback.",
    "rpb_cpu_seconds": "CPU time of one compile unit, by mode.",
    "rpb_peak_rss_bytes": "Largest resident set of any process in one compile unit.",
    "rpb_ninja_longest_edge_seconds": "Longest single ninja edge in one compile unit.",
    "rpb_wheel_size_bytes": "Size of an exported wheel.",
}

COMMON = ("builder", "config", "gpu_arch", "host_class", "scenario", "target_set")


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


def render(rec: dict, previous_success: float | None = None) -> str:
    o = _Out({k: rec.get(k, "") for k in COMMON})
    ok = rec.get("status") == "ok"
    if rec.get("t_start") is not None and rec.get("t_end") is not None:
        o.add("rpb_run_duration_seconds", float(rec["t_end"]) - float(rec["t_start"]))
    o.add("rpb_run_success", 1 if ok else 0)
    if ok and rec.get("t_end") is not None:
        o.add("rpb_run_last_success_timestamp_seconds", float(rec["t_end"]))
    else:
        o.add("rpb_run_last_success_timestamp_seconds", previous_success)
    pins = rec.get("pins") or {}
    o.add("rpb_run_info", 1, run_id=rec.get("run_id", ""), **{f"pin_{k}": v for k, v in sorted(pins.items())})

    for target, t in sorted((rec.get("targets") or {}).items()):
        bk = t["buildkit"]
        o.add("rpb_target_duration_seconds", bk.get("duration_s"), target=target)
        o.add("rpb_buildkit_steps", bk.get("steps_total"), target=target, state="total")
        o.add("rpb_buildkit_steps", bk.get("steps_cached"), target=target, state="cached")
        o.add("rpb_buildkit_cached_ratio", bk.get("cached_ratio"), target=target)

    for unit, u in sorted((rec.get("compile_units") or {}).items()):
        sc = u.get("sccache")
        if sc is None or u.get("fresh") is False:
            continue
        for lang in sorted(set(sc["hits"]) | set(sc["misses"])):
            o.add("rpb_sccache_compiles", sc["hits"].get(lang, 0), unit=unit, lang=lang, result="hit")
            o.add("rpb_sccache_compiles", sc["misses"].get(lang, 0), unit=unit, lang=lang, result="miss")
            o.add("rpb_sccache_hit_ratio", sc["hit_ratio"].get(lang), unit=unit, lang=lang)
        o.add("rpb_sccache_compiles", sc["cache_errors"], unit=unit, lang="all", result="error")
        o.add("rpb_sccache_remote", 1, unit=unit, state=u.get("remote") or "unknown")
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


def textfile_name(rec: dict) -> str:
    slot = "_".join(str(rec.get(k, "")) for k in ("scenario", "config", "gpu_arch", "builder", "target_set"))
    return "rpb_" + re.sub(r"[^A-Za-z0-9.-]+", "_", slot).strip("_") + ".prom"


def previous_success(text: str) -> float | None:
    for line in text.splitlines():
        if line.startswith("rpb_run_last_success_timestamp_seconds{"):
            return float(line.rsplit(" ", 1)[1])
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: python3 -m telemetry.prom <record.json> <textfile-dir>", file=sys.stderr)
        return 2
    rec = json.loads(Path(argv[1]).read_text())
    target = Path(argv[2]) / textfile_name(rec)
    previous = previous_success(target.read_text()) if target.exists() else None
    write_textfile(render(rec, previous), target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
