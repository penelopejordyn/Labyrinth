## What we’re building

You want an Apple-Notes-style **“Refine handwriting”** feature.

Not just smoothing.
Like: **replace the entire stroke path** with a cleaner version that still looks like *your handwriting*.

---

## The plan (in plain terms)

### ✅ 1) Use DeepWriting as the “expert teacher” (offline only)

DeepWriting already knows how to do the thing you want:

* take messy handwriting
* rewrite it into cleaner handwriting
* keep the same style / personality
* output a *whole new stroke path* (not just smooth the old one)

So DeepWriting is basically the “professional calligrapher model” we trust.

**But…**
DeepWriting is old TensorFlow code and is hard to run nicely on an iPad.

So we don’t ship DeepWriting in the app.

---

### ✅ 2) Train a new modern model to copy DeepWriting (the “student”)

We train a new model — a small transformer rewrite model — that learns:

> “When I see messy handwriting, output the same cleaned result DeepWriting would.”

So DeepWriting generates the “answer key” for tons of examples, and the transformer learns to imitate it.

This is called **distillation**:

* teacher gives lots of high-quality outputs
* student learns to match them

---

## Why this is the best approach

### Why not just convert DeepWriting to CoreML?

Because it’s messy:

* old TF1 architecture
* random sampling inside
* harder to convert and optimize
* harder to guarantee it runs fast and stable on-device

It might work, but it’s a big risk + long engineering effort.

---

## Why the student transformer is better for your app

The student model:
✅ runs fast on **Apple Neural Engine** (ANE)
✅ exports cleanly to **CoreML**
✅ runs on-device on M-series iPads
✅ gives stable, deterministic results
✅ still produces full stroke replacement (not smoothing)

So you get:
**DeepWriting’s quality**
with **Apple-level performance + on-device shipping**

---

## How it works in the app (your UX idea still works)

When the user stops writing (pen up for ~500ms):

1. take the last sentence / phrase chunk
2. run the student model on it
3. replace the strokes with the refined version
4. keep original as undo

It will feel like Apple Notes refinement.

---

## One sentence summary

We use DeepWriting as an offline “perfect handwriting refiner” to generate training examples, then train a modern on-device transformer to do the same refinement quickly on iPads using CoreML.

---



I’m going to structure this like an engineering build plan with:

* what to build
* what files to write
* the exact pipeline
* concrete code skeletons (Python + Swift)

You already have:
✅ IAM samples in JSON (`points: [[dx,dy,p], ...]`, plus `norm`)
✅ `p=1` tokens are `[0,0,1]` at stroke starts
✅ dx/dy normalized (or at least normalization is available per file)

---

# ✅ MVP Goal (what “done” looks like)

When the user writes with Apple Pencil and then pauses (pen up > 500ms):

1. Your app grabs the last “writing burst”
2. Converts it to `[dx, dy, p]`
3. Runs a CoreML model on-device
4. Replaces the strokes with refined strokes
5. Undo works

This first MVP can be **generic** (not personalized yet).

---

# Big picture: what you are building

You will ship **a small rewrite model** (student) that was trained to imitate **DeepWriting refinement outputs** (teacher).

✅ Teacher (DeepWriting): offline only, Python/TF1
✅ Student (Transformer rewrite): trained in PyTorch, exported to CoreML, runs on iPad

---

# Phase 1 — Build the Teacher Dataset (the most important phase)

This phase produces your training data:

### `X = original/messy strokes`

### `Y = DeepWriting refined strokes`

## 1.1 Project structure

Make a repo folder like:

```
refine_mvp/
  iam_json/                 # your IAM json files
  deepwriting/              # clone deepwriting repo + pretrained model
  distill_out/              # output dataset shards (npz)
  scripts/
    build_pairs.py
    teacher_refine.py
    chunking.py
    normalize.py
```



## 1.2 Standardize your input format (you basically already did) the result ->/Users/pennymarshall/Desktop/lineStrokes

Every sample should be an array of tokens:

`token[t] = [dx, dy, p]`

Rules:

* first token of each stroke: `[0,0,1]`
* all movement tokens: `[dx,dy,0]`
* **no huge teleports** across strokes ✅ (you fixed this)

---

## 1.3 Chunking (fixed model input length)

Even if your UI uses “pen up > 500ms”, your model still needs bounded length.

Pick:

* `MAX_LEN = 512` (recommended for MVP)

Chunking algorithm:

* break points into windows of 512 tokens
* if shorter than 512, pad with `[0,0,0]`
* create a `mask[512]` (1 for real tokens, 0 for pad)

### `scripts/chunking.py`

```python
import numpy as np

def to_windows(points, max_len=512, overlap=0):
    step = max_len - overlap if overlap > 0 else max_len
    windows = []
    i = 0
    while i < len(points):
        windows.append(points[i:i+max_len])
        i += step
    return windows

def pad_window(window, max_len=512):
    L = len(window)
    X = np.zeros((max_len, 3), dtype=np.float32)
    mask = np.zeros((max_len,), dtype=np.float32)
    if L > 0:
        X[:L] = np.array(window, dtype=np.float32)
        mask[:L] = 1.0
    return X, mask
```

---

## 1.4 Normalization (match what you’ll do on device)

Your IAM JSON includes per-file `norm`.

For training, do:

* normalize dx/dy
* leave p unchanged

### `scripts/normalize.py`

```python
def normalize_X(X, norm):
    mean_dx = float(norm["mean_dx"])
    std_dx  = float(norm["std_dx"])
    mean_dy = float(norm["mean_dy"])
    std_dy  = float(norm["std_dy"])

    out = X.copy()
    out[:, 0] = (out[:, 0] - mean_dx) / (std_dx + 1e-8)
    out[:, 1] = (out[:, 1] - mean_dy) / (std_dy + 1e-8)
    return out
```

✅ You will use the **same normalization** in Swift later.

---

## 1.5 Teacher inference wrapper (DeepWriting)

This is the only repo-specific part.

### What the teacher must do

Input:

* `X [512,3]`
* `mask [512]`

Output:

* `Y [512,3]` refined tokens

**Critical teacher rule:** deterministic output
No randomness. No sampling.

* use predicted mean `μ(dx), μ(dy)`
* pen state = probability > 0.5

### How to implement it (the safest approach)

Instead of trying to convert TF graphs manually, **reuse DeepWriting’s existing eval code** by wrapping it.

You have two options:

### ✅ Option A (fastest): run DeepWriting via a subprocess

You write a small script that:

1. saves `X/mask` to a temp file
2. calls a DeepWriting inference script
3. reads `Y` back from temp output

This is the least fragile way.

### ✅ Option B (cleaner): import DeepWriting model and run inference directly

More elegant, but you’ll spend more time hunting tensor names / graph specifics.

For MVP speed, do Option A.

---

### `scripts/teacher_refine.py` (Option A skeleton)

```python
import json
import numpy as np
import subprocess
import tempfile
import os

def refine_with_deepwriting(X, mask, deepwriting_root, experiment_dir, model_name):
    """
    Writes X/mask to temp file -> runs deepwriting inference -> reads Y back
    """
    with tempfile.TemporaryDirectory() as td:
        inp = os.path.join(td, "input.json")
        out = os.path.join(td, "output.json")

        with open(inp, "w") as f:
            json.dump({
                "X": X.tolist(),
                "mask": mask.tolist()
            }, f)

        cmd = [
            "python", os.path.join(deepwriting_root, "your_infer_script.py"),
            "--input", inp,
            "--output", out,
            "--exp", experiment_dir,
            "--model", model_name
        ]
        subprocess.check_call(cmd)

        with open(out, "r") as f:
            obj = json.load(f)
        Y = np.array(obj["Y"], dtype=np.float32)
        return Y
```

You will create `your_infer_script.py` inside the DeepWriting repo folder that:

* loads model
* runs deterministic inference
* writes `Y`

Even if that script takes you a day, it’s worth it.

---

## 1.6 Dataset builder: IAM JSON → (X,Y,mask) shards

Now you generate training data.

### `scripts/build_pairs.py`

