# Plugin API Brainstorm — Theme Plugins + Card Plugins (CSC v1.1)

This document sketches a plugin API for **Labyrinth** (this repo’s Slate app) with two plugin types:

- **Theme plugins**: change canvas + UI styling (canvas clear color, fractal grid background style, UI tokens).
- **Card plugins**: define new **Card Types** (sandboxed mini-apps) that render + run logic inside their own bounds.

Cards are treated as **untrusted**. The security boundary is defined by **Card Security Contract (CSC) v1.1** (verbatim below). The plugin API should make CSC the natural/default outcome (push-only data, events-only back, default deny, secrets vault, etc.).

---

## Platform Reality: data-only + sandboxed runtime only

Labyrinth will not support native-code plugin modules on any platform.

Practical tiers:

1) **Data-only**: themes, assets, presets (safe + cross-platform).
2) **Sandboxed runtime**: Web cards (WKWebView) with a narrow host bridge.

---

# **Card Security Contract (CSC) — v1.1**

This contract defines the security boundary between **Labyrinth (the Native Host / Canvas OS)** and **Cards (sandboxed mini-apps)**. It is the single source of truth for what Cards may access, how data flows, and how Cards may interact with the canvas, assets, and the network.

---

## **1) Core Principle**

> **Cards do not access host data directly.
> Cards operate only on data explicitly provided by the Native Host.**

The Host is the sole authority over:

* the canvas model
* strokes and layers
* files and assets
* secrets and credentials
* inter-card communication
* device capabilities

Cards are strictly sandboxed runtimes.

---

## **2) Trust Model**

* **Native Host = Trusted**
  Code-signed, App Store reviewed, and in full control of system resources.

* **Cards = Untrusted**
  Downloaded community plugins must be treated as potentially malicious, buggy, or privacy-invasive.

---

## **3) Default Deny**

Cards begin with **zero capabilities**.
Every capability must be explicitly granted by the Host and, where relevant, by the user.

---

## **4) Forbidden Capabilities (Hard Deny)**

A Card must **never** be able to:

### 4.1 Host Data & Canvas

* Enumerate all cards, strokes, layers, frames, or documents
* Read strokes from the canvas (global or scoped) without an explicit host share action
* Subscribe to live canvas updates
* Access selection state, undo history, or internal metadata

### 4.2 Writing / Mutating Host State

* Create, move, delete, or edit strokes on the canvas
* Move, resize, or rotate other objects
* Create or destroy cards (except via host-controlled actions)
* Trigger host commands beyond the narrow, defined API

### 4.3 Filesystem & User Data

* Read/write arbitrary files
* Browse directories
* Obtain file paths or file handles
* Access contacts, photos, calendars, microphone, camera, location, Bluetooth, etc.

### 4.4 Cross-Card Data Access

* Read or write other cards’ internal state
* Direct Card → Card messaging without host mediation
* Any shared memory between cards

---

## **5) Allowed Capabilities (Within the Sandbox)**

A Card **may**:

### 5.1 Maintain Local State

* Store and load its own state blob (host-managed persistence)
* Use internal storage within its sandbox (e.g., IndexedDB/localStorage)

### 5.2 Render & Interact

* Render visuals within its own bounds
* Receive input events routed by the host (pointer, pencil, keyboard where applicable)
* Animate, compute, and run logic inside its runtime

### 5.3 Network (Conditional)

Network is **denied by default**.

If enabled by the Host, Cards may make network requests **only under one of these models**:

**A) Host-Proxy Model (Recommended)**

* All requests pass through a Host Network Broker
* The Host enforces allowlists, rate limits, and logging
* The Host injects credentials (never the Card)

**B) Open Web Model**

* The Card behaves like a constrained browser tab in WKWebView
* The Host still controls permissions and domain policies

**In both cases:**

> Cards may use authentication **only via Host-provided opaque tokens. Cards must never collect or store secrets directly.**

---

## **6) Data Flow Contract**

All data must flow across the boundary in one of two ways:

### 6.1 Host → Card (Push Only)

The Host may provide scoped data such as:

