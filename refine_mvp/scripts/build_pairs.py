#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

from chunking import pad_window, to_windows
from normalize import DxDyNorm, normalize_X
from teacher_refine import DeepWritingSubprocessConfig, DeepWritingSubprocessTeacher, IdentityTeacher, TeacherRefiner


def _iter_json_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if not root.exists():
        raise FileNotFoundError(root)
    return sorted(p for p in root.rglob("*.json") if p.is_file())


def _load_points_and_norm(path: Path) -> tuple[np.ndarray, DxDyNorm | None]:
    obj = json.loads(path.read_text(encoding="utf-8"))
    points = np.asarray(obj.get("points", []), dtype=np.float32)
    norm_obj = obj.get("norm")
    norm = DxDyNorm.from_json(norm_obj) if isinstance(norm_obj, dict) else None
    return points, norm


def _save_shard(out_dir: Path, shard_idx: int, Xs: list[np.ndarray], Ys: list[np.ndarray], Ms: list[np.ndarray]) -> Path:
    X = np.stack(Xs).astype(np.float32, copy=False)  # [N,T,3]
    Y = np.stack(Ys).astype(np.float32, copy=False)  # [N,T,3]
    M = np.stack(Ms).astype(np.float32, copy=False)  # [N,T]

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"shard_{shard_idx:04d}.npz"
    np.savez_compressed(out_path, X=X, Y=Y, mask=M)
    return out_path


def _make_teacher(args: argparse.Namespace) -> TeacherRefiner:
    if args.teacher == "identity":
        return IdentityTeacher()

    if args.teacher == "deepwriting-subprocess":
        cfg = DeepWritingSubprocessConfig(
            python=args.python,
            infer_script=Path(args.infer_script),
            deepwriting_root=Path(args.deepwriting_root),
            model_save_dir=Path(args.model_save_dir),
            model_id=args.model_id,
            checkpoint_id=args.checkpoint_id,
        )
        return DeepWritingSubprocessTeacher(cfg)

    raise ValueError(f"Unknown teacher: {args.teacher}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 1: build (X, Y, mask) distillation shards from IAM JSON.")
    parser.add_argument("--iam-json", type=Path, required=True, help="Input root (directory) of JSON point streams.")
    parser.add_argument("--out-dir", type=Path, required=True, help="Output directory for .npz shards.")
    parser.add_argument("--max-len", type=int, default=512, help="Sequence length (default: %(default)s).")
    parser.add_argument("--overlap", type=int, default=0, help="Window overlap (default: %(default)s).")
    parser.add_argument("--shard-size", type=int, default=2048, help="Examples per shard (default: %(default)s).")
    parser.add_argument("--limit-files", type=int, default=None, help="Optional cap on input files.")
    parser.add_argument("--limit-windows", type=int, default=None, help="Optional cap on total windows.")

    parser.add_argument(
        "--normalize",
        choices=["none", "meanstd"],
        default="meanstd",
        help="Whether to apply per-file mean/std to dx/dy (default: %(default)s).",
    )
    parser.add_argument(
        "--zero-stroke-starts",
        action="store_true",
        help="Force dx=dy=0 wherever p==1 after normalization (keeps [0,0,1] stroke starts).",
    )

    parser.add_argument(
        "--teacher",
        choices=["identity", "deepwriting-subprocess"],
        default="identity",
        help="Teacher backend (default: %(default)s).",
    )

    # DeepWriting teacher params (only used when --teacher deepwriting-subprocess)
    parser.add_argument("--python", default="python3", help="Python executable for teacher subprocess.")
    parser.add_argument(
        "--infer-script",
        default="refine_mvp/scripts/deepwriting_infer_server.py",
        help="DeepWriting persistent inference server script to run in a subprocess.",
    )
    parser.add_argument(
        "--deepwriting-root",
        default="deepwriting-teacher",
        help="Path to DeepWriting repo folder.",
    )
    parser.add_argument("--model-save-dir", default="runs", help="DeepWriting model save dir (contains model_id/).")
    parser.add_argument("--model-id", default="", help="DeepWriting model folder name (required for deepwriting teacher).")
    parser.add_argument("--checkpoint-id", default=None, help="Optional checkpoint id.")

    args = parser.parse_args()

    teacher = _make_teacher(args)

    try:
        files = _iter_json_files(args.iam_json)
        if args.limit_files is not None:
            files = files[: max(0, args.limit_files)]
        if not files:
            raise SystemExit(f"No JSON files found under: {args.iam_json}")

        Xs: list[np.ndarray] = []
        Ys: list[np.ndarray] = []
        Ms: list[np.ndarray] = []
        shard_idx = 0
        total_windows = 0

        for file_idx, path in enumerate(files, start=1):
            points, norm = _load_points_and_norm(path)
            if points.size == 0:
                continue
            if points.ndim != 2 or points.shape[1] != 3:
                continue

            if args.normalize == "meanstd":
                if norm is None:
                    raise SystemExit(f"Missing norm in {path} (needed for --normalize meanstd).")
                points = normalize_X(points, norm, zero_stroke_starts=args.zero_stroke_starts)
            elif args.zero_stroke_starts:
                stroke_start = points[:, 2] >= 0.5
                if np.any(stroke_start):
                    points = np.array(points, dtype=np.float32, copy=True)
                    points[stroke_start, 0] = 0.0
                    points[stroke_start, 1] = 0.0

            windows = to_windows(points, max_len=args.max_len, overlap=args.overlap)
            for w in windows:
                X, mask = pad_window(w, max_len=args.max_len)

                Y = teacher.refine(X, mask)
                if not np.isfinite(Y).all():
                    continue

                Xs.append(X)
                Ys.append(Y)
                Ms.append(mask)
                total_windows += 1

                if args.limit_windows is not None and total_windows >= args.limit_windows:
                    break

                if len(Xs) >= args.shard_size:
                    out_path = _save_shard(args.out_dir, shard_idx, Xs, Ys, Ms)
                    print(json.dumps({"saved": str(out_path), "shape": [int(len(Xs)), int(args.max_len), 3]}))
                    shard_idx += 1
                    Xs, Ys, Ms = [], [], []

            if args.limit_windows is not None and total_windows >= args.limit_windows:
                break

            if file_idx % 250 == 0:
                print(json.dumps({"files": file_idx, "total_windows": total_windows}))

        if Xs:
            out_path = _save_shard(args.out_dir, shard_idx, Xs, Ys, Ms)
            print(json.dumps({"saved": str(out_path), "shape": [int(len(Xs)), int(args.max_len), 3]}))

        if total_windows <= 0:
            raise SystemExit("No windows produced. Check input JSON format and --max-len.")

        return 0
    finally:
        try:
            teacher.close()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
