# Section Functionality Plan (Lasso → Create Section → Group + Link)

This plan is written against the current Slate codebase in `/Slate/Slate` (5×5 fractal frames, cross‑depth rendering/hit testing, stroke linking already implemented).

The goal is to add **Sections** as first‑class grouping objects so we can ship the homepage “idea map” next.

**Update (Jan 2026):** Sections no longer *own* strokes/cards. Strokes and cards remain stored on `Frame.strokes` / `Frame.cards`
and carry an optional `sectionID` (UUID) referencing a Section (which may live in an ancestor frame). This enables cross‑depth
membership (e.g. Section created at depth 1 can include strokes drawn at depth 2 if they fall within its bounds).

---

## 0) Clarifying Questions (Please Answer Before Implementation)

1) **Overlaps / nesting**
- Can Sections overlap or be nested?
- If multiple Sections contain the same point, which one “wins” for **new strokes/cards** (topmost by z‑order, smallest area, newest created, or disallow overlaps)?

2) **Membership rules**
- If a stroke/card that belongs to a Section is later moved **outside** the Section bounds (lasso move/resize), should it:
  - A) automatically move back to the Frame (unsectioned),
  - B) stay in the Section until manually removed,
  - C) prompt?

3) **Rendering order**
- You wrote “Sections only below strokes” but also want an opaque name box. Should the **name label** render:
  - A) below strokes (so strokes can cover it), or
  - B) above strokes but below cards (recommended for readability)?

4) **Section visibility**
- Fill alpha: do you want Sections to be strictly transparent (alpha 0) with only a border + label, or keep the **semi‑transparent fill** you described?
- Border thickness: constant screen px, or scale with zoom like content?

5) **Create Section eligibility**
- Can the user create a Section when the lasso contains **no items** (just a region), or only if it captures ≥ 1 stroke/card?

6) **Link destination UI**
- For “Add Link”, do you want:
  - A) “Paste URL” + “Link to Section…” + “Link to Card…” (search picker), or
  - B) one unified picker that includes Sections, Cards, and URLs?

7) **Tap behavior**
- When tapping a linked highlight:
  - Section/Card link should **teleport** camera to the destination, correct?
  - Should it also **flash** / temporarily highlight the destination Section/Card?

8) **Names are mandatory**
- For existing canvases with existing cards: is it acceptable to auto‑name missing names as `Untitled` (and allow rename later), or should we force a naming pass?

9) **Cross‑canvas / “floating” Sections**
- You mentioned Sections may have `canvasId: nil` and “float as idea islands”. Should we support creating those now, or is that strictly a homepage‑only concept later?

---

## 1) Quick Index (Existing Code We’ll Build On)

**Core containers**
- `Frame.swift`: `Frame.strokes`, `Frame.cards`, `Frame.sections`, `Frame.children`
- `Stroke.swift`: `Stroke.sectionID` + link fields (`link`, `linkSectionID`)
- `Card.swift`: `Card.name`, `Card.sectionID`

**Rendering + hit testing**
- `MetalCoordinator.swift`: `renderFrame(...)`, depth neighborhood renderer, lasso, cross‑depth hit testing, stroke link selection/highlight
- `TouchableMTKView.swift`: long‑press selection UI + context menus (UIMenuController)

**Persistence**
- `Serialization.swift`: `CanvasSaveDataV2`, `FrameDTOv2`, `StrokeDTO`, `CardDTO`
- `PersistenceManager.swift`: import/export, v1→v2 normalization

---

## 2) Definitions (What a Section Is vs a Card)

### Section
- A **transparent grouping region** defined by a lasso polygon in a specific `Frame`.
- Membership:
  - canvas strokes/cards stay on frames and reference the section via `Stroke.sectionID` / `Card.sectionID`
- Renders **below strokes** (fill/border), but label placement is TBD (see Q3).
- Exists to power:
  - knowledge structure (“Programming Languages” contains “Swift”)
  - homepage graph nodes (Section bubbles)

### Card
- A **context container** (image/grid/lined/solid already exist; future: gif/tweet/youtube/text/recording).
- Always renders **above all strokes** (already true).
- Can be linkable as a whole, and can also contain linkable strokes inside it.

---

## 3) Data Model Additions (vNext)

### A) Introduce `Section`
Add a new model file (recommended): `Section.swift`

