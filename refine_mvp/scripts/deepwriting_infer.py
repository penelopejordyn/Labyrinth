#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import numpy as np


def _add_deepwriting_to_syspath(deepwriting_root: Path) -> None:
    root = deepwriting_root.resolve()
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(root / "source"))


def _load_input(path: Path) -> tuple[np.ndarray, np.ndarray]:
    obj = json.loads(path.read_text(encoding="utf-8"))
    X = np.asarray(obj["X"], dtype=np.float32)
    mask = np.asarray(obj["mask"], dtype=np.float32)
    if X.ndim != 2 or X.shape[1] != 3:
        raise ValueError(f"Expected X shape [T,3], got {X.shape}")
    if mask.ndim != 1 or mask.shape[0] != X.shape[0]:
        raise ValueError(f"Expected mask shape [T], got {mask.shape} for X {X.shape}")
    return X, mask


def _stroke_start_to_pen_end(x: np.ndarray) -> np.ndarray:
    """
    Convert p=1-at-stroke-start into pen_end (pen_up at end of stroke) for DeepWriting-style inputs.
    """
    if x.ndim != 2 or x.shape[1] != 3:
        raise ValueError(f"Expected x shape [T,3], got {x.shape}")

    p_start = x[:, 2] >= 0.5
    pen_end = np.zeros((x.shape[0],), dtype=np.float32)
    if x.shape[0] > 1:
        pen_end[:-1] = p_start[1:].astype(np.float32)
    if x.shape[0] > 0:
        pen_end[-1] = 1.0
    out = np.array(x, dtype=np.float32, copy=True)
    out[:, 2] = pen_end
    return out


def _build_model_input(x_pen_end: np.ndarray, input_dims: list[int]) -> np.ndarray:
    """
    DeepWriting models may expect extra input dims (e.g. char labels, bow label).
    We fill those dims with zeros.
    """
    if x_pen_end.ndim != 2 or x_pen_end.shape[1] != 3:
        raise ValueError(f"Expected x_pen_end shape [T,3], got {x_pen_end.shape}")
    total_in = int(sum(input_dims))
    if total_in < 3:
        raise ValueError(f"Invalid input_dims (sum < 3): {input_dims}")

    out = np.zeros((1, x_pen_end.shape[0], total_in), dtype=np.float32)
    out[0, :, 0:3] = x_pen_end
    return out


def _infer_input_dims(config: dict[str, Any]) -> list[int]:
    # Best-effort, enough to run reconstruction with a conditional model by providing zeros for label dims.
    dataset_cls = str(config.get("dataset_cls", ""))
    use_bow = bool(config.get("use_bow_labels", True))
    alphabet_size = int(config.get("num_gmm_components", 70))

    if "Conditional" in dataset_cls:
        return [3, alphabet_size, 1] if use_bow else [3, alphabet_size]
    return [3]


def _infer_target_dims(config: dict[str, Any]) -> list[int]:
    dataset_cls = str(config.get("dataset_cls", ""))
    use_bow = bool(config.get("use_bow_labels", True))
    alphabet_size = int(config.get("num_gmm_components", 70))

    if "Conditional" in dataset_cls:
        # Stroke (2), pen (1), char labels (alphabet), eoc (1), bow (1)
        return [2, 1, alphabet_size, 1, 1] if use_bow else [2, 1, alphabet_size, 1]
    return [2, 1]


