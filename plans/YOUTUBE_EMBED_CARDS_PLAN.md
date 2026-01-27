# YouTube Embed Cards — Feasibility + Implementation Plan

Goal: add a new Card type that embeds a YouTube video using **YouTubePlayerKit**, while keeping Slate’s Metal renderer stable/performant and enforcing a fixed aspect ratio (matching the embedded content).

---

## Feasibility Summary (What’s realistic in this codebase)

### 1) Rendering approach: Metal cannot “draw” a web view
- **YouTubePlayerKit** is backed by `WKWebView` (YouTube iFrame).
- Our canvas is a `MTKView` (Metal). We can’t render a `WKWebView` into the Metal pipeline without brittle capture hacks.
- **Feasible solution:** treat YouTube cards like “hybrid UI”:
  - The card itself is still a normal Metal card (background + border + name label).
  - When the user interacts with the YouTube card, we overlay a `YouTubePlayerViewController` (or hosting view) on top of the `MTKView`, positioned to match the card’s on-screen rect.

This is already consistent with existing patterns:
- Inline renaming uses `UITextField` overlays that are re-positioned frame-by-frame.
- Link menus and card/section menus are popover overlays.

### 2) Performance constraints (very important)
- `WKWebView` is heavy. Creating one per visible YouTube card will cause memory/CPU spikes.
- YouTubePlayerKit has a hard limitation: **simultaneous playback of multiple players is not supported**.
- **Feasible policy:** only ONE “active” YouTube player view exists at a time.
  - Non-active YouTube cards render a thumbnail/placeholder via Metal.
  - The active card gets the real `WKWebView` overlay.

### 3) Aspect ratio feasibility
User requirement: “YouTube embed cards should always have the aspect ratio of the thing embedded.”
- In practice, YouTube embeds are almost always **16:9** (standard player).
- YouTube Shorts are commonly **9:16**; however, the iFrame player’s container is still often 16:9 with letterboxing.
- **Feasible implementation:**
  - Default aspect ratio to **16:9**.
  - Optionally detect `/shorts/` URLs and use **9:16**.
  - Always enforce locked resizing using that stored ratio.
  - Store the ratio in the card content so it is stable across export/import.

### 4) Compliance / App Store review
- Use YouTubePlayerKit (ToS compliant iFrame approach).
- Add the YouTube API Terms of Service link in App Review notes:
  - https://developers.google.com/youtube/terms/api-services-terms-of-service
- No background audio (explicit limitation).

---

## Clarifying Questions (to avoid rewrites)

1) Creation UX:
   - Should a YouTube card be created from the **card settings menu** (“Type: YouTube”) or from a **paste action** (paste URL → convert to YouTube card)?
2) Playback UX:
   - Tap the card to play/pause inline?
   - Or tap to “activate” (show overlay), then play inside the player UI?
3) Fullscreen:
   - Should fullscreen be allowed (YouTubePlayerKit supports `.system`)?
4) Rotation:
   - Cards can rotate today. Do we need YouTube cards to support rotation visually?
     - If “yes”, we must rotate the overlay view to match card rotation + camera rotation (more complex).
     - If “no”, we should **force rotation = 0** for YouTube cards (simpler and more stable).
5) Multiple visible YouTube cards:
   - Confirm “only one active player” is acceptable; others show thumbnails.

---

## Proposed Implementation Plan (incremental, low-risk)

### Phase 0 — Dependency + project setup
1) Add **YouTubePlayerKit** via Swift Package Manager in Xcode:
   - `https://github.com/SvenTiigi/YouTubePlayerKit.git` (from `2.0.0`).
2) If building for Mac Catalyst: enable **Outgoing Connections (Client)** capability.
3) (Optional) Add a small internal note (README or App Review note checklist) about the YouTube ToS link requirement.

### Phase 1 — Data model + serialization
1) Extend `CardType` with a new case, e.g.
   - `.youtube(videoID: String, aspectRatio: Double)` (or store the original URL + parsed source)
2) Extend `CardContentDTO` with:
   - `case youtube(videoID: String, aspectRatio: Double)`
3) Update export/import:
   - `Frame.toDTOv2()` / `Card.toDTO()` logic (wherever card content is encoded)
   - `PersistenceManager.cardType(from:)` to restore `.youtube(...)`
