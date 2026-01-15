# Reducing Save File Size (JSON) — Brainstorm & Options

## Current State (Why files get huge)
Export currently uses `JSONEncoder` with:
- `.prettyPrinted` + `.sortedKeys` (`PersistenceManager.swift:22`)
- v2 schema that stores strokes as:
  - per-stroke metadata + `points: [[Float]]` (`Serialization.swift:80`, `Stroke.swift:254`)
- card images stored inline as `Data` (`CardContentDTO.image(pngData: Data)`), which becomes **base64 inside JSON** (`Serialization.swift:96`, `Card.swift:218`).

### Biggest size drivers
1. **Pretty-printed whitespace**
   - `points` arrays become hundreds of thousands of lines with indentation/newlines.
   - This can easily add **tens of MB**.
2. **Point encoding overhead**
   - Each point is `[x, y]` (nested arrays) → lots of `[` `]` plus commas + repeated float text.
   - Text floats are very expensive vs binary (e.g., `-0.0012345` is ~9–10 bytes for one value).
3. **Inline images as base64**
   - Base64 adds ~**33%** overhead over binary.
   - PNG/JPEG data is already “compressed-looking”, so gzip/LZFSE won’t shrink it much once base64’d.

## Option Set A — “Still JSON”, minimal code changes (fastest wins)

### A1) Stop pretty printing (instant, backwards compatible)
Change export to remove `.prettyPrinted`.
- Expected: noticeably smaller files + drastically fewer lines.
- Zero schema change; import stays unchanged.

Notes:
- Keep `.sortedKeys` only if you truly need stable diffs; it doesn’t help size.

### A2) Compress the JSON bytes after encoding (still a single file)
Keep JSON schema, but write **compressed bytes**:
- `.json.gz` (gzip) or `.json.lzfse` (LZFSE via Apple `Compression` framework).
- Expected: **very large** reduction for stroke-heavy files (often 5–20× smaller).
- Image-heavy documents shrink less (base64 PNG doesn’t compress well).

Tradeoffs:
- The exported file is no longer human-readable in a text editor.
- Import needs to detect compression + decompress before `JSONDecoder`.

Implementation sketch (conceptual):
- Export: `let json = encoder.encode(saveData)` → `compress(json)` → write bytes.
- Import: sniff header / UTType → `decompress(data)` → decode JSON.

### A3) “Compact JSON” toggle (UI-level)
Offer two export modes:
- **Human-readable**: prettyPrinted (debug)
- **Compact**: minified JSON (default)
This preserves your debugging workflow while avoiding giant files for normal usage.

## Option Set B — Schema tweaks that keep JSON human-readable

### B1) Flatten points to a single array
Instead of:
```json
"points": [[x0,y0],[x1,y1],...]
```
use:
```json
"points": [x0,y0,x1,y1,...]
```
Benefits:
- Removes 2 brackets per point → meaningful savings at scale.
- Still human-readable.

Cost:
- Requires a v3 schema or conditional decode in `StrokeDTO`.

### B2) Shorten keys (v3)
For stroke-heavy documents, key names add up. Example:
- `zoomCreation` → `z`
- `worldWidth` → `w`
- `depthWrite` → `dw`
- `origin` → `o`

This helps, but it’s secondary compared to point storage.

### B3) Drop per-stroke UUIDs (or compress them)
UUID strings are 36 bytes + quotes.
If you don’t need stable IDs across sessions, you can:
- omit `id` entirely and reconstruct on import, or
- store IDs as `Data` (16 bytes) (still base64 in JSON), or
- store as an integer sequence within a frame.

This is a medium win if you have *huge* stroke counts.

## Option Set C — Keep JSON, but store large arrays as binary blobs (best “JSON-compatible” size win)

### C1) Store points as base64-encoded binary instead of float text
Replace `points: [[Float]]` with something like:
- `pointsFormat: "f32le"` (or `"i16q"` etc)
- `pointsData: Data` (base64 in JSON)

Binary packing options:
1. **Float32**: 8 bytes per point (x,y), base64 → ~10.7 bytes/point.
2. **Float16**: 4 bytes per point, base64 → ~5.3 bytes/point (needs careful precision validation).
3. **Quantized Int16**: 4 bytes per point after scaling, base64 → ~5.3 bytes/point.

This usually beats textual floats by a lot, and it reduces decode time too.

### C2) Delta encoding + varint (even smaller, less readable)
Stroke points are highly correlated; deltas are small.
Pipeline:
1. Quantize `x,y` to ints using a known scale (ex: 1/1024 world units).
2. Delta encode vs previous point.
3. ZigZag encode signed deltas.
4. Varint pack.
5. Store the resulting bytes as `Data` in JSON (base64).

