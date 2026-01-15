# GIF Cards (FLAnimatedImage + Giphy Search) — Feasibility + Implementation Plan

Goal: add a new **GIF Card** type that can display animated GIFs efficiently (multiple at once), with a Giphy-powered search/selection UI, and locked aspect ratio to the GIF’s intrinsic size.

---

## Feasibility Summary

### 1) Metal renderer vs. animated image reality
- The canvas is rendered via **Metal** (`MTKView`), but **FLAnimatedImage** renders via **UIKit** (`FLAnimatedImageView`).
- Rendering an animated GIF inside Metal would require decoding frames and uploading textures continuously (custom pipeline).
- **Feasible approach (recommended):** hybrid overlay approach:
  - Metal renders the card background/border/name like normal.
  - A `FLAnimatedImageView` is overlaid above the `MTKView`, positioned/rotated/scaled to match the card’s on-screen transform.

This is consistent with existing overlay patterns in the app (inline name fields, link handle, floating menus).

### 2) “Multiple GIFs simultaneously” is feasible, but needs guardrails
FLAnimatedImage is designed for multiple concurrent GIFs, but we still need to protect the app:
- Too many visible GIF cards + continuous per-frame repositioning can become CPU heavy.
- **Feasible policy options:**
  - A) **Animate all visible GIF cards** (best UX, highest risk)
  - B) **Animate only up to N visible cards** (LRU by screen area, best tradeoff)
  - C) **Animate only selected/active GIF card** (safest MVP)

### 3) Card rotation + camera rotation are the main complexity
Cards can rotate and the camera can rotate.
To match Metal, the overlay view must apply:
- translation to the card center (screen)
- scale from world→screen (`zoomInFrame`)
- rotation of `finalRotation = cameraRotation + card.rotation`

This is feasible, but must be done carefully to avoid jitter.

### 4) Persistence: GIF binaries can explode JSON size
Saving raw GIF data into JSON (base64) can be huge, especially for multiple GIFs.
Feasible storage strategies:
- A) Store **GIF data inline** (simple, huge files)
- B) Store **local file reference** (store in app storage, JSON stays small)
- C) Store **remote URL / Giphy ID** (small JSON, requires network to rehydrate)

Given your earlier concern about 100MB+ JSON saves, **(B)** is usually the best fit.

### 5) Giphy search integration feasibility (SwiftyGiphy caveat)
SwiftyGiphy:
- Provides a ready-made search UI (`SwiftyGiphyViewController`)
- BUT: **no Swift Package Manager support** (CocoaPods/manual only) and it brings extra deps (ObjectMapper, SDWebImage/GIF, NSTimer-Blocks).

Feasible choices:
- Path 1: **Manual-vendor SwiftyGiphy + deps** into the repo (works, more maintenance risk).
- Path 2: **Don’t use SwiftyGiphy UI**; implement a small custom Giphy search view controller using `URLSession` + Codable (cleaner, SPM-friendly).
- Path 3: Add **CocoaPods** to the project (big tooling shift; usually not worth it if you’re already using SPM).

---

## Clarifying Questions (to pick the right architecture)

1) Should GIF cards **always animate**, even while panning/zooming, or is it OK to pause while gestures are active?
2) Do you want GIF cards to be **fully offline** (export/import includes GIFs), or is “re-download from Giphy” acceptable?
3) What’s an acceptable cap for simultaneous playback if needed (e.g. **max 6 animated GIF cards** at once)?
4) Should GIF cards support **card rotation** (most consistent), or do we force `card.rotation = 0` for GIF cards (simpler)?

---

## Proposed Implementation Plan (incremental)

### Phase 0 — Dependencies & project setup
1) Add **FLAnimatedImage** via Swift Package Manager:
   - `https://github.com/Flipboard/FLAnimatedImage.git` (from `1.0.16`)
2) Decide Giphy integration approach:
   - If insisting on SwiftyGiphy: plan manual vendoring + dependency audit.
   - Otherwise implement a small in-house Giphy picker (recommended for SPM).
3) Add Giphy API key handling:
   - Store in an app config (Info.plist key or a local settings file), not hardcoded.

