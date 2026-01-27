# Handwriting refinement MVP (teacher → student distillation)

This folder follows `plans/handwriting refinement plan.md`.

## What lives where

- `refine_mvp/scripts/`: dataset prep + teacher distillation scripts (Phase 1)
- `TRM-student/`: student model training + CoreML export (Phases 2–3)
- `deepwriting-teacher/`: DeepWriting codebase (teacher, offline only)

## IAM corpus input

Point streams are expected as JSON with:

```json
{ "version": 2, "points": [[dx, dy, p], ...], "norm": { "mean_dx": ..., "std_dx": ..., "mean_dy": ..., "std_dy": ... } }
```

Where:
- `p=1` marks the first token of a stroke (stroke start)
- stroke-start tokens have `dx=0, dy=0` *before* any normalization

## Teacher distillation (Phase 1.5 / 1.6)

DeepWriting runs as an **offline** teacher via a persistent subprocess (`deepwriting_infer_server.py`).

Build distillation shards:

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

Notes:
- Stroke boundaries are kept fixed: `p` is copied from input → output.
- Stroke-start tokens are forced to `[0,0,1]` (no teleport moves).

## Student deps (Phases 2–3)

See `refine_mvp/requirements-student.txt` and `TRM-student/README.md`.
