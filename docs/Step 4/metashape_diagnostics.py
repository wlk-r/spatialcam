#!/usr/bin/env python3
"""
Report Metashape camera/reference consistency for a spatialcam project.

Run through Metashape's bundled Python:
  /Applications/MetashapePro.app/Contents/MacOS/MetashapePro -r metashape_diagnostics.py \
    /path/to/project.psx --out /path/to/camera_diagnostics.csv
"""
from __future__ import annotations

import argparse
import csv
import math
import re
import statistics
from pathlib import Path

import Metashape


def shot_number(label: str) -> int:
    match = re.search(r"(\d+)", label)
    return int(match.group(1)) if match else -1


def camera_center_world(chunk: Metashape.Chunk, camera: Metashape.Camera) -> Metashape.Vector | None:
    if camera.transform is None or chunk.transform.matrix is None:
        return None
    return chunk.transform.matrix.mulp(camera.center)


def reference_location(camera: Metashape.Camera) -> Metashape.Vector | None:
    loc = camera.reference.location
    if loc is None:
        return None
    return loc


def distance(a: Metashape.Vector, b: Metashape.Vector) -> float:
    dx = float(a.x - b.x)
    dy = float(a.y - b.y)
    dz = float(a.z - b.z)
    return math.sqrt(dx * dx + dy * dy + dz * dz)


def vector_path(rows: list[dict], prefix: str) -> float:
    total = 0.0
    for left, right in zip(rows, rows[1:]):
        dx = left[f"{prefix}_x"] - right[f"{prefix}_x"]
        dy = left[f"{prefix}_y"] - right[f"{prefix}_y"]
        dz = left[f"{prefix}_z"] - right[f"{prefix}_z"]
        total += math.sqrt(dx * dx + dy * dy + dz * dz)
    return total


def load_rows(project: Path) -> list[dict]:
    doc = Metashape.Document()
    doc.open(str(project), read_only=True)
    if not doc.chunks:
        raise SystemExit(f"No chunks found in {project}")
    chunk = doc.chunks[0]

    rows = []
    for camera in sorted(chunk.cameras, key=lambda c: shot_number(c.label)):
        ref = reference_location(camera)
        est = camera_center_world(chunk, camera)
        row = {
            "label": camera.label,
            "shot": shot_number(camera.label),
            "aligned": 1 if est is not None else 0,
            "ref_x": "",
            "ref_y": "",
            "ref_z": "",
            "est_x": "",
            "est_y": "",
            "est_z": "",
            "delta_m": "",
        }
        if ref is not None:
            row["ref_x"] = float(ref.x)
            row["ref_y"] = float(ref.y)
            row["ref_z"] = float(ref.z)
        if est is not None:
            row["est_x"] = float(est.x)
            row["est_y"] = float(est.y)
            row["est_z"] = float(est.z)
        if ref is not None and est is not None:
            row["delta_m"] = distance(ref, est)
        rows.append(row)
    return rows


def write_csv(rows: list[dict], out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    fields = ["label", "shot", "aligned", "ref_x", "ref_y", "ref_z", "est_x", "est_y", "est_z", "delta_m"]
    with out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def parse_blocks(value: str | None, rows: list[dict]) -> list[tuple[str, int, int]]:
    if value:
        blocks = []
        for part in value.split(","):
            name, span = part.split(":", 1) if ":" in part else ("block", part)
            start, end = span.split("-", 1)
            blocks.append((name, int(start), int(end)))
        return blocks

    valid_shots = [r["shot"] for r in rows if r["shot"] >= 0]
    if not valid_shots:
        return []
    return [("all", min(valid_shots), max(valid_shots))]


def print_summary(rows: list[dict], blocks: list[tuple[str, int, int]]) -> None:
    aligned = [r for r in rows if r["aligned"] and r["delta_m"] != ""]
    print(f"METASHAPE_VERSION: {Metashape.app.version}")
    print(f"ALIGNED_WITH_REFERENCE: {len(aligned)}/{len(rows)}")

    for name, start, end in blocks:
        block = [r for r in aligned if start <= r["shot"] <= end]
        if not block:
            print(f"{name} shots {start}-{end}: no aligned referenced cameras")
            continue
        deltas = [r["delta_m"] for r in block]
        ref_path = vector_path(block, "ref")
        est_path = vector_path(block, "est")
        ratio = est_path / ref_path if ref_path else float("nan")
        print(
            f"{name} shots {start}-{end}: n={len(block)} "
            f"delta med/mean/max={statistics.median(deltas):.3f}/"
            f"{statistics.mean(deltas):.3f}/{max(deltas):.3f} m, "
            f"ref_path={ref_path:.3f} m, est_path={est_path:.3f} m, est/ref={ratio:.3f}"
        )

    unaligned = [r["label"] for r in rows if not r["aligned"]]
    if unaligned:
        print("UNALIGNED:", ", ".join(unaligned))

    print("TOP_OUTLIERS:")
    for row in sorted(aligned, key=lambda r: r["delta_m"], reverse=True)[:12]:
        print(f"  {row['label']} delta={row['delta_m']:.3f} m")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument(
        "--blocks",
        help="Comma-separated named shot ranges, e.g. room1:2-57,room2:58-125,room3:126-175",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    project = args.project.expanduser().resolve()
    out = args.out.expanduser().resolve() if args.out else project.parent / "camera_diagnostics.csv"
    rows = load_rows(project)
    write_csv(rows, out)
    print_summary(rows, parse_blocks(args.blocks, rows))
    print(f"CSV: {out}")


if __name__ == "__main__":
    main()
