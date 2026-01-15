# Link Highlight Sections (V2) — Plan

This plan extends the current stroke-linking + highlight implementation so highlights behave like “text highlights”:

1) Dragging the selector over an already-selected stroke **toggles it off** (deselect).
2) Long‑pressing an existing highlight box shows a context menu to **remove that highlight section**.
3) Highlight sections are **distinct boxes** (no accidental merging/enlarging when creating a nearby section, even with the same URL).

Scope: `/Slate/Slate` (Swift + Metal). No deletion of legacy code; keep reference blocks commented where useful.

---

## 0) Current Implementation (What We’re Building On)

- Stroke link persistence
  - `Stroke.swift`: `var link: String?`
  - `Serialization.swift`: `StrokeDTO.link`
- Selection UI + “Add Link” prompt
  - `TouchableMTKView.swift`: one selection handle + `UIMenuController` + alert prompt
  - `MetalCoordinator.swift`: `linkSelection` state + selection bounds + link application
- Persistent highlight rendering
  - `MetalCoordinator.swift`: builds + draws rounded‑rect highlight boxes from linked strokes.

---

## 1) Data Model Upgrade: “Highlight Section” Identity (Fixes Box Merging)

### Problem
Right now persistent highlight boxes are grouped by URL string, so two separate highlight “sections” using the same URL collapse into one growing box.

### Solution
Introduce a stable identity per highlight section and group boxes by that identity, not by URL.

### Implementation
1) Add `linkSectionID: UUID?` to `Stroke`.
   - Keep `link: String?` as the URL payload.
2) Update persistence:
   - `Serialization.swift`: add optional `linkSectionID: UUID?` to `StrokeDTO` (non-breaking).
   - `Stroke.swift`: include in `toDTO()` and `init(dto:)`.
3) Rendering grouping key:
   - When accumulating persistent highlight bounds, use a key:
     - If `stroke.linkSectionID != nil`: group by that UUID.
     - Else if `stroke.link != nil`: group by a legacy key derived from the URL string (so old saves still render).
   - Recommended representation in code:
     - `enum LinkHighlightKey { case section(UUID); case legacy(String) }` (Hashable)

### Behavioral rule for new highlights
When the user taps “Add Link”, always create a **new** `linkSectionID = UUID()` and assign it to the selected strokes (even if the URL matches an existing one). This guarantees “different highlighted sections should be different boxes”.

---

## 2) Selection Toggle While Dragging Handle (Deselect on Re‑Hit)

### Goal
When dragging the selection handle:
- If the handle moves over a stroke that is already selected, that stroke should be removed from the selection.
- If it moves over a non-selected stroke, it should be added.

### Implementation
1) Add removal support to `StrokeLinkSelection`:
   - Add `mutating func remove(key: LinkedStrokeKey)` that updates both `keys` and `strokes`.
2) Add “hover gating” to prevent repeated toggles while staying over the same stroke:
   - In `MetalCoordinator.swift`, add a property like:
     - `private var linkSelectionHoverKey: LinkedStrokeKey? = nil`
   - In `extendLinkSelection(to:viewSize:)`:
     - Run the hit test.
     - If no hit: set hoverKey = nil.
     - If hitKey != hoverKey:
       - If selection already contains hitKey → remove it.
       - Else → insert it.
       - Set hoverKey = hitKey.
3) Empty selection behavior:
   - If selection becomes empty after a toggle, call `clearLinkSelection()` to dismiss handles/menu cleanly.
4) Keep the “snap handle to bounds” behavior after drag end.

---

## 3) Long‑Press a Highlight Box → Context Menu → Remove Section

### Goal
When the user long‑presses inside an existing persistent highlight box:
- Show a context menu with `Remove Highlight` (or `Remove Link`).
- If confirmed, remove the highlight section (clear link fields) for that section only.

### Implementation
1) Persist per-frame highlight boxes for hit testing:
   - While rendering (or during the same accumulation pass), keep a dictionary:
     - `highlightBoundsByKey: [LinkHighlightKey: CGRect]` in active-world space (padded, matching visuals).
2) Add coordinator hit test:
   - `func hitTestHighlightSection(at screenPoint:viewSize:) -> LinkHighlightKey?`
     - Convert screen→active world and check which padded rect contains the point.
3) Add UI plumbing for the menu:
   - `TouchableMTKView.swift`:
     - Add a new long-press path (or extend the existing one) that:
       - First checks `coord.hitTestHighlightSection(...)`.
       - If hit, present a menu anchored at the touch point with one action: `Remove Highlight`.
     - Track which section is being acted on (store `LinkHighlightKey` in the view).
4) Implement removal:
   - `MetalCoordinator.swift`:
     - `func removeHighlightSection(_ key: LinkHighlightKey)`
       - Traverse the full retained root (`rootFrame`) recursively:
         - Canvas strokes: clear `stroke.link` + `stroke.linkSectionID` for matches.
         - Card strokes: same.
       - Matching rules:
         - `.section(id)`: match `stroke.linkSectionID == id`
         - `.legacy(url)`: match `stroke.linkSectionID == nil && stroke.link == url`
5) Interaction priority:
   - On long press:
     - If in highlight box → show remove menu (do not start selection).
     - Else → existing behavior: begin link selection on stroke hit.

---

## 4) Prevent Existing Boxes From Growing When Creating a Nearby Section

This should fall out naturally from section IDs:
- New sections get new `linkSectionID`.
- Rendering groups by `linkSectionID` (or legacy bucket).
- Therefore, creating another section nearby cannot union into an older section’s box.

Edge cases to define:
- If the user selects strokes that are already part of a section and taps “Add Link”:
  - We should **reassign** them into the new section (override semantics).
  - Old section box shrinks accordingly.

---

## 5) Manual Verification Checklist

### Toggle selection
- Long-press to start selection on a stroke.
- Drag the handle across strokes A, B, C (they are added).
- Drag back across B again → B is removed from the selection.
- Drag off all strokes → no accidental repeated toggles.

### Remove highlight section
- Add a link to a selection.
- Tap away (selection clears) → persistent highlight box remains.
- Long-press inside the persistent box → menu appears.
- Tap `Remove Highlight` → box disappears; tapping those strokes no longer opens a link.

### Separate boxes (no merging)
- Create section 1 with URL `https://example.com`.
- Create section 2 nearby with the *same* URL.
- Expect: two separate highlight boxes (not one growing box).