Suggested core fields (canvas‑local):
- `id: UUID`
- `name: String` (required)
- `color: SIMD4<Float>` (used for border + fill tint)
- `fillOpacity: Float` (or computed constant)
- `polygon: [SIMD2<Double>]` (in **frame coordinates**)
- `bounds: CGRect` (cached AABB in frame coords for culling + quick hit tests)
- `tags: [Tag]` (can be stubbed initially)

### B) Add `name` to `Card`
Extend `Card`:
- `var name: String` (required)
- `var sectionID: UUID?` (optional membership reference)
- (optional future) `var tags: [Tag]`
- (optional future) `var linkTarget: LinkTarget?` for linking the whole card

### C) Shared “Linkable Node” metadata (homepage)
You provided a target structure:
```
id: String
name: String
strokeCount: Int
canvasId: String?
references: [String]
tags: [Tag]
```
Plan: treat this as a **derived index layer** we can compute from runtime models:
- Section node: `strokeCount = count(strokes where stroke.sectionID == section.id)` (+ optionally include card-local strokes)
- Card node: similar (if cards participate in the homepage graph)
- `references`: derived from links found on strokes/cards inside the node

We can store this index:
- either computed on demand for the homepage,
- or persisted as a separate cache (optional).

---

## 4) Persistence / Save Schema

### A) Add `sections` to frames (new save version)
Update `Frame`:
- `var sections: [Section] = []`

Update DTOs in `Serialization.swift`:
- Add `SectionDTO`
- Add `sections: [SectionDTO]` to `FrameDTOv2`

Versioning:
- Bump save version to `3` (recommended) **or** keep `version: 2` and make `sections` optional.
- Prefer v3 so we can:
  - add card names cleanly,
  - add link targets cleanly,
  - keep migrations explicit.

### B) Migration strategy
- v2 save (no sections, no card names):
  - set `sections = []`
  - auto‑name cards (e.g. `Image`, `Grid`, `Untitled`) and mark renameable later
- v1 telescoping:
  - continue current v1→v2 normalization
  - then apply v2→v3 naming defaults

---

## 5) Creating a Section (UX + Data Movement)

### A) Lasso finish → context menu
When lasso selection completes:
- Show a context menu item: `Create Section`
- Only show when:
  - lasso polygon is valid (≥ 3 points)
  - AND (depending on Q5) it either:
    - contains at least one stroke/card, or
    - always allowed to create an empty section region

### B) Prompt for name + color
On `Create Section`:
- Prompt for `name` (required)
- Allow choosing a color (MVP: reuse a small palette, later full picker)

### C) Determine captured items
For each candidate item in the active frame neighborhood (likely the active frame only for MVP):
- Stroke inclusion rule (pick one):
  - origin point inside polygon (fast)
  - AABB intersects polygon (more accurate)
  - any segment intersects polygon (expensive; not recommended for MVP)
- Card inclusion rule:
  - card origin inside polygon (fast)
  - rotated card AABB intersects polygon (better)

### D) Move ownership from Frame → Section
Once captured sets are determined:
- Remove strokes/cards from `frame.strokes` / `frame.cards`
- Set `stroke.sectionID = section.id` / `card.sectionID = section.id`
- Append the new `section` to `frame.sections`

### E) Automatic capture for new content
On stroke commit / card creation:
- Resolve container at the creation point:
  - inside a card → card stroke (existing)
  - else inside a section → section stroke/card
  - else → frame stroke/card

This requires a new hit‑test helper:
- `func sectionContaining(pointInFrame: SIMD2<Double>) -> Section?`
  - AABB precheck → point‑in‑polygon
  - deterministic tie‑break for overlaps (Q1)

---

## 6) Rendering (Section Shape + Label)

### A) Where sections render in the pipeline
Recommended order per frame:
1. **Section fills** (semi‑transparent)
2. **Section borders** (opaque)
3. **Canvas strokes** (frame + section strokes)
4. **Cards** (frame + section cards)
5. Existing overlays (link highlights, lasso preview, etc.)

If Q3 says label should be above strokes:
- draw label after strokes but before cards.

### B) How to draw the lasso polygon
We need fill + border:
- Fill: triangulate polygon (ear clipping; no external deps)
- Border: polyline rendered as:
  - either a thin “stroke” built from edges using the existing stroke segment pipeline,
  - or a dedicated simple line pipeline (optional).

