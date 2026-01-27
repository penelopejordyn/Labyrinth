#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

import torch

from model import StrokeRefineTransformer


def _disable_transformer_fastpaths() -> None:
    """
    Torch's TransformerEncoder/Attention may pick different internal fastpaths between calls
    (e.g. fused encoder layer kernels). That can break `torch.jit.trace`'s sanity checks and
    can also make CoreML conversion less predictable.
    """

    if hasattr(torch.backends, "mha") and hasattr(torch.backends.mha, "set_fastpath_enabled"):  # type: ignore[attr-defined]
        try:
            torch.backends.mha.set_fastpath_enabled(False)  # type: ignore[attr-defined]
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 3: export student model to CoreML (.mlpackage).")
    parser.add_argument("--ckpt", type=Path, required=True, help="Path to trained PyTorch weights (.pt).")
    parser.add_argument("--out", type=Path, required=True, help="Output .mlpackage path.")
    parser.add_argument("--max-len", type=int, default=512, help="Sequence length (default: %(default)s).")
    args = parser.parse_args()

    try:
        import coremltools as ct  # type: ignore
    except Exception as e:
        raise SystemExit(f"Missing dependency coremltools. Install it then retry. Error: {e}")

    model = StrokeRefineTransformer()
    model.load_state_dict(torch.load(args.ckpt, map_location="cpu"))
    model.eval()

    example_x = torch.zeros((1, args.max_len, 3), dtype=torch.float32)
    example_m = torch.ones((1, args.max_len), dtype=torch.float32)

    _disable_transformer_fastpaths()

    # `check_trace` can fail with Transformer fastpaths (graphs differ across invocations),
    # even when outputs are deterministic. We disable it for reliability.
    traced = torch.jit.trace(model, (example_x, example_m), check_trace=False, strict=False)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="x", shape=example_x.shape),
            ct.TensorType(name="mask", shape=example_m.shape),
        ],
        outputs=[
            ct.TensorType(name="y_xy"),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )

    out_path = args.out.expanduser().resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    print(f"Saved: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
