#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def audit_session(session: Path) -> bool:
    shot_json = sorted(session.glob("shot_*.json"))
    complete = []
    incomplete = []

    for sidecar_path in shot_json:
        sidecar = json.loads(sidecar_path.read_text())
        missing = []

        image = session / sidecar["image"]
        if not image.exists():
            missing.append(sidecar["image"])

        depth = sidecar.get("depth")
        if depth:
            for key in ("file", "confidence"):
                name = depth.get(key)
                if name and not (session / name).exists():
                    missing.append(name)

        if missing:
            incomplete.append((sidecar_path.name, missing))
        else:
            complete.append(sidecar_path.name)

    # Files a sidecar legitimately claims. Anything else matching shot_* is an orphan —
    # an image/depth/confidence with no sidecar (partial write or a dropped file in transfer).
    referenced = set()
    indices = []
    for sidecar_path in shot_json:
        sidecar = json.loads(sidecar_path.read_text())
        referenced.add(sidecar["image"])
        depth = sidecar.get("depth")
        if depth:
            for key in ("file", "confidence"):
                if depth.get(key):
                    referenced.add(depth[key])
        if isinstance(sidecar.get("index"), int):
            indices.append(sidecar["index"])

    orphan_files = sorted(
        p.name
        for p in session.glob("shot_*")
        if p.suffix.lower() != ".json" and p.name not in referenced
    )

    # Sidecars are contracted to be contiguous and 1-indexed; report any gaps.
    gaps = []
    if indices:
        indices.sort()
        gaps = [i for i in range(indices[0], indices[-1] + 1) if i not in set(indices)]

    temp_files = sorted(p.name for p in session.glob("*.sb-*"))

    print(session)
    print(f"  manifest: {'yes' if (session / 'manifest.json').exists() else 'no'}")
    print(f"  complete sidecars: {len(complete)}")
    if complete:
        print(f"  complete range: {complete[0]} ... {complete[-1]}")
    print(f"  incomplete sidecars: {len(incomplete)}")
    for name, missing in incomplete:
        print(f"    {name}: missing {', '.join(missing)}")
    print(f"  orphan files (no sidecar): {', '.join(orphan_files) if orphan_files else 'none'}")
    print(f"  index gaps: {', '.join(map(str, gaps)) if gaps else 'none'}")
    print(f"  temp files: {', '.join(temp_files) if temp_files else 'none'}")
    print()
    return not incomplete and not orphan_files and not gaps and not temp_files


def main() -> None:
    parser = argparse.ArgumentParser(description="Audit spatialcam session folders or downloaded .xcappdata containers.")
    parser.add_argument("path", type=Path)
    args = parser.parse_args()

    root = args.path
    if root.is_dir() and root.name.startswith("session_"):
        sessions = [root]
    else:
        sessions = sorted(root.glob("**/captures/session_*"))

    if not sessions:
        raise SystemExit(f"No session_* folders found under {root}")

    ok = True
    for session in sessions:
        ok = audit_session(session) and ok
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
