#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any
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


def _looks_like_glob(s: str) -> bool:
    return any(ch in s for ch in ["*", "?", "["])


def _collect_input_files(inputs: list[str]) -> list[Path]:
    files: list[Path] = []
    for raw in inputs:
        raw = os.path.expanduser(raw)
        if _looks_like_glob(raw):
            files.extend(Path(p) for p in glob.glob(raw))
            continue

        p = Path(raw)
        if p.is_dir():
            files.extend(p.rglob("*.json"))
            files.extend(p.rglob("*.xml"))
        else:
            files.append(p)

    uniq: list[Path] = []
    seen: set[Path] = set()
    for p in files:
        try:
            resolved = p.resolve()
        except Exception:
            resolved = p
        if resolved in seen:
            continue
        seen.add(resolved)
        uniq.append(p)
    return uniq


def _load_json_payload(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Expected a JSON object")
    return data


def _load_points_from_payload(payload: dict[str, Any]) -> list[list[float]]:
    points = payload.get("points")
    if not isinstance(points, list):
        raise ValueError("Missing/invalid 'points' array")
    out: list[list[float]] = []
    for entry in points:
        if not isinstance(entry, list) or len(entry) < 3:
            continue
        dx = float(entry[0])
        dy = float(entry[1])
        p = float(entry[2])
        out.append([dx, dy, p])
    return out


def _load_points_from_iam_line_strokes_xml(path: Path) -> list[list[float]]:
    tree = ET.parse(path)
    root = tree.getroot()
    stroke_set = root.find(".//StrokeSet")
    if stroke_set is None:
        raise ValueError("Missing StrokeSet in IAM XML")

    points: list[list[float]] = []
    prev_xy: tuple[float, float] | None = None

    for stroke in stroke_set.findall("./Stroke"):
        stroke_points: list[tuple[float, float]] = []
        for pt in stroke.findall("./Point"):
            try:
                x = float(pt.attrib.get("x", "0"))
                y = float(pt.attrib.get("y", "0"))
            except Exception:
                continue
            if not math.isfinite(x) or not math.isfinite(y):
                continue
            stroke_points.append((x, y))

        if not stroke_points:
            continue

        for idx, (x, y) in enumerate(stroke_points):
            if prev_xy is None:
                dx = 0.0
                dy = 0.0
            else:
                dx = x - prev_xy[0]
                dy = y - prev_xy[1]
            pen_up = 1.0 if idx == (len(stroke_points) - 1) else 0.0
            points.append([dx, dy, pen_up])
            prev_xy = (x, y)

    return points


def _load_payload_and_points(path: Path) -> tuple[dict[str, Any], list[list[float]]]:
    suffix = path.suffix.lower()
    if suffix == ".xml":
        points = _load_points_from_iam_line_strokes_xml(path)
        payload: dict[str, Any] = {"version": 1, "source": str(path), "points": points}
        return payload, points

    payload = _load_json_payload(path)
    points = _load_points_from_payload(payload)
    return payload, points


def _output_filename_for_input(path: Path) -> str:
    if path.suffix.lower() == ".xml":
        return f"{path.stem}.json"
    return path.name


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Compute dataset-wide mean/std for dx/dy across RNN stroke sequences, and optionally write normalized copies. "
            "Inputs can be JSON ({version, points:[[dx,dy,p],...]}) or IAM lineStrokes XML."
        )
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Input JSON/XML files, directories, or glob patterns.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="If set, write normalized JSON files into this directory (filenames preserved).",
    )
    parser.add_argument(
        "--stats",
        type=Path,
        default=None,
        help="If set, write computed mean/std JSON to this path.",
    )
    args = parser.parse_args()

    input_files = [p for p in _collect_input_files(args.inputs) if p.is_file()]
    if not input_files:
        raise SystemExit("No input files found.")

    dx_stats = RunningStats()
    dy_stats = RunningStats()

    total_files = 0
    for path in input_files:
        try:
            _payload, points = _load_payload_and_points(path)
        except Exception:
            continue
        if not points:
            continue
        total_files += 1
        for dx, dy, _p in points:
            if not math.isfinite(dx) or not math.isfinite(dy):
                continue
            dx_stats.update(dx)
            dy_stats.update(dy)

    if dx_stats.n <= 0 or dy_stats.n <= 0:
        raise SystemExit("No valid points found (expected [dx, dy, p] triples).")

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
        "files": total_files,
        "points": dx_stats.n,
        "mean_dx": mean_dx,
        "std_dx": std_dx,
        "mean_dy": mean_dy,
        "std_dy": std_dy,
    }

    print(json.dumps(stats_payload, indent=2, sort_keys=True))

    if args.stats is not None:
        args.stats.parent.mkdir(parents=True, exist_ok=True)
        args.stats.write_text(json.dumps(stats_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.out_dir is not None:
        args.out_dir.mkdir(parents=True, exist_ok=True)
        for path in input_files:
            try:
                data, points = _load_payload_and_points(path)
            except Exception:
                continue

            normalized: list[list[float]] = []
            for dx, dy, p in points:
                ndx = (dx - mean_dx) / std_dx
                ndy = (dy - mean_dy) / std_dy
                normalized.append([float(ndx), float(ndy), float(p)])

            out = dict(data)
            out["points"] = normalized
            out["norm"] = {
                "version": 1,
                "mean_dx": mean_dx,
                "std_dx": std_dx,
                "mean_dy": mean_dy,
                "std_dy": std_dy,
            }

            (args.out_dir / _output_filename_for_input(path)).write_text(
                json.dumps(out, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
