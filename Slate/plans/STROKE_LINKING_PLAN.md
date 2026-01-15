# Stroke Linking Plan (Long‑Press Select → Add Link → Tap to Open)

This plan is written against the current Slate codebase in `/Slate/Slate` and assumes strokes/cards are already rendering + hit testing across depths via the 5×5 fractal cache.

---

## 0) Quick Index (Existing Code We’ll Build On)

**Stroke model + persistence**
- `Stroke.swift`: `Stroke` + `toDTO()` + `init(dto:device:)`
- `Serialization.swift`: `StrokeDTO` (currently has no link field)

**Hit testing (already cross‑depth)**
- `MetalCoordinator.swift`: `hitTestStrokeHierarchy(screenPoint:viewSize:)` (canvas + card strokes)
- `MetalCoordinator.swift`: `hitTestHierarchy(screenPoint:viewSize:)` (cards across depths)

**Gesture entry points**
- `TouchableMTKView.swift`: `handleTap(_:)` (finger), `handleCardLongPress(_:)` (finger long press)
- `MetalCoordinator.swift`: `handleLongPress(at:)` (currently: open card settings via `onEditCard`)

**Rendering**
- `MetalCoordinator.swift`: `renderDepthNeighborhood(...)` builds `visibleFractalFramesDrawOrder` + `visibleFractalFrameTransforms`
- `MetalCoordinator.swift`: `renderFrame(...)` draws grid, strokes, cards

---

## 1) Target UX (What the User Experiences)

### A) Long‑press to select strokes
1. User finger long‑presses on a stroke.
2. The stroke gets a **translucent yellow highlight** overlay.
3. Two **selection handles** appear (text‑selection style) so the user can expand selection to nearby strokes.
4. A floating context menu appears (when the user is not dragging a handle) with **one action**:
   - `Add Link`

### B) Expand selection with handles
- Dragging a handle expands the selection by “picking up” nearby strokes (v1: best‑effort, deterministic, performant).
- While dragging:
  - Highlight stays visible.
  - Context menu hides/dismisses.
- On release:
  - Context menu returns.

### C) Add a link
1. Tap `Add Link`.
2. A prompt appears that lets the user paste/type a URL.
3. On confirm, all selected strokes receive the link and **remain highlighted** (selection stays active).

### D) Dismiss + open
- Tap away (empty space / not on selected strokes):
  - highlight + handles + menu disappear (selection clears)
- Tap on a linked highlighted stroke:
  - opens the link

Optional follow‑up (not required by this plan, but recommended later):
- Show a subtle indicator for linked strokes even when not selected (so links are discoverable).

---

## 2) Data Model + Persistence (Required First)

### A) Add link storage to strokes
Add an optional link field to `Stroke`:
- Prefer storing as `String?` (easier to persist + tolerant of invalid URLs), with a computed `URL?` helper.
- Name suggestion: `var linkURLString: String?` or `var link: String?`

Key invariant:
- Any code path that “recreates” a `Stroke` (lasso transforms, resize, import normalization, etc.) must carry the link field forward.

### B) Update save schema (non‑breaking)
Update `Serialization.swift`:
- Add `let link: String?` to `StrokeDTO` (optional so old saves decode).

Update `Stroke.swift`:
- `toDTO()` includes `link`.
- `init(dto:)` reads `dto.link`.

### C) Reduce “forgot to copy field” bugs
Right now many places re‑init `Stroke(...)` directly (e.g. lasso translate/scale/rotate paths).
Add a small helper to centralize copying:
- `Stroke.copy(overrides...)` or `Stroke.rebuilding(origin:segments:localBounds:...)` that always preserves:
  - `id`, `color`, `zoomEffectiveAtCreation`, `depthID`, `depthWriteEnabled`, **link**

---

## 3) Selection State (Coordinator‑Owned, UI‑Driven)

### A) Introduce a dedicated “link selection” state
Create new file `StrokeLinkSelection.swift` (recommended) or keep this near the existing selection structs in `MetalCoordinator.swift`.

Suggested types:
- `struct LinkedStrokeRef {`
  - `enum Container { case canvas(frame: Frame), card(card: Card, frame: Frame) }`
  - `let container: Container`
  - `let strokeID: UUID`
  - `let depthID: UInt32` (optional; useful for stable ordering / “latest wins”)
  - `}`
- `struct StrokeLinkSelection {`
  - `var strokes: [LinkedStrokeRef]` (or grouped per frame/card like lasso does)
  - `var handleAActiveWorld: SIMD2<Double>`
  - `var handleBActiveWorld: SIMD2<Double>`
  - `var menuAnchorActiveWorldRect: CGRect` (computed)
  - `}`

Store on the coordinator:
- `var linkSelection: StrokeLinkSelection?`
- `var isDraggingLinkHandle: Bool`

### B) Coordinator API surface (so UIKit gestures stay small)
Add methods on `MetalCoordinator`:
- `func beginLinkSelection(at screenPoint: CGPoint, viewSize: CGSize)`
- `func clearLinkSelection()`
- `func extendLinkSelection(handle: HandleSide, to screenPoint: CGPoint, viewSize: CGSize)`
- `func addLinkToSelection(_ urlString: String)`
- `func openLinkIfNeeded(at screenPoint: CGPoint, viewSize: CGSize) -> Bool`
- `func linkSelectionContains(screenPoint: CGPoint, viewSize: CGSize) -> Bool` (for tap‑away dismissal)

