from __future__ import annotations

import glob
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import Dataset


@dataclass(frozen=True)
class ShardIndex:
    path: str
    row: int


class NPZShardsDataset(Dataset):
    def __init__(self, data_dir: Path) -> None:
        data_dir = data_dir.expanduser().resolve()
        paths = sorted(glob.glob(str(data_dir / "*.npz")))
        if not paths:
            raise FileNotFoundError(f"No .npz shards under: {data_dir}")
        self._paths = paths
        self._index: list[ShardIndex] = []

        for p in self._paths:
            with np.load(p) as d:
                n = int(d["X"].shape[0])
            self._index.extend(ShardIndex(path=p, row=i) for i in range(n))

        self._cache_path: str | None = None
        self._cache: dict[str, np.ndarray] | None = None

    def __len__(self) -> int:
        return len(self._index)

    def _load_shard(self, path: str) -> dict[str, np.ndarray]:
        if self._cache_path == path and self._cache is not None:
            return self._cache
        d = np.load(path)
        self._cache_path = path
        self._cache = {"X": d["X"], "Y": d["Y"], "mask": d["mask"]}
        return self._cache

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        item = self._index[idx]
        shard = self._load_shard(item.path)

        X = torch.tensor(shard["X"][item.row], dtype=torch.float32)  # [T,3]
        Y = torch.tensor(shard["Y"][item.row], dtype=torch.float32)  # [T,3]
        M = torch.tensor(shard["mask"][item.row], dtype=torch.float32)  # [T]
        return X, Y, M

