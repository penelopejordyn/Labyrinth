# UI “First Open” Lag Investigation

## Symptom
- The *first* time a UI element is presented (layers menu, old SwiftUI sheets, “Are you sure?” dialogs, YouTube URL field, etc.) the app hitches / drops frames.
- After it’s been shown once, subsequent opens are smooth.
- This has been present since the earliest iterations (before the 5×5 fractal work).

## Why this pattern usually happens on iOS
This “first use is slow, then it’s fine forever” pattern is almost always **one-time system warm-up cost**, not a leak or an algorithmic per-open cost.

Common one-time costs:
- **Dynamic framework + symbol loading** (UIKit/SwiftUI/TextInput/SwiftUI-hosting internals).
- **Text system warm-up** (CoreText shaping caches, font fallback caches, SF Symbols glyph cache).
- **UIVisualEffect / blur warm-up** (material effects can trigger expensive setup the first time).
- **Keyboard / input system handshake** (the first ever `UITextField`/`UITextView` editing session can stutter).
- **WebKit process launch** (first `WKWebView`/YouTube player interaction spawns WebContent/Networking processes).

Once the OS has spun these up, it keeps the caches/processes hot, so you stop seeing the hitch.

## Evidence / how this maps to Slate
In this codebase, the “first-open” menus (layers popover, card settings popover, link picker popovers) all do some combination of:
- `UIVisualEffectView(effect: UIBlurEffect(...))` (“liquid glass” background)
- `UITableView` creation + cell registration
- `UITextField` creation and first focus
- SF Symbols via `UIImage(systemName:)`
- (for YouTube playback) a `WKWebView`-backed player/overlay (WebKit processes are expensive the first time)

Those are exactly the subsystems that usually cause the one-time spike.

## Is this caused by “UIKit view inside SwiftUI”?
Not exactly. SwiftUI↔UIKit bridging can add some overhead, but the bigger culprit is usually:
- the **first time** the system needs the underlying UIKit presentation stack / text system / blur system,
- not the fact that the app mixes SwiftUI and UIKit.

You can see the same behavior in many “pure UIKit” apps the first time they present:
- a blur-heavy popover,
- a text field + keyboard,
- or a `UIAlertController`.

## Can we “fix” it?
### Things that are effectively unavoidable
- **First keyboard bring-up**: the first real text-input session can stutter (TextInput/keyboard pipeline). You can’t fully prewarm it without actually showing the keyboard.
- **First WebKit usage**: spawning WebKit processes is expensive. You can *prewarm*, but it still costs time somewhere.

### Things we *can* mitigate (tradeoffs)
You can’t usually eliminate the cost, but you can **move it** and/or **split it** so it’s less noticeable:

1) **Prewarm on launch / idle**
   - Create (but don’t present) representative UI components early:
     - `UIVisualEffectView` with the exact blur style you use.
     - A `UITableView` with one registered cell class.
     - A `UITextField` (without focusing it).
     - A dummy `UIAlertController` (UIKit side) to warm its view/controller path.
   - Pros: first “real” open feels instant.
   - Cons: you shift the hitch earlier (app launch / first seconds).

2) **Prewarm WebKit early**
   - Create a hidden `WKWebView` and load `about:blank` once.
   - Pros: the first YouTube/WebView interaction is much smoother.
   - Cons: higher baseline memory; still a one-time CPU spike (just moved).

3) **Split warmup into smaller chunks**
   - Schedule warmup steps across multiple runloop ticks (or a few frames) to avoid one massive stall.
   - Pros: reduces “single huge hitch”.
   - Cons: a handful of smaller hitches can still be noticeable in a drawing app.

4) **Reduce first-open work in the UI**
   - Defer expensive subviews until the tab/section is actually opened (e.g., don’t build YouTube tab controls until the tab is selected).
   - Pros: faster initial open of the menu.
   - Cons: the first time you open that tab still hitches (just delayed).

5) **Avoid blur for the very first presentation**
   - First open could use a simpler translucent background, then switch to blur after.
   - Pros: can eliminate the blur warm-up hitch.
   - Cons: visual inconsistency; complexity.

## Recommended approach for Slate (lowest risk)
Because Slate is a drawing app where hitches are very noticeable:
- Accept that a true “zero cost first open” is not realistic.
- If the hitch is big enough to annoy, implement **optional prewarm**:
  - Run it once after the first frame is rendered and the user is idle.
  - Focus on **blur + table + symbols**, and optionally WebKit.
  - Avoid trying to prewarm the keyboard (it requires actually showing it).

## How to confirm the exact culprit (quick checks)
Use Instruments on device (Time Profiler):
- Start recording.
- Trigger first open of Layers menu.
- Trigger first open of “Clear” confirmation dialog.
- Trigger first tap into a URL field (keyboard).

Typically you’ll see one of:
- WebKit process start (YouTube)
- TextInput/keyboard / CoreText / font caches (URL field)
- UIVisualEffect / backdrop pipeline work (blur popovers)
- SwiftUI presentation stack work (first sheet/dialog)

## Bottom line
- This is a **normal iOS warm-up behavior** pattern.
- There isn’t a clean “bug fix” that makes the first open free.
- The best mitigation is **prewarming** (moving the cost earlier / to idle) and minimizing what’s created on first open.

