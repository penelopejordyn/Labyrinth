#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator
import xml.etree.ElementTree as ET


@dataclass
class RunningStats:
    n: int = 0
    mean: float = 0.0
    m2: float = 0.0

    def update(self, x: float) -> None:
        if not math.isfinite(x):
            return
        self.n += 1
        delta = x - self.mean
        self.mean += delta / self.n
        delta2 = x - self.mean
        self.m2 += delta * delta2

    def variance_population(self) -> float:
        if self.n <= 0:
            return float("nan")
        return self.m2 / self.n

    def std_population(self) -> float:
        v = self.variance_population()
        return math.sqrt(v) if math.isfinite(v) and v >= 0 else float("nan")


def iter_dxdy_p_from_iam_xml(path: Path) -> Iterator[tuple[float, float, int]]:
    tree = ET.parse(path)
    root = tree.getroot()
    stroke_set = root.find(".//StrokeSet")
    if stroke_set is None:
        return

    prev_xy: tuple[float, float] | None = None

    for stroke in stroke_set.findall("./Stroke"):
        stroke_points: list[tuple[float, float]] = []
        for pt in stroke.findall("./Point"):
            x_raw = pt.attrib.get("x")
            y_raw = pt.attrib.get("y")
            if x_raw is None or y_raw is None:
                continue
            try:
                x = float(x_raw)
                y = float(y_raw)
            except Exception:
                continue
            if not math.isfinite(x) or not math.isfinite(y):
                continue
            stroke_points.append((x, y))

        if not stroke_points:
            continue

        last_idx = len(stroke_points) - 1
        for idx, (x, y) in enumerate(stroke_points):
            if prev_xy is None:
                dx = 0.0
                dy = 0.0
            else:
                dx = x - prev_xy[0]
                dy = y - prev_xy[1]

            p = 1 if idx == last_idx else 0
            yield (dx, dy, p)
            prev_xy = (x, y)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Recursively convert IAM lineStrokes XML files into training-ready RNN point streams.\n"
            "- Each XML becomes one JSON with points [[dx_norm, dy_norm, p], ...]\n"
            "- dx/dy are deltas with cross-stroke 'teleport' jumps\n"
            "- p=1 on the final point of each stroke\n"
            "- Normalization is dataset-wide (global mean/std across all files)\n"
        )
    )
    parser.add_argument(
        "--input-root",
        type=Path,
        default=Path("/Users/pennymarshall/Downloads/lineStrokes"),
        help="Root folder containing IAM lineStrokes XML files (default: %(default)s).",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("corpus"),
        help="Output folder (created if missing). Default: %(default)s (relative to repo root/CWD).",
    )
    parser.add_argument(
        "--stats-path",
        type=Path,
        default=None,
        help="Where to write dataset stats JSON (default: <output-root>/rnn_stats.json).",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing output JSON files.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional max number of XML files to process (for quick tests).",
    )
    args = parser.parse_args()

    input_root = args.input_root.expanduser().resolve()
    output_root = args.output_root.expanduser().resolve()
    stats_path = (args.stats_path or (output_root / "rnn_stats.json")).expanduser().resolve()

    if not input_root.exists() or not input_root.is_dir():
        raise SystemExit(f"Input root not found or not a directory: {input_root}")

    xml_files = sorted(input_root.rglob("*.xml"))
    if args.limit is not None:
        xml_files = xml_files[: max(0, args.limit)]
    if not xml_files:
        raise SystemExit(f"No .xml files found under: {input_root}")

    dx_stats = RunningStats()
    dy_stats = RunningStats()
    total_points = 0
    parsed_files = 0
    skipped_files = 0

    for i, xml_path in enumerate(xml_files, start=1):
        try:
            count_this = 0
            for dx, dy, _p in iter_dxdy_p_from_iam_xml(xml_path):
                if not math.isfinite(dx) or not math.isfinite(dy):
                    continue
                dx_stats.update(dx)
                dy_stats.update(dy)
                total_points += 1
                count_this += 1
            if count_this > 0:
                parsed_files += 1
            else:
                skipped_files += 1
        except Exception:
            skipped_files += 1

        if i % 500 == 0:
            print(f"[pass1] {i}/{len(xml_files)} files, {total_points} points...")

    if dx_stats.n <= 0 or dy_stats.n <= 0:
        raise SystemExit("No valid points found across XML files.")

    mean_dx = dx_stats.mean
    mean_dy = dy_stats.mean
    std_dx = dx_stats.std_population()
    std_dy = dy_stats.std_population()

    if not math.isfinite(std_dx) or std_dx <= 0:
        raise SystemExit(f"Invalid std_dx computed: {std_dx}")
    if not math.isfinite(std_dy) or std_dy <= 0:
        raise SystemExit(f"Invalid std_dy computed: {std_dy}")

    stats_payload = {
        "version": 1,
        "input_root": str(input_root),
        "files_total": len(xml_files),
        "files_parsed": parsed_files,
        "files_skipped": skipped_files,
        "points": total_points,
        "mean_dx": mean_dx,
        "std_dx": std_dx,
        "mean_dy": mean_dy,
        "std_dy": std_dy,
    }

    output_root.mkdir(parents=True, exist_ok=True)
    stats_path.parent.mkdir(parents=True, exist_ok=True)
    stats_path.write_text(json.dumps(stats_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def norm(dx: float, dy: float) -> tuple[float, float]:
        return ((dx - mean_dx) / std_dx, (dy - mean_dy) / std_dy)

    written_files = 0
    written_points = 0

    for i, xml_path in enumerate(xml_files, start=1):
        rel = xml_path.relative_to(input_root)
        out_path = (output_root / rel).with_suffix(".json")
        if out_path.exists() and not args.overwrite:
            continue

        try:
            points: list[list[float]] = []
            for dx, dy, p in iter_dxdy_p_from_iam_xml(xml_path):
                ndx, ndy = norm(dx, dy)
                if not math.isfinite(ndx) or not math.isfinite(ndy):
                    continue
                points.append([float(ndx), float(ndy), float(p)])

            if not points:
                continue

            out_obj = {
                "version": 1,
                "source": str(xml_path),
                "points": points,
                "norm": {
                    "version": 1,
                    "mean_dx": mean_dx,
                    "std_dx": std_dx,
                    "mean_dy": mean_dy,
                    "std_dy": std_dy,
                },
            }

            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(json.dumps(out_obj, separators=(",", ":")) + "\n", encoding="utf-8")
            written_files += 1
            written_points += len(points)
        except Exception:
            continue

        if i % 500 == 0:
            print(f"[pass2] {i}/{len(xml_files)} files, wrote {written_files} JSON...")

    print(
        json.dumps(
            {
                "output_root": str(output_root),
                "stats_path": str(stats_path),
                "written_files": written_files,
                "written_points": written_points,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

