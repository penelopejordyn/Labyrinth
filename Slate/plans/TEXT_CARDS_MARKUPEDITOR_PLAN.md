# Text Cards (MarkupEditor) — Feasibility + Implementation Plan

Goal: add a new **Text Card** type that supports WYSIWYG rich‑text editing using **MarkupEditor**, with:
- Default **transparent** card background (but user can change it)
- Canvas-native feel (no “sheet” UI)
- Works with existing fractal frames / zoom / pan / rotation / export‑import

---

## Feasibility Summary

### 1) Metal rendering vs. WKWebView reality
- MarkupEditor is a `WKWebView` + JavaScript (ProseMirror) editor.
- Our canvas is rendered in **Metal** (`MTKView`). Metal cannot directly render an interactive `WKWebView`.
- **Feasible approach:** hybrid rendering (same as YouTube embeds):
  - **Metal** renders a cached preview of the text card (texture) + optional background.
  - A **single** active `MarkupEditorUIView` is overlaid as a UIKit view only when the user is editing that text card.

This matches how the app already uses “UI overlays that track world transforms” (name editing text fields, link handle, floating menus).

### 2) Performance constraints
- `WKWebView` is heavy; multiple simultaneously active editors will be expensive.
- **Feasible policy:** only one active editor overlay at a time.
- Non‑active text cards render as cached textures (fast) rather than live web views.

### 3) “Transparent background” feasibility
- Cards currently don’t have a separate “background alpha”; they have:
  - `card.backgroundColor` (RGB, alpha currently treated as opaque by UI)
  - `card.opacity` (applies to the whole card)
- If we use `card.opacity` for background transparency, the text preview would also become transparent, which is not what we want.
- **Feasible approach:**
  - Treat `card.backgroundColor.w` as background alpha for text cards.
  - Keep `card.opacity = 1.0` for the card itself.
  - Render the text preview as a texture with transparent background (text only).
  - Render the background as a separate solid pass underneath the preview texture.

This yields: background can be transparent while text stays fully opaque.

### 4) Rotation + camera rotation feasibility
Cards can rotate (`card.rotation`) and the camera can rotate (`rotationAngle`).
- If we overlay the editor only as an axis-aligned rect, it will drift/mismatch when rotation is involved.
- **Feasible (but more complex):** rotate the overlay view by the same angle used by Metal:
  - `finalRotation = cameraRotation + card.rotation`
  - Place the overlay at the card center in screen coordinates
  - Set overlay bounds to (cardSize * zoomInFrame)
  - Apply `CGAffineTransform(rotationAngle: finalRotation)` + corner radius

If we want a simpler MVP: forbid rotation for text cards (force `card.rotation = 0`), but that’s a product decision.

---

## Clarifying Questions (important before implementation)

1) **Preview fidelity:** When not editing, should the text card preview match MarkupEditor’s styling exactly?
   - Options:
     - A) Fast: render plain text extracted from HTML (good MVP, but not identical to editor)
     - B) Better: render HTML → `NSAttributedString` → texture (medium fidelity)
     - C) Best: offscreen `WKWebView` snapshot to texture (highest fidelity, heaviest)
2) **Toolbar UX:** Do you want the MarkupEditor toolbar visible while editing?
   - A) No toolbar (keyboard shortcuts only) — simplest but weak on iPad
   - B) Use MarkupEditor’s toolbar inside the overlay (may exceed card bounds)
   - C) Use our existing floating menu style to host a minimal toolbar (best UX, most work)
3) **Scroll behavior:** If text exceeds the card bounds, should the card scroll internally, or should it auto-grow?
4) **Local images + tables:** Enable MarkupEditor local images/tables now, or keep MVP to text + lists + links?

---

## Proposed Implementation Plan (incremental, feasibility-first)

### Phase 0 — Add dependency + verify it can load
1) Add `MarkupEditor` via Swift Package Manager in Xcode.
2) Create a tiny scratch view controller to instantiate `MarkupEditorUIView` to ensure:
   - `WKWebView` loads resources (`markup.html`, `markup.js`, CSS)
   - no console spam / process termination loops

### Phase 1 — Data model + persistence (no UI yet)
1) Extend `CardType` with a new case, e.g.:
   - `.text(html: String)`
2) Extend `CardContentDTO` with:
   - `case text(html: String)`
3) Update export/import:
   - Encode/decode the HTML string.
4) Add optional cached preview storage decision:
   - MVP: do **not** store preview texture in JSON (regenerate lazily).

Feasibility: straightforward; matches how `CardContentDTO` handles `.image/.grid/.lined`.

### Phase 2 — Rendering: background + preview texture
1) Add `TextCardPreviewCache`:
   - Key: `card.id` (or hash of html)
   - Value: `MTLTexture` (text preview image)
2) Pick preview generation strategy (based on answers):
   - A) Plain text draw (fastest MVP)
   - B) `NSAttributedString` from HTML → draw into `UIGraphicsImageRenderer`
   - C) Offscreen `WKWebView` snapshot (most faithful, slowest)
3) Update Metal card render switch:
   - For `.text` cards:
     - Pass 1: draw solid background using `card.backgroundColor` (alpha allowed)
     - Pass 2: draw preview texture quad (like `.image`) on top

### Phase 3 — Creation UI (making a text card)
1) Add a “Text” option to the existing `CardSettingsFloatingMenu` type segment (or a new “+ Card” flow):
   - Default content: `"<p></p>"` (or `"<h1></h1>"` etc)
   - Default background alpha = 0 (transparent)
2) Immediately generate a preview texture for the default html (or show a placeholder “Tap to edit”).

### Phase 4 — Editing overlay (MarkupEditorUIView on top of the canvas)
1) Add a single overlay manager in `TouchableMTKView`:
   - `activeTextCardID`
   - `activeTextEditorView: MarkupEditorUIView?` (or the underlying `MarkupWKWebView`)
2) Activation:
   - Tap a text card → mount overlay and focus the editor.
3) Per-frame reposition:
   - Add `updateTextCardEditorOverlay()` called from the same place overlays are updated every frame.
   - Compute:
     - card center in screen coordinates
     - size in screen points (`card.size * zoomInFrame`)
     - apply rotation transform (if supporting rotation)
4) Dismissal:
   - Tap away → call `getHtml()` from the active `MarkupWKWebView`, store into the card, regenerate preview texture, remove overlay.

### Phase 5 — Background customization for text cards
1) Default: transparent background (alpha = 0).
2) Let users change the background color via existing card background palette:
   - If needed, enable alpha support for `backgroundColorWell` for text cards (`supportsAlpha = true`).
3) Ensure label box text remains readable regardless of background.

### Phase 6 — Interaction conflicts + safety
1) While the text editor overlay is active:
   - Disable canvas pan/rotation/pinch gestures when touch is inside the editor rect (gesture delegate checks).
   - Pencil drawing should not draw on the canvas when editing a text card (decide policy).
2) When moving/resizing a text card:
   - Option A (simplest): hide editor overlay until gesture ends.
   - Option B: keep editor following live (more complex).

### Phase 7 — Quality + edge cases
1) Ensure exporting/importing a canvas preserves text cards.
2) Ensure previews rebuild lazily after import.
3) If `WKWebView` process is terminated:
   - reload editor and keep card content safe.
4) Performance:
   - throttle preview regeneration (debounce typing; regenerate preview on “done” / tap-away).
