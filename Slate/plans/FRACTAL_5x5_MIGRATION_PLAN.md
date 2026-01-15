# 5x5 Fractal Grid Migration Plan (from Telescoping Frames)

This plan is written against the current Slate codebase in `/Slate` and references the existing telescoping implementation so the migration work can be done incrementally and safely.

---

## 0) Quick Index (Current Code You’ll Be Replacing)

**Telescoping data model**
- `Frame.swift`: `Frame` = linked-list-ish bounded coordinate system using `originInParent`, `scaleRelativeToParent`, `children: [Frame]`, `depthFromRoot`.

**Telescoping transitions (zoom-driven)**
- `TouchableMTKView.swift`: `checkTelescopingTransitions`, `drillDownToNewFrame`, `popUpToParentFrame`.
  - Zoom in threshold: `> 1000.0`
  - Zoom out threshold: `< 0.5`

**Cross-frame rendering + transforms**
- `MetalCoordinator.swift`:
  - `renderFrame(_:cameraCenterInThisFrame:...)` renders parent/current/children
  - Cross-frame transforms assume a *linked list* child chain:
    - `childFrame(of:)` returns `frame.children.first`
    - `collectFrameTransforms`, `transformFromActive(to:)` only walk one descendant chain

**Persistence**
- `Serialization.swift`: `CanvasSaveData(version: 1)` and `FrameDTO` stores `originInParent`, `scaleRelativeToParent`, `depthFromRoot`, `children: [FrameDTO]`.
- `PersistenceManager.swift`: `restoreFrame` rebuilds the telescoping tree.

---

## 1) What We’re Building (Target Mental Model)

### A. Frames Become Tiles in an Infinite 2D World (Per Depth)
At any depth, the “world” is an infinite tiling of same-sized **Frames** (tiles). You can:
- **Pan forever** by walking tile-to-tile.
- **Zoom in** to enter a **child tile** inside the current tile.
- **Zoom out** to return to the **parent tile** containing the current tile.

### B. Every Frame Contains a 5×5 Grid of Children
Each frame contains **25 child slots** indexed by integers:
- `col, row ∈ {0,1,2,3,4}`
- Center tile is `(2,2)`
- Scale factor between parent and child is constant: `S = 5`

### C. Navigation is “Family-Based” (No Global Floats)
To find neighbors without global coordinates:
- **Sibling**: another child of the same parent (`(col±1,row)`).
- **Uncle**: parent’s neighbor in a direction (same depth as parent).
- **Cousin**: child of an uncle (what you enter after crossing a parent boundary).
- **Up, Over, Down** recursion resolves neighbors endlessly and sparsely instantiates missing nodes.

---

## 2) Key Design Decisions (Lock These Before Coding)

### A. Canonical Frame Size (World Units)
We need a *bounded* local coordinate domain per frame so coordinates never explode.

**Recommendation (practical, minimal disruption):**
- Define a constant frame extent in “world units” (the same units currently used everywhere: point/pixel-like coordinates).
- Example:
  - `frameExtentX = 4096.0`
  - `frameExtentY = 4096.0`
- A frame’s local coordinates live in:
  - `x ∈ [-frameExtentX/2, +frameExtentX/2]`
  - `y ∈ [-frameExtentY/2, +frameExtentY/2]`

Why:
- Keeps all math bounded and stable.
- Keeps the existing GPU transform + stroke math intact (world coordinates are still “points”, just bounded by tile swapping).

Alternative (if you want frame size = initial viewport size):
- Derive extents from `MTKView.bounds.size` at app start and persist them in save files.
- This matches “screen fills a tile at zoom=1” more literally, but couples saves to the device/aspect ratio.

### B. Normalized Zoom Range
To keep “how many tiles you can see” bounded, normalize zoom so you *never* zoom out so far that you need to draw dozens of same-depth tiles.

**Recommendation: keep `zoomScale` normalized to `[1, 5)`**
- If `zoomScale >= 5` → drill down (`zoomScale /= 5`)
- If `zoomScale < 1` → pop up (`zoomScale *= 5`)

This keeps the viewport ≤ one tile’s extent per axis, which makes same-depth neighbor rendering tractable (typically 2×2, worst-case 3×3 when rotated).

---

## 3) Data Model Changes (From Linked List → 5×5 Sparse Grid)

### A. Add Grid Types
Create:

```swift
struct GridIndex: Hashable, Codable {
  var col: Int // 0...4
  var row: Int // 0...4
}

enum Direction { case left, right, up, down }
```

