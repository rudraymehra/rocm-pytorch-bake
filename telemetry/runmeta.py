"""Helpers scripts/rpb uses to find the BuildKit history records of one run.

python3 -m telemetry.runmeta refs <bake-metadata.json|-> <history-ls.json> <run_id>
    prints "<target>\t<ref-id>" lines: every record of the run found by name in
    history ls, with the metadata file's refs taking precedence. The metadata file
    lists only the targets that finished, so failed targets come from history ls.
python3 -m telemetry.runmeta refs-since <history-ls.json> <unix-time>
    prints "<record name>\t<ref-id>" for every record created at or after that time
    (for builds that do not name their records, such as the AIC baseline)
python3 -m telemetry.runmeta pins <bake-print.json>
    prints the pinned versions as JSON
python3 -m telemetry.runmeta outputs <bake-print.json>
    prints the local output directories of the requested targets, one per line
python3 -m telemetry.runmeta wheels <dir> [<dir> ...]
    prints {"<wheel file>": bytes} as JSON for the wheels directly in those directories
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from telemetry.collect import _ts

_PIN_ARG = re.compile(
    r"^(GPU_ARCH|BASE_IMAGE|PYTHON_VERSION|ROCM_INDEX_URL|TORCH_GIT_URL|RUST_TOOLCHAIN|AITER_PREBUILD"
    r"|SCCACHE_SHA256|[A-Z0-9_]+_(REF|SHA|VERSION))$"
)


def _ref_id(ref: str) -> str:
    # buildx.build.ref and history ls refs are "<builder>/<node>/<id>"; history
    # inspect/logs take the bare id.
    return ref.rsplit("/", 1)[-1]


def refs_from_metadata(meta: dict) -> dict[str, str]:
    return {
        target: _ref_id(v["buildx.build.ref"])
        for target, v in meta.items()
        if isinstance(v, dict) and "buildx.build.ref" in v
    }


def _rows(text: str) -> list[dict]:
    text = text.strip()
    if not text:
        return []
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def refs_from_history_ls(text: str, run_id: str) -> dict[str, str]:
    """Records are named rpb/<target>/<gfx>/<run_id> through BUILDKIT_BUILD_NAME."""
    out = {}
    for row in _rows(text):
        parts = (row.get("name") or "").split("/")
        if len(parts) == 4 and parts[0] == "rpb" and parts[3] == run_id:
            out.setdefault(parts[1], _ref_id(row["ref"]))
    return out


def refs_since(text: str, t_start: float) -> dict[str, str]:
    """Records created at or after t_start (Unix time), keyed by a file-safe name."""
    out = {}
    for row in _rows(text):
        created = row.get("created_at")
        if not created or _ts(created).timestamp() < t_start:
            continue
        name = re.sub(r"[^A-Za-z0-9._-]+", "_", row.get("name") or _ref_id(row["ref"]))
        out.setdefault(name, _ref_id(row["ref"]))
    return out


def pins_from_bake_print(printed: dict) -> dict[str, str]:
    pins = {}
    for target in printed.get("target", {}).values():
        for k, v in (target.get("args") or {}).items():
            if _PIN_ARG.match(k):
                pins[k] = v
    return dict(sorted(pins.items()))


def local_outputs(printed: dict) -> list[str]:
    dests = []
    for target in printed.get("target", {}).values():
        for out in target.get("output") or []:
            if isinstance(out, dict) and out.get("type") == "local" and out.get("dest"):
                dests.append(out["dest"])
    return sorted(set(dests))


def wheel_sizes(dirs: list[Path]) -> dict[str, int]:
    return {p.name: p.stat().st_size for d in dirs for p in sorted(Path(d).glob("*.whl"))}


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "refs" and len(argv) == 5:
        hist = Path(argv[3])
        refs = refs_from_history_ls(hist.read_text(), argv[4]) if hist.exists() else {}
        if argv[2] != "-" and Path(argv[2]).exists():
            try:
                refs.update(refs_from_metadata(json.loads(Path(argv[2]).read_text())))
            except ValueError:
                pass  # an unfinished metadata file; history ls already has the records
        for target, ref in sorted(refs.items()):
            print(f"{target}\t{ref}")
        return 0
    if cmd == "refs-since" and len(argv) == 4:
        for name, ref in sorted(refs_since(Path(argv[2]).read_text(), float(argv[3])).items()):
            print(f"{name}\t{ref}")
        return 0
    if cmd == "pins" and len(argv) == 3:
        print(json.dumps(pins_from_bake_print(json.loads(Path(argv[2]).read_text())), indent=2))
        return 0
    if cmd == "outputs" and len(argv) == 3:
        for dest in local_outputs(json.loads(Path(argv[2]).read_text())):
            print(dest)
        return 0
    if cmd == "wheels" and len(argv) >= 3:
        print(json.dumps(wheel_sizes([Path(a) for a in argv[2:]]), indent=2, sort_keys=True))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
