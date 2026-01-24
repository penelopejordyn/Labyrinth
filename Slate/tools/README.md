# Tools

## RNN normalization

Export `rnn_strokes.json` files from the app, then compute dataset-wide normalization stats and (optionally) write normalized copies:

- Stats only: `python3 tools/rnn_normalize.py path/to/exports/*.json --stats rnn_stats.json`
- Normalize + write: `python3 tools/rnn_normalize.py path/to/exports/*.json --out-dir normalized --stats normalized/rnn_stats.json`

`p` is preserved; only `dx/dy` are standardized using the global mean/std computed across all input points.

## Build IAM corpus

Convert IAM `lineStrokes/` XML into normalized per-file JSON under `corpus/`:

- `python3 tools/build_rnn_corpus_from_linestrokes.py --input-root /Users/pennymarshall/Downloads/lineStrokes --output-root corpus --overwrite`

This writes `corpus/rnn_stats.json` and preserves subfolders (e.g. `corpus/a01/a01-000/a01-000u-01.json`).