This can get extremely small for smooth strokes, but is more complex to implement/debug.

## Option Set D — New container format (recommended long-term)

### D1) `.slate` = ZIP container (JSON manifest + binary payloads)
Use a zip container (common pattern: like `.docx`, `.pages`, `.usdz`, glTF split JSON/BIN).

Example layout:
- `manifest.json` (small; frames, cards, stroke metadata, references)
- `strokes.bin` (binary packed points for all strokes, with offsets/lengths)
- `images/<cardID>.png` (raw PNG bytes, no base64 overhead)

Benefits:
- Removes the base64 penalty for images (big win for image-heavy docs).
- Allows fast streaming load (read only needed blobs).
- Manifest stays human-inspectable.

Tradeoffs:
- More code and a new export/import path.
- Need a custom `UTType` and `FileDocument` content types (instead of plain `.json`).

## Practical Recommendation (stepwise)

### Step 1 (do now): Compact JSON export
- Remove `.prettyPrinted`.
- Optional: keep `.sortedKeys` off unless you need stable diffs.

### Step 2 (low risk, big size): Add compressed export/import
- Add `.json.gz` or `.slatejson.lzfse` as an export option.

### Step 3 (best overall): v3 container
- Add `.slate` zip format:
  - JSON manifest
  - binary blobs for stroke points
  - binary files for images

### Step 4 (optional): quantization/delta encoding
- If you still need smaller sizes, implement per-stroke point blob compression.
- Validate visually (especially at extreme zoom) before shipping.

## Notes on expected savings (rough intuition)
- **Removing prettyPrinted**: often 2–5× smaller for stroke-heavy files (and far fewer lines).
- **Gzip/LZFSE** (stroke-heavy): commonly 5–20× smaller total.
- **Inline base64 images**: don’t compress much; best fixed by a container (D1).
- **Binary point blobs** (C1/C2): can reduce stroke data size by several× even before gzip.

## Review: Your existing compression code (Compendium)
File: `/Users/pennymarshall/Documents/Compendium/Compendium/Storage/Compression.swift`

### What it does
- Uses Apple’s `Compression` framework (`compression_encode_buffer` / `compression_decode_buffer`).
- Default algorithm is `.zlib`.
- Adds:
  - `PKDrawing.compressedDataRepresentation()` which compresses `PKDrawing.dataRepresentation()`.
  - `Data.compressed(...)` / `Data.decompressed(...)` helpers.

### Would this help Slate saves?
Yes — the *idea* is exactly Option Set A2 from above: encode JSON → compress bytes → write compressed file. For stroke-heavy documents, zlib/LZFSE compression typically shrinks very well because:
- JSON has lots of repetition (`"points"`, brackets, commas, similar float prefixes, etc.).
- Stroke point sequences are highly redundant.

However:
- It won’t meaningfully fix **inline base64 images** (your `CardContentDTO.image(pngData: Data)`), because base64 is already “random-looking” text and PNG is already compressed.
- For image-heavy docs, a container format (zip with raw PNG files) is still the best path.

### Important: the current implementation likely doesn’t work reliably as written
Two issues in `Compression.swift`:
1. **`reserveCapacity` doesn’t allocate writable elements**
   - `destinationBuffer.reserveCapacity(bufferSize)` does *not* change `destinationBuffer.count`.
   - `withUnsafeMutableBufferPointer` sees `count == 0` and `baseAddress == nil`.
   - The code force-unwraps `destBuffer.baseAddress!`, which will crash or be invalid.

2. **Fixed output sizing (`*2` for compress, `*10` for decompress) is not robust**
   - Compression output can be slightly larger than input in worst cases (rare for JSON but possible).
   - Decompression output can exceed `compressedSize * 10` depending on the content and algorithm.
   - When the buffer is too small, `compression_decode_buffer` returns `0` (failure).

So: the algorithm choice is good, but the helper needs a proper allocation/loop strategy.

### What I’d reuse from it (for Slate)
- Keep the same **Compression.framework** approach (zlib or, better on Apple platforms, **LZFSE** for speed + good ratio).
- Rewrite the helper using either:
  - `compression_stream` (streaming; safest for unknown output sizes), or
  - allocate an output `[UInt8](repeating: 0, count: estimatedSize)` and retry with a larger buffer on failure (simple but less elegant).

### File-format recommendation if you use this
- Don’t write compressed bytes as `.json` (it won’t be valid JSON).
- Prefer:
  - `.json.gz` (standard gzip header; easiest interoperability), or
  - a custom `.slatejson` with a tiny header (magic + algorithm + uncompressed length), or
  - the longer-term `.slate` zip container.