class _DummyDataProcessor:
    def __init__(self, input_dims: list[int], target_dims: list[int]):
        self.input_dims = input_dims
        self.target_dims = target_dims

    def text_to_one_hot(self, text: list[str] | str) -> np.ndarray:
        # Reconstruction path does not need labels; return a correctly-shaped dummy value anyway.
        _ = text
        alphabet_size = int(self.target_dims[2]) if len(self.target_dims) >= 3 else 70
        return np.zeros((1, alphabet_size), dtype=np.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description="DeepWriting deterministic inference wrapper (teacher).")
    parser.add_argument("--input", type=Path, required=True, help="Input JSON: {X:[[...]], mask:[...]} (X is [T,3]).")
    parser.add_argument("--output", type=Path, required=True, help="Output JSON: {Y:[[...]]} (Y is [T,3]).")
    parser.add_argument("--deepwriting-root", type=Path, required=True, help="Path to deepwriting-teacher folder.")
    parser.add_argument("--model-save-dir", type=Path, required=True, help="DeepWriting model save dir.")
    parser.add_argument("--model-id", type=str, required=True, help="DeepWriting model folder name.")
    parser.add_argument("--checkpoint-id", type=str, default=None, help="Optional checkpoint id.")
    args = parser.parse_args()

    _add_deepwriting_to_syspath(args.deepwriting_root)
    from tf_compat import tf  # noqa: E402

    from tf_models_hw import HandwritingVRNNGmmModel, HandwritingVRNNModel  # noqa: E402

    X, mask = _load_input(args.input)
    real_len = int(np.sum(mask >= 0.5))
    real_len = max(0, min(real_len, int(X.shape[0])))

    Y = np.zeros_like(X, dtype=np.float32)
    if real_len == 0:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"Y": Y.tolist()}), encoding="utf-8")
        return 0

    x_real = np.array(X[:real_len], dtype=np.float32, copy=False)
    x_pen_end = _stroke_start_to_pen_end(x_real)

    model_dir = (args.model_save_dir / args.model_id).resolve()
    config_path = model_dir / "config.json"
    if not config_path.exists():
        raise SystemExit(f"Missing config.json: {config_path}")
    config: dict[str, Any] = json.loads(config_path.read_text(encoding="utf-8"))

    config["model_dir"] = str(model_dir)
    config["checkpoint_id"] = args.checkpoint_id

    ModelClsName = str(config.get("model_cls", "HandwritingVRNNGmmModel"))
    ModelCls = {"HandwritingVRNNGmmModel": HandwritingVRNNGmmModel, "HandwritingVRNNModel": HandwritingVRNNModel}.get(
        ModelClsName
    )
    if ModelCls is None:
        raise SystemExit(f"Unsupported model_cls for this wrapper: {ModelClsName}")

    input_dims = _infer_input_dims(config)
    target_dims = _infer_target_dims(config)

    data_processor = _DummyDataProcessor(input_dims=input_dims, target_dims=target_dims)

    batch_size = 1
    seq_len_dyn = None
    strokes = tf.placeholder(tf.float32, shape=[batch_size, seq_len_dyn, sum(input_dims)])
    targets = tf.placeholder(tf.float32, shape=[batch_size, seq_len_dyn, sum(target_dims)])
    seq_len = tf.placeholder(tf.int32, shape=[batch_size])

    # Build the reconstruction/inference graph (validation-mode cell behavior) without building the loss graph.
    # This keeps the output dependent on the given input strokes while avoiding the TF1-only `tf.contrib.distributions`
    # dependencies used in the training loss for GMM variants.
    with tf.name_scope("validation"):
        model = ModelCls(
            config,
            reuse=False,
            input_op=strokes,
            target_op=targets,
            input_seq_length_op=seq_len,
            input_dims=input_dims,
            target_dims=target_dims,
            batch_size=batch_size,
            mode="validation",
            data_processor=data_processor,
        )
        model.get_constructors()
        model.build_cell()
        model.build_rnn_layer()
        model.build_predictions_layer()

    with tf.Session() as sess:
        saver = tf.train.Saver()
        if args.checkpoint_id is None:
            ckpt = tf.train.latest_checkpoint(str(model_dir))
        else:
            ckpt = str(model_dir / args.checkpoint_id)
        if ckpt is None:
            raise SystemExit(f"Could not find checkpoint under: {model_dir}")
        saver.restore(sess, ckpt)

        model_inputs = _build_model_input(x_pen_end, input_dims=input_dims)
        feed = {strokes: model_inputs, seq_len: np.asarray([real_len], dtype=np.int32)}
        out_sample = sess.run(model.ops_evaluation["output_sample"], feed_dict=feed)
        out_sample = np.asarray(out_sample, dtype=np.float32)[0]

    # Teacher provides dx/dy; keep p (stroke-start marker) from the original input.
    Y[:real_len, 0:2] = out_sample[:, 0:2]
    Y[:real_len, 2] = x_real[:, 2]

    # Enforce "no teleport": stroke-start tokens should never move.
    stroke_start = Y[:real_len, 2] >= 0.5
    Y[:real_len][stroke_start, 0] = 0.0
    Y[:real_len][stroke_start, 1] = 0.0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"Y": Y.tolist()}), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
