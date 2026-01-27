#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

import deepwriting_infer


def _read_json_line(stdin: object) -> dict:
    line = sys.stdin.readline()
    if line == "":
        raise EOFError
    line = line.strip()
    if not line:
        return {}
    return json.loads(line)


def main() -> int:
    parser = argparse.ArgumentParser(description="DeepWriting persistent deterministic inference server (teacher).")
    parser.add_argument("--deepwriting-root", type=Path, required=True, help="Path to deepwriting-teacher folder.")
    parser.add_argument("--model-save-dir", type=Path, required=True, help="DeepWriting model save dir.")
    parser.add_argument("--model-id", type=str, required=True, help="DeepWriting model folder name.")
    parser.add_argument("--checkpoint-id", type=str, default=None, help="Optional checkpoint id.")
    parser.add_argument(
        "--protocol-prefix",
        type=str,
        default="@@DWJSON@@",
        help="Prefix for JSON responses written to stdout (default: %(default)s).",
    )
    args = parser.parse_args()

    deepwriting_infer._add_deepwriting_to_syspath(args.deepwriting_root)
    from tf_compat import tf  # noqa: E402

    from tf_models_hw import HandwritingVRNNGmmModel, HandwritingVRNNModel  # noqa: E402

    model_dir = (args.model_save_dir / args.model_id).resolve()
    config_path = model_dir / "config.json"
    if not config_path.exists():
        raise SystemExit(f"Missing config.json: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    config["model_dir"] = str(model_dir)
    config["checkpoint_id"] = args.checkpoint_id

    ModelClsName = str(config.get("model_cls", "HandwritingVRNNGmmModel"))
    ModelCls = {"HandwritingVRNNGmmModel": HandwritingVRNNGmmModel, "HandwritingVRNNModel": HandwritingVRNNModel}.get(
        ModelClsName
    )
    if ModelCls is None:
        raise SystemExit(f"Unsupported model_cls for this server: {ModelClsName}")

    input_dims = deepwriting_infer._infer_input_dims(config)
    target_dims = deepwriting_infer._infer_target_dims(config)
    data_processor = deepwriting_infer._DummyDataProcessor(input_dims=input_dims, target_dims=target_dims)

    batch_size = 1
    seq_len_dyn = None
    strokes = tf.placeholder(tf.float32, shape=[batch_size, seq_len_dyn, sum(input_dims)])
    targets = tf.placeholder(tf.float32, shape=[batch_size, seq_len_dyn, sum(target_dims)])
    seq_len = tf.placeholder(tf.int32, shape=[batch_size])

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

    saver = tf.train.Saver()
    if args.checkpoint_id is None:
        ckpt = tf.train.latest_checkpoint(str(model_dir))
    else:
        ckpt = str(model_dir / args.checkpoint_id)
    if ckpt is None:
        raise SystemExit(f"Could not find checkpoint under: {model_dir}")

    prefix = str(args.protocol_prefix)
    with tf.Session() as sess:
        saver.restore(sess, ckpt)

        while True:
            try:
                obj = _read_json_line(sys.stdin)
            except EOFError:
                break
            if not obj:
                continue

            X = np.asarray(obj.get("X", []), dtype=np.float32)
            mask = np.asarray(obj.get("mask", []), dtype=np.float32)
            if X.ndim != 2 or X.shape[1] != 3:
                raise ValueError(f"Expected X shape [T,3], got {X.shape}")
            if mask.ndim != 1 or mask.shape[0] != X.shape[0]:
                raise ValueError(f"Expected mask shape [T], got {mask.shape} for X {X.shape}")

            real_len = int(np.sum(mask >= 0.5))
            real_len = max(0, min(real_len, int(X.shape[0])))

            Y = np.zeros_like(X, dtype=np.float32)
            if real_len > 0:
                x_real = np.array(X[:real_len], dtype=np.float32, copy=False)
                x_pen_end = deepwriting_infer._stroke_start_to_pen_end(x_real)
                model_inputs = deepwriting_infer._build_model_input(x_pen_end, input_dims=input_dims)

                feed = {strokes: model_inputs, seq_len: np.asarray([real_len], dtype=np.int32)}
                out_sample = sess.run(model.ops_evaluation["output_sample"], feed_dict=feed)
                out_sample = np.asarray(out_sample, dtype=np.float32)[0]

                # Teacher provides dx/dy; keep stroke-start markers (p) from the original input.
                Y[:real_len, 0:2] = out_sample[:, 0:2]
                Y[:real_len, 2] = x_real[:, 2]

                # Enforce "no teleport": stroke-start tokens should never move.
                stroke_start = Y[:real_len, 2] >= 0.5
                Y[:real_len][stroke_start, 0] = 0.0
                Y[:real_len][stroke_start, 1] = 0.0

            sys.stdout.write(prefix + json.dumps({"Y": Y.tolist()}, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