We should also simplify the lasso polygon before storing:
- Ramer–Douglas–Peucker or distance‑threshold resampling
- helps performance + reduces JSON size

### C) Name label
Two implementation options (pick based on perf + complexity):
1) UIKit overlay labels in `TouchableMTKView` (fast to implement; OK if few visible)
2) Render text into a texture (CoreText → CGImage → MTLTexture) and draw as a small card‑quad

Either way:
- label background is opaque (section color at 100% alpha or white), text black.

---

## 7) Hit Testing + Editing Interactions

### A) Hit testing must traverse Sections
Update cross‑depth hit testing to consider:
- strokes in `frame.sections[*].strokes`
- cards in `frame.sections[*].cards`

This impacts:
- lasso selection capture
- eraser hit testing
- link selection hit testing
- card selection/editing

### B) Lasso + “ownership updates” after transforms
When user moves/resizes via lasso:
- After applying transforms, optionally re‑evaluate container membership (Q2).
- If we choose dynamic membership:
  - moved items can migrate between Sections or back to Frame.

---

## 8) Linking: Sections ↔ Cards (No Stroke↔Stroke)

### A) Link target model
We should evolve the current `Stroke.link: String?` into a typed destination:
- `enum LinkTarget { case url(String), section(UUID), card(UUID) }`

Migration compatibility:
- Keep storing as string in JSON initially, using a stable internal scheme:
  - `slate://section/<uuid>`
  - `slate://card/<uuid>`
  - external URLs remain `https://...`

### B) “Add Link” UX (selection anchor → choose destination)
Current flow supports pasting a URL.
Extend to support internal links:
- `Add Link…` opens a sheet/picker with:
  - Search Sections by name
  - Search Cards by name
  - Paste external URL

When link is applied:
- The selected highlight box persists (existing behavior)
- The destination reference becomes discoverable for homepage graph edges

### C) Tap to navigate
On tap of linked highlight:
- if external URL → open via `UIApplication.open`
- if internal section/card:
  - find the destination entity (by id) in the frame tree
  - set `activeFrame` appropriately
  - adjust camera to center on destination bounds/origin

---

## 9) Homepage Graph Support (Post‑Sections, Pre‑Homepage)

Once Sections exist, we can build a lightweight index for the homepage:
- Nodes:
  - Canvas (the drawing file)
  - Sections (within canvas)
  - (optional) Cards, if you want them as first‑class bubbles
- Edges:
  - A → B if any stroke/card inside A links to B
- Visual styling:
  - tags → colors/gradients (Inside‑Out “emotion orb” idea)

This plan sets us up by ensuring:
- everything has a stable `id`
- everything has a `name`
- links are explicit + machine‑readable

---

## 10) Future Card Types + Aspect Ratio Rules (Not Required For Sections MVP)

### A) GIF cards
- Search/selection UI: `SwiftyGiphy`
- Playback/display: `FLAnimatedImage` (or modern alternatives if preferred)
- Resizing: locked to media aspect ratio

### B) Tweet embed cards
- Follow X/Twitter iOS embed guidance (per linked blog)
- Store: tweet id + cached preview
- Resizing: locked aspect ratio

### C) YouTube embed cards
- `YouTubePlayerKit`
- Store: video id + playback state
- Resizing: locked aspect ratio

### D) Text cards
- `MarkupEditor`
- Store: markdown/html + style
- Resizing: freeform or content‑aware (needs decision)

### E) Voice recording cards
- Store: audio file reference + waveform preview
- Resizing: **always fixed aspect ratio** (per your rule)

Dependency note:
- This repo currently runs with network access restricted; adding SPM packages is doable later but should be a dedicated step (with approval).

---

## 11) Acceptance Criteria (Sections MVP)

- Lasso selection finish shows `Create Section`.
- Creating a section prompts for **name** (required) and a color.
- Captured strokes/cards are removed from `Frame` and stored in `Section`.
- New strokes/cards created inside section bounds are stored in that Section.
- Section renders as a colored region (fill + border) and shows its name label.
- Hit testing + lasso + eraser + linking continue to work for items inside Sections.
- Export/import preserves Sections and names (with migration defaults for old saves).