### B. Refactor `Frame`
Current `Frame` fields to retire/replace:
- Retire: `originInParent`, `scaleRelativeToParent`, `depthFromRoot`, `children: [Frame]` (array)
- Add:
  - `weak var parent: Frame?` (keep)
  - `var indexInParent: GridIndex?` (nil for topmost root)
  - `var childrenByIndex: [GridIndex: Frame]` (sparse)
  - (Optional) cached neighbor refs if profiling says you need it

New invariants:
- A frame can have 0–25 children, uniquely addressed by `(col,row)`.
- Each child must have:
  - `child.parent === self`
  - `child.indexInParent == that slot`

### C. Constructors / Helpers to Add
Implement helpers on `Frame` (or a new `FractalFrameGraph` service) so the rest of the code never manually edits links:

- `func child(at index: GridIndex) -> Frame`
  - Creates child if missing (sparse instantiation).

- `func neighbor(_ dir: Direction) -> Frame`
  - Resolves same-depth neighbors using the “Up, Over, Down” algorithm.
  - Creates uncles/cousins as needed.
  - Creates a new **super-root** if recursion hits the top.

- `func ensureSuperRoot() -> Frame`
  - Creates a new parent and places `self` at `(2,2)` if `parent == nil`.

---

## 4) Core Math (All Integer Grid + Small Doubles)

### A. Parent ↔ Child Coordinate Transform (Scale = 5)
Let:
- `S = 5`
- `tileW = frameExtentX / S`
- `tileH = frameExtentY / S`

**Child tile center in parent coordinates**:
```text
centerX(col) = (col - 2) * tileW
centerY(row) = (row - 2) * tileH
```

**Parent → Child (point in parent space to child-local space)**:
```text
pChild = (pParent - childCenterInParent) * S
```

**Child → Parent**:
```text
pParent = childCenterInParent + (pChild / S)
```

### B. Locating Which Child Tile a Point Falls Into
Given a point `pParent` in the current frame (parent space), map to `(col,row)`:

```text
col = floor((pParent.x + frameExtentX/2) / tileW)
row = floor((pParent.y + frameExtentY/2) / tileH)
clamp to 0...4
```

Use the **gesture anchor** (`anchorWorld`) as the reference point so zoom transitions “center on finger” deterministically.

---

## 5) Algorithms (Zoom + Pan + Neighbor Resolution)

### A. Zoom In (Drill Down)
Trigger: `zoomScale >= 5`

1. Compute `index = childIndexForPoint(anchorWorld)`
2. `child = activeFrame.child(at: index)` (create if missing)
3. Convert anchor into child space:
   - `anchorWorld = (anchorWorld - childCenterInParent(index)) * 5`
4. `activeFrame = child`
5. `zoomScale /= 5`
6. Solve `panOffset` so the same `anchorScreen` maps to the new `anchorWorld`:
   - reuse `solvePanOffsetForAnchor_Double` (already correct and stable)

Loop steps 1–6 while `zoomScale >= 5` to handle “fast pinch” that jumps multiple levels in one gesture.

### B. Zoom Out (Pop Up)
Trigger: `zoomScale < 1`

1. Ensure parent exists:
   - if `activeFrame.parent == nil`: create super-root, place old top at `(2,2)`
2. Let `index = activeFrame.indexInParent!`
3. Convert anchor into parent space:
   - `anchorWorld = childCenterInParent(index) + (anchorWorld / 5)`
4. `activeFrame = parent`
5. `zoomScale *= 5`
6. Solve `panOffset` to keep `anchorScreen` pinned.

Loop while `zoomScale < 1`.

### C. Same-Depth Neighbor (Up, Over, Down)
Goal: return the adjacent frame at the same depth in a cardinal direction.

Pseudo-code:
```swift
func neighbor(_ frame: Frame, _ dir: Direction) -> Frame {
  guard let parent = frame.parent, let idx = frame.indexInParent else {
    // Hit top: expand universe upward, then retry.
    let superRoot = Frame()
    superRoot.childrenByIndex[GridIndex(col: 2, row: 2)] = frame
    frame.parent = superRoot
    frame.indexInParent = GridIndex(col: 2, row: 2)
    return neighbor(frame, dir)
  }

  let (dx, dy) = dir.delta
  let next = GridIndex(col: idx.col + dx, row: idx.row + dy)

  if next.col ∈ 0...4 && next.row ∈ 0...4 {
    return parent.child(at: next) // sibling
  }

  // Out of bounds → we need the parent’s neighbor (uncle).
  let uncle = neighbor(parent, dir) // recursion “Up”
  let wrapped = GridIndex(col: (next.col + 5) % 5, row: (next.row + 5) % 5)
  return uncle.child(at: wrapped)   // “Down” into cousin
}
```