### Phase 1 — Data model & persistence
1) Extend `CardType` with a new case, e.g.:
   - `.gif(localAssetID: String, pixelSize: SIMD2<Int>)` (preferred for local file storage)
   - or `.gif(data: Data, pixelSize: SIMD2<Int>)` (inline, simplest but huge)
   - or `.gif(remoteURL: String, pixelSize: SIMD2<Int>)` (rehydrate on demand)
2) Extend `CardContentDTO` similarly:
   - `case gif(localAssetID: String, width: Int, height: Int)` (or `gifData: Data`)
3) Update export/import in `Serialization.swift` / `PersistenceManager.swift`.
4) Enforce locked aspect ratio:
   - store `pixelSize` (or `aspectRatio`) in the content so it survives reloads.

### Phase 2 — Rendering strategy (Metal background + overlay animation)
**MVP recommendation:** Metal renders a static poster for the card; overlay animates when allowed.

1) Create a `GIFOverlayManager` owned by `TouchableMTKView`:
   - pool of `FLAnimatedImageView` instances
   - map `card.id -> FLAnimatedImageView`
2) Each frame, update visible overlays:
   - compute card on-screen transform (center/size/rotation)
   - set overlay `bounds` (screen-space size)
   - set overlay `center`
   - apply rotation transform
   - apply rounded-corner mask + clip
3) Visibility/culling rules:
   - only create/update overlays for cards that are actually on screen
   - optional cap: only animate the top N largest on-screen GIF cards
4) Playback rules:
   - pause / hide overlay while dragging/resizing the card (optional)
   - optionally pause while pinch/rotate gestures are active

### Phase 3 — GIF asset loading (fast first loop, good memory behavior)
1) On GIF selection (or import), store the asset:
   - write GIF bytes to `Library/Caches` or `Application Support`
   - store `localAssetID` in the card content
2) When a GIF card becomes visible/active:
   - load bytes from disk → `FLAnimatedImage(animatedGIFData:)`
   - set `imageView.animatedImage = ...`
3) Memory pressure:
   - listen for `UIApplication.didReceiveMemoryWarningNotification`
   - release all `FLAnimatedImage` objects for off-screen cards
   - keep on-screen ones if possible

### Phase 4 — Creation UI: “Pick GIF”
Two feasible UX approaches:

**Option A (SwiftyGiphy UI)**
1) Present `SwiftyGiphyViewController` modally.
2) On selection, take the chosen GIF URL:
   - download GIF data
   - compute pixel size
   - create `.gif(...)` card and size it by aspect ratio.

**Option B (Recommended: custom Giphy picker)**
1) Create a `GiphyPickerViewController`:
   - search bar + collection view grid
   - results show still thumbnails (static images) for speed
2) On selection:
   - download the original GIF URL bytes
   - compute pixel size
   - create/update card content.

### Phase 5 — Interaction & hit testing
1) Ensure overlays do not steal gestures:
   - set `gifImageView.isUserInteractionEnabled = false` so canvas gestures still work.
2) Card resize locking:
   - in the resize-handle code path, if card is `.gif`, enforce aspect ratio:
     - derive height from width (or vice versa) using stored ratio.

### Phase 6 — Export/import behavior
Pick one:
- **Preferred:** JSON stores `localAssetID` and the exporter bundles GIF files separately (or writes into a single archive).
- If you must stay single-file JSON: store GIF data inline (expect very large files).

Also decide how to handle “missing local asset” on import:
- show placeholder + “Tap to re-download” (if URL available)
- or mark card as broken.

---

## Acceptance Criteria (what “done” means)

1) User can create a GIF card via a picker (Giphy search).
2) The card animates smoothly (first loop no stall) and multiple GIF cards can animate at once (or within the chosen cap).
3) GIF cards respect frame delays (fast GIFs match browser behavior).
4) GIF cards are robust under memory pressure (no crash; off-screen GIFs stop/release).
5) Resizing the card keeps the correct aspect ratio.
6) Export/import round-trips GIF cards according to the chosen persistence strategy.