Implementation notes:
- Use existing `hitTestStrokeHierarchy(...)` to “pick” strokes reliably across depths/cards.
- Keep selection stable by de‑duplicating by `strokeID` + container identity.

---

## 4) Rendering the Yellow Highlight (Metal)

### A) Goal
Draw a yellow translucent overlay *over* the stroke geometry without breaking batching.

### B) Approach (minimal CPU overhead)
In `MetalCoordinator.renderFrame(...)` (or immediately after the batched stroke pass for that frame):
1. Build a small list of **batched instances** for only the selected strokes in that frame.
2. Draw them with the existing batched stroke pipeline, but:
   - override fragment color to yellow (or set per‑instance color to yellow)
   - use slightly thicker width than the base stroke
   - depth writes off (so it overlays cleanly)
   - blending on (so it’s translucent)

Where this plugs in:
- After normal strokes/cards are drawn for a frame, do:
  - `renderLinkHighlightOverlay(for: frame, ...)`

Card strokes:
- If highlighting strokes that live in a card, keep using the existing stencil clip path so highlight stays inside the card.

### C) Width and opacity rules (to feel like selection)
- Color: `RGBA(1.0, 0.9, 0.0, 0.30–0.45)`
- Width: base + constant screen thickness:
  - `highlightWorldWidth = stroke.worldWidth + (desiredPx / zoomInFrame)`

---

## 5) Handles + Context Menu (UIKit overlay inside `TouchableMTKView`)

### A) Handles
Implement lightweight handle views as `UIView` subviews of `TouchableMTKView`:
- Two circular handles (start/end), high contrast, always on top.
- Each handle has a `UIPanGestureRecognizer`.
- While dragging:
  - set `coord.isDraggingLinkHandle = true`
  - call `coord.extendLinkSelection(handle:to:viewSize:)` continuously
  - hide menu
- On end/cancel:
  - set dragging false
  - re‑show menu

Handle positioning:
- Every frame (or on demand after camera changes), update handle screen positions:
  - Convert `handleAActiveWorld` / `handleBActiveWorld` → screen via `worldToScreenPixels(... panOffset/zoom/rotation ...)` in `MetalGeometry.swift`
  - Set handle views’ centers.

### B) Context menu
Preferred implementation:
- Use `UIEditMenuInteraction` (iOS 16+) attached to `TouchableMTKView`.
  - Provide a menu with one action: `Add Link`.
  - Present it anchored to the selection’s screen‑space rect.

Fallback (if needed):
- `UIMenuController` anchored to a `UIMenuController` target rect.

When to show:
- After `beginLinkSelection(...)`
- After handle drag ends

When to hide:
- When handle drag begins
- When selection clears

---

## 6) “Add Link” Flow (Paste Prompt → Apply to Selection)

### A) Prompt UI
On `Add Link`:
- Present a `UIAlertController(title: "Add Link", style: .alert)` with:
  - a text field
  - actions: Cancel / Add
- Prefill from clipboard if present:
  - `UIPasteboard.general.url?.absoluteString` (preferred)
  - else `UIPasteboard.general.string`

Validation:
- Accept bare domains by auto‑prefixing `https://` if no scheme.
- Store the raw string on the stroke.

### B) Apply link
`coord.addLinkToSelection(urlString)`:
- Resolve each selected stroke container and set `stroke.link = urlString`.
- Keep `linkSelection` intact so highlight persists until tap‑away.

Optional (future): push an undo action for link edits.

---

## 7) Tap Behavior (Dismiss or Open Link)

Update `TouchableMTKView.handleTap(_:)` to incorporate link selection:
Order of operations (recommended):
1. If a link selection exists:
   - If tap is outside selection → `coord.clearLinkSelection()` and return (don’t toggle card selection).
   - If tap hits a linked stroke in the selection → open link and return.
2. If no selection (or selection tap didn’t open):
   - If tap hits *any* linked stroke (via `hitTestStrokeHierarchy`) → open link and return.
3. Then proceed with existing logic:
   - lasso tap handling
   - card toggle
   - clear card selections

This preserves the “tap away dismisses selection” invariant without breaking existing card workflows.

---

## 8) Selecting “Nearby Strokes” While Dragging Handles (v1 Algorithm)

Keep it simple + predictable first:
- Each drag update:
  - run `hitTestStrokeHierarchy` at the handle location using a small radius (independent of brush size)
  - if it returns a stroke, add it to selection

Notes:
- This mirrors text selection: moving a handle “walks” the selection across nearby content.
- It’s cross‑depth automatically because `hitTestStrokeHierarchy` already consults `visibleFractalFramesDrawOrder`.

Future upgrades (if needed):
- Expand selection by selecting all strokes intersecting the capsule/rect defined by the two handles.
- Add hysteresis so a stroke doesn’t flicker in/out while dragging near edges.

---

## 9) QA / Acceptance Checklist

- Long‑press on a stroke highlights it yellow and shows 2 handles.
- Context menu appears when not dragging; contains `Add Link`.
- Dragging a handle hides the menu and expands selection to nearby strokes.
- After adding a link, selected strokes remain highlighted until tap‑away.
- Tap away clears highlight + handles + menu.
- Tap on highlighted linked stroke opens the URL.
- Export/import preserves stroke links (v2 files), and old files still import (link optional).
