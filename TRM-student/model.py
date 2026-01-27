from __future__ import annotations

import torch
import torch.nn as nn


class StrokeRefineTransformer(nn.Module):
    def __init__(
        self,
        d_model: int = 192,
        layers: int = 6,
        heads: int = 6,
        ff: int = 768,
        dropout: float = 0.05,
    ) -> None:
        super().__init__()
        self.in_proj = nn.Linear(3, d_model)

        enc_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=heads,
            dim_feedforward=ff,
            dropout=dropout,
            batch_first=True,
            activation="gelu",
            norm_first=True,
        )
        self.encoder = nn.TransformerEncoder(enc_layer, num_layers=layers)

        # We keep stroke boundaries fixed by copying `p` from input at runtime.
        # The student predicts only dx/dy.
        self.out_xy = nn.Linear(d_model, 2)

    def forward(self, x: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        """
        Args:
            x: [B,T,3] float32
            mask: [B,T] float32 (1=real token, 0=pad)
        Returns:
            y_xy: [B,T,2] float32
        """
        h = self.in_proj(x)
        pad_mask = mask == 0
        h = self.encoder(h, src_key_padding_mask=pad_mask)
        return self.out_xy(h)

