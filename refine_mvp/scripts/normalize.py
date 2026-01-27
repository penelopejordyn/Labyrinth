from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np


@dataclass(frozen=True)
class DxDyNorm:
    mean_dx: float
    std_dx: float
    mean_dy: float
    std_dy: float

    @staticmethod
    def from_json(norm: dict[str, Any]) -> "DxDyNorm":
        return DxDyNorm(
            mean_dx=float(norm["mean_dx"]),
            std_dx=float(norm["std_dx"]),
            mean_dy=float(norm["mean_dy"]),
            std_dy=float(norm["std_dy"]),
        )


def normalize_X(X: np.ndarray, norm: DxDyNorm, *, zero_stroke_starts: bool = False) -> np.ndarray:
    """
    Normalize dx/dy using mean/std. Preserves p.

    If zero_stroke_starts is True, forces dx=0,dy=0 wherever p==1 after normalization.
    This keeps stroke-start tokens as [0,0,1] in the model input space.
    """
    if X.ndim != 2 or X.shape[1] != 3:
        raise ValueError(f"Expected X shape [T,3], got {X.shape}")

    out = X.astype(np.float32, copy=True)
    out[:, 0] = (out[:, 0] - norm.mean_dx) / (norm.std_dx + 1e-8)
    out[:, 1] = (out[:, 1] - norm.mean_dy) / (norm.std_dy + 1e-8)

    if zero_stroke_starts:
        stroke_start = out[:, 2] >= 0.5
        out[stroke_start, 0] = 0.0
        out[stroke_start, 1] = 0.0

    return out

