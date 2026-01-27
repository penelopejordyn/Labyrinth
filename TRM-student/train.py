#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import DataLoader

from dataset import NPZShardsDataset
from model import StrokeRefineTransformer


def _device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():  # type: ignore[attr-defined]
        return "mps"
    return "cpu"


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 2: train a student rewrite model (dx/dy only).")
    parser.add_argument("--data-dir", type=Path, default=Path("refine_mvp/distill_out"), help="Dir of .npz shards.")
    parser.add_argument("--out-dir", type=Path, default=Path("TRM-student/out"), help="Output dir for checkpoints.")
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-2)
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--d-model", type=int, default=192)
    parser.add_argument("--layers", type=int, default=6)
    parser.add_argument("--heads", type=int, default=6)
    parser.add_argument("--ff", type=int, default=768)
    args = parser.parse_args()

    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    ds = NPZShardsDataset(args.data_dir)
    dl = DataLoader(
        ds,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=args.num_workers,
        pin_memory=torch.cuda.is_available(),
        drop_last=True,
    )

    device = _device()
    model = StrokeRefineTransformer(
        d_model=args.d_model,
        layers=args.layers,
        heads=args.heads,
        ff=args.ff,
    ).to(device)

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    huber = nn.SmoothL1Loss(reduction="none")

    for epoch in range(1, args.epochs + 1):
        model.train()
        total = 0.0
        steps = 0

        for X, Y, M in dl:
            X = X.to(device)  # [B,T,3]
            Y = Y.to(device)  # [B,T,3]
            M = M.to(device)  # [B,T]

            pred_xy = model(X, M)  # [B,T,2]
            tgt_xy = Y[..., 0:2]

            w = M.unsqueeze(-1)
            loss_xy = huber(pred_xy, tgt_xy) * w
            loss_xy = loss_xy.sum() / (w.sum() + 1e-6)

            opt.zero_grad(set_to_none=True)
            loss_xy.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()

            total += float(loss_xy.item())
            steps += 1

        mean_loss = total / max(1, steps)
        print(f"epoch {epoch}/{args.epochs} loss_xy={mean_loss:.6f}")

        ckpt_path = out_dir / "student.pt"
        torch.save(model.state_dict(), ckpt_path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

