# TRM-student (Phase 2–3)

This folder follows `plans/handwriting refinement plan.md`.

## Inputs

Training data comes from `refine_mvp/distill_out/*.npz` built via:

```bash
python3 -u refine_mvp/scripts/build_pairs.py \
  --iam-json refine_mvp/iam_json \
  --out-dir refine_mvp/distill_out \
  --teacher deepwriting-subprocess \
  --normalize none \
  --zero-stroke-starts \
  --deepwriting-root deepwriting-teacher \
  --model-save-dir deepwriting-teacher \
  --model-id tf-1514981744-deepwriting_synthesis_model
```

Each shard contains:
- `X`: `[N,512,3]` (input tokens `[dx,dy,p]`)
- `Y`: `[N,512,3]` (teacher-refined tokens; `p` is preserved from `X`)
- `mask`: `[N,512]` (1=real token, 0=pad)

## Training

Dependencies:

```bash
pip install torch
```

```bash
python3 -u TRM-student/train.py \
  --data-dir refine_mvp/distill_out \
  --out-dir TRM-student/out \
  --epochs 10
```

## CoreML export

Dependencies:

```bash
pip install coremltools
```

```bash
python3 -u TRM-student/export_coreml.py \
  --ckpt TRM-student/out/student.pt \
  --out TRM-student/out/StrokeRefineStudent.mlpackage
```