* A raster snapshot of a lasso selection
* A vector snapshot of selected strokes
* A single approved asset from the File Registry
* Structured data produced by the Host (e.g., recognized LaTeX)

All Host → Card data must be:

* **Minimal** (only what’s needed)
* **Scoped** (selection-, card-, or session-specific)
* **Auditable** (the Host can show what was shared)

### 6.2 Card → Host (Events Only)

Cards may send events such as:

* `sizePreferenceChanged`
* `interactionEvent` (e.g., “user selected object”)
* `requestAsset(type)`
* `requestNetwork(service)`
* `exportRequested`

The Host may ignore any event.

---

## **7) User Consent Requirements**

A Card may receive Host data **only via explicit user action**, including:

* Lasso → “Convert to Math”
* “Choose Model…” inside a 3D card
* Drag & drop onto a card
* “Attach from Registry…”

**No background sharing. No silent access.**

---

## **8) File Registry Contract**

The app may provide a Host-managed **File Registry** (assets library) for images, PDFs, and 3D models.

**Cards cannot browse or read the Registry directly.**

Access must follow this flow:

1. Card requests an asset type (e.g., `requestAsset("3d-model")`)
2. Host presents picker UI
3. User selects one item
4. Host grants either:

   * an **opaque asset token**, or
   * a copied payload (blob/bytes), scoped to that card

Rules:

* Tokens are scoped to a single card instance
* Tokens can be revoked by the Host
* Cards may **never** list all assets

---

## **9) Cross-Card Interaction Contract**

Cards may interact **only via Host mediation**.

If enabled, the Host may provide:

* `publishEvent(topic, payload)`
* `subscribe(topic)` (Host controls topics)

All interactions must be:

* data-minimal
* privacy-safe
* never expose another card’s state

---

## **10) Execution & Runtime Constraints**

The Host controls:

* runtime type (WebCard, NativeCard, etc.)
* CPU/memory budgets
* rate limits
* background execution (typically none)

Cards must tolerate suspension and restoration from saved state.

---

## **11) Auditing & Transparency (Required UX)**

The Host should provide a per-card panel showing:

* enabled capabilities
* granted assets
* shared selections (with previews)
* network access status
* a **Revoke Access** button

---

# **12) Secrets & Credentials Contract (NEW in v1.1)**

### 12.1 Core Rule

> **No Card may directly collect, store, or transmit API keys, secrets, tokens, passwords, or credentials.**

All secrets must be managed by the **Host’s Secrets Vault**.
Cards may only receive **opaque, scoped, revocable tokens.**

---

### 12.2 Secrets Vault (Host Responsibility)

The Host must provide a centralized **Secrets Vault** that lets users:

* Add, view (masked), revoke, and rotate secrets
* See which Cards are authorized to use each secret

Secrets are **never visible to Card code.**

---

### 12.3 How Cards Access Secrets

When a Card requires an API key:

1. Card declares a capability, e.g.:

```json
{
  "capabilities": ["network:openai"]
}
```

2. Host asks the user:

> “Allow this card to use your OpenAI key?”

3. If approved, the Host grants the Card an **opaque token**, e.g.:

```
token://openai/card-123/session-abc
```

4. The Card uses only this token — **never the real key.**
5. The Host can revoke the token at any time.

---

### 12.4 What Cards Are Forbidden to Do

A Card must **not**:

* Ask users to paste API keys inside the card UI
* Store credentials in localStorage / IndexedDB
* Embed hardcoded keys
* Redirect users to collect secrets externally
* Log or inspect tokens in readable form

---

### 12.5 Network + Secrets

**If using Host-Proxy Model (recommended):**

* The Card never sees secrets at all.
* It sends abstract requests like:

```js
cardAPI.request({
  service: "openai",
  body: {...}
});
```

**If using Open Web Model:**

* The Host still supplies only an opaque bearer token, scoped to that card.

---

### 12.6 User Transparency

For every Card using a secret, the Host should show:

> “This Math Chat card can use your OpenAI key. Revoke anytime.”

---

# **13) Canonical Examples**

### 13.1 Math Card (Lasso → Convert)