```python
import os, glob, json
import numpy as np

from chunking import to_windows, pad_window
from normalize import normalize_X
from teacher_refine import refine_with_deepwriting

MAX_LEN = 512
SHARD_SIZE = 2048

def load_json(path):
    with open(path, "r") as f:
        obj = json.load(f)
    return obj["points"], obj["norm"]

def save_shard(out_dir, shard_idx, Xs, Ys, Ms):
    X = np.stack(Xs)    # [N,512,3]
    Y = np.stack(Ys)    # [N,512,3]
    M = np.stack(Ms)    # [N,512]
    p = os.path.join(out_dir, f"shard_{shard_idx:04d}.npz")
    np.savez_compressed(p, X=X, Y=Y, mask=M)
    print("Saved:", p, X.shape)

def main():
    iam_dir = "../iam_json"
    out_dir = "../distill_out"
    os.makedirs(out_dir, exist_ok=True)

    deepwriting_root = "../deepwriting"
    experiment_dir = "..."   # where pretrained experiment is
    model_name = "..."       # the model folder name

    Xs, Ys, Ms = [], [], []
    shard_idx = 0

    for path in sorted(glob.glob(os.path.join(iam_dir, "*.json"))):
        points, norm = load_json(path)

        windows = to_windows(points, max_len=MAX_LEN, overlap=0)
        for w in windows:
            X, mask = pad_window(w, max_len=MAX_LEN)
            X = normalize_X(X, norm)

            Y = refine_with_deepwriting(
                X, mask,
                deepwriting_root=deepwriting_root,
                experiment_dir=experiment_dir,
                model_name=model_name
            )

            Xs.append(X)
            Ys.append(Y)
            Ms.append(mask)

            if len(Xs) >= SHARD_SIZE:
                save_shard(out_dir, shard_idx, Xs, Ys, Ms)
                shard_idx += 1
                Xs, Ys, Ms = [], [], []

    if len(Xs) > 0:
        save_shard(out_dir, shard_idx, Xs, Ys, Ms)

if __name__ == "__main__":
    main()
```

✅ After this, you will have:
`distill_out/shard_0000.npz`, etc.

Each shard contains:

* `X`: `[N,512,3]`
* `Y`: `[N,512,3]`
* `mask`: `[N,512]`

---

# Phase 2 — Train the Student Rewrite Model

This is the model you export to CoreML.

## 2.1 Student model (Transformer encoder rewrite model)

This is what you use:

* reads the entire input sequence
* rewrites it in one shot
* no sampling, fast inference

### `student/model.py`

```python
import torch
import torch.nn as nn

class StrokeRefineTransformer(nn.Module):
    def __init__(self, d_model=192, layers=6, heads=6, ff=768):
        super().__init__()
        self.in_proj = nn.Linear(3, d_model)

        enc_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=heads,
            dim_feedforward=ff,
            dropout=0.05,
            batch_first=True,
            activation="gelu",
            norm_first=True,
        )
        self.encoder = nn.TransformerEncoder(enc_layer, num_layers=layers)

        self.out_xy = nn.Linear(d_model, 2)
        self.out_p  = nn.Linear(d_model, 1)

    def forward(self, x, mask):
        """
        x: [B,T,3]
        mask: [B,T] 1=real 0=pad
        """
        h = self.in_proj(x)
        pad_mask = (mask == 0)  # transformer expects True for padding
        h = self.encoder(h, src_key_padding_mask=pad_mask)

        xy = self.out_xy(h)
        p  = torch.sigmoid(self.out_p(h))
        return torch.cat([xy, p], dim=-1)
```

This model is CoreML-friendly.

---

## 2.2 Training loop

Train to imitate teacher outputs.

### `student/train.py`

```python
import glob
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
from model import StrokeRefineTransformer

class NPZDataset(Dataset):
    def __init__(self, paths):
        self.paths = paths
        self.idx = []
        self.cache = {}

        for p in self.paths:
            data = np.load(p)
            N = data["X"].shape[0]
            self.idx.extend([(p, i) for i in range(N)])

    def __len__(self):
        return len(self.idx)

    def __getitem__(self, i):
        path, j = self.idx[i]
        if path not in self.cache:
            self.cache = {path: np.load(path)}
        d = self.cache[path]
        X = torch.tensor(d["X"][j], dtype=torch.float32)
        Y = torch.tensor(d["Y"][j], dtype=torch.float32)
        M = torch.tensor(d["mask"][j], dtype=torch.float32)
        return X, Y, M

def main():
    shard_paths = sorted(glob.glob("../distill_out/*.npz"))
    ds = NPZDataset(shard_paths)
    dl = DataLoader(ds, batch_size=32, shuffle=True, num_workers=2)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = StrokeRefineTransformer().to(device)

    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, weight_decay=1e-2)

    huber = nn.SmoothL1Loss(reduction="none")
    bce   = nn.BCELoss(reduction="none")

    for epoch in range(10):
        model.train()
        total = 0.0
        for X, Y, M in dl:
            X, Y, M = X.to(device), Y.to(device), M.to(device)
            pred = model(X, M)

            pred_xy = pred[..., :2]
            pred_p  = pred[..., 2]
            tgt_xy  = Y[..., :2]
            tgt_p   = Y[..., 2]

            mask_xy = M.unsqueeze(-1)

            loss_xy = huber(pred_xy, tgt_xy) * mask_xy
            loss_xy = loss_xy.sum() / (mask_xy.sum() + 1e-6)

            loss_p = bce(pred_p, tgt_p) * M
            loss_p = loss_p.sum() / (M.sum() + 1e-6)

            loss = loss_xy + 0.5 * loss_p

            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()

            total += float(loss.item())

        print(f"epoch {epoch}: loss={total/len(dl):.4f}")

    torch.save(model.state_dict(), "stroke_refine_student.pt")

if __name__ == "__main__":
    main()
```

