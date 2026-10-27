"""Turn the raw files of one build run into a single record.json.

Inputs (all written by scripts/rpb into results/<run_id>/):
  meta.json                  run metadata (pins, host, scenario, config)
  inspect/<target>.json      docker buildx history inspect --format json
  steps/<target>.jsonl       docker buildx history logs --progress=rawjson
  telemetry/<name>-*.{json,txt,log}   sccache stats, /usr/bin/time -v, .ninja_log
  wheels.json                {"<wheel file name>": size_in_bytes}

Usage: python3 -m telemetry.collect results/<run_id>
"""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

SCHEMA_VERSION = 1


def _ratio(num: float, den: float) -> float | None:
    return num / den if den else None


def parse_inspect(obj: dict) -> dict:
    total = int(obj.get("NumTotalSteps", 0))
    cached = int(obj.get("NumCachedSteps", 0))
    duration_ns = obj.get("Duration")
    error = obj.get("Error") or None
    return {
        "name": obj.get("Name"),
        "ref": obj.get("Ref"),
        "status": obj.get("Status"),
        "duration_s": duration_ns / 1e9 if duration_ns else None,
        "steps_total": total,
        "steps_cached": cached,
        "steps_completed": int(obj.get("NumCompletedSteps", 0)),
        "cached_ratio": _ratio(cached, total),
        "error": error.get("Message") if error else None,
    }


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def parse_rawjson(lines: list[str]) -> list[dict]:
    """One entry per vertex digest, in first-seen order, from the last update seen."""
    order: list[str] = []
    latest: dict[str, dict] = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        for v in json.loads(line).get("vertexes") or []:
            digest = v.get("digest")
            if not digest:
                continue
            if digest not in latest:
                order.append(digest)
                latest[digest] = {}
            latest[digest].update({k: val for k, val in v.items() if val is not None})
    stages = []
    for digest in order:
        v = latest[digest]
        started, completed = v.get("started"), v.get("completed")
        duration = (_ts(completed) - _ts(started)).total_seconds() if started and completed else None
        stages.append({
            "digest": digest,
            "name": v.get("name", ""),
            "cached": bool(v.get("cached", False)),
            "started": started,
            "completed": completed,
            "duration_s": duration,
            "error": v.get("error"),
        })
    return stages


def time_weighted_hit_ratio(stages: list[dict], reference: list[dict]) -> float | None:
    """Share of the reference (cold) step time that this run served from cache.

    Steps are matched by name. Returns None when no step names overlap.
    """
    ref_time = {s["name"]: s["duration_s"] or 0.0 for s in reference}
    total = saved = 0.0
    for s in stages:
        if s["name"] not in ref_time:
            continue
        total += ref_time[s["name"]]
        if s["cached"]:
            saved += ref_time[s["name"]]
    return _ratio(saved, total)


def parse_sccache(obj: dict) -> dict:
    stats = obj["stats"]
    hits = dict(stats["cache_hits"]["counts"])
    misses = dict(stats["cache_misses"]["counts"])
    langs = sorted(set(hits) | set(misses))
    return {
        "version": obj.get("version"),
        "compile_requests": stats["compile_requests"],
        "unsupported_compiler": stats["requests_unsupported_compiler"],
        "not_cacheable": stats["requests_not_cacheable"],
        "hits": hits,
        "misses": misses,
        "hit_ratio": {lang: _ratio(hits.get(lang, 0), hits.get(lang, 0) + misses.get(lang, 0)) for lang in langs},
        "cache_errors": sum(stats["cache_errors"]["counts"].values()),
        "cache_read_errors": stats["cache_read_errors"],
        "cache_write_errors": stats["cache_write_errors"],
        "cache_timeouts": stats["cache_timeouts"],
        "levels": [
            {k: lvl[k] for k in ("name", "hits", "misses", "writes", "write_failures")}
            for lvl in stats.get("multi_level") or []
        ],
    }


def parse_ninja_log(text: str, top: int = 20) -> dict:
    last: dict[str, tuple[int, int]] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        start, end, _mtime, output = line.split("\t")[:4]
        last[output] = (int(start), int(end))
    if not last:
        return {"edges": 0, "span_s": 0.0, "longest": []}
    span = max(e for _, e in last.values()) - min(s for s, _ in last.values())
    longest = sorted(last.items(), key=lambda kv: kv[1][1] - kv[1][0], reverse=True)[:top]
    return {
        "edges": len(last),
        "span_s": span / 1000.0,
        "longest": [{"output": out, "seconds": (e - s) / 1000.0} for out, (s, e) in longest],
    }


_TIME_FIELDS = {
    "User time (seconds)": ("user_s", float),
    "System time (seconds)": ("system_s", float),
    "Maximum resident set size (kbytes)": ("peak_rss_bytes", lambda v: int(v) * 1024),
    "Exit status": ("exit_status", int),
}


def parse_time_v(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        key, sep, value = line.strip().rpartition(": ")
        if sep and key in _TIME_FIELDS:
            name, conv = _TIME_FIELDS[key]
            out[name] = conv(value.strip())
    return out


def _read_json(path: Path):
    return json.loads(path.read_text()) if path.exists() else None


def build_record(run_dir: Path) -> dict:
    meta = _read_json(run_dir / "meta.json") or {}
    targets = {}
    for f in sorted((run_dir / "inspect").glob("*.json")):
        target = f.stem
        entry = {"buildkit": parse_inspect(json.loads(f.read_text()))}
        steps = run_dir / "steps" / f"{target}.jsonl"
        if steps.exists():
            entry["stages"] = parse_rawjson(steps.read_text().splitlines())
        targets[target] = entry

    compile_units = {}
    tel = run_dir / "telemetry"
    for f in sorted(tel.glob("*-sccache.json")) if tel.exists() else []:
        name = f.name[: -len("-sccache.json")]
        unit = {"sccache": parse_sccache(json.loads(f.read_text()))}
        remote = tel / f"{name}-sccache-remote.txt"
        # redis | none | fallback, written by rpb-sccache-run; None for older runs
        unit["remote"] = remote.read_text().strip() if remote.exists() else None
        time_file = tel / f"{name}-time.txt"
        if time_file.exists():
            unit["time"] = parse_time_v(time_file.read_text())
        ninja = tel / f"{name}-ninja.log"
        if ninja.exists():
            unit["ninja"] = parse_ninja_log(ninja.read_text())
        compile_units[name] = unit

    return {
        "schema_version": SCHEMA_VERSION,
        **meta,
        "targets": targets,
        "compile_units": compile_units,
        "wheels": _read_json(run_dir / "wheels.json") or {},
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python3 -m telemetry.collect results/<run_id>", file=sys.stderr)
        return 2
    run_dir = Path(argv[1])
    record = build_record(run_dir)
    out = run_dir / "record.json"
    tmp = out.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    tmp.replace(out)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