This is exactly the “Edge of the World” recursion described in your summary, including the stop condition (super-root creation).

### D. Infinite Panning (Tile Swaps + Anchor-Safe)
We keep coordinates bounded by swapping `activeFrame` when the camera center exits the local tile extent.

Inputs:
- `cameraCenter = Coordinator.calculateCameraCenterWorld(viewSize:)` (already exists)
- `anchorWorld/anchorScreen` if a gesture owns an anchor (pan/pinch/rotation)

Logic:
1. While `cameraCenter.x > +frameExtentX/2`:
   - `activeFrame = activeFrame.neighbor(.right)`
   - `cameraCenter.x -= frameExtentX`
   - if anchoring: `anchorWorld.x -= frameExtentX`
2. While `cameraCenter.x < -frameExtentX/2`: (mirror for left)
3. Repeat for `y` with `frameExtentY` (up/down).
4. Re-solve `panOffset` using:
   - `anchorWorld` + `anchorScreen` if anchoring
   - else use screen center as the anchor (keeps cameraCenter stable)

Important: do this during:
- `handlePan` updates
- momentum updates (`CADisplayLink`)
- pinch/rotation updates (so a pinch near an edge doesn’t drift into huge coords)

---

## 6) Rendering Plan (What to Draw So Panning Never Shows “Void”)

The telescoping renderer (`renderFrame`) currently assumes parent/child depth layering, not same-depth tiling.

### Phase 1 (MVP): Draw Only the Active Frame
Get navigation correct first:
- Render only `activeFrame` content.
- Accept that at `zoomScale ≈ 1` you may see edges (no neighbor tiles yet).

### Phase 2: Draw Same-Depth Neighborhood (Recommended: 3×3)
To make panning seamless, render a neighborhood around the active frame:
- Offsets `dx,dy ∈ {-1,0,1}`
- For each offset:
  - resolve `frame(dx,dy)` using repeated `neighbor` calls
  - compute `cameraCenterInThatFrame = cameraCenterActive - (dx*frameExtentX, dy*frameExtentY)`
  - render that frame with that camera center

Implementation approach:
- Extract “draw strokes + cards for a single frame” into a `renderFrameContent(...)` helper.
- Keep the existing Metal pipeline and stroke code; just call the content renderer multiple times with adjusted camera centers.

### Phase 3 (Optional): Depth Preview (Parent/Children)
After panning is solid:
- Reintroduce depth layering *selectively* (not “render every child”):
  - When zoom is near 1, optionally render the most relevant child tiles (e.g., the tile under the camera center and its neighbors).
  - When zoom is near 5, optionally render the parent as background.

This avoids exploding draw calls as the tree grows.

---

## 7) Hit Testing & Interaction Plan (Cards/Lasso/Erase)

`MetalCoordinator` currently hit-tests a linked list depth chain (`childFrame(of:)`).
That must change because the fractal grid introduces:
- multiple children per frame
- same-depth neighbors

Recommended approach:
1. Build a `VisibleFrameSet` each frame (the same frames you render: active + 3×3 neighbors, optionally parent/child layers).
2. For each visible frame, keep a `(scale, translation)` mapping from **active-frame coordinates** → that frame.
   - Same-depth neighbors: `scale = 1`, `translation = (-dx*frameExtentX, -dy*frameExtentY)`
   - Parent/child: use the scale=5 formulas (plus same-depth translations as needed)
3. Replace `collectFrameTransforms` / `transformFromActive(to:)` with transforms derived from `VisibleFrameSet`.
4. Update:
   - `hitTestHierarchy(...)`
   - lasso selection / eraser targeting
   - card drag/resize conversions

MVP: hit-test only within `activeFrame`, then expand to visible neighbors.

---

## 8) Persistence (Save/Load) Plan

### A. New Schema (v2)
Update `CanvasSaveData.version` to `2` and store:
- `fractalScale = 5`
- `frameExtentX`, `frameExtentY` (if not hard-coded)
- `rootFrame: FrameDTOv2`

`FrameDTOv2` should include:
- `id`
- `indexInParent: {col,row}?` (nil at root)
- `strokes`, `cards`
- `children: [ChildDTO]` where `ChildDTO` is `{col,row,frame}`

