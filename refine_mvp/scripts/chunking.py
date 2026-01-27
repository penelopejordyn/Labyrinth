from __future__ import annotations

import numpy as np


def to_windows(points: np.ndarray, max_len: int = 512, overlap: int = 0) -> list[np.ndarray]:
    """
    Split a [T,3] point stream into windows of length max_len (optionally overlapping).
    """
    if max_len <= 0:
        raise ValueError("max_len must be > 0")
    if overlap < 0 or overlap >= max_len:
        raise ValueError("overlap must be in [0, max_len)")

    if points.ndim != 2 or points.shape[1] != 3:
        raise ValueError(f"Expected points shape [T,3], got {points.shape}")

    step = max_len - overlap
    windows: list[np.ndarray] = []
    for i in range(0, int(points.shape[0]), step):
        windows.append(points[i : i + max_len])
    return windows


def pad_window(window: np.ndarray, max_len: int = 512) -> tuple[np.ndarray, np.ndarray]:
    """
    Pad a variable-length [L,3] window to [max_len,3], returning (X, mask).

    - X is float32, padded with zeros.
    - mask is float32, 1 for real tokens, 0 for padding.
    """
    if max_len <= 0:
        raise ValueError("max_len must be > 0")
    if window.ndim != 2 or window.shape[1] != 3:
        raise ValueError(f"Expected window shape [L,3], got {window.shape}")

    length = int(window.shape[0])
    X = np.zeros((max_len, 3), dtype=np.float32)
    mask = np.zeros((max_len,), dtype=np.float32)
    if length <= 0:
        return X, mask

    clipped = window[:max_len].astype(np.float32, copy=False)
    X[: clipped.shape[0]] = clipped
    mask[: clipped.shape[0]] = 1.0
    return X, mask