1. User lassos strokes
2. Taps **Convert to Math**
3. Host creates Math Card
4. Host sends a snapshot of only the selection
5. Card computes or displays result
6. No further canvas access is granted

### 13.2 3D Viewer Card (Registry → Pick Model)

1. User opens 3D card
2. Taps **Choose Model**
3. Host shows Registry picker
4. User selects one model
5. Host grants an asset token
6. Card renders via WebGPU
7. Card cannot see any other assets

### 13.3 Chatbot Card

1. Card declares `network:openai`
2. User approves access via Secrets Vault
3. Host issues opaque token
4. Requests are proxied (preferred) or scoped
5. Card never handles real credentials

---

## **14) Non-Goals (Out of Scope for v1.1)**

* Downloadable native code plugins
* Cards that mutate the global canvas
* General scripting access to host internals
* Background automation across the canvas

---

# **One-line summary of v1.1**

> *Cards are sandboxed mini-apps that operate only on data the Host explicitly provides, use only Host-managed secrets, and communicate with the world through tightly mediated APIs.*

---

## Plugin API (CSC-aligned)

### 1) Plugin Package Format (suggestion)

Importable zip-based package:

- extension: `.labyrinthplugin` (zip)
- required: `manifest.json`
- optional: `themes/*.json`, `cards/*`, `assets/*`

Example:

```
ExamplePack.labyrinthplugin
  manifest.json
  themes/
    midnight.json
    midnight-preview.png
  cards/
    timer/
      index.html
      card.js
      styles.css
      icon.png
      settings.html
```

Manifest sketch:

```json
{
  "id": "com.example.labyrinth.timerpack",
  "name": "Timer Pack",
  "version": "1.0.0",
  "minHostAPIVersion": 1,
  "author": "Example Co",
  "themes": [
    { "themeID": "midnight", "path": "themes/midnight.json", "preview": "themes/midnight-preview.png" }
  ],
  "cards": [
    {
      "typeID": "com.example.labyrinth.timer",
      "name": "Timer",
      "icon": "cards/timer/icon.png",
      "runtime": { "kind": "web", "entry": "cards/timer/index.html" },
      "settings": { "kind": "web", "entry": "cards/timer/settings.html" },
      "defaultSizePt": { "width": 300, "height": 200 },
      "capabilities": []
    }
  ]
}
```

### 2) Theme Plugins

Themes must be safely **data-only**. A theme is a pure **token map** interpreted by the Host (no code, no behavior changes), plus optional fractal grid overlay styling.

**Theme capabilities**
- none (themes are not code)

**Allowed contents**
- JSON tokens such as:
  - colors (hex or RGBA)
  - font names (from a host-allowed list)
  - spacing / radius values (within host-defined ranges)
- optional small preview image included in the plugin package (local file path only)

**Not allowed in themes**
- JS/HTML
- arbitrary URLs that fetch more logic
- anything that changes behavior (themes may only affect appearance)
- arbitrary CSS injection

**Recommended host validation rules**
- theme is a pure token map interpreted by the Host
- Host validates everything:
  - color format (hex/RGBA) and component ranges
  - numeric ranges for spacing/radius
  - font names restricted to a host allowlist
  - no unknown keys (either reject or ignore unknown keys)
- themes can only affect approved UI surfaces (palette, canvas background, card chrome, grid overlay, etc.)

**Extra safety win**
- never let themes provide raw CSS; instead expose host-defined token names and a fixed mapping to UI (and optionally to web-card CSS variables)

**Theme knobs**
- canvas clear color
- UI colors/material tokens
- fractal grid overlay:
  - per-group colors/alphas
  - per-group axis toggles:
    - `"horizontal"` draws only horizontal lines
    - `"vertical"` draws only vertical lines
    - `"both"` draws grid lines
  - optional per-group width in pixels

Theme JSON sketch (note “lined” = same fractal positions, vertical removed):