✅ After training, you have `stroke_refine_student.pt`.

---

# Phase 3 — Export to CoreML

This creates the `.mlpackage` you add to Xcode.

## 3.1 CoreML export script

Install:

```bash
pip install coremltools
```

### `student/export_coreml.py`

```python
import torch
import coremltools as ct
import numpy as np
from model import StrokeRefineTransformer

MAX_LEN = 512

def main():
    model = StrokeRefineTransformer()
    model.load_state_dict(torch.load("stroke_refine_student.pt", map_location="cpu"))
    model.eval()

    example_x = torch.zeros((1, MAX_LEN, 3), dtype=torch.float32)
    example_m = torch.ones((1, MAX_LEN), dtype=torch.float32)

    traced = torch.jit.trace(model, (example_x, example_m))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="x", shape=example_x.shape),
            ct.TensorType(name="mask", shape=example_m.shape),
        ],
        outputs=[
            ct.TensorType(name="y"),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )

    mlmodel.save("StrokeRefineStudent.mlpackage")
    print("Saved StrokeRefineStudent.mlpackage")

if __name__ == "__main__":
    main()
```

✅ You now have `StrokeRefineStudent.mlpackage`.

---

# Phase 4 — iPad Integration (Swift)

Now we connect it to your drawing app.

## 4.1 Runtime trigger (pen-up > 500ms)

You already described this behavior, so implement:

* when stroke ends → start timer
* if no new stroke starts before 500ms → refine the last “burst”

## 4.2 Burst selection

MVP simplest:

* refine **all strokes since last refine trigger**
* OR refine last N strokes

You don’t need perfect sentence detection for MVP.

---

## 4.3 Convert strokes → tokens `[dx,dy,p]`

You already have this working.

Rules:

* `[0,0,1]` at stroke start
* `[dx,dy,0]` within stroke

✅ You already fixed it.

---

## 4.4 Normalize dx/dy in Swift

You must match training normalization.

You can start with global constants:

* `mean_dx=0, mean_dy=0`
* `std_dx/std_dy` computed from IAM normalization pass

Store in app constants.

Swift example:

```swift
dxNorm = (dx - meanDx) / stdDx
dyNorm = (dy - meanDy) / stdDy
```

---

## 4.5 Pad to 512 tokens + build mask

You need two MLMultiArrays:

* `x: [1,512,3]`
* `mask: [1,512]`

Pseudo-Swift:

```swift
for i in 0..<512 {
    if i < tokens.count {
        x[0,i,0] = tokens[i].dxNorm
        x[0,i,1] = tokens[i].dyNorm
        x[0,i,2] = tokens[i].p
        mask[0,i] = 1
    } else {
        x[0,i,*] = 0
        mask[0,i] = 0
    }
}
```

---

## 4.6 Run CoreML model

Call:

```swift
let out = try model.prediction(x: xArray, mask: maskArray)
let y = out.y   // [1,512,3]
```

---

## 4.7 Convert output tokens → refined strokes

You’ll take:

* `dx_hat, dy_hat`
* `p_hat` (probability)

Decision rule:

```swift
p = (p_hat > 0.5) ? 1 : 0
```

Rebuild absolute points:

* start at origin (0,0)
* accumulate dx/dy
* split strokes where p==1

Finally anchor into canvas by adding the original start position offset.

---

## 4.8 Replace strokes in your canvas

MVP approach:

* remove original strokes from that burst
* add refined strokes
* store original for Undo

---

# MVP Definition Checklist

You’re “done” when you have all these working:

✅ IAM JSON → `(X,Y,mask)` distillation dataset
✅ student model trains and outputs stable strokes
✅ student exports to CoreML
✅ app calls CoreML after pen-up 500ms
✅ app replaces strokes
✅ undo works
✅ no huge delays (ideally <150ms)