Do **not** store explicit neighbors; they’re derivable from the tree.

### B. Backward Compatibility (v1 → v2)
Two options:

**Option 1 (Fast): break compatibility**
- Only load v2.
- Treat existing v1 saves as “legacy”.

**Option 2 (Recommended): one-time conversion**
- Load v1 telescoping tree into memory using the existing importer.
- Convert each telescoping `Frame` into a fractal `Frame`:
  - Place each former child into the closest `(col,row)` slot of its parent based on `originInParent`:
    - `col,row = childIndexForPoint(originInParent)`
  - Convert coordinates:
    - move strokes/cards into the new child with appropriate scale/translation (needs careful math)
- Save back out as v2.

Given telescoping frames can have arbitrary offsets, conversion is non-trivial; plan on doing this only if you truly need legacy files.

---

## 9) Step-by-Step Implementation Roadmap (Suggested Order)

### Step 1 — Add Core Types & Constants
- Add `GridIndex`, `Direction`, `fractalScale = 5`.
- Add `frameExtentX/Y` constants (or config stored in Coordinator).

### Step 2 — Introduce the New Frame Graph API
- Refactor `Frame` (or add `FractalFrame`) with `indexInParent` + `childrenByIndex`.
- Implement `child(at:)` and `neighbor(_:)` (Up/Over/Down + super-root expansion).
- Add debug utilities to print a frame’s “address” (path of indices up to root).

### Step 3 — Replace Telescoping Zoom Transitions
- In `TouchableMTKView.swift`, replace `checkTelescopingTransitions` with `checkFractalZoomTransitions`.
- Implement drill-down / pop-up loops (normalize zoom to `[1,5)`).
- Maintain anchor stability using existing `solvePanOffsetForAnchor_Double`.

### Step 4 — Add Pan Boundary Handling (Keep Coordinates Bounded)
- After any pan update (and during momentum), run `checkFractalPanTransitions`:
  - if cameraCenter exits `±frameExtent/2`, swap activeFrame to neighbor and wrap `cameraCenter` (and `anchorWorld` if needed).
  - re-solve `panOffset`.

### Step 5 — Rendering: Same-Depth Neighborhood
- Extract `renderFrameContent(...)` from `renderFrame(...)`.
- Render active + 3×3 neighbors using transformed camera centers.
- Keep recursion off initially (no parent/child layering).

### Step 6 — Interaction: Hit Test Visible Frames
- Build `VisibleFrameSet` (same as render list).
- Update hit testing and card interactions to use that set.

### Step 7 — Persistence v2
- Add v2 DTOs and versioning.
- Update export/import to use the new tree encoding.
- (Optional) v1 import conversion.

### Step 8 — Delete/Archive Telescoping-Specific Code
- Remove:
  - `originInParent`, `scaleRelativeToParent`, `depthFromRoot` usage
  - linked-list assumptions (`childFrame(of:)`)
  - telescoping docs in `ARCHITECTURE.md` (replace with fractal docs)

---

## 10) Manual Test Scenarios (Must Pass)

### A. Zoom Drill Test (No Coordinate Growth)
1. Start in root.
2. Zoom in repeatedly (crossing many depth levels).
3. Verify:
   - `anchorScreen` stays pinned (no jump)
   - camera remains stable (no jitter)
   - no large coordinate magnitudes accumulate in stroke origins

### B. The “Edge of the World” Scenario (Your Example)
1. Move to `(4,2)` at multiple consecutive depths.
2. Pan right.
3. Verify:
   - recursion climbs until it finds (or creates) an uncle
   - a cousin chain is created only along the needed shaft
   - you land in `(0,2)` at each unwind step

### C. Infinite Panning Stress
1. Pan right for ~60 seconds with momentum enabled.
2. Verify:
   - no precision artifacts appear
   - `activeFrame` changes as expected
   - memory growth is sparse/linear with traveled distance (not exponential)

### D. Rendering Seamlessness (After Neighborhood Rendering)
1. At zoom near 1, pan so the view overlaps tile boundaries.
2. Verify:
   - no “void” appears; adjacent tiles render.

---

## 11) Notes on Scope (What to Defer If Needed)

If you need an MVP quickly:
- Do zoom + pan transitions + bounded coords first.
- Render only active frame initially.
- Limit hit-testing to active frame.
- Add neighbor rendering + multi-frame hit-testing next.