```json
{
  "themeID": "midnight-lined",
  "name": "Midnight (Lined)",
  "tokens": {
    "canvas.clearColor": "#121316",
    "ui.accent": [0.2, 0.8, 1.0, 1.0],
    "ui.text.primary": "#FFFFFF",
    "ui.panel.material": "ultraThin",
    "ui.font.body": "system",
    "ui.radius.panel": 12,
    "ui.spacing.menu": 12
  },
  "fractalGrid": {
    "enabled": true,
    "groups": [
      { "level": "tileBorder", "axes": "horizontal", "color": [1, 1, 1, 0.16], "widthPx": 1.5 },
      { "level": "child",      "axes": "horizontal", "color": [1, 1, 1, 0.09], "widthPx": 1.0 },
      { "level": "grandchild", "axes": "horizontal", "color": [1, 1, 1, 0.05], "widthPx": 1.0 }
    ]
  }
}
```

### 3) Card Plugins (Card Types)

Cards should be treated as untrusted and sandboxed.

**Recommended runtime for user-installable cards**
- `WKWebView` overlay runtime, positioned over the Metal-rendered card rect.
- Multiple plugin cards may be open at once, but the Host enforces a hard cap (currently **10** simultaneous webviews).
- UX (YouTube-style):
  - first tap selects the card; second tap opens the webview overlay
  - an **X** button is the only way to close the webview overlay (no tap-away auto-close)
  - when closed, the card renders a **snapshot of the latest webview state** as its background

**Card state & persistence**
- host persists a per-card opaque state blob (CSC §5.1), e.g. JSON bytes
- host never provides a “get host state” API to cards

**Extensible serialization (host save format)**
- add a generic plugin card content case:

```swift
enum CardContentDTO: Codable {
  // built-in cases...
  case plugin(typeID: String, payload: Data)
}
```

**Host → Card: push-only messages (CSC §6.1)**
- `init({ cardInstanceID, typeID, payload, themeTokens, grantedAssets, grantedCapabilities })`
- `setActive({ isActive })`
- `setBounds({ widthPt, heightPt, devicePixelRatio })`
- `pushSelectionSnapshot({ kind, data })` (only via explicit user action)
- `pushAsset({ assetToken | bytes })` (only after user pick)

**Card → Host: events-only (CSC §6.2)**
- `setPayload({ payload })`
- `sizePreferenceChanged({ widthPt, heightPt })`
- `requestAsset({ type })`
- `requestNetwork({ service, request })`
- `exportRequested({ kind })`

### 4) Capabilities (default deny)

Card manifests may declare capabilities, but grants are always host/user-controlled:

- `network:<service>` (e.g., `network:openai`)
- `fileRegistry:<type>` (e.g., `fileRegistry:image`, `fileRegistry:3d-model`)
- `crossCard:pubsub` (host-mediated topics only)

Anything else is either forbidden by CSC or out of scope.

### 5) Secrets Vault + Network Broker (CSC §12 / §5.3)

Cards must never handle raw secrets.

Recommended model:
- Card requests: `requestNetwork({ service: "openai", ... })`
- Host:
  - checks capability grant
  - uses Secrets Vault to fetch the real key
  - executes request via Network Broker
  - returns only the response payload needed

### 6) File Registry tokens (CSC §8)

- Cards cannot browse assets.
- Cards can only request an asset type, then the Host shows UI and returns:
  - an opaque, revocable, per-card `assetToken`, or
  - a copied blob scoped to the card.

### 7) Required auditing UI (CSC §11)

Per-card “Permissions” panel should show:
- granted capabilities
- granted assets (previews)
- shared selections (previews)
- network status/logs
- “Uses OpenAI key via Host proxy” + revoke



Each card instance gets a cardStateBlob stored by the native host (CoreData/SQLite/files—whatever you use).

The plugin can read/write only its own blob via your Card API.



next steps: write plugin api according to this document. 

---

## Suggested rollout (repo-friendly)

1) **Themes first** (data-only): make canvas clear color + fractal grid overlay style theme-driven.
2) **Card type registry**: create cards by `typeID` (built-ins first).
3) **Web card runtime host**: up to 10 active `WKWebView` overlays, close-only via X, snapshot placeholder when closed, strict push/event bridge.
4) **Plugin packages**: import/unpack/validate `.labyrinthplugin`.
5) **Secrets Vault + Network Broker**: enforce “no secrets in cards” before allowing networked cards.