4) Decide version bump:
   - Current save `version` is `4`. Adding a new enum case is easiest with `version = 5` (optional since you have no users).

Feasibility note: this is straightforward; the only “hard” part is deciding the exact stored fields.

### Phase 2 — Creation UI (pasting a YouTube URL)
1) In the card settings floating menu, add a “YouTube” tab/type.
2) When chosen:
   - Show a small popover prompt (like the link popovers) to paste a YouTube URL.
   - Parse URL → video ID (YouTubePlayerKit has URL parsing for `YouTubePlayer.Source`, but we can also write a lightweight parser).
   - Create/convert the card to `.youtube(videoID, aspectRatio)`.
3) Set initial size using the locked ratio:
   - Example: keep width in world units and set height = width / ratio.

### Phase 3 — Placeholder rendering (thumbnail or “play” card)
Goal: YouTube cards should render in Metal like other cards even when not playing.

Option A (fastest):
- Render a dark solid card background + a play icon (Metal text/icon rendering or a small texture).
- Show the card name label as usual.

Option B (better UX) were using this one!:
- Fetch and cache a thumbnail for the video ID:
  - Use `YouTubeVideoThumbnail(videoID:resolution:)` from YouTubePlayerKit to get a URL / image.
  - Convert the `UIImage` to `MTLTexture` and store it in the card (or an in-memory cache keyed by `videoID`).
  - Render via the existing `.image(texture)` pipeline.

Feasibility note:
- Thumbnail fetching is networked and async; must be cached to avoid hammering.
- Rendering the thumbnail as a Metal texture is already implemented (image cards).

### Phase 4 — Active playback overlay (the “real” embed)
1) Add a small manager in `TouchableMTKView` (or a dedicated controller) that can:
   - Maintain **one** active `YouTubePlayerViewController` (or hosting view).
   - Attach it as a subview above the `MTKView`.
   - Reposition it every frame using the same math used for card label overlays:
     - Use the card’s on-screen rect (computed from card origin/size/rotation + camera pan/zoom/rotation).
2) Activation rule:
   - When the user taps a YouTube card (or selects it), activate the player overlay for that card.
   - Tapping away deactivates and removes the overlay (player stops or pauses).
3) Only one active:
   - If a different YouTube card is tapped, reuse the same player instance and swap source.

Feasibility note:
- This is the core “hard” piece, but it fits the existing architecture (overlay UI that tracks transforms).

### Phase 5 — Input routing + gesture conflicts
1) When the YouTube overlay is active, decide whether canvas gestures should still work:
   - Likely: while the card is “editing/selected”, touches within the card rect go to the player; outside continues to pan canvas.
2) Make sure the overlay doesn’t break:
   - lasso, panning, card drag, resize handles.
3) When dragging/resizing a YouTube card:
   - Temporarily hide the player overlay or keep it following (prefer hiding for simplicity).

### Phase 6 — Enforce locked aspect ratio
1) Add an “aspect ratio lock” path to the resize-handle logic in `TouchableMTKView.handlePan`:
   - If `card.type == .youtube(...)`, when resizing, compute one dimension from the other.
2) Decide which dimension “wins”:
   - Usually track the horizontal delta and compute height = width / ratio (feels stable).
3) Apply minimum size clamping while preserving ratio.

### Phase 7 — Polishing + safety
1) Visible affordances:
   - When not active: show a play icon overlay on the thumbnail.
2) Persistence:
   - Ensure export/import round-trips YouTube cards.
3) Edge cases:
   - Offline / no network → show placeholder + error state.
   - Video removed/unavailable → show error in overlay and keep placeholder.
4) App review checklist:
   - Include YouTube ToS link in review notes.

---

## Implementation Notes (for this repo specifically)

- The best place to position the overlay is `TouchableMTKView`, because it already owns:
  - inline text fields,
  - link selection handle overlay,
  - long-press menus.
- The per-frame update hook is already in `Coordinator.updateDebugHUD`:
  - it calls `updateCardNameEditorOverlay()` and `updateSectionNameEditorOverlay()` each frame.
  - we can add `updateYouTubeOverlay()` in the same pattern.

---

