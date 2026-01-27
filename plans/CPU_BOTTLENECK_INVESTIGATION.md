# CPU Bottleneck Investigation (Many Strokes Visible)

## Symptom
- When lots of strokes are visible, **GPU frame time stays low** but **CPU frame time spikes**.
- This pattern almost always means the CPU is spending time **building / encoding work** (draw calls, state changes, culling, data uploads), not that the GPU can’t shade fast enough.

## Primary Cause (Most Likely): Too Many Draw Calls / Encoder Work Per Frame

### What the renderer does today
- The render loop (`MetalCoordinator.swift:2011`) renders the visible 5×5 same‑depth neighborhood and then renders a **±6 depth window** for each base tile:
  - `renderDepthNeighborhood(...)` (`MetalCoordinator.swift:748`) renders:
    - up to `fractalStrokeVisibilityDepthRadius = 6` ancestors
    - the base frame
    - up to 6 descendant levels (culling tiles but still visiting all existing children in-range)
- Each frame is rendered via `renderFrame(...)` (`MetalCoordinator.swift:897`).

### Why this becomes CPU-bound
Inside `renderFrame(...)`, **every Stroke = at least one Metal draw call**:
- The code loops `frame.strokes` and for each stroke calls:
  - `encoder.setVertexBytes(...)`
  - `encoder.setFragmentBytes(...)`
  - `encoder.setVertexBuffer(segmentBuffer, ...)`
  - `encoder.drawPrimitives(... instanceCount: stroke.segments.count)`
  - (see the `drawStroke(...)` closure in `MetalCoordinator.swift:959`)

Even though each stroke draws via instancing (segments are instances), you’re still paying CPU cost per stroke because **each stroke is its own draw**.

This is exactly the failure mode you described:
- GPU stays happy because the shader work per segment is cheap and bandwidth is fine.
- CPU explodes because Metal command encoding overhead scales ~linearly with **number of strokes drawn**, multiplied by:
  - how many frames you render (5×5 tiles that exist)
  - the ±6 depth neighborhood window
  - cards and card-strokes being rendered similarly

### Back-of-napkin scaling
If you have:
- `F` frames rendered this frame (can be dozens with same-depth tiles + ±6 depth window)
- `S` strokes visible per frame

Then the CPU is likely doing **O(F × S)** draw calls per frame.

At a few thousand draw calls per frame, it’s common for CPU frame time to blow up while GPU stays low.

## Secondary Contributors (Also Real, but Usually Smaller Than Draw Calls)

### 1) Per-stroke CPU math for culling
Each stroke does multiple `sqrt` / bound computations:
- distance-to-camera and radius computations (`MetalCoordinator.swift:970`–`983`)
- These are small per stroke, but become meaningful once you have tens of thousands of strokes.

### 2) Depth neighborhood + recursion overhead
Even with tile-level culling, `renderDepthNeighborhood(...)` (`MetalCoordinator.swift:832`) recursively walks children and may visit a lot of frames if the tree is populated.
That multiplies the number of stroke loops and draw calls.

### 3) Per-card buffer allocations (if lots of cards)
Cards currently allocate a new `MTLBuffer` for the quad **every frame**:
- `device.makeBuffer(bytes: card.localVertices, ...)` in `MetalCoordinator.swift:1187`
This is a real CPU cost if many cards are on screen (not your main issue if the repro is “lots of strokes”).

## Why GPU Frame Time Can Stay Low While CPU Spikes
- Each stroke draw is “small” and the GPU is massively parallel.
- Metal draw-call submission has a non-trivial fixed CPU cost per draw/state change.
- If you’re drawing many strokes as many draws, you hit the classic “**CPU submit bound**” regime.

## How to Confirm Quickly (No Instruments Required)
1. Add counters to the debug HUD:
   - `framesRenderedThisFrame`
   - `strokesDrawnThisFrame`
   - `strokeDrawCallsThisFrame` (should ~= strokes drawn + card-stroke draws + overlay draws)
   - `segmentInstancesDrawnThisFrame` (sum of `stroke.segments.count`)
2. Correlate CPU frame time with draw-call count:
   - If CPU time rises ~linearly with draw calls, this is the culprit.

Note: `debugDrawnVerticesThisFrame` / `debugDrawnNodesThisFrame` are reset but never incremented currently (`MetalCoordinator.swift:907`), so the HUD won’t show draw growth yet.

## Remediation Directions (Ranked by Impact)

### A) Batch strokes to reduce draw calls (highest impact)
Goal: go from “1 draw per stroke” → “1–2 draws per frame”.

High-level approach:
- Build one (or two) big segment buffers per rendered frame:
  - one buffer for `depthWriteEnabled == true`
  - one buffer for `depthWriteEnabled == false`
- Change the segment instance format so each instance has everything the shader needs:
  - endpoints in *frame/world coordinates* (not stroke-local)
  - stroke width (or worldWidth)
  - depth value (derived from depthID)
  - color
- Then the vertex shader applies *one shared camera transform* for the entire frame:
  - subtract camera center
  - rotate
  - scale by zoom
  - project to NDC

This removes per-stroke `setBytes`/`drawPrimitives` overhead and replaces it with:
- one CPU pass to append visible segments into a buffer
- a single instanced draw call (or two, for write vs no-write)

### B) Reintroduce ICB / indirect draws (high impact, more complex)
There’s already a comment about ICB being removed (`MetalCoordinator.swift:25`).
ICB/indirect can reduce per-frame command encoding overhead by keeping draw commands persistent and updating only small per-stroke transform buffers.

### C) Improve CPU culling math (medium impact)
- Precompute stroke bounding radius in world space when the stroke is created (store in `Stroke`).
- Avoid `sqrt` by comparing squared distances where possible.
- Consider coarse spatial bins per frame (grid / quadtree) so “visible strokes” iteration is smaller than `frame.strokes.count`.

### D) Reduce the amount of content you render (medium)
- Make `fractalStrokeVisibilityDepthRadius` dynamic based on zoom or user setting.
- If CPU is the bottleneck, lowering ±6 to ±3 instantly cuts the number of frames rendered in half.

### E) Remove per-frame allocations (small→medium)
- Cache card quad vertex buffers (don’t allocate per card per frame).
- Ensure overlays/handles don’t allocate buffers repeatedly.

## Recommended Next Step
If you want, I can:
1. Add the missing per-frame counters to the debug HUD so we can see draw calls/segments in real time.
2. Prototype the “batched segments per frame” path behind a debug toggle to validate the CPU drop before a full refactor.
