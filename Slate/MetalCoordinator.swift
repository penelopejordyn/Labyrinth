// MetalCoordinator.swift manages the Metal pipeline, render passes, camera state,
// and gesture-driven updates for the drawing experience.
import Foundation
import Metal
import MetalKit
import simd
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Coordinator

	class Coordinator: NSObject, MTKViewDelegate {
	    var device: MTLDevice!
	    var commandQueue: MTLCommandQueue!
	    var pipelineState: MTLRenderPipelineState!
	    var cardPipelineState: MTLRenderPipelineState!      // Pipeline for textured cards
	    var cardSolidPipelineState: MTLRenderPipelineState! // Pipeline for solid color cards
	    var cardLinedPipelineState: MTLRenderPipelineState! // Pipeline for lined paper cards
	    var cardGridPipelineState: MTLRenderPipelineState!  // Pipeline for grid paper cards
	    var cardShadowPipelineState: MTLRenderPipelineState! // Pipeline for card shadows
	    var sectionFillPipelineState: MTLRenderPipelineState! // Unmasked solid triangles (Sections)
	    var strokeSegmentPipelineState: MTLRenderPipelineState! // SDF segment pipeline
	    var strokeSegmentBatchedPipelineState: MTLRenderPipelineState! // Batched SDF segment pipeline
	    var depthClearPipelineState: MTLRenderPipelineState!    // Depth+stencil reset between z-stack items
	    var postProcessPipelineState: MTLRenderPipelineState!   // FXAA fullscreen pass
	    var samplerState: MTLSamplerState!                  // Sampler for card textures
	    var vertexBuffer: MTLBuffer!
	    var quadVertexBuffer: MTLBuffer!                    // Unit quad for instanced segments

    // Note: ICB removed - using simple GPU-offset approach instead

    // MARK: - Batched Segment Upload (Ring Buffer)

    private static let maxInFlightFrameCount: Int = 3
    private static let batchedSegmentBufferInitialByteCount: Int = 8 * 1024 * 1024
    private static let batchedSegmentBufferAlignment: Int = 16

    private let inFlightSemaphore = DispatchSemaphore(value: Coordinator.maxInFlightFrameCount)
    private var inFlightFrameIndex: Int = 0

    private var batchedSegmentBuffers: [MTLBuffer] = []
    private var batchedSegmentBufferLength: Int = 0
    private var batchedSegmentBufferOffset: Int = 0

    //  Stencil States for Card Clipping
    var stencilStateDefault: MTLDepthStencilState! // Default passthrough (no testing)
    var stencilStateWrite: MTLDepthStencilState!   // Writes 1s to stencil (card background)
    var stencilStateWriteNoDepth: MTLDepthStencilState! // Writes 1s to stencil (depth-tested, no depth writes)
    var stencilStateRead: MTLDepthStencilState!    // Stencil read only (no depth test)
    var stencilStateClear: MTLDepthStencilState!   // Writes 0s to stencil (cleanup)

    // Depth States for Stroke Rendering
    var strokeDepthStateWrite: MTLDepthStencilState!   // Depth test + write enabled
    var strokeDepthStateNoWrite: MTLDepthStencilState! // Depth test enabled, depth write disabled
    var cardStrokeDepthStateWrite: MTLDepthStencilState!   // Depth test + write enabled, stencil read
    var cardStrokeDepthStateNoWrite: MTLDepthStencilState! // Depth test enabled, stencil read only

    // Offscreen render targets (scene -> texture, then FXAA -> drawable)
    private var offscreenColorTexture: MTLTexture?
    private var offscreenDepthStencilTexture: MTLTexture?
    private var offscreenTextureWidth: Int = 0
    private var offscreenTextureHeight: Int = 0

    // MARK: - Modal Input: Pencil vs. Finger

    /// Tracks what object we are currently drawing on with the pencil
    /// Now includes the Frame to support cross-depth drawing
    enum DrawingTarget {
        case canvas(Frame)
        case card(Card, Frame) // Track BOTH Card and the Frame it belongs to
    }
    var currentDrawingTarget: DrawingTarget?

    // MARK: - Lasso Selection
    struct LassoFrameSelection {
        var frame: Frame
        var strokeIDs: Set<UUID>
    }

    struct LassoCardSelection {
        let card: Card
        let frame: Frame
    }

    struct LassoCardStrokeSelection {
        let card: Card
        let frame: Frame
        let strokeIDs: Set<UUID>
    }

    struct LassoSelection {
        var points: [SIMD2<Double>] // Closed polygon in active frame coordinates
        var bounds: CGRect
        var center: SIMD2<Double>
        var frames: [LassoFrameSelection]
        var cards: [LassoCardSelection]
        var cardStrokes: [LassoCardStrokeSelection]
    }

		    private struct StrokeSnapshot {
		        let id: UUID
		        let frame: Frame
		        let index: Int
		        let activePoints: [SIMD2<Double>]
		        let color: SIMD4<Float>
		        let worldWidth: Double
		        let zoomEffectiveAtCreation: Float
		        let depthID: UInt32
		        let depthWriteEnabled: Bool
		        let layerID: UUID?
		        let sectionID: UUID?
		        let link: String?
		        let linkSectionID: UUID?
		        let linkTargetSectionID: UUID?
		        let linkTargetCardID: UUID?
		        let frameScale: Double
		        let frameTranslation: SIMD2<Double>
		    }

    private struct CardSnapshot {
        let card: Card
        let frameScale: Double
        let frameTranslation: SIMD2<Double>
        let originActive: SIMD2<Double>
        let size: SIMD2<Double>
        let rotation: Float
    }

		    private struct CardStrokeSnapshot {
		        let card: Card
		        let frame: Frame
		        let index: Int
		        let activePoints: [SIMD2<Double>]
		        let color: SIMD4<Float>
		        let worldWidth: Double
		        let zoomEffectiveAtCreation: Float
		        let depthID: UInt32
		        let depthWriteEnabled: Bool
		        let layerID: UUID?
		        let link: String?
		        let linkSectionID: UUID?
		        let linkTargetSectionID: UUID?
		        let linkTargetCardID: UUID?
		        let frameScale: Double
		        let frameTranslation: SIMD2<Double>
		        let cardOrigin: SIMD2<Double>
		        let cardRotation: Double
		    }

    private struct LassoTransformState {
        let basePoints: [SIMD2<Double>]
        let baseCenter: SIMD2<Double>
        let baseStrokes: [StrokeSnapshot]
        let baseCards: [CardSnapshot]
        let baseCardStrokes: [CardStrokeSnapshot]
        var currentScale: Double
        var currentRotation: Double
    }

    private enum LassoTarget {
        case canvas
        case card(Card, Frame)
    }

    // MARK: - Undo/Redo System

    enum UndoAction {
        case drawStroke(stroke: Stroke, target: DrawingTarget)
        case eraseStroke(stroke: Stroke, strokeIndex: Int, target: DrawingTarget)
        case moveCard(card: Card, frame: Frame, oldOrigin: SIMD2<Double>)
        case resizeCard(card: Card, frame: Frame, oldOrigin: SIMD2<Double>, oldSize: SIMD2<Double>)
        // TODO: Add lasso move/transform cases
    }

    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []
    private let maxUndoActions = 25

    var currentTouchPoints: [CGPoint] = []      // Real historical points (SCREEN space)
    var predictedTouchPoints: [CGPoint] = []    // Future points (Transient, SCREEN space)
    var liveStrokeOrigin: SIMD2<Double>?        // Temporary origin for live stroke (Double precision)

    // MARK: - Handwriting Refinement (CoreML)
    // Refines committed strokes after the user pauses (debounced), similar to Smart Script.
    // Wire these up to UI when ready.
    var handwritingRefinementEnabled: Bool = false
    var handwritingRefinementBias: Float = 2.0
    var handwritingRefinementInputScale: Float = 2.0
    /// 0 = keep raw strokes, 1 = fully refined.
    var handwritingRefinementStrength: Float = 0.7
    /// User must be idle (no new stroke started) for this long before refinement runs.
    var handwritingRefinementDebounceSeconds: TimeInterval = 0.5

    private struct PendingHandwritingStroke {
        let stroke: Stroke
        let target: DrawingTarget
        let rawScreenPoints: [CGPoint]
        let viewSize: CGSize
        let zoomAtCreation: Double
        let panAtCreation: SIMD2<Double>
        let rotationAngle: Float
        let baseWidth: Double
        let constantScreenSize: Bool
    }

    private var handwritingRefiner: HandwritingRefinerEngine?
    private var pendingHandwritingStrokes: [PendingHandwritingStroke] = []
    private var handwritingRefinementWorkItem: DispatchWorkItem?
    private let handwritingRefinementQueue = DispatchQueue(label: "slate.handwritingRefinement", qos: .userInitiated)

	    var lassoDrawingPoints: [CGPoint] = []
	    var lassoPredictedPoints: [CGPoint] = []
	    var lassoSelection: LassoSelection?
	    var lassoPreviewStroke: Stroke?
	    var lassoPreviewFrame: Frame?
	    private var lassoTransformState: LassoTransformState?
	    private var lassoTarget: LassoTarget?
	    private var lassoPreviewCard: Card?
	    private var lassoPreviewCardFrame: Frame?

	    // MARK: - Stroke Linking Selection
	    var linkSelection: StrokeLinkSelection?
	    var isDraggingLinkHandle: Bool = false
	    private var linkSelectionHoverKey: LinkedStrokeKey?
	    private var maskEraserLayerOverrideID: UUID?

    //  OPTIMIZATION: Adaptive Fidelity
    // Track last saved point for distance filtering to prevent vertex explosion during slow drawing
    var lastSavedPoint: CGPoint?

    // Telescoping Reference Frames
    // Instead of a flat array, we use a linked list of Frames for infinite zoom
    var rootFrame = Frame()           // The "Base Reality" - top level that cannot be zoomed out of
    lazy var activeFrame: Frame = rootFrame  // The current "Local Universe" we are viewing/editing

	    // MARK: - Layers (Global Z Order)
	    /// Global draw-order layers for strokes (not cards/sections).
	    var layers: [CanvasLayer] = []
	    /// Only one layer can be selected at a time; new strokes are created on this layer.
	    var selectedLayerID: UUID?
	    /// Global z-order stack (top → bottom) containing layers + cards.
	    var zOrder: [CanvasZItem] = []

    // 5x5 fractal grid configuration (set once from the view size).
    // Frame coordinates are treated as bounded within ±extent/2, and panning swaps tiles when exiting.
    var fractalFrameExtent: SIMD2<Double> = .zero

    // MARK: - Fractal Root Management

    private func topmostFrame(from frame: Frame) -> Frame {
        var top = frame
        while let parent = top.parent {
            top = parent
        }
        return top
    }

    /// Ensure a stable topmost root is retained (required because `Frame.parent` is `weak`).
    @discardableResult
    func ensureSuperRootRetained(for frame: Frame) -> Frame {
        let candidate = frame.ensureSuperRoot()
        let top = topmostFrame(from: candidate)
        rootFrame = top
        return top
    }

    /// Resolve a same-depth neighbor using the "Up, Over, Down" algorithm and retain any new super-root.
    func neighborFrame(from frame: Frame, direction: GridDirection) -> Frame {
        frame.neighbor(direction) { newRoot in
            self.rootFrame = newRoot
        }
    }

    /// Resolve a same-depth neighbor without instantiating missing frames.
    /// Returns nil when the neighbor/cousin chain hasn't been created yet.
    private func neighborFrameIfExists(from frame: Frame, direction: GridDirection) -> Frame? {
        frame.neighborIfExists(direction)
    }

    /// Returns the frame at an (dx,dy) offset from `activeFrame` without creating missing frames.
    ///
    /// Important: imported canvases may have sparse tiles where intermediate neighbors were never instantiated
    /// (e.g. tile (4,2) exists but (3,2) does not). A step-by-step neighbor walk would fail to "reach" those
    /// tiles, causing strokes/cards to appear culled. This implementation resolves the target via the
    /// balanced-base-5 coordinate implied by the root→frame index path, so any existing frame can be found
    /// without requiring intermediate siblings to exist.
    private func frameAtOffsetFromActiveIfExists(dx: Int, dy: Int) -> Frame? {
        if dx == 0, dy == 0 { return activeFrame }

        // Build the index path from the retained topmost root to the active frame.
        // (Most-significant digit first; each digit is in 0...4.)
        var pathReversed: [GridIndex] = []
        var cursor: Frame? = activeFrame
        while let frame = cursor, frame !== rootFrame {
            guard let idx = frame.indexInParent, let parent = frame.parent else { return nil }
            pathReversed.append(idx)
            cursor = parent
        }
        guard cursor === rootFrame else { return nil }

        let depth = pathReversed.count
        guard depth > 0 else { return nil } // activeFrame is topmost; no same-depth neighbors unless we expand.

        // Represent the root→active path as balanced base-5 digits in [-2, 2].
        var xDigits: [Int] = []
        var yDigits: [Int] = []
        xDigits.reserveCapacity(depth)
        yDigits.reserveCapacity(depth)
        for idx in pathReversed.reversed() { // root → active
            xDigits.append(idx.col - GridIndex.center.col)
            yDigits.append(idx.row - GridIndex.center.row)
        }

        func applyOffset(to digits: [Int], offset: Int) -> [Int]? {
            let base = GridIndex.gridSize
            let half = base / 2
            var out = digits
            var carry = offset

            for i in stride(from: out.count - 1, through: 0, by: -1) {
                let sum = out[i] + carry
                var digit = sum % base
                if digit > half {
                    digit -= base
                } else if digit < -half {
                    digit += base
                }
                carry = (sum - digit) / base
                out[i] = digit
            }

            guard carry == 0 else { return nil }
            return out
        }

        guard let targetXDigits = applyOffset(to: xDigits, offset: dx),
              let targetYDigits = applyOffset(to: yDigits, offset: dy) else { return nil }

        var f: Frame? = rootFrame
        for i in 0..<depth {
            let idx = GridIndex(col: targetXDigits[i] + GridIndex.center.col,
                                row: targetYDigits[i] + GridIndex.center.row)
            f = f?.childIfExists(at: idx)
            if f == nil { return nil }
        }

        return f
    }

	    weak var metalView: MTKView?

	    // MARK: - Card Interaction Callbacks
	    var onEditCard: ((Card) -> Void)?
	    var onPencilSqueeze: (() -> Void)?

    //  UPGRADED: Store camera state as Double for infinite precision
    var panOffset: SIMD2<Double> = .zero
    var zoomScale: Double = 1.0
    var rotationAngle: Float = 0.0

    // MARK: - Brush Settings
    let brushSettings = BrushSettings()

		    private let lassoDashLengthPx: Double = 6.0
		    private let lassoGapLengthPx: Double = 4.0
		    private let lassoLineWidthPx: Double = 1.5
		    private let boxLassoCornerRadiusPx: Double = 10.0
		    private let boxLassoCornerSegments: Int = 8
		    private let lassoColor = SIMD4<Float>(1.0, 1.0, 1.0, 0.6)
		    private let linkHighlightColor = SIMD4<Float>(1.0, 0.92, 0.0, 0.38)
		    private let linkHighlightExtraWidthPx: Double = 10.0
		    private let linkHitTestRadiusPx: Double = 14.0
		    private let linkHighlightPaddingPx: Double = 8.0
		    private let linkHighlightCornerRadiusPx: Float = 10.0
		    private let linkHighlightPersistentAlphaScale: Float = 0.55
		    private let cardCornerRadiusPx: Float = 12.0
		    var cardShadowEnabled: Bool = true
		    private enum DefaultsKeys {
		        static let cardNamesVisible = "slate.cardNamesVisible"
		    }
		    var cardNamesVisible: Bool = (UserDefaults.standard.object(forKey: DefaultsKeys.cardNamesVisible) as? Bool) ?? true {
		        didSet {
		            UserDefaults.standard.set(cardNamesVisible, forKey: DefaultsKeys.cardNamesVisible)
		        }
		    }
		    private let cardShadowBlurPx: Float = 18.0
		    private let cardShadowOpacity: Float = 0.25
		    private let cardShadowOffsetPx = SIMD2<Float>(0.0, 0.0)
		    private let sectionBorderWidthPx: Double = 1.0
		    private let sectionLabelMarginPx: Double = 10.0
		    private let sectionLabelCornerRadiusPx: Float = 8.0

		    // MARK: - Link Highlight Sections (Rebuilt Every Frame)
		    enum LinkHighlightKey: Hashable {
		        case section(UUID)
		        case legacy(String) // Fallback for older content without section IDs
		    }

		    private var linkHighlightBoundsByKeyActiveThisFrame: [LinkHighlightKey: CGRect] = [:]
		    private var pendingSectionLabelBuilds: Set<UUID> = []
		    private var pendingCardLabelBuilds: Set<UUID> = []

		    // MARK: - Internal Link Reference Graph (cached; rebuilt on link changes)
		    private struct InternalLinkReferenceEdge: Hashable {
		        let sourceID: UUID
		        let targetID: UUID
		    }

		    private var internalLinkReferenceEdges: [InternalLinkReferenceEdge] = []
		    private var internalLinkReferenceNamesByID: [UUID: String] = [:]
		    private var internalLinkTargetsPresent: Bool = false

		    // MARK: - YouTube Thumbnails (in-memory cache)
		    private var youtubeThumbnailCache: [String: MTLTexture] = [:]
		    private var youtubeThumbnailRequestsInFlight: Set<String> = []
		    private let youtubeThumbnailCacheLock = NSLock()

	    // MARK: - Debug Metrics
	    var debugDrawnVerticesThisFrame: Int = 0
	    var debugDrawnNodesThisFrame: Int = 0

	    // MARK: - Fractal Grid Overlay (Debug)
	    private var fractalGridOverlayBuffer: MTLBuffer?
	    private var fractalGridOverlayInstanceCount: Int = 0
	    private var fractalGridOverlayExtent: SIMD2<Double> = .zero
	    private let fractalGridOverlayEnabled: Bool = true

		    // MARK: - Fractal Cross-Depth Rendering
		    private let fractalStrokeVisibilityDepthRadius: Int = 6

		    // MARK: - Cross-Depth Interaction Cache
		    /// Rebuilt every `draw(in:)` from the exact set of frames that were rendered.
		    /// Used for cross-depth hit testing (cards, strokes) and lasso operations.
		    private var visibleFractalFrameTransforms: [ObjectIdentifier: (scale: Double, translation: SIMD2<Double>)] = [:]
		    private var visibleFractalFramesDrawOrder: [Frame] = []

		    private func ensureYouTubeThumbnailTexture(card: Card, videoID: String) -> MTLTexture? {
		        guard !videoID.isEmpty else { return nil }

		        if let texture = card.youtubeThumbnailTexture,
		           card.youtubeThumbnailVideoID == videoID,
		           texture.device === device {
		            return texture
		        }

		        youtubeThumbnailCacheLock.lock()
		        let cached = youtubeThumbnailCache[videoID]
		        youtubeThumbnailCacheLock.unlock()

		        if let cached {
		            card.youtubeThumbnailTexture = cached
		            card.youtubeThumbnailVideoID = videoID
		            return cached
		        }

		        requestYouTubeThumbnail(videoID: videoID)
		        return nil
		    }

		    private func requestYouTubeThumbnail(videoID: String) {
		        guard !videoID.isEmpty else { return }

		        youtubeThumbnailCacheLock.lock()
		        if youtubeThumbnailCache[videoID] != nil || youtubeThumbnailRequestsInFlight.contains(videoID) {
		            youtubeThumbnailCacheLock.unlock()
		            return
		        }
		        youtubeThumbnailRequestsInFlight.insert(videoID)
		        youtubeThumbnailCacheLock.unlock()

		        guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") else {
		            youtubeThumbnailCacheLock.lock()
		            youtubeThumbnailRequestsInFlight.remove(videoID)
		            youtubeThumbnailCacheLock.unlock()
		            return
		        }

		        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
		            guard let self else { return }
		            guard let data,
		                  let image = UIImage(data: data),
		                  let cgImg = image.cgImage else {
		                self.youtubeThumbnailCacheLock.lock()
		                self.youtubeThumbnailRequestsInFlight.remove(videoID)
		                self.youtubeThumbnailCacheLock.unlock()
		                return
		            }

		            let loader = MTKTextureLoader(device: self.device)
		            let texture = try? loader.newTexture(
		                cgImage: cgImg,
		                options: [
		                    .origin: MTKTextureLoader.Origin.bottomLeft,
		                    .SRGB: false
		                ]
		            )

		            self.youtubeThumbnailCacheLock.lock()
		            self.youtubeThumbnailRequestsInFlight.remove(videoID)
		            if let texture {
		                self.youtubeThumbnailCache[videoID] = texture
		            }
		            self.youtubeThumbnailCacheLock.unlock()
		        }.resume()
		    }

		    // MARK: - Debug Tools
		    func debugPopulateFrames(parentCount: Int = 20,
		                             childCount: Int = 20,
		                             strokesPerFrame: Int = 1000,
		                             maxOffset: Double = 1000.0) {
		        /*
		        // MARK: - Legacy Telescoping Debug Fill (Reference Only)
		        // This code populated a parent/child linked list for stress testing.
		        // It relied on `originInParent`, `scaleRelativeToParent`, and the single-child invariant.
		        */

		        guard let view = metalView else { return }
		        ensureFractalExtent(viewSize: view.bounds.size)

		        let cameraCenterActive = calculateCameraCenterWorld(viewSize: view.bounds.size)
		        let extent = fractalFrameExtent

		        func frameAtOffset(dx: Int, dy: Int) -> Frame {
		            var f = activeFrame
		            if dx > 0 { for _ in 0..<dx { f = neighborFrame(from: f, direction: .right) } }
		            if dx < 0 { for _ in 0..<(-dx) { f = neighborFrame(from: f, direction: .left) } }
		            if dy > 0 { for _ in 0..<dy { f = neighborFrame(from: f, direction: .down) } }
		            if dy < 0 { for _ in 0..<(-dy) { f = neighborFrame(from: f, direction: .up) } }
		            return f
		        }

		        // Keep the debug workload bounded regardless of the legacy parameter defaults.
		        let radius = 1
		        var targets: [(frame: Frame, cameraCenter: SIMD2<Double>)] = []
		        targets.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
		        for dy in -radius...radius {
		            for dx in -radius...radius {
		                let frame = frameAtOffset(dx: dx, dy: dy)
		                let offset = SIMD2<Double>(Double(dx) * extent.x, Double(dy) * extent.y)
		                targets.append((frame: frame, cameraCenter: cameraCenterActive - offset))
		            }
		        }

		        for (frame, cameraCenter) in targets {
		            frame.strokes.reserveCapacity(frame.strokes.count + strokesPerFrame)
		            let effectiveZoom = max(zoomScale, 1e-6)
		            for _ in 0..<strokesPerFrame {
		                let points = randomStrokePoints(center: cameraCenter, maxOffset: maxOffset)
		                let virtualScreenPoints = points.map { CGPoint(x: $0.x * effectiveZoom, y: $0.y * effectiveZoom) }
		                let color = SIMD4<Float>(Float.random(in: 0.1...1.0),
		                                         Float.random(in: 0.1...1.0),
		                                         Float.random(in: 0.1...1.0),
		                                         1.0)
		                let stroke = Stroke(screenPoints: virtualScreenPoints,
		                                    zoomAtCreation: effectiveZoom,
		                                    panAtCreation: .zero,
		                                    viewSize: .zero,
		                                    rotationAngle: 0,
		                                    color: color,
		                                    baseWidth: Double.random(in: 2.0...10.0),
		                                    zoomEffectiveAtCreation: Float(effectiveZoom),
		                                    device: device,
		                                    depthID: allocateStrokeDepthID(),
		                                    depthWriteEnabled: true)
		                frame.strokes.append(stroke)
		            }
		        }
		    }

		    func clearAllStrokes() {
		        var topFrame = activeFrame
		        while let parent = topFrame.parent {
		            topFrame = parent
		        }

		        func clearRecursively(_ frame: Frame) {
		            frame.strokes.removeAll()
		            for card in frame.cards {
		                card.strokes.removeAll()
		            }
		            for child in frame.children.values {
		                clearRecursively(child)
		            }
		        }

		        clearRecursively(topFrame)
		    }

	    private func rebuildFractalGridOverlayIfNeeded(extent: SIMD2<Double>) {
	        guard extent.x > 0.0, extent.y > 0.0 else { return }

	        let dx = abs(fractalGridOverlayExtent.x - extent.x)
	        let dy = abs(fractalGridOverlayExtent.y - extent.y)
	        if fractalGridOverlayBuffer != nil, dx < 0.5, dy < 0.5 {
	            return
	        }

	        fractalGridOverlayExtent = extent

	        let borderAlpha: Float = 0.16
	        let childAlpha: Float = 0.09
	        let grandchildAlpha: Float = 0.05

	        let borderColor = SIMD4<Float>(1, 1, 1, borderAlpha)
	        let childColor = SIMD4<Float>(1, 1, 1, childAlpha)
	        let grandchildColor = SIMD4<Float>(1, 1, 1, grandchildAlpha)

	        let half = extent * 0.5
	        let childStep = FractalGrid.tileExtent(frameExtent: extent) // extent / 5
	        let grandCount = GridIndex.gridSize * GridIndex.gridSize    // 25
	        let grandStep = childStep / Double(GridIndex.gridSize)      // extent / 25

	        var segments: [StrokeSegmentInstance] = []
	        segments.reserveCapacity(25 * 52)

	        func addSegment(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, color: SIMD4<Float>) {
	            segments.append(
	                StrokeSegmentInstance(
	                    p0: SIMD2<Float>(Float(p0.x), Float(p0.y)),
	                    p1: SIMD2<Float>(Float(p1.x), Float(p1.y)),
	                    color: color
	                )
	            )
	        }

	        for tileY in -2...2 {
	            for tileX in -2...2 {
	                let center = SIMD2<Double>(Double(tileX) * extent.x, Double(tileY) * extent.y)
	                let xMin = center.x - half.x
	                let xMax = center.x + half.x
	                let yMin = center.y - half.y
	                let yMax = center.y + half.y

	                // Same-depth tile border (frame boundary).
	                addSegment(SIMD2<Double>(xMin, yMin), SIMD2<Double>(xMax, yMin), color: borderColor)
	                addSegment(SIMD2<Double>(xMax, yMin), SIMD2<Double>(xMax, yMax), color: borderColor)
	                addSegment(SIMD2<Double>(xMax, yMax), SIMD2<Double>(xMin, yMax), color: borderColor)
	                addSegment(SIMD2<Double>(xMin, yMax), SIMD2<Double>(xMin, yMin), color: borderColor)

	                // Child grid boundaries (5x5 inside this tile).
	                for i in 1..<GridIndex.gridSize {
	                    let x = xMin + Double(i) * childStep.x
	                    addSegment(SIMD2<Double>(x, yMin), SIMD2<Double>(x, yMax), color: childColor)
	                    let y = yMin + Double(i) * childStep.y
	                    addSegment(SIMD2<Double>(xMin, y), SIMD2<Double>(xMax, y), color: childColor)
	                }

	                // Grandchild grid boundaries (25x25 inside this tile), skipping child lines.
	                for i in 1..<grandCount {
	                    if i % GridIndex.gridSize == 0 { continue }
	                    let x = xMin + Double(i) * grandStep.x
	                    addSegment(SIMD2<Double>(x, yMin), SIMD2<Double>(x, yMax), color: grandchildColor)
	                    let y = yMin + Double(i) * grandStep.y
	                    addSegment(SIMD2<Double>(xMin, y), SIMD2<Double>(xMax, y), color: grandchildColor)
	                }
	            }
	        }

	        fractalGridOverlayInstanceCount = segments.count
	        fractalGridOverlayBuffer = device.makeBuffer(bytes: segments,
	                                                     length: segments.count * MemoryLayout<StrokeSegmentInstance>.stride,
	                                                     options: .storageModeShared)
	    }

		    private func drawFractalGridOverlay(encoder: MTLRenderCommandEncoder,
		                                        viewSize: CGSize,
		                                        cameraCenterWorld: SIMD2<Double>,
		                                        zoom: Double,
		                                        rotation: Float) {
	        guard fractalGridOverlayEnabled else { return }
	        let extent = fractalFrameExtent
	        guard extent.x > 0.0, extent.y > 0.0 else { return }
	        rebuildFractalGridOverlayIfNeeded(extent: extent)
	        guard let buffer = fractalGridOverlayBuffer, fractalGridOverlayInstanceCount > 0 else { return }

	        let z = max(zoom, 1e-6)
	        let angle = Double(rotation)
	        let c = cos(angle)
	        let s = sin(angle)

	        // Overlay is authored in active-frame world coords around (0,0).
	        let dx = -cameraCenterWorld.x
	        let dy = -cameraCenterWorld.y
	        let rotatedOffsetScreen = SIMD2<Float>(
	            Float((dx * c - dy * s) * z),
	            Float((dx * s + dy * c) * z)
	        )

	        // 1–2px looks best; keep it constant in screen space.
	        let halfPixelWidth: Float = 1.0

	        var transform = StrokeTransform(
	            relativeOffset: .zero,
	            rotatedOffsetScreen: rotatedOffsetScreen,
	            zoomScale: Float(z),
	            screenWidth: Float(viewSize.width),
	            screenHeight: Float(viewSize.height),
	            rotationAngle: rotation,
	            halfPixelWidth: halfPixelWidth,
	            featherPx: 1.0,
	            depth: 0.0
	        )

	        encoder.setRenderPipelineState(strokeSegmentPipelineState)
	        encoder.setDepthStencilState(stencilStateDefault)
	        encoder.setCullMode(.none)
	        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
	        encoder.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
	        encoder.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
	        encoder.setVertexBuffer(buffer, offset: 0, index: 2)
	        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: fractalGridOverlayInstanceCount)

		        debugDrawnNodesThisFrame += 1
		        debugDrawnVerticesThisFrame += 4 * fractalGridOverlayInstanceCount
		    }

		    private func renderLinkHighlightOverlays(encoder: MTLRenderCommandEncoder,
		                                             viewSize: CGSize,
		                                             cameraCenterWorld: SIMD2<Double>,
		                                             zoom: Double,
		                                             rotation: Float) {
		        guard linkSelection != nil || !linkHighlightBoundsByKeyActiveThisFrame.isEmpty else { return }

		        encoder.setDepthStencilState(stencilStateDefault)
		        encoder.setCullMode(.none)
		        encoder.setRenderPipelineState(cardSolidPipelineState)

		        func drawRoundedRect(_ rect: CGRect, color: SIMD4<Float>) {
		            let w = rect.width
		            let h = rect.height
		            guard w.isFinite, h.isFinite, w > 0, h > 0 else { return }

		            let center = SIMD2<Double>(rect.midX, rect.midY)
		            let halfSize = SIMD2<Double>(w * 0.5, h * 0.5)
		            let relativeOffset = center - cameraCenterWorld

		            let hw = Float(halfSize.x)
		            let hh = Float(halfSize.y)
		            let verts: [StrokeVertex] = [
		                StrokeVertex(position: SIMD2<Float>(-hw, -hh), uv: SIMD2<Float>(0, 0), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>( hw, -hh), uv: SIMD2<Float>(1, 0), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>(-hw,  hh), uv: SIMD2<Float>(0, 1), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>( hw, -hh), uv: SIMD2<Float>(1, 0), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>( hw,  hh), uv: SIMD2<Float>(1, 1), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>(-hw,  hh), uv: SIMD2<Float>(0, 1), color: SIMD4<Float>(1, 1, 1, 1))
		            ]

		            var transform = CardTransform(
		                relativeOffset: SIMD2<Float>(Float(relativeOffset.x), Float(relativeOffset.y)),
		                zoomScale: Float(zoom),
		                screenWidth: Float(viewSize.width),
		                screenHeight: Float(viewSize.height),
		                rotationAngle: rotation,
		                depth: 0.0
		            )

				            var style = CardStyleUniforms(
				                cardHalfSize: SIMD2<Float>(hw, hh),
				                zoomScale: Float(zoom),
				                cornerRadiusPx: linkHighlightCornerRadiusPx,
				                shadowBlurPx: 0.0,
				                shadowOpacity: 0.0,
				                cardOpacity: 1.0
				            )

		            var fill = color

		            verts.withUnsafeBytes { bytes in
		                guard let base = bytes.baseAddress else { return }
		                encoder.setVertexBytes(base, length: bytes.count, index: 0)
		            }
		            encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
		            encoder.setFragmentBytes(&fill, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
		            encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
		            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		        }

			        if !linkHighlightBoundsByKeyActiveThisFrame.isEmpty {
			            var persistentColor = linkHighlightColor
			            persistentColor.w *= linkHighlightPersistentAlphaScale
			            for (_, rect) in linkHighlightBoundsByKeyActiveThisFrame {
			                drawRoundedRect(rect, color: persistentColor)
			            }
			        }

		        if let selectionBounds = linkSelectionBoundsActiveWorld() {
		            drawRoundedRect(selectionBounds, color: linkHighlightColor)
		        }
		    }

		    // MARK: - Undo/Redo Implementation

	    func pushUndo(_ action: UndoAction) {
	        undoStack.append(action)
	        if undoStack.count > maxUndoActions {
	            undoStack.removeFirst()
	        }
	        redoStack.removeAll() // Clear redo stack when new action is performed
	    }

	    func pushUndoMoveCard(card: Card, frame: Frame, oldOrigin: SIMD2<Double>) {
	        pushUndo(.moveCard(card: card, frame: frame, oldOrigin: oldOrigin))
	    }

	    func pushUndoResizeCard(card: Card, frame: Frame, oldOrigin: SIMD2<Double>, oldSize: SIMD2<Double>) {
	        pushUndo(.resizeCard(card: card, frame: frame, oldOrigin: oldOrigin, oldSize: oldSize))
	    }

	    // TODO: Implement lasso snapshot capture for undo support

	    func undo() {
	        guard let action = undoStack.popLast() else { return }

	        switch action {
	        case .drawStroke(let stroke, let target):
	            // Remove the stroke
	            switch target {
	            case .canvas(let frame):
	                if let index = frame.strokes.firstIndex(where: { $0.id == stroke.id }) {
	                    frame.strokes.remove(at: index)
	                }
	            case .card(let card, _):
	                if let index = card.strokes.firstIndex(where: { $0.id == stroke.id }) {
	                    card.strokes.remove(at: index)
	                }
	            }
	            redoStack.append(action)

	        case .eraseStroke(let stroke, let strokeIndex, let target):
	            // Restore the stroke
	            switch target {
	            case .canvas(let frame):
	                frame.strokes.insert(stroke, at: min(strokeIndex, frame.strokes.count))
	            case .card(let card, _):
	                card.strokes.insert(stroke, at: min(strokeIndex, card.strokes.count))
	            }
	            redoStack.append(action)

	        case .moveCard(let card, _, let oldOrigin):
	            let currentOrigin = card.origin
	            card.origin = oldOrigin
	            redoStack.append(.moveCard(card: card, frame: activeFrame, oldOrigin: currentOrigin))

	        case .resizeCard(let card, _, let oldOrigin, let oldSize):
	            let currentOrigin = card.origin
	            let currentSize = card.size
	            card.origin = oldOrigin
	            card.size = oldSize
	            card.rebuildGeometry()
	            redoStack.append(.resizeCard(card: card, frame: activeFrame, oldOrigin: currentOrigin, oldSize: currentSize))
	        }
	    }

	    func redo() {
	        guard let action = redoStack.popLast() else { return }

	        switch action {
	        case .drawStroke(let stroke, let target):
	            // Re-add the stroke
	            switch target {
	            case .canvas(let frame):
	                frame.strokes.append(stroke)
	            case .card(let card, _):
	                card.strokes.append(stroke)
	            }
	            undoStack.append(action)

	        case .eraseStroke(let stroke, let strokeIndex, let target):
	            // Re-remove the stroke
	            switch target {
	            case .canvas(let frame):
	                if let index = frame.strokes.firstIndex(where: { $0.id == stroke.id }) {
	                    frame.strokes.remove(at: index)
	                }
	            case .card(let card, _):
	                if let index = card.strokes.firstIndex(where: { $0.id == stroke.id }) {
	                    card.strokes.remove(at: index)
	                }
	            }
	            undoStack.append(action)

	        case .moveCard(let card, let frame, let oldOrigin):
	            let currentOrigin = card.origin
	            card.origin = oldOrigin
	            undoStack.append(.moveCard(card: card, frame: frame, oldOrigin: currentOrigin))

	        case .resizeCard(let card, let frame, let oldOrigin, let oldSize):
	            let currentOrigin = card.origin
	            let currentSize = card.size
	            card.origin = oldOrigin
	            card.size = oldSize
	            card.rebuildGeometry()
	            undoStack.append(.resizeCard(card: card, frame: frame, oldOrigin: currentOrigin, oldSize: currentSize))
	        }
	    }

	    func replaceCanvas(with newRoot: Frame,
	                       fractalExtent: SIMD2<Double> = .zero,
	                       layers: [CanvasLayer]? = nil,
	                       zOrder: [CanvasZItem]? = nil,
	                       selectedLayerID: UUID? = nil) {
	        // Reset the canvas to a known root reference (topmost) and deterministic active frame.
	        let top = topmostFrame(from: newRoot)
	        top.parent = nil
	        top.indexInParent = nil
	        rootFrame = top

	        var initial = top
	        // Prefer the embedded "original" root at depth 0 by walking down the center chain.
	        while initial.depthFromRoot < 0, let center = initial.children[GridIndex.center] {
	            initial = center
	        }
	        activeFrame = initial

	        if fractalExtent.x > 0.0, fractalExtent.y > 0.0 {
	            fractalFrameExtent = fractalExtent
	        } else {
	            fractalFrameExtent = .zero
	        }
	        panOffset = .zero
	        zoomScale = 1.0
	        rotationAngle = 0.0
	        currentDrawingTarget = nil
	        currentTouchPoints = []
	        predictedTouchPoints = []
	        liveStrokeOrigin = nil
	        lastSavedPoint = nil
	        clearLassoSelection()
	        lassoDrawingPoints = []
	        lassoPredictedPoints = []
	        resetStrokeDepthID(using: top)
	        self.layers = layers ?? []
	        self.zOrder = zOrder ?? []
	        self.selectedLayerID = selectedLayerID
	        ensureDefaultLayersIfNeeded()
	        assignDefaultLayerIDToCanvasStrokesIfNeeded()
	        syncZOrderWithCanvas()
	        rebuildInternalLinkReferenceCache()
	    }

	    // MARK: - Global Stroke Depth Ordering
	    // A monotonic per-stroke counter lets depth testing work across telescoping frames.
	    // Larger depthID = newer stroke; we map this into Metal NDC depth (smaller = closer).
	    private var nextStrokeDepthID: UInt32 = 0

	    private func allocateStrokeDepthID() -> UInt32 {
	        let id = nextStrokeDepthID
	        if nextStrokeDepthID < StrokeDepth.slotCount - 1 {
	            nextStrokeDepthID += 1
	        }
	        return id
	    }

	    private func peekStrokeDepthID() -> UInt32 {
	        nextStrokeDepthID
	    }

	    private func resetStrokeDepthID(using frame: Frame) {
	        if let maxDepth = maxStrokeDepthID(in: frame) {
	            if maxDepth < StrokeDepth.slotCount - 1 {
	                nextStrokeDepthID = maxDepth + 1
	            } else {
	                nextStrokeDepthID = StrokeDepth.slotCount - 1
	            }
	        } else {
	            nextStrokeDepthID = 0
	        }
	    }

	    private func maxStrokeDepthID(in frame: Frame) -> UInt32? {
	        var maxID: UInt32?

	        func consider(_ id: UInt32) {
	            if let current = maxID {
	                if id > current {
	                    maxID = id
	                }
	            } else {
	                maxID = id
	            }
	        }

	        for stroke in frame.strokes {
	            consider(stroke.depthID)
	        }
	        for card in frame.cards {
	            for stroke in card.strokes {
	                consider(stroke.depthID)
	            }
	        }
		        for child in frame.children.values {
		            if let childMax = maxStrokeDepthID(in: child) {
		                consider(childMax)
		            }
		        }

	        return maxID
	    }

		    private func findFrame(withDepth depth: Int, in frame: Frame) -> Frame? {
		        if frame.depthFromRoot == depth {
		            return frame
		        }
		        for child in frame.children.values {
		            if let found = findFrame(withDepth: depth, in: child) {
		                return found
		            }
		        }
		        return nil
		    }

	    override init() {
	        super.init()
	        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!

        makePipeLine()
        makeVertexBuffer()
        makeQuadVertexBuffer()

        inFlightFrameIndex = Self.maxInFlightFrameCount - 1
        ensureBatchedSegmentBuffers(minByteCount: Self.batchedSegmentBufferInitialByteCount)

	        ensureDefaultLayersIfNeeded()
    }

	    private func ensureDefaultLayersIfNeeded() {
	        if layers.isEmpty {
	            let layer = CanvasLayer(name: "Layer 1")
	            layers = [layer]
	            selectedLayerID = layer.id
	        }

	        if selectedLayerID == nil || !layers.contains(where: { $0.id == selectedLayerID }) {
	            selectedLayerID = layers.first?.id
	        }

	        if zOrder.isEmpty {
	            zOrder = layers.map { .layer($0.id) }
	        }
	    }

	    private func assignDefaultLayerIDToCanvasStrokesIfNeeded() {
	        guard let defaultLayerID = layers.first?.id else { return }

	        func walk(_ frame: Frame) {
	            for stroke in frame.strokes where stroke.layerID == nil {
	                stroke.layerID = defaultLayerID
	            }
	            for child in frame.children.values {
	                walk(child)
	            }
	        }

	        walk(rootFrame)
	    }

	    func selectLayer(id: UUID) {
	        guard layers.contains(where: { $0.id == id }) else { return }
	        selectedLayerID = id
	    }

	    private func allCardsInCanvas(from frame: Frame) -> [Card] {
	        var result: [Card] = []
	        result.reserveCapacity(frame.cards.count)

	        func walk(_ f: Frame) {
	            result.append(contentsOf: f.cards)
	            for child in f.children.values {
	                walk(child)
	            }
	        }

	        walk(frame)
	        return result
	    }

	    private func allSectionsInCanvas(from frame: Frame) -> [Section] {
	        var result: [Section] = []
	        result.reserveCapacity(frame.sections.count)

	        func walk(_ f: Frame) {
	            result.append(contentsOf: f.sections)
	            for child in f.children.values {
	                walk(child)
	            }
	        }

	        walk(frame)
	        return result
	    }

	    private func syncZOrderWithCanvas() {
	        ensureDefaultLayersIfNeeded()

	        let cards = allCardsInCanvas(from: rootFrame)
	        let cardIDs = Set(cards.map(\.id))

	        var seenCards = Set<UUID>()
	        var seenLayers = Set<UUID>()
	        var normalized: [CanvasZItem] = []
	        normalized.reserveCapacity(zOrder.count + layers.count + cards.count)

	        for item in zOrder {
	            switch item {
	            case .card(let id):
	                guard cardIDs.contains(id), !seenCards.contains(id) else { continue }
	                seenCards.insert(id)
	                normalized.append(item)
	            case .layer(let id):
	                guard layers.contains(where: { $0.id == id }), !seenLayers.contains(id) else { continue }
	                seenLayers.insert(id)
	                normalized.append(item)
	            }
	        }

	        // Missing cards default to the top of the stack (front).
	        let missingCards = cards.map(\.id).filter { !seenCards.contains($0) }
	        normalized.insert(contentsOf: missingCards.map { .card($0) }, at: 0)

	        // Missing layers default to the bottom of the stack (behind cards by default).
	        for layer in layers where !seenLayers.contains(layer.id) {
	            normalized.append(.layer(layer.id))
	        }

	        zOrder = normalized
	    }

	    private func zDepthBand(for item: CanvasZItem) -> (bias: Float, scale: Float) {
	        if zOrder.isEmpty {
	            ensureDefaultLayersIfNeeded()
	            syncZOrderWithCanvas()
	        }

	        let count = max(zOrder.count, 1)
	        let depthMax = Float(1.0).nextDown
	        let scale = depthMax / Float(count)
	        guard let idx = zOrder.firstIndex(of: item) else {
	            return (bias: 0.0, scale: 1.0)
	        }
	        return (bias: Float(idx) * scale, scale: scale)
	    }

	    // MARK: - Layer Management

	    private func nextNumberedName(base: String, existingNames: [String]) -> String {
	        let escaped = NSRegularExpression.escapedPattern(for: base)
	        let pattern = "^\\s*\(escaped)\\s+(\\d+)\\s*$"
	        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

	        var used: Set<Int> = []
	        used.reserveCapacity(existingNames.count)

	        for name in existingNames {
	            let range = NSRange(name.startIndex..<name.endIndex, in: name)
	            guard let match = regex?.firstMatch(in: name, options: [], range: range),
	                  match.numberOfRanges >= 2,
	                  let numberRange = Range(match.range(at: 1), in: name),
	                  let number = Int(name[numberRange]),
	                  number > 0 else { continue }
	            used.insert(number)
	        }

	        var candidate = 1
	        while used.contains(candidate) {
	            candidate += 1
	        }
	        return "\(base) \(candidate)"
	    }

	    func addLayer() {
	        ensureDefaultLayersIfNeeded()

	        let name = nextNumberedName(base: "Layer", existingNames: layers.map(\.name))
	        let layer = CanvasLayer(name: name)
	        layers.append(layer)
	        selectedLayerID = layer.id

	        // Insert below leading cards so cards remain on top by default.
	        let insertIndex = zOrder.prefix { item in
	            if case .card = item { return true }
	            return false
	        }.count
	        zOrder.insert(.layer(layer.id), at: min(max(insertIndex, 0), zOrder.count))
	        syncZOrderWithCanvas()
	    }

	    func renameLayer(id: UUID, to newName: String) {
	        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
	        layers[index].name = newName
	    }

	    func toggleLayerHidden(id: UUID) {
	        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
	        layers[index].isHidden.toggle()
	    }

	    func toggleCardHidden(id: UUID) {
	        guard let found = findCard(id: id, in: rootFrame) else { return }
	        let card = found.card
	        card.isHidden.toggle()

	        if card.isHidden {
	            card.isEditing = false
	            clearLassoSelection()
	            clearLinkSelection()
	            if case .card(let targetCard, _) = currentDrawingTarget, targetCard === card {
	                currentDrawingTarget = nil
	            }
	            (metalView as? TouchableMTKView)?.deactivateYouTubeOverlayIfTarget(card: card)
	        }
	    }

	    func deleteLayer(id: UUID) {
	        ensureDefaultLayersIfNeeded()
	        guard layers.count > 1 else { return }
	        guard layers.contains(where: { $0.id == id }) else { return }

	        clearLassoSelection()
	        clearLinkSelection()

	        func walk(_ frame: Frame) {
	            frame.strokes.removeAll { stroke in
	                stroke.layerID == id
	            }
	            for child in frame.children.values {
	                walk(child)
	            }
	        }
	        walk(rootFrame)
	        if internalLinkTargetsPresent {
	            rebuildInternalLinkReferenceCache()
	        }

	        layers.removeAll { $0.id == id }
	        zOrder.removeAll { item in
	            if case .layer(let layerID) = item {
	                return layerID == id
	            }
	            return false
	        }

	        if selectedLayerID == id {
	            selectedLayerID = layers.first?.id
	        }

	        ensureDefaultLayersIfNeeded()
	        syncZOrderWithCanvas()
	    }

	    func moveZOrderItem(from sourceIndex: Int, to destinationIndex: Int) {
	        guard sourceIndex != destinationIndex else { return }
	        guard zOrder.indices.contains(sourceIndex) else { return }
	        let item = zOrder.remove(at: sourceIndex)
	        let clamped = max(0, min(destinationIndex, zOrder.count))
	        zOrder.insert(item, at: clamped)
	    }

	    func normalizeZOrder() {
	        syncZOrderWithCanvas()
	    }

	    func presentLayersMenu() {
	        guard let sourceView = metalView as? UIView else { return }
	        guard let vc = nearestViewController(from: sourceView) else { return }

	        if vc.presentedViewController is LayersFloatingMenuViewController {
	            return
	        }

	        let anchorRect = CGRect(x: sourceView.bounds.maxX - 44,
	                                y: sourceView.bounds.maxY - 180,
	                                width: 1,
	                                height: 1)

	        let menu = LayersFloatingMenuViewController(
	            coordinator: self,
	            onDismiss: {},
	            sourceRect: anchorRect,
	            sourceView: sourceView
	        )

	        vc.present(menu, animated: true)
	    }

	    private func nearestViewController(from view: UIView) -> UIViewController? {
	        var responder: UIResponder? = view
	        while let current = responder {
	            if let vc = current as? UIViewController {
	                return vc
	            }
	            responder = current.next
	        }
	        return nil
	    }

    private func align(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        let mask = alignment - 1
        return (value + mask) & ~mask
    }

    private func ensureBatchedSegmentBuffers(minByteCount: Int) {
        let minimum = max(minByteCount, Self.batchedSegmentBufferInitialByteCount)
        if !batchedSegmentBuffers.isEmpty, minimum <= batchedSegmentBufferLength {
            return
        }

        let newLength = max(minimum, max(batchedSegmentBufferLength * 2, Self.batchedSegmentBufferInitialByteCount))
        var newBuffers: [MTLBuffer] = []
        newBuffers.reserveCapacity(Self.maxInFlightFrameCount)

        for _ in 0..<Self.maxInFlightFrameCount {
            guard let buffer = device.makeBuffer(length: newLength, options: .storageModeShared) else {
                fatalError("Failed to allocate batched stroke segment buffer (\(newLength) bytes)")
            }
            newBuffers.append(buffer)
        }

        batchedSegmentBuffers = newBuffers
        batchedSegmentBufferLength = newLength
        batchedSegmentBufferOffset = 0
    }

    private func beginBatchedSegmentUploadsForFrame() {
        inFlightFrameIndex = (inFlightFrameIndex + 1) % Self.maxInFlightFrameCount
        batchedSegmentBufferOffset = 0
    }

    private func allocateBatchedSegmentStorage(byteCount: Int) -> (buffer: MTLBuffer, offset: Int, destination: UnsafeMutableRawPointer)? {
        guard byteCount > 0 else { return nil }

        ensureBatchedSegmentBuffers(minByteCount: byteCount)
        var buffer = batchedSegmentBuffers[inFlightFrameIndex]

        var offset = align(batchedSegmentBufferOffset, to: Self.batchedSegmentBufferAlignment)

        if offset + byteCount > buffer.length {
            // Grow and restart from zero in the new buffer. This intentionally switches buffers
            // instead of wrapping within the same one (to avoid overwriting earlier uploads).
            ensureBatchedSegmentBuffers(minByteCount: offset + byteCount)
            buffer = batchedSegmentBuffers[inFlightFrameIndex]
            batchedSegmentBufferOffset = 0
            offset = 0
        }

        let destination = buffer.contents().advanced(by: offset)
        batchedSegmentBufferOffset = offset + byteCount
        return (buffer, offset, destination)
    }

    private func uploadBatchedSegments(_ instances: [BatchedStrokeSegmentInstance]) -> (buffer: MTLBuffer, offset: Int)? {
        guard !instances.isEmpty else { return nil }

        let byteCount = instances.count * MemoryLayout<BatchedStrokeSegmentInstance>.stride
        ensureBatchedSegmentBuffers(minByteCount: byteCount)
        var buffer = batchedSegmentBuffers[inFlightFrameIndex]

        var offset = align(batchedSegmentBufferOffset, to: Self.batchedSegmentBufferAlignment)

        if offset + byteCount > buffer.length {
            // Grow and restart from zero in the new buffer.
            ensureBatchedSegmentBuffers(minByteCount: offset + byteCount)
            buffer = batchedSegmentBuffers[inFlightFrameIndex]
            batchedSegmentBufferOffset = 0
            offset = 0
        }

        instances.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            memcpy(buffer.contents().advanced(by: offset), baseAddress, byteCount)
        }

        batchedSegmentBufferOffset = offset + byteCount
        return (buffer, offset)
    }

	    // MARK: - Recursive Renderer
	    /// Calculate Metal depth value for a stroke based on creation order
	    ///
	    /// **DEPTH TESTING BY STROKE ORDER:**
	    /// Newer strokes (higher depthID) are always rendered on top of older strokes,
	    /// regardless of which telescope depth they were created at.
	    ///
	    /// Example:
	    /// - Draw stroke A at depth -9 (depthID = 100)
	    /// - Draw stroke B at depth 0  (depthID = 200)
	    /// - Draw stroke C at depth -9 (depthID = 300)
	    ///
	    /// Result: C is on top of B, which is on top of A
	    ///
	    /// This uses the global monotonic depthID counter, so stroke ordering is consistent
	    /// across all telescope depths from -∞ to +∞.
	    ///
	    /// **OVERDRAW PREVENTION:**
	    /// All segments within a stroke share the same depth value. The depth buffer prevents
	    /// pixel-level overdraw when drawing complex shapes. Front-to-back rendering of
	    /// depth-write-enabled strokes provides early-Z rejection for maximum performance.
	    ///
	    /// - Parameters:
	    ///   - depthID: The stroke's depth ID (monotonic counter for creation order)
	    /// - Returns: Metal NDC depth value [0, 1] where 0 is closest
	    private func strokeDepth(for depthID: UInt32) -> Float {
	        StrokeDepth.metalDepth(for: depthID)
	    }

			    private func collectDepthNeighborhood(baseFrame: Frame,
			                                          cameraCenterInBaseFrame: SIMD2<Double>,
			                                          cameraCenterInActiveFrame: SIMD2<Double>,
			                                          viewSize: CGSize,
			                                          zoomActive: Double,
			                                          visited: inout Set<ObjectIdentifier>) {
			        ensureFractalExtent(viewSize: viewSize)
			        let extent = fractalFrameExtent
			        let scale = FractalGrid.scale

		        func recordRenderedFrame(_ frame: Frame,
		                                 cameraCenterInFrame: SIMD2<Double>,
		                                 zoomInFrame: Double) {
		            let id = ObjectIdentifier(frame)
		            let safeZoomInFrame = max(zoomInFrame, 1e-12)
		            let scaleFromActive = zoomActive / safeZoomInFrame
		            let translation = cameraCenterInFrame - cameraCenterInActiveFrame * scaleFromActive
		            visibleFractalFrameTransforms[id] = (scale: scaleFromActive, translation: translation)
		            visibleFractalFramesDrawOrder.append(frame)
		        }

		        // A) Ancestors (up to N). Render farthest-first as a background layer.
		        var ancestors: [(frame: Frame, cameraCenter: SIMD2<Double>, zoom: Double)] = []
		        ancestors.reserveCapacity(fractalStrokeVisibilityDepthRadius)

		        var currentFrame = baseFrame
		        var cameraCenter = cameraCenterInBaseFrame
		        var currentZoom = zoomActive

		        for _ in 0..<fractalStrokeVisibilityDepthRadius {
		            guard let parent = currentFrame.parent,
		                  let index = currentFrame.indexInParent else {
		                break
	            }

	            let childCenter = FractalGrid.childCenterInParent(frameExtent: extent, index: index)
	            cameraCenter = childCenter + (cameraCenter / scale)
	            currentZoom *= scale
	            currentFrame = parent
	            ancestors.append((frame: currentFrame, cameraCenter: cameraCenter, zoom: currentZoom))
	        }

			        for entry in ancestors.reversed() {
			            let id = ObjectIdentifier(entry.frame)
			            guard visited.insert(id).inserted else { continue }
			            recordRenderedFrame(entry.frame,
			                                cameraCenterInFrame: entry.cameraCenter,
			                                zoomInFrame: entry.zoom)
			        }

		        // B) Base frame.
			        let baseID = ObjectIdentifier(baseFrame)
			        if visited.insert(baseID).inserted {
			            recordRenderedFrame(baseFrame,
			                                cameraCenterInFrame: cameraCenterInBaseFrame,
			                                zoomInFrame: zoomActive)
			        }

	        // C) Descendants (down to N).
	        let screenW = Double(viewSize.width)
	        let screenH = Double(viewSize.height)
	        let screenRadius = sqrt(screenW * screenW + screenH * screenH) * 0.5
	        let tileExtentInParent = FractalGrid.tileExtent(frameExtent: extent)
	        let tileRadiusInParent = sqrt(tileExtentInParent.x * tileExtentInParent.x +
	                                      tileExtentInParent.y * tileExtentInParent.y) * 0.5

	        func renderDescendants(of frame: Frame,
	                               cameraCenterInFrame: SIMD2<Double>,
	                               zoomInFrame: Double,
	                               remaining: Int) {
	            guard remaining > 0 else { return }
	            guard !frame.children.isEmpty else { return }

	            let parentWorldRadius = screenRadius / max(zoomInFrame, 1e-6)
	            let childZoom = zoomInFrame / scale

	            for (index, child) in frame.children {
	                let childCenter = FractalGrid.childCenterInParent(frameExtent: extent, index: index)

	                // Tile-level culling in the parent's coordinate space.
	                let dx = childCenter.x - cameraCenterInFrame.x
	                let dy = childCenter.y - cameraCenterInFrame.y
	                let dist = sqrt(dx * dx + dy * dy)
	                if (dist - tileRadiusInParent) > parentWorldRadius { continue }

			                let cameraCenterInChild = (cameraCenterInFrame - childCenter) * scale
			                let id = ObjectIdentifier(child)
			                if visited.insert(id).inserted {
			                    recordRenderedFrame(child,
			                                        cameraCenterInFrame: cameraCenterInChild,
			                                        zoomInFrame: childZoom)
			                }

	                renderDescendants(of: child,
	                                  cameraCenterInFrame: cameraCenterInChild,
	                                  zoomInFrame: childZoom,
	                                  remaining: remaining - 1)
	            }
	        }

			        renderDescendants(of: baseFrame,
			                          cameraCenterInFrame: cameraCenterInBaseFrame,
			                          zoomInFrame: zoomActive,
			                          remaining: fractalStrokeVisibilityDepthRadius)
			    }

			    private func renderVisibleSections(encoder: MTLRenderCommandEncoder,
			                                       viewSize: CGSize,
			                                       cameraCenterWorld: SIMD2<Double>,
			                                       zoomActive: Double,
			                                       rotation: Float) {
			        guard !visibleFractalFramesDrawOrder.isEmpty else { return }

			        let screenW = Double(viewSize.width)
			        let screenH = Double(viewSize.height)
			        let screenRadius = sqrt(screenW * screenW + screenH * screenH) * 0.5
			        let cullRadius = screenRadius * brushSettings.cullingMultiplier

			        for frame in visibleFractalFramesDrawOrder {
			            guard !frame.sections.isEmpty else { continue }
			            let id = ObjectIdentifier(frame)
			            guard let transform = visibleFractalFrameTransforms[id] else { continue }

			            let scaleFromActive = transform.scale
			            let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
			            let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation

			            renderSections(in: frame,
			                           cameraCenterInThisFrame: cameraCenterInFrame,
			                           viewSize: viewSize,
			                           currentZoom: zoomInFrame,
			                           currentRotation: rotation,
			                           cullRadiusScreen: cullRadius,
			                           encoder: encoder)
			        }
			    }

			    private func renderVisibleDepthWriteStrokes(encoder: MTLRenderCommandEncoder,
			                                               viewSize: CGSize,
			                                               cameraCenterWorld: SIMD2<Double>,
			                                               zoomActive: Double,
			                                               rotation: Float) {
			        guard !visibleFractalFramesDrawOrder.isEmpty else { return }

			        for frame in visibleFractalFramesDrawOrder {
			            guard !frame.strokes.isEmpty else { continue }
			            let id = ObjectIdentifier(frame)
			            guard let transform = visibleFractalFrameTransforms[id] else { continue }

			            let scaleFromActive = transform.scale
			            let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
			            let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation

			            renderFrame(frame,
			                        cameraCenterInThisFrame: cameraCenterInFrame,
			                        viewSize: viewSize,
			                        currentZoom: zoomInFrame,
			                        currentRotation: rotation,
			                        encoder: encoder,
			                        excludedChild: nil,
			                        depthFromActive: 0,
			                        renderStrokes: true,
			                        renderCards: false,
			                        renderNoDepthWriteStrokes: false)
			        }
			    }

			    private func renderVisibleNoDepthWriteStrokes(encoder: MTLRenderCommandEncoder,
			                                                 viewSize: CGSize,
			                                                 cameraCenterWorld: SIMD2<Double>,
			                                                 zoomActive: Double,
			                                                 rotation: Float,
			                                                 strokeLayerFilterID: UUID? = nil,
			                                                 zDepthBias: Float = 0.0,
			                                                 zDepthScale: Float = 1.0) {
			        guard !visibleFractalFramesDrawOrder.isEmpty else { return }

			        struct Item {
			            let depthID: UInt32
			            let stroke: Stroke
			            let frame: Frame
			            let cameraCenterInFrame: SIMD2<Double>
			            let zoomInFrame: Double
			        }

			        let screenW = Double(viewSize.width)
			        let screenH = Double(viewSize.height)
			        let screenRadius = sqrt(screenW * screenW + screenH * screenH) * 0.5
			        let cullRadius = screenRadius * brushSettings.cullingMultiplier

			        var items: [Item] = []
			        items.reserveCapacity(256)

			        for frame in visibleFractalFramesDrawOrder {
			            guard !frame.strokes.isEmpty else { continue }
			            let id = ObjectIdentifier(frame)
			            guard let transform = visibleFractalFrameTransforms[id] else { continue }

			            let scaleFromActive = transform.scale
			            let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
			            let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation
			            let zoom = max(zoomInFrame, 1e-6)

			            for stroke in frame.strokes where !stroke.depthWriteEnabled {
			                if let strokeLayerFilterID {
			                    let effective = stroke.layerID ?? layers.first?.id
			                    if effective != strokeLayerFilterID { continue }
			                }
			                guard !stroke.segments.isEmpty, stroke.segmentBuffer != nil else { continue }

			                let strokeZoom = max(Double(stroke.zoomEffectiveAtCreation), 1.0)
			                if zoom > strokeZoom * 100_000.0 { continue }

			                let dx = stroke.origin.x - cameraCenterInFrame.x
			                let dy = stroke.origin.y - cameraCenterInFrame.y
			                let thresholdWorld = stroke.cullingRadiusWorld + (cullRadius / max(zoom, 1e-9))
			                let dist2 = dx * dx + dy * dy
			                if dist2 > thresholdWorld * thresholdWorld { continue }

			                if stroke.hasAnyLink,
			                   let rectFrame = strokeBoundsRectInContainerSpace(stroke) {
			                    // Avoid an extra transform lookup by using the cached active->frame transform.
			                    let invScale = scaleFromActive != 0 ? (1.0 / scaleFromActive) : 1.0
			                    let minFrame = SIMD2<Double>(rectFrame.minX, rectFrame.minY)
			                    let maxFrame = SIMD2<Double>(rectFrame.maxX, rectFrame.maxY)
			                    let minActive = (minFrame - transform.translation) * invScale
			                    let maxActive = (maxFrame - transform.translation) * invScale
			                    let rectActive = CGRect(x: minActive.x,
			                                            y: minActive.y,
			                                            width: maxActive.x - minActive.x,
			                                            height: maxActive.y - minActive.y)
			                    let paddingActive = linkHighlightPaddingPx / max(scaleFromActive, 1e-12)
			                    let padded = rectActive.insetBy(dx: -paddingActive, dy: -paddingActive)
			                    recordLinkHighlightBounds(link: stroke.link, sectionID: stroke.linkSectionID, rectActive: padded)
			                }

			                items.append(Item(depthID: stroke.depthID,
			                                  stroke: stroke,
			                                  frame: frame,
			                                  cameraCenterInFrame: cameraCenterInFrame,
			                                  zoomInFrame: zoomInFrame))
			            }
			        }

                        let selectedLayer = selectedLayerID ?? layers.first?.id
                        let hasLiveNoWritePreview: Bool = {
                            guard brushSettings.toolMode == .paint, brushSettings.depthWriteEnabled == false else { return false }
                            guard let target = currentDrawingTarget, case .canvas = target else { return false }
                            guard liveStrokeOrigin != nil else { return false }
                            guard (currentTouchPoints.count + predictedTouchPoints.count) >= 2 else { return false }
                            guard strokeLayerFilterID == nil || (selectedLayer != nil && strokeLayerFilterID == selectedLayer) else { return false }
                            return true
                        }()

				        guard !items.isEmpty || hasLiveNoWritePreview else { return }
				        items.sort { $0.depthID < $1.depthID }

			        encoder.setRenderPipelineState(strokeSegmentPipelineState)
			        encoder.setCullMode(.none)
			        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
			        encoder.setDepthStencilState(strokeDepthStateNoWrite)

			        let angle = Double(rotation)
			        let c = cos(angle)
			        let s = sin(angle)

				        for item in items {
				            let stroke = item.stroke
				            guard !stroke.segments.isEmpty, let segmentBuffer = stroke.segmentBuffer else { continue }

			            let zoom = max(item.zoomInFrame, 1e-6)
			            let dx = stroke.origin.x - item.cameraCenterInFrame.x
			            let dy = stroke.origin.y - item.cameraCenterInFrame.y

			            let rotatedOffsetScreen = SIMD2<Float>(
			                Float((dx * c - dy * s) * zoom),
			                Float((dx * s + dy * c) * zoom)
			            )

			            let basePixelWidth = Float(stroke.worldWidth * zoom)
			            let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

			            var transformUniform = StrokeTransform(
			                relativeOffset: .zero,
			                rotatedOffsetScreen: rotatedOffsetScreen,
			                zoomScale: Float(zoom),
			                screenWidth: Float(viewSize.width),
			                screenHeight: Float(viewSize.height),
			                rotationAngle: rotation,
			                halfPixelWidth: halfPixelWidth,
			                featherPx: 1.0,
			                depth: zDepthBias + strokeDepth(for: stroke.depthID) * zDepthScale
			            )

			            encoder.setVertexBytes(&transformUniform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
			            encoder.setFragmentBytes(&transformUniform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
			            encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
			            encoder.drawPrimitives(type: .triangleStrip,
			                                   vertexStart: 0,
			                                   vertexCount: 4,
			                                   instanceCount: stroke.segments.count)

				            debugDrawnNodesThisFrame += 1
				            debugDrawnVerticesThisFrame += 4 * stroke.segments.count
				        }

                        // Live paint preview (no-depth-write): render as the newest stroke inside this layer's no-write pass.
                        if brushSettings.toolMode == .paint, brushSettings.depthWriteEnabled == false {
                            let selectedLayer = selectedLayerID ?? layers.first?.id
                            let isTargetLayer = strokeLayerFilterID == nil || (selectedLayer != nil && strokeLayerFilterID == selectedLayer)
                            if isTargetLayer,
                               let target = currentDrawingTarget,
                               case .canvas(let targetFrame) = target,
                               liveStrokeOrigin != nil,
                               let screenPoints = buildLiveScreenPoints(),
                               screenPoints.count >= 2 {
                                let targetID = ObjectIdentifier(targetFrame)
                                if let transform = visibleFractalFrameTransforms[targetID] {
                                    let scaleFromActive = transform.scale
                                    let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
                                    let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation

                                    let liveStroke = createStrokeForFrame(screenPoints: screenPoints,
                                                                         frame: targetFrame,
                                                                         viewSize: viewSize,
                                                                         depthID: peekStrokeDepthID(),
                                                                         color: brushSettings.color,
                                                                         depthWriteEnabled: false)
                                    if !liveStroke.segments.isEmpty, let segmentBuffer = liveStroke.segmentBuffer {
                                        let zoom = max(zoomInFrame, 1e-6)
                                        let dx = liveStroke.origin.x - cameraCenterInFrame.x
                                        let dy = liveStroke.origin.y - cameraCenterInFrame.y

                                        let rotatedOffsetScreen = SIMD2<Float>(
                                            Float((dx * c - dy * s) * zoom),
                                            Float((dx * s + dy * c) * zoom)
                                        )

                                        let basePixelWidth = Float(liveStroke.worldWidth * zoom)
                                        let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

                                        var transformUniform = StrokeTransform(
                                            relativeOffset: .zero,
                                            rotatedOffsetScreen: rotatedOffsetScreen,
                                            zoomScale: Float(zoom),
                                            screenWidth: Float(viewSize.width),
                                            screenHeight: Float(viewSize.height),
                                            rotationAngle: rotation,
                                            halfPixelWidth: halfPixelWidth,
                                            featherPx: 1.0,
                                            depth: zDepthBias + strokeDepth(for: liveStroke.depthID) * zDepthScale
                                        )

                                        encoder.setVertexBytes(&transformUniform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
                                        encoder.setFragmentBytes(&transformUniform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
                                        encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
                                        encoder.drawPrimitives(type: .triangleStrip,
                                                               vertexStart: 0,
                                                               vertexCount: 4,
                                                               instanceCount: liveStroke.segments.count)

                                        debugDrawnNodesThisFrame += 1
                                        debugDrawnVerticesThisFrame += 4 * liveStroke.segments.count
                                    }
                                }
                            }
                        }
				    }

		    private func renderVisibleCards(encoder: MTLRenderCommandEncoder,
		                                    viewSize: CGSize,
		                                    cameraCenterWorld: SIMD2<Double>,
		                                    zoomActive: Double,
		                                    rotation: Float) {
		        guard !visibleFractalFramesDrawOrder.isEmpty else { return }

		        for frame in visibleFractalFramesDrawOrder {
		            guard !frame.cards.isEmpty else { continue }
		            let id = ObjectIdentifier(frame)
		            guard let transform = visibleFractalFrameTransforms[id] else { continue }

		            let scaleFromActive = transform.scale
		            let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
		            let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation

		            renderFrame(frame,
		                        cameraCenterInThisFrame: cameraCenterInFrame,
		                        viewSize: viewSize,
		                        currentZoom: zoomInFrame,
		                        currentRotation: rotation,
		                        encoder: encoder,
		                        renderStrokes: false,
		                        renderCards: true)
		        }
		    }

			    private func renderVisibleZStack(encoder: MTLRenderCommandEncoder,
			                                     viewSize: CGSize,
			                                     cameraCenterWorld: SIMD2<Double>,
			                                     zoomActive: Double,
			                                     rotation: Float) {
		        guard !visibleFractalFramesDrawOrder.isEmpty else { return }

		        if zOrder.isEmpty {
		            ensureDefaultLayersIfNeeded()
		            syncZOrderWithCanvas()
		        }

		        let items = zOrder
		        guard !items.isEmpty else { return }

		        func clearDepthAndStencilForZItem() {
		            encoder.setRenderPipelineState(depthClearPipelineState)
		            encoder.setDepthStencilState(stencilStateWrite)
		            encoder.setStencilReferenceValue(0)
		            encoder.setCullMode(.none)
		            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		        }

		        var visibleCardsByID: [UUID: (card: Card, frame: Frame, cameraCenterInFrame: SIMD2<Double>, zoomInFrame: Double)] = [:]
		        visibleCardsByID.reserveCapacity(32)

		        for frame in visibleFractalFramesDrawOrder {
		            guard !frame.cards.isEmpty else { continue }
		            let id = ObjectIdentifier(frame)
		            guard let transform = visibleFractalFrameTransforms[id] else { continue }
		            let scaleFromActive = transform.scale
		            let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
		            let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation
		            for card in frame.cards {
		                if card.isHidden { continue }
		                visibleCardsByID[card.id] = (card: card,
		                                             frame: frame,
		                                             cameraCenterInFrame: cameraCenterInFrame,
		                                             zoomInFrame: zoomInFrame)
		            }
		        }

		        // Bottom → top, so top items draw last.
		        for idx in stride(from: items.count - 1, through: 0, by: -1) {
		            let item = items[idx]

		            switch item {
		            case .layer(let layerID):
		                if layers.first(where: { $0.id == layerID })?.isHidden == true {
		                    continue
		                }
		                // Reset depth between z-stack items so each layer/card has the full depth range
		                // available for per-stroke ordering (prevents depth quantization when many
		                // z-items exist).
		                clearDepthAndStencilForZItem()
		                // Depth-write strokes for this layer (per-frame batching).
		                for frame in visibleFractalFramesDrawOrder {
		                    guard !frame.strokes.isEmpty else { continue }
		                    let id = ObjectIdentifier(frame)
		                    guard let transform = visibleFractalFrameTransforms[id] else { continue }

		                    let scaleFromActive = transform.scale
		                    let zoomInFrame = zoomActive / max(scaleFromActive, 1e-12)
		                    let cameraCenterInFrame = cameraCenterWorld * scaleFromActive + transform.translation

		                    renderFrame(frame,
		                                cameraCenterInThisFrame: cameraCenterInFrame,
		                                viewSize: viewSize,
		                                currentZoom: zoomInFrame,
		                                currentRotation: rotation,
		                                encoder: encoder,
		                                renderStrokes: true,
		                                renderCards: false,
		                                renderNoDepthWriteStrokes: false,
		                                strokeLayerFilterID: layerID,
		                                zDepthBias: 0.0,
		                                zDepthScale: 1.0)
		                }

		                // No-depth-write strokes for this layer (globally sorted by depthID).
		                renderVisibleNoDepthWriteStrokes(encoder: encoder,
		                                                 viewSize: viewSize,
		                                                 cameraCenterWorld: cameraCenterWorld,
		                                                 zoomActive: zoomActive,
		                                                 rotation: rotation,
		                                                 strokeLayerFilterID: layerID,
		                                                 zDepthBias: 0.0,
		                                                 zDepthScale: 1.0)

		            case .card(let cardID):
		                guard let entry = visibleCardsByID[cardID] else { continue }
		                // Reset depth between z-stack items so this card doesn't interact with
		                // stroke depth values from other layers/cards.
		                clearDepthAndStencilForZItem()
		                renderFrame(entry.frame,
		                            cameraCenterInThisFrame: entry.cameraCenterInFrame,
		                            viewSize: viewSize,
		                            currentZoom: entry.zoomInFrame,
		                            currentRotation: rotation,
		                            encoder: encoder,
		                            renderStrokes: false,
		                            renderCards: true,
		                            renderNoDepthWriteStrokes: false,
		                            cardFilterID: cardID,
		                            zDepthBias: 0.0,
		                            zDepthScale: 1.0)
		            }
		        }
		    }

		    private func renderSections(in frame: Frame,
		                                cameraCenterInThisFrame: SIMD2<Double>,
		                                viewSize: CGSize,
		                                currentZoom: Double,
		                                currentRotation: Float,
		                                cullRadiusScreen: Double,
		                                encoder: MTLRenderCommandEncoder) {
		        guard !frame.sections.isEmpty else { return }

		        let zoom = max(currentZoom, 1e-6)

		        encoder.setDepthStencilState(stencilStateDefault)
		        encoder.setCullMode(.none)

		        for section in frame.sections {
		            let bounds = section.bounds
		            guard bounds != .null else { continue }

		            // Screen-space culling (stable across extreme zoom).
		            let center = SIMD2<Double>(Double(bounds.midX), Double(bounds.midY))
		            let radiusWorld = 0.5 * hypot(Double(bounds.width), Double(bounds.height))
		            let dx = center.x - cameraCenterInThisFrame.x
		            let dy = center.y - cameraCenterInThisFrame.y
		            let distScreen = hypot(dx, dy) * zoom
		            let radiusScreen = radiusWorld * zoom
		            if (distScreen - radiusScreen) > cullRadiusScreen {
		                continue
		            }

		            let borderWidthWorld = sectionBorderWidthPx / zoom
		            section.rebuildRenderBuffersIfNeeded(device: device, borderWidthWorld: borderWidthWorld)

		            let origin = section.origin
		            let relativeOffset = origin - cameraCenterInThisFrame
		            var transform = CardTransform(
		                relativeOffset: SIMD2<Float>(Float(relativeOffset.x), Float(relativeOffset.y)),
		                zoomScale: Float(zoom),
		                screenWidth: Float(viewSize.width),
		                screenHeight: Float(viewSize.height),
		                rotationAngle: currentRotation,
		                depth: 1.0
		            )

		            // 1) Fill (semi-transparent)
		            if let buffer = section.fillVertexBuffer, section.fillVertexCount > 0 {
		                encoder.setRenderPipelineState(sectionFillPipelineState)
		                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
		                encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)

		                var fill = section.color
		                fill.w = min(max(section.fillOpacity, 0.0), 1.0)
		                encoder.setFragmentBytes(&fill, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
		                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: section.fillVertexCount)
		                debugDrawnNodesThisFrame += 1
		                debugDrawnVerticesThisFrame += section.fillVertexCount
		            }

		            // 2) Border (fully opaque)
		            if let buffer = section.borderVertexBuffer, section.borderVertexCount > 0 {
		                encoder.setRenderPipelineState(sectionFillPipelineState)
		                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
		                encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)

		                var border = section.color
		                border.w = 1.0
		                encoder.setFragmentBytes(&border, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
		                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: section.borderVertexCount)
		                debugDrawnNodesThisFrame += 1
		                debugDrawnVerticesThisFrame += section.borderVertexCount
		            }

		            // 3) Name label (opaque box with black text)
		            if section.labelTexture == nil && !pendingSectionLabelBuilds.contains(section.id) {
		                pendingSectionLabelBuilds.insert(section.id)
		                let sectionID = section.id
		                DispatchQueue.main.async { [weak self] in
		                    guard let self else { return }
		                    section.ensureLabelTexture(device: self.device)
		                    self.pendingSectionLabelBuilds.remove(sectionID)
		                }
		            }

		            guard let labelTexture = section.labelTexture else { continue }
		            guard section.labelWorldSize.x > 0, section.labelWorldSize.y > 0 else { continue }

			            // Keep the label box a constant on-screen size (and offset) regardless of zoom,
			            // and always place it *outside* the section bounds.
			            //
			            // If the label would exceed 25% of the section width (in screen space), hide it.
			            let labelSizeWorld = SIMD2<Double>(section.labelWorldSize.x / zoom,
			                                              section.labelWorldSize.y / zoom)
			            let maxLabelWidthWorld = Double(bounds.width) * 0.5
			            if maxLabelWidthWorld.isFinite, maxLabelWidthWorld > 0, labelSizeWorld.x > maxLabelWidthWorld {
			                continue
			            }
			            let labelMarginWorld = sectionLabelMarginPx / zoom
			            let labelCenter = SIMD2<Double>(
			                Double(bounds.minX) + labelMarginWorld + labelSizeWorld.x * 0.5,
			                Double(bounds.minY) - labelMarginWorld - labelSizeWorld.y * 0.5
		            )

		            let labelRelativeOffset = labelCenter - cameraCenterInThisFrame
		            var labelTransform = CardTransform(
		                relativeOffset: SIMD2<Float>(Float(labelRelativeOffset.x), Float(labelRelativeOffset.y)),
		                zoomScale: Float(zoom),
		                screenWidth: Float(viewSize.width),
		                screenHeight: Float(viewSize.height),
		                rotationAngle: currentRotation,
		                depth: 1.0
		            )

		            let hw = Float(labelSizeWorld.x * 0.5)
		            let hh = Float(labelSizeWorld.y * 0.5)
		            let labelVerts: [StrokeVertex] = [
		                StrokeVertex(position: SIMD2<Float>(-hw, -hh), uv: SIMD2<Float>(0, 0), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>( hw, -hh), uv: SIMD2<Float>(1, 0), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>(-hw,  hh), uv: SIMD2<Float>(0, 1), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>( hw, -hh), uv: SIMD2<Float>(1, 0), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>( hw,  hh), uv: SIMD2<Float>(1, 1), color: SIMD4<Float>(1, 1, 1, 1)),
		                StrokeVertex(position: SIMD2<Float>(-hw,  hh), uv: SIMD2<Float>(0, 1), color: SIMD4<Float>(1, 1, 1, 1))
		            ]

		            var style = CardStyleUniforms(
		                cardHalfSize: SIMD2<Float>(hw, hh),
		                zoomScale: Float(zoom),
		                cornerRadiusPx: sectionLabelCornerRadiusPx,
		                shadowBlurPx: 0.0,
		                shadowOpacity: 0.0,
		                cardOpacity: 1.0
		            )

		            encoder.setRenderPipelineState(cardPipelineState)
		            labelVerts.withUnsafeBytes { bytes in
		                guard let base = bytes.baseAddress else { return }
		                encoder.setVertexBytes(base, length: bytes.count, index: 0)
		            }
		            encoder.setVertexBytes(&labelTransform, length: MemoryLayout<CardTransform>.stride, index: 1)
		            encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
		            encoder.setFragmentTexture(labelTexture, index: 0)
		            encoder.setFragmentSamplerState(samplerState, index: 0)
		            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

		            debugDrawnNodesThisFrame += 1
		            debugDrawnVerticesThisFrame += 6
		        }
		    }

    /// Recursively render a frame and adjacent depth levels (depth ±1).
    ///
    /// ** BIDIRECTIONAL RENDERING:**
    /// We now render in three layers:
    /// 1. Parent frame (background - depth -1)
    /// 2. Current frame (middle layer - depth 0)
    /// 3. Child frames (foreground details - depth +1)
    ///
    /// This ensures strokes remain visible when transitioning between depths.
    ///
    /// - Parameters:
    ///   - frame: The frame to render
    ///   - cameraCenterInThisFrame: Where the camera is positioned in this frame's coordinate system
    ///   - viewSize: The view dimensions
    ///   - currentZoom: The current zoom level (adjusted for each frame level)
    ///   - currentRotation: The rotation angle
    ///   - encoder: The Metal render encoder
	    func renderFrame(_ frame: Frame,
	                     cameraCenterInThisFrame: SIMD2<Double>,
	                     viewSize: CGSize,
	                     currentZoom: Double,
	                     currentRotation: Float,
	                     encoder: MTLRenderCommandEncoder,
	                     excludedChild: Frame? = nil,
	                     depthFromActive: Int = 0,
	                     renderStrokes: Bool = true,
	                     renderCards: Bool = true,
	                     renderNoDepthWriteStrokes: Bool = true,
	                     strokeLayerFilterID: UUID? = nil,
	                     cardFilterID: UUID? = nil,
	                     zDepthBias: Float = 0.0,
	                     zDepthScale: Float = 1.0) { // NEW: allow split passes

        /*
        // LAYER 1: LEGACY (Telescoping) PARENT RENDERING -------------------------------
        // Previously rendered the parent frame (depth -1) as a background layer using
        // `originInParent` and `scaleRelativeToParent`. This is disabled for the fractal grid
        // neighborhood renderer (same-depth tiling).
        */

        // LAYER 2: RENDER THIS FRAME (Middle Layer - Depth 0) --------------------------

        // 2.1: RENDER CANVAS STROKES (Background layer - below cards)
        // SCREEN SPACE CULLING FIX:
        // Instead of calculating world bounds (which fail at extreme zoom), we calculate
        // the "Maximum Visible Radius" from the screen center in screen-space pixels.
        // This is numerically stable at all zoom levels because screen dimensions are constant.

        let screenW = Double(viewSize.width)
        let screenH = Double(viewSize.height)

        // Distance from screen center to corner (diagonal)
        let screenRadius = sqrt(screenW * screenW + screenH * screenH) * 0.5

        // Apply Culling Multiplier for testing
        let cullRadius = screenRadius * brushSettings.cullingMultiplier

	        if renderStrokes {
	            // Sections are rendered as a global bottom layer in `draw(in:)`.

	            // Render canvas strokes using depth testing (early-Z).
	            encoder.setRenderPipelineState(strokeSegmentPipelineState)
	            encoder.setCullMode(.none)
	            encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

            let zoom = max(currentZoom, 1e-6)
            let angle = Double(currentRotation)
            let c = cos(angle)
            let s = sin(angle)

                    if brushSettings.isMaskEraser {
                        let selectedLayer = selectedLayerID ?? layers.first?.id
                        if brushSettings.hitTestAllLayers ||
                            strokeLayerFilterID == nil ||
                            (selectedLayer != nil && strokeLayerFilterID == selectedLayer) {
                            drawLiveEraserOnCanvasIfNeeded(frame: frame,
                                                           cameraCenterInThisFrame: cameraCenterInThisFrame,
                                                           viewSize: viewSize,
                                                           currentZoom: currentZoom,
                                                           currentRotation: currentRotation,
                                                           zDepthBias: zDepthBias,
                                                           zDepthScale: zDepthScale,
                                                           encoder: encoder)
                        }
                    }

	        let strokeCount = frame.strokes.count
	        func depthForStroke(_ stroke: Stroke) -> Float {
	            zDepthBias + strokeDepth(for: stroke.depthID) * zDepthScale
	        }

        func drawStroke(_ stroke: Stroke, depth: Float) {
            guard !stroke.segments.isEmpty, let segmentBuffer = stroke.segmentBuffer else { return }

            // ZOOM-BASED CULLING: Skip strokes drawn at extreme zoom when we're zoomed way out
            // If current zoom is more than 100,000x higher than when the stroke was created,
            // the stroke would be invisible (sub-pixel), so skip all math and rendering
            let strokeZoom = max(Double(stroke.zoomEffectiveAtCreation), 1.0) // Treat 0 as 1
            if zoom > strokeZoom * 100_000.0 {
                return
            }

            let dx = stroke.origin.x - cameraCenterInThisFrame.x
            let dy = stroke.origin.y - cameraCenterInThisFrame.y

            // Screen-space culling (stable at extreme zoom levels).
            // Condition: distWorld > (radiusWorld + cullRadius/zoom)
	            let thresholdWorld = stroke.cullingRadiusWorld + (cullRadius / max(zoom, 1e-9))
	            let dist2 = dx * dx + dy * dy
	            if dist2 > thresholdWorld * thresholdWorld { return }

		            if stroke.hasAnyLink,
		               let rectFrame = strokeBoundsRectInContainerSpace(stroke),
		               let rectActive = frameRectInActiveWorld(rectFrame, frame: frame) {
		                let padded = paddedActiveRect(rectActive, frame: frame, paddingInFrameWorld: linkHighlightPaddingPx)
		                recordLinkHighlightBounds(link: stroke.link, sectionID: stroke.linkSectionID, rectActive: padded)
		            }

	            let rotatedOffsetScreen = SIMD2<Float>(
	                Float((dx * c - dy * s) * zoom),
	                Float((dx * s + dy * c) * zoom)
	            )

            let basePixelWidth = Float(stroke.worldWidth * zoom)
            let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

            var transform = StrokeTransform(
                relativeOffset: .zero,
                rotatedOffsetScreen: rotatedOffsetScreen,
                zoomScale: Float(zoom),
                screenWidth: Float(viewSize.width),
                screenHeight: Float(viewSize.height),
                rotationAngle: currentRotation,
                halfPixelWidth: halfPixelWidth,
                featherPx: 1.0,
                depth: depth
            )

            encoder.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            encoder.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: stroke.segments.count)

            debugDrawnNodesThisFrame += 1
            debugDrawnVerticesThisFrame += 4 * stroke.segments.count
        }

        // Live paint preview (depth-write): render as the newest stroke inside the selected layer pass.
        if brushSettings.toolMode == .paint, brushSettings.depthWriteEnabled {
            let selectedLayer = selectedLayerID ?? layers.first?.id
            let isTargetLayer = strokeLayerFilterID == nil || (selectedLayer != nil && strokeLayerFilterID == selectedLayer)
            if isTargetLayer,
               let target = currentDrawingTarget,
               case .canvas(let targetFrame) = target,
               targetFrame === frame,
               liveStrokeOrigin != nil,
               let screenPoints = buildLiveScreenPoints(),
               screenPoints.count >= 2 {
                let liveStroke = createStrokeForFrame(screenPoints: screenPoints,
                                                     frame: frame,
                                                     viewSize: viewSize,
                                                     depthID: peekStrokeDepthID(),
                                                     color: brushSettings.color,
                                                     depthWriteEnabled: true)
                encoder.setRenderPipelineState(strokeSegmentPipelineState)
                encoder.setDepthStencilState(strokeDepthStateWrite)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
                drawStroke(liveStroke, depth: depthForStroke(liveStroke))
            }
        }

        // Depth-write strokes: batched (one draw call per frame).
        var writeStrokesToBatch: [Stroke] = []
        writeStrokesToBatch.reserveCapacity(min(strokeCount, 256))
        var batchedWriteInstanceCount: Int = 0

        func considerStrokeForBatch(_ stroke: Stroke) {
            if let strokeLayerFilterID {
                let effective = stroke.layerID ?? layers.first?.id
                if effective != strokeLayerFilterID {
                    // Allow global pixel-eraser mask strokes to be applied in every layer pass.
                    if !(stroke.maskAppliesToAllLayers && stroke.color.w == 0) {
                        return
                    }
                }
            }
            guard stroke.depthWriteEnabled else { return }
            guard !stroke.batchedSegments.isEmpty else { return }

            let strokeZoom = max(Double(stroke.zoomEffectiveAtCreation), 1.0)
            if zoom > strokeZoom * 100_000.0 { return }

            let dx = stroke.origin.x - cameraCenterInThisFrame.x
            let dy = stroke.origin.y - cameraCenterInThisFrame.y
            let thresholdWorld = stroke.cullingRadiusWorld + (cullRadius / max(zoom, 1e-9))
            let dist2 = dx * dx + dy * dy
            if dist2 > thresholdWorld * thresholdWorld { return }

            if stroke.hasAnyLink,
               let rectFrame = strokeBoundsRectInContainerSpace(stroke),
               let rectActive = frameRectInActiveWorld(rectFrame, frame: frame) {
                let padded = paddedActiveRect(rectActive, frame: frame, paddingInFrameWorld: linkHighlightPaddingPx)
                recordLinkHighlightBounds(link: stroke.link, sectionID: stroke.linkSectionID, rectActive: padded)
            }

            writeStrokesToBatch.append(stroke)
            batchedWriteInstanceCount += stroke.batchedSegments.count
        }

        if strokeCount > 0 {
            for i in stride(from: strokeCount - 1, through: 0, by: -1) {
                considerStrokeForBatch(frame.strokes[i])
            }
        }

        if batchedWriteInstanceCount > 0,
           let upload = allocateBatchedSegmentStorage(byteCount: batchedWriteInstanceCount * MemoryLayout<BatchedStrokeSegmentInstance>.stride) {
            let writePtr = upload.destination
            var byteOffset = 0

            for stroke in writeStrokesToBatch {
                let segments = stroke.batchedSegments
                let bytesToCopy = segments.count * MemoryLayout<BatchedStrokeSegmentInstance>.stride
                segments.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    memcpy(writePtr.advanced(by: byteOffset), baseAddress, bytesToCopy)
                }
                byteOffset += bytesToCopy
            }

            var batchedTransform = BatchedStrokeTransform(
                cameraCenterWorld: SIMD2<Float>(Float(cameraCenterInThisFrame.x), Float(cameraCenterInThisFrame.y)),
                zoomScale: Float(zoom),
                screenWidth: Float(viewSize.width),
                screenHeight: Float(viewSize.height),
                rotationAngle: currentRotation,
                featherPx: 1.0
            )
	            batchedTransform.depthBias = zDepthBias
	            batchedTransform.depthScale = zDepthScale

            encoder.setRenderPipelineState(strokeSegmentBatchedPipelineState)
            encoder.setDepthStencilState(strokeDepthStateWrite)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&batchedTransform, length: MemoryLayout<BatchedStrokeTransform>.stride, index: 1)
            encoder.setFragmentBytes(&batchedTransform, length: MemoryLayout<BatchedStrokeTransform>.stride, index: 1)
            encoder.setVertexBuffer(upload.buffer, offset: upload.offset, index: 2)
            encoder.drawPrimitives(type: .triangleStrip,
                                   vertexStart: 0,
                                   vertexCount: 4,
                                   instanceCount: batchedWriteInstanceCount)

            debugDrawnNodesThisFrame += 1
            debugDrawnVerticesThisFrame += 4 * batchedWriteInstanceCount
        }

        /*
        // Depth-write strokes: LEGACY per-stroke path (reference only).
        encoder.setDepthStencilState(strokeDepthStateWrite)
        if strokeCount > 0 {
            for i in stride(from: strokeCount - 1, through: 0, by: -1) {
                let stroke = frame.strokes[i]
                guard stroke.depthWriteEnabled else { continue }
                drawStroke(stroke, depth: depthForStroke(stroke))
            }
        }
        */

	        if renderNoDepthWriteStrokes {
	            // No-depth-write strokes: oldest -> newest (painter's algorithm), but depth-tested.
	            encoder.setRenderPipelineState(strokeSegmentPipelineState)
	            encoder.setCullMode(.none)
	            encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
	            encoder.setDepthStencilState(strokeDepthStateNoWrite)
	            if strokeCount > 0 {
	                var noWrite: [Stroke] = []
	                noWrite.reserveCapacity(min(strokeCount, 128))

	                for stroke in frame.strokes where !stroke.depthWriteEnabled {
	                    if let strokeLayerFilterID {
	                        let effective = stroke.layerID ?? layers.first?.id
	                        if effective != strokeLayerFilterID { continue }
	                    }
	                    noWrite.append(stroke)
	                }

	                if !noWrite.isEmpty {
	                    noWrite.sort { $0.depthID < $1.depthID }
	                    for stroke in noWrite {
	                        drawStroke(stroke, depth: depthForStroke(stroke))
	                    }
	                }
	            }
	        }

	        // 2.1.5: LINK HIGHLIGHT OVERLAY (Selected strokes) [DISABLED]
	        // Replaced by rounded-rect overlays rendered in active space via `renderLinkHighlightOverlays(...)`.
	        /*
	        if let selection = linkSelection {
	            var highlightStrokeRefs: [LinkedStrokeRef] = []
	            highlightStrokeRefs.reserveCapacity(min(selection.strokes.count, 8))
	            var highlightInstanceCount = 0

	            for ref in selection.strokes {
	                guard case .canvas(let selectedFrame) = ref.container, selectedFrame === frame else { continue }
	                guard let stroke = resolveCurrentStroke(for: ref) else { continue }
	                guard !stroke.batchedSegments.isEmpty else { continue }

	                let strokeZoom = max(Double(stroke.zoomEffectiveAtCreation), 1.0)
	                if zoom > strokeZoom * 100_000.0 { continue }

	                let dx = stroke.origin.x - cameraCenterInThisFrame.x
	                let dy = stroke.origin.y - cameraCenterInThisFrame.y
	                let thresholdWorld = stroke.cullingRadiusWorld + (cullRadius / max(zoom, 1e-9))
	                let dist2 = dx * dx + dy * dy
	                if dist2 > thresholdWorld * thresholdWorld { continue }

	                highlightStrokeRefs.append(ref)
	                highlightInstanceCount += stroke.batchedSegments.count
	            }

	            if highlightInstanceCount > 0,
	               let upload = allocateBatchedSegmentStorage(byteCount: highlightInstanceCount * MemoryLayout<BatchedStrokeSegmentInstance>.stride) {
	                let stride = MemoryLayout<BatchedStrokeSegmentInstance>.stride
	                var byteOffset = 0

	                for ref in highlightStrokeRefs {
	                    guard let stroke = resolveCurrentStroke(for: ref) else { continue }

	                    let highlightWidthWorld = stroke.worldWidth + (linkHighlightExtraWidthPx / max(zoom, 1e-6))
	                    let widthF = Float(highlightWidthWorld)

	                    for seg in stroke.batchedSegments {
	                        var inst = seg
	                        inst.color = linkHighlightColor
	                        inst.params = SIMD2<Float>(widthF, seg.params.y)
	                        upload.destination.advanced(by: byteOffset)
	                            .assumingMemoryBound(to: BatchedStrokeSegmentInstance.self)
	                            .pointee = inst
	                        byteOffset += stride
	                    }
	                }

	                var highlightTransform = BatchedStrokeTransform(
	                    cameraCenterWorld: SIMD2<Float>(Float(cameraCenterInThisFrame.x), Float(cameraCenterInThisFrame.y)),
	                    zoomScale: Float(zoom),
	                    screenWidth: Float(viewSize.width),
	                    screenHeight: Float(viewSize.height),
	                    rotationAngle: currentRotation,
	                    featherPx: 1.0
	                )

	                encoder.setRenderPipelineState(strokeSegmentBatchedPipelineState)
	                encoder.setDepthStencilState(stencilStateDefault) // Ignore depth; selection should be visible.
	                encoder.setCullMode(.none)
	                encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
	                encoder.setVertexBytes(&highlightTransform, length: MemoryLayout<BatchedStrokeTransform>.stride, index: 1)
	                encoder.setFragmentBytes(&highlightTransform, length: MemoryLayout<BatchedStrokeTransform>.stride, index: 1)
	                encoder.setVertexBuffer(upload.buffer, offset: upload.offset, index: 2)
	                encoder.drawPrimitives(type: .triangleStrip,
	                                       vertexStart: 0,
	                                       vertexCount: 4,
	                                       instanceCount: highlightInstanceCount)

	                debugDrawnNodesThisFrame += 1
	                debugDrawnVerticesThisFrame += 4 * highlightInstanceCount
	            }
	        }
	        */
        }

	        // 2.2: RENDER CARDS (Middle layer - on top of canvas strokes)
	        if renderCards {
	            let cardsToRender = frame.cards
	        for card in cardsToRender {
	            if let cardFilterID, card.id != cardFilterID {
	                continue
	            }
	            if card.isHidden {
	                continue
	            }
            // A. Calculate Position
            // Card lives in the Frame, so it moves with the Frame
            let relativeOffsetDouble = card.origin - cameraCenterInThisFrame
            let cardOffsetLocal = cardOffsetFromCameraInLocalSpace(card: card,
                                                                   cameraCenter: cameraCenterInThisFrame)

            // SCREEN SPACE CULLING for cards
            let distWorld = sqrt(relativeOffsetDouble.x * relativeOffsetDouble.x + relativeOffsetDouble.y * relativeOffsetDouble.y)
            let distScreen = distWorld * currentZoom
            let cardRadiusWorld = sqrt(pow(card.size.x, 2) + pow(card.size.y, 2)) * 0.5
            let cardRadiusScreen = cardRadiusWorld * currentZoom

            if (distScreen - cardRadiusScreen) > cullRadius {
                continue // Cull card
            }

	            let cardSurfaceDepth = zDepthBias + StrokeDepth.metalDepth(for: 0) * zDepthScale

	            let relativeOffset = SIMD2<Float>(Float(cardOffsetLocal.x), Float(cardOffsetLocal.y))
	            let cardHalfSize = SIMD2<Float>(Float(card.size.x * 0.5), Float(card.size.y * 0.5))
	            var style = CardStyleUniforms(
	                cardHalfSize: cardHalfSize,
	                zoomScale: Float(currentZoom),
	                cornerRadiusPx: cardCornerRadiusPx,
	                // Scale with zoom so the shadow shrinks when zooming out.
	                shadowBlurPx: cardShadowBlurPx * Float(currentZoom),
	                shadowOpacity: cardShadowOpacity,
	                cardOpacity: card.opacity
	            )

            // B. Handle Rotation
            // Cards have their own rotation property
            // Total Rotation = Camera Rotation + Card Rotation
            let finalRotation = currentRotation + card.rotation

            var transform = CardTransform(
                relativeOffset: relativeOffset,
                zoomScale: Float(currentZoom),
                screenWidth: Float(viewSize.width),
                screenHeight: Float(viewSize.height),
                rotationAngle: finalRotation,
                depth: cardSurfaceDepth
            )

	            if cardShadowEnabled {
	                let shadowExpandWorld = Double(style.shadowBlurPx) / max(currentZoom, 1e-6)
	                let scaleX = (card.size.x * 0.5 + shadowExpandWorld) / max(card.size.x * 0.5, 1e-6)
	                let scaleY = (card.size.y * 0.5 + shadowExpandWorld) / max(card.size.y * 0.5, 1e-6)
	                let shadowVertices = card.localVertices.map { vertex in
	                    StrokeVertex(
	                        position: SIMD2<Float>(vertex.position.x * Float(scaleX), vertex.position.y * Float(scaleY)),
                        uv: vertex.uv,
                        color: vertex.color
                    )
                }

                let shadowOffset = shadowOffsetInCardLocalSpace(offsetPx: cardShadowOffsetPx,
                                                                rotation: finalRotation,
                                                                zoom: currentZoom)
                var shadowTransform = CardTransform(
                    relativeOffset: SIMD2<Float>(Float(cardOffsetLocal.x + shadowOffset.x),
                                                 Float(cardOffsetLocal.y + shadowOffset.y)),
                    zoomScale: Float(currentZoom),
                    screenWidth: Float(viewSize.width),
                    screenHeight: Float(viewSize.height),
                    rotationAngle: finalRotation,
                    depth: cardSurfaceDepth
                )

                if let shadowBuffer = device.makeBuffer(bytes: shadowVertices,
                                                        length: shadowVertices.count * MemoryLayout<StrokeVertex>.stride,
                                                        options: .storageModeShared) {
                    encoder.setDepthStencilState(stencilStateDefault)
                    encoder.setRenderPipelineState(cardShadowPipelineState)
                    encoder.setVertexBytes(&shadowTransform, length: MemoryLayout<CardTransform>.stride, index: 1)
                    encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
                    encoder.setVertexBuffer(shadowBuffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
            }

            //  STEP 1: DRAW CARD BACKGROUND + WRITE STENCIL
            // Write '1' into the stencil buffer where the card pixels are
            encoder.setDepthStencilState(stencilStateWrite)
            encoder.setStencilReferenceValue(1)

	            // C. Set Pipeline & Bind Content Based on Card Type
	            switch card.type {
	            case .solidColor:
	                // Use solid color pipeline (no texture required)
	                encoder.setRenderPipelineState(cardSolidPipelineState)
                encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
                var c = card.backgroundColor
                encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)

            case .image(let texture):
                // Use textured pipeline (requires texture binding)
                encoder.setRenderPipelineState(cardPipelineState)
                encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)

            case .lined(let config):
                // Use procedural lined paper pipeline
                encoder.setRenderPipelineState(cardLinedPipelineState)
                encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)

                // 1. Background Color
                var bg = card.backgroundColor
                encoder.setFragmentBytes(&bg, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

                // 2. Uniforms (Lines)
                // FIX: Calculate World Spacing based on Creation Zoom
                // Formula: SpacingPts / CreationZoom = SpacingWorld
                // Example: 25pts / 1000x = 0.025 world units
                let worldSpacing = config.spacing / Float(card.creationZoom)
                let worldLineWidth = config.lineWidth / Float(card.creationZoom)

                var uniforms = CardShaderUniforms(
                    spacing: worldSpacing,        // Pass WORLD units to shader
                    lineWidth: worldLineWidth,    // Scale line width too!
                    color: config.color,
                    cardWidth: Float(card.size.x),
                    cardHeight: Float(card.size.y)
                )
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CardShaderUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)

            case .grid(let config):
                // Use procedural grid paper pipeline
                encoder.setRenderPipelineState(cardGridPipelineState)
                encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)

                // 1. Background Color
                var bg = card.backgroundColor
                encoder.setFragmentBytes(&bg, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

                // 2. Uniforms (Grid)
                // FIX: Calculate World Spacing based on Creation Zoom
                let worldSpacing = config.spacing / Float(card.creationZoom)
                let worldLineWidth = config.lineWidth / Float(card.creationZoom)

                var uniforms = CardShaderUniforms(
                    spacing: worldSpacing,        // Pass WORLD units to shader
                    lineWidth: worldLineWidth,    // Scale line width too!
                    color: config.color,
                    cardWidth: Float(card.size.x),
                    cardHeight: Float(card.size.y)
                )
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CardShaderUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)

	            case .youtube(let videoID, _):
	                if let texture = ensureYouTubeThumbnailTexture(card: card, videoID: videoID) {
	                    // Render the cached thumbnail like an image card.
	                    encoder.setRenderPipelineState(cardPipelineState)
	                    encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
	                    encoder.setFragmentTexture(texture, index: 0)
	                    encoder.setFragmentSamplerState(samplerState, index: 0)
	                    encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
	                } else {
	                    // Placeholder background (thumbnail loads async).
	                    encoder.setRenderPipelineState(cardSolidPipelineState)
	                    encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
	                    var c = card.backgroundColor
	                    encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
	                    encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
	                }

	            case .plugin:
	                // Plugin cards render a snapshot placeholder (when available); interactive UI is hosted via an overlay runtime.
	                if let texture = card.pluginSnapshotTexture {
	                    encoder.setRenderPipelineState(cardPipelineState)
	                    encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
	                    encoder.setFragmentTexture(texture, index: 0)
	                    encoder.setFragmentSamplerState(samplerState, index: 0)
	                    encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
	                } else {
	                    encoder.setRenderPipelineState(cardSolidPipelineState)
	                    encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
	                    var c = card.backgroundColor
	                    encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
	                    encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
	                }

	            case .drawing:
	                continue // Future: Render nested strokes
	            }

            // D. Draw the Card Quad (writes to both color buffer and stencil)
            let vertexBuffer = device.makeBuffer(
                bytes: card.localVertices,
                length: card.localVertices.count * MemoryLayout<StrokeVertex>.stride,
                options: .storageModeShared
            )
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            //  STEP 2: DRAW CARD STROKES (CLIPPED TO CARD)
            // Only draw where stencil == 1
            let isLiveCardEraserTarget: Bool
            if brushSettings.isMaskEraser, let target = currentDrawingTarget,
               case .card(let targetCard, let targetFrame) = target,
               targetFrame === frame, targetCard === card {
                isLiveCardEraserTarget = true
            } else {
                isLiveCardEraserTarget = false
            }

            let isLiveCardPaintTarget: Bool
            if brushSettings.toolMode == .paint, let target = currentDrawingTarget,
               case .card(let targetCard, let targetFrame) = target,
               targetFrame === frame, targetCard === card {
                isLiveCardPaintTarget = true
            } else {
                isLiveCardPaintTarget = false
            }

            let isLiveCardLassoTarget = (lassoPreviewCard === card && lassoPreviewCardFrame === frame)

            if !card.strokes.isEmpty || isLiveCardEraserTarget || isLiveCardPaintTarget || isLiveCardLassoTarget {
                encoder.setRenderPipelineState(strokeSegmentPipelineState)
                encoder.setStencilReferenceValue(1)
                encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

                // Calculate "magic offset" for card-local coordinates
                let totalRotation = currentRotation + card.rotation
                let offset = SIMD2<Float>(Float(cardOffsetLocal.x), Float(cardOffsetLocal.y))

                func drawCardStroke(_ stroke: Stroke) {
                    guard !stroke.segments.isEmpty, let segmentBuffer = stroke.segmentBuffer else { return }

	                    // ZOOM-BASED CULLING: Skip strokes drawn at extreme zoom when we're zoomed way out
	                    let strokeZoom = max(Double(stroke.zoomEffectiveAtCreation), 1.0) // Treat 0 as 1
	                    if currentZoom > strokeZoom * 100_000.0 {
	                        return
	                    }

		                    if stroke.hasAnyLink,
		                       let rectCard = strokeBoundsRectInContainerSpace(stroke) {
		                        let rectFrame = cardLocalRectToFrameAABB(rectCard, card: card)
		                        if let rectActive = frameRectInActiveWorld(rectFrame, frame: frame) {
		                            let padded = paddedActiveRect(rectActive, frame: frame, paddingInFrameWorld: linkHighlightPaddingPx)
		                            recordLinkHighlightBounds(link: stroke.link, sectionID: stroke.linkSectionID, rectActive: padded)
		                        }
		                    }

	                    let strokeOffset = stroke.origin
	                    let strokeRelativeOffset = offset + SIMD2<Float>(Float(strokeOffset.x), Float(strokeOffset.y))

                    // Calculate screen-space thickness for card strokes
                    let basePixelWidth = Float(stroke.worldWidth * currentZoom)
                    let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

                    // Calculate depth based on stroke's depthID (creation order)
                    let cardStrokeDepth = zDepthBias + strokeDepth(for: stroke.depthID) * zDepthScale

                    var strokeTransform = StrokeTransform(
                        relativeOffset: strokeRelativeOffset,
                        rotatedOffsetScreen: SIMD2<Float>(Float((Double(strokeRelativeOffset.x) * cos(Double(totalRotation)) - Double(strokeRelativeOffset.y) * sin(Double(totalRotation))) * currentZoom),
                                                          Float((Double(strokeRelativeOffset.x) * sin(Double(totalRotation)) + Double(strokeRelativeOffset.y) * cos(Double(totalRotation))) * currentZoom)),
                        zoomScale: Float(currentZoom),
                        screenWidth: Float(viewSize.width),
                        screenHeight: Float(viewSize.height),
                        rotationAngle: totalRotation,
                        halfPixelWidth: halfPixelWidth,
                        featherPx: 1.0,
                        depth: cardStrokeDepth
                    )

                    encoder.setVertexBytes(&strokeTransform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
                    encoder.setFragmentBytes(&strokeTransform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
                    encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: stroke.segments.count)
                }

                let liveCardMaskStroke: Stroke?
                if isLiveCardEraserTarget, let screenPoints = buildLiveScreenPoints() {
                    liveCardMaskStroke = createStrokeForCard(
                        screenPoints: screenPoints,
                        card: card,
                        frame: frame,
                        viewSize: viewSize,
                        depthID: peekStrokeDepthID(),
                        color: SIMD4<Float>(0, 0, 0, 0),
                        depthWriteEnabled: true
                    )
                } else {
                    liveCardMaskStroke = nil
                }

                let liveCardPaintStroke: Stroke?
                if isLiveCardPaintTarget, let screenPoints = buildLiveScreenPoints() {
                    liveCardPaintStroke = createStrokeForCard(
                        screenPoints: screenPoints,
                        card: card,
                        frame: frame,
                        viewSize: viewSize,
                        depthID: peekStrokeDepthID(),
                        color: brushSettings.color,
                        depthWriteEnabled: brushSettings.depthWriteEnabled
                    )
                } else {
                    liveCardPaintStroke = nil
                }

                let liveCardLassoStroke = isLiveCardLassoTarget ? lassoPreviewStroke : nil

                let strokeCount = card.strokes.count

                // Depth-write strokes: newest -> oldest (front-to-back).
                encoder.setDepthStencilState(cardStrokeDepthStateWrite)
                if let liveStroke = liveCardMaskStroke {
                    drawCardStroke(liveStroke)
                }
                if let liveStroke = liveCardPaintStroke, liveStroke.depthWriteEnabled {
                    drawCardStroke(liveStroke)
                }
                if strokeCount > 0 {
                    for i in stride(from: strokeCount - 1, through: 0, by: -1) {
                        let stroke = card.strokes[i]
                        guard stroke.depthWriteEnabled else { continue }
                        drawCardStroke(stroke)
                    }
                }

                // No-depth-write strokes: oldest -> newest (painter's), but depth-tested.
                encoder.setDepthStencilState(cardStrokeDepthStateNoWrite)
                if let liveLasso = liveCardLassoStroke {
                    drawCardStroke(liveLasso)
                }
		                for i in 0..<strokeCount {
		                    let stroke = card.strokes[i]
		                    guard !stroke.depthWriteEnabled else { continue }
		                    drawCardStroke(stroke)
		                }
                if let liveStroke = liveCardPaintStroke, !liveStroke.depthWriteEnabled {
                    drawCardStroke(liveStroke)
                }

		                // LINK HIGHLIGHT OVERLAY (Card strokes) [DISABLED]
		                // Replaced by rounded-rect overlays rendered in active space via `renderLinkHighlightOverlays(...)`.
		                /*
		                if let selection = linkSelection {
		                    var selectedCardStrokeRefs: [LinkedStrokeRef] = []
		                    selectedCardStrokeRefs.reserveCapacity(min(selection.strokes.count, 8))

		                    for ref in selection.strokes {
		                        guard case .card(let selectedCard, let selectedFrame) = ref.container,
		                              selectedFrame === frame,
		                              selectedCard === card else { continue }
		                        selectedCardStrokeRefs.append(ref)
		                    }

		                    if !selectedCardStrokeRefs.isEmpty {
		                        encoder.setDepthStencilState(stencilStateRead) // Stencil clip only; ignore depth for highlight.
		                        encoder.setStencilReferenceValue(1)
		                        encoder.setRenderPipelineState(strokeSegmentPipelineState)
		                        encoder.setCullMode(.none)
		                        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

		                        func drawCardStrokeHighlight(_ stroke: Stroke) {
		                            guard !stroke.segments.isEmpty else { return }
		                            let strokeZoom = max(Double(stroke.zoomEffectiveAtCreation), 1.0)
		                            if currentZoom > strokeZoom * 100_000.0 { return }

		                            var highlightSegments: [StrokeSegmentInstance] = []
		                            highlightSegments.reserveCapacity(stroke.segments.count)
		                            for seg in stroke.segments {
		                                highlightSegments.append(StrokeSegmentInstance(p0: seg.p0, p1: seg.p1, color: linkHighlightColor))
		                            }
		                            guard let buffer = device.makeBuffer(bytes: highlightSegments,
		                                                                 length: highlightSegments.count * MemoryLayout<StrokeSegmentInstance>.stride,
		                                                                 options: .storageModeShared) else { return }

		                            let highlightWorldWidth = stroke.worldWidth + (linkHighlightExtraWidthPx / max(currentZoom, 1e-6))
		                            let basePixelWidth = Float(highlightWorldWidth * currentZoom)
		                            let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

		                            let strokeOffset = stroke.origin
		                            let strokeRelativeOffset = offset + SIMD2<Float>(Float(strokeOffset.x), Float(strokeOffset.y))
		                            let cardStrokeDepth = zDepthBias + strokeDepth(for: stroke.depthID) * zDepthScale

		                            var strokeTransform = StrokeTransform(
		                                relativeOffset: strokeRelativeOffset,
		                                rotatedOffsetScreen: SIMD2<Float>(
		                                    Float((Double(strokeRelativeOffset.x) * cos(Double(totalRotation)) - Double(strokeRelativeOffset.y) * sin(Double(totalRotation))) * currentZoom),
		                                    Float((Double(strokeRelativeOffset.x) * sin(Double(totalRotation)) + Double(strokeRelativeOffset.y) * cos(Double(totalRotation))) * currentZoom)
		                                ),
		                                zoomScale: Float(currentZoom),
		                                screenWidth: Float(viewSize.width),
		                                screenHeight: Float(viewSize.height),
		                                rotationAngle: totalRotation,
		                                halfPixelWidth: halfPixelWidth,
		                                featherPx: 1.0,
		                                depth: cardStrokeDepth
		                            )

		                            encoder.setVertexBytes(&strokeTransform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
		                            encoder.setFragmentBytes(&strokeTransform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
		                            encoder.setVertexBuffer(buffer, offset: 0, index: 2)
		                            encoder.drawPrimitives(type: .triangleStrip,
		                                                   vertexStart: 0,
		                                                   vertexCount: 4,
		                                                   instanceCount: highlightSegments.count)
		                        }

		                        for ref in selectedCardStrokeRefs {
		                            guard let stroke = resolveCurrentStroke(for: ref) else { continue }
		                            drawCardStrokeHighlight(stroke)
		                        }
		                    }
		                }
		                */
	            }

	            //  STEP 3: CLEANUP STENCIL (Reset to 0 for next card)
	            // Draw the card quad again with stencil clear mode
            encoder.setRenderPipelineState(cardSolidPipelineState)
            encoder.setDepthStencilState(stencilStateClear)
            encoder.setStencilReferenceValue(0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<CardTransform>.stride, index: 1)
            var clearColor = SIMD4<Float>(0, 0, 0, 0)
            encoder.setFragmentBytes(&clearColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // E. Draw Resize Handles (If Selected) 
            // Handles should not be affected by stencil
            if card.isLocked {
                drawCardLockIcon(card: card,
                                 cameraCenter: cameraCenterInThisFrame,
                                 viewSize: viewSize,
                                 zoom: currentZoom,
                                 rotation: currentRotation,
                                 encoder: encoder)
            }
            if card.isEditing && !card.isLocked {
                encoder.setDepthStencilState(stencilStateDefault) // Disable stencil for handles
                drawCardHandles(card: card,
                                cameraCenter: cameraCenterInThisFrame,
                                viewSize: viewSize,
                                zoom: currentZoom,
                                rotation: currentRotation,
                                encoder: encoder)
            }

            // F. Draw Card Name Label (opaque box, fixed on-screen size, outside the card bounds)
            if cardNamesVisible {
                if card.labelTexture == nil && !pendingCardLabelBuilds.contains(card.id) {
                    pendingCardLabelBuilds.insert(card.id)
                    let cardID = card.id
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        card.ensureLabelTexture(device: self.device)
                        self.pendingCardLabelBuilds.remove(cardID)
                    }
                }

	            if let labelTexture = card.labelTexture,
	               card.labelWorldSize.x > 0, card.labelWorldSize.y > 0 {

	                // Keep the label box a constant on-screen size (and offset) regardless of zoom,
	                // and always place it *outside* the card bounds.
	                //
	                // If the label would exceed 25% of the card width (in screen space), hide it.
	                let cardRectLocal = CGRect(x: -card.size.x * 0.5,
	                                           y: -card.size.y * 0.5,
	                                           width: card.size.x,
	                                           height: card.size.y)
	                let aabb = cardLocalRectToFrameAABB(cardRectLocal, card: card)
	                let labelSizeWorld = SIMD2<Double>(card.labelWorldSize.x / currentZoom,
	                                                   card.labelWorldSize.y / currentZoom)
	                let maxLabelWidthWorld = card.size.x * 0.5
	                if maxLabelWidthWorld.isFinite, maxLabelWidthWorld > 0, labelSizeWorld.x > maxLabelWidthWorld {
	                    continue
	                }
	                let labelMarginWorld = sectionLabelMarginPx / currentZoom
	                let labelCenter = SIMD2<Double>(
	                    Double(aabb.minX) + labelMarginWorld + labelSizeWorld.x * 0.5,
	                    Double(aabb.minY) - labelMarginWorld - labelSizeWorld.y * 0.5
                )

                let labelRelativeOffset = labelCenter - cameraCenterInThisFrame
                var labelTransform = CardTransform(
                    relativeOffset: SIMD2<Float>(Float(labelRelativeOffset.x), Float(labelRelativeOffset.y)),
                    zoomScale: Float(currentZoom),
                    screenWidth: Float(viewSize.width),
                    screenHeight: Float(viewSize.height),
                    rotationAngle: currentRotation,
                    depth: 1.0
                )

                let hw = Float(labelSizeWorld.x * 0.5)
                let hh = Float(labelSizeWorld.y * 0.5)
                let labelVerts: [StrokeVertex] = [
                    StrokeVertex(position: SIMD2<Float>(-hw, -hh), uv: SIMD2<Float>(0, 0), color: SIMD4<Float>(1, 1, 1, 1)),
                    StrokeVertex(position: SIMD2<Float>( hw, -hh), uv: SIMD2<Float>(1, 0), color: SIMD4<Float>(1, 1, 1, 1)),
                    StrokeVertex(position: SIMD2<Float>(-hw,  hh), uv: SIMD2<Float>(0, 1), color: SIMD4<Float>(1, 1, 1, 1)),
                    StrokeVertex(position: SIMD2<Float>( hw, -hh), uv: SIMD2<Float>(1, 0), color: SIMD4<Float>(1, 1, 1, 1)),
                    StrokeVertex(position: SIMD2<Float>( hw,  hh), uv: SIMD2<Float>(1, 1), color: SIMD4<Float>(1, 1, 1, 1)),
                    StrokeVertex(position: SIMD2<Float>(-hw,  hh), uv: SIMD2<Float>(0, 1), color: SIMD4<Float>(1, 1, 1, 1))
                ]

                var style = CardStyleUniforms(
                    cardHalfSize: SIMD2<Float>(hw, hh),
                    zoomScale: Float(currentZoom),
                    cornerRadiusPx: sectionLabelCornerRadiusPx,
                    shadowBlurPx: 0.0,
                    shadowOpacity: 0.0,
                    cardOpacity: 1.0
                )

                encoder.setDepthStencilState(stencilStateDefault)
                encoder.setRenderPipelineState(cardPipelineState)
                labelVerts.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    encoder.setVertexBytes(base, length: bytes.count, index: 0)
                }
                encoder.setVertexBytes(&labelTransform, length: MemoryLayout<CardTransform>.stride, index: 1)
                encoder.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
                encoder.setFragmentTexture(labelTexture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

                debugDrawnNodesThisFrame += 1
                debugDrawnVerticesThisFrame += 6
            }
            }
        }
        }

        // Reset pipeline and stencil state for subsequent rendering (live stroke, overlays, etc.)
        encoder.setRenderPipelineState(strokeSegmentPipelineState)
        encoder.setDepthStencilState(stencilStateDefault)
        /*
        // LAYER 3: LEGACY (Telescoping) CHILD RENDERING -------------------------------
        // Previously rendered child frames (depth +1) recursively. In the fractal grid,
        // we render a same-depth neighborhood (3x3) instead, and depth previews are a
        // separate follow-up step.
        */
    }

    private func buildLiveScreenPoints() -> [CGPoint]? {
        guard !currentTouchPoints.isEmpty else { return nil }

        var screenPoints = currentTouchPoints
        if let last = screenPoints.last,
           let firstPredicted = predictedTouchPoints.first,
           last == firstPredicted {
            screenPoints.append(contentsOf: predictedTouchPoints.dropFirst())
        } else {
            screenPoints.append(contentsOf: predictedTouchPoints)
        }

        guard !screenPoints.isEmpty else { return nil }

        // Keep the live preview cheap and bounded.
        let maxScreenPoints = 1000
        if screenPoints.count > maxScreenPoints {
            let step = max(1, screenPoints.count / maxScreenPoints)
            var downsampled: [CGPoint] = []
            downsampled.reserveCapacity(maxScreenPoints + 1)
            for i in stride(from: 0, to: screenPoints.count, by: step) {
                downsampled.append(screenPoints[i])
            }
            if let last = screenPoints.last, last != downsampled.last {
                downsampled.append(last)
            }
            screenPoints = downsampled
        }

        return screenPoints
    }

    // MARK: - Handwriting Refinement (Debounced)

    private func handwritingTargetsMatch(_ a: DrawingTarget, _ b: DrawingTarget) -> Bool {
        switch (a, b) {
        case (.canvas(let fa), .canvas(let fb)):
            return fa.id == fb.id
        case (.card(let ca, let fa), .card(let cb, let fb)):
            return ca.id == cb.id && fa.id == fb.id
        default:
            return false
        }
    }

    private func smoothStrokePointsForCommit(_ points: [CGPoint]) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        if points.count < 3 {
            return points
        }

        var paddedPoints = points

        // Add phantom point at the start: 2A - B
        if paddedPoints.count >= 2 {
            let first = paddedPoints[0]
            let second = paddedPoints[1]
            let phantomStart = CGPoint(x: 2 * first.x - second.x, y: 2 * first.y - second.y)
            paddedPoints.insert(phantomStart, at: 0)
        }

        // Add phantom point at the end: 2D - C
        if paddedPoints.count >= 3 {
            let last = paddedPoints[paddedPoints.count - 1]
            let secondLast = paddedPoints[paddedPoints.count - 2]
            let phantomEnd = CGPoint(x: 2 * last.x - secondLast.x, y: 2 * last.y - secondLast.y)
            paddedPoints.append(phantomEnd)
        }

        var smooth = catmullRomPoints(points: paddedPoints,
                                      closed: false,
                                      alpha: 0.5,
                                      segmentsPerCurve: 20)

        smooth = simplifyStroke(smooth, minScreenDist: 1.5, minAngleDeg: 5.0)
        return smooth
    }

    private func denoiseRefinedStrokePoints(_ points: [CGPoint], passes: Int = 4) -> [CGPoint] {
        guard points.count > 2, passes > 0 else { return points }

        var current = points
        for _ in 0..<passes {
            var next = current
            for i in 1..<(current.count - 1) {
                let p0 = current[i - 1]
                let p1 = current[i]
                let p2 = current[i + 1]
                next[i] = CGPoint(
                    x: (p0.x + 2.0 * p1.x + p2.x) / 4.0,
                    y: (p0.y + 2.0 * p1.y + p2.y) / 4.0
                )
            }
            current = next
        }
        return current
    }

    private func scheduleHandwritingRefinement() {
        handwritingRefinementWorkItem?.cancel()

        let delay = max(0.0, handwritingRefinementDebounceSeconds)
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingHandwritingRefinement()
        }
        handwritingRefinementWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func flushPendingHandwritingRefinement() {
        handwritingRefinementWorkItem = nil

        guard handwritingRefinementEnabled else {
            pendingHandwritingStrokes.removeAll()
            return
        }

        let pending = pendingHandwritingStrokes
        pendingHandwritingStrokes = []
        guard !pending.isEmpty else { return }

        // Note: This model is text-conditioned, but we intentionally do not expose
        // text context in the UI right now. An empty string still produces a valid
        // one-hot input (terminator-only) so we can run refinement without a textbox.
        let text = ""
        let bias = handwritingRefinementBias
        let inputScale = handwritingRefinementInputScale
        let strength = handwritingRefinementStrength

        // Enforce a consistent coordinate transform across the phrase.
        let zoom = pending[0].zoomAtCreation
        let rotation = pending[0].rotationAngle
        let rotationEpsilon: Float = 1e-6
        let consistent = pending.allSatisfy {
            abs($0.zoomAtCreation - zoom) < 1e-6 && abs($0.rotationAngle - rotation) < rotationEpsilon
        }
        guard consistent else { return }

        handwritingRefinementQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.handwritingRefiner == nil {
                    self.handwritingRefiner = try HandwritingRefinerEngine()
                }
                guard let refiner = self.handwritingRefiner else { return }

                var settings = HandwritingRefinerEngine.Settings()
                settings.bias = bias
                settings.inputScale = inputScale
                settings.refinementStrength = strength

                let session = try refiner.makeSession(text: text, settings: settings)
                let refinedPoints = try self.refineHandwritingPhrase(pending, session: session, zoom: zoom, rotation: rotation)

                DispatchQueue.main.async { [weak self] in
                    self?.applyHandwritingRefinement(pending: pending, refinedPoints: refinedPoints)
                }
	            } catch {
	                // Fail open: keep raw strokes (but surface error in debug builds).
	                #if DEBUG
	                print("Handwriting refinement failed: \(error)")
	                #endif
	            }
	        }
	    }

    private func refineHandwritingPhrase(_ pending: [PendingHandwritingStroke],
                                        session: HandwritingRefinerEngine.Session,
                                        zoom: Double,
                                        rotation: Float) throws -> [[CGPoint]] {
        guard let firstPoint = pending.first?.rawScreenPoints.first else { return [] }

        try session.beginStroke(firstScreenPoint: firstPoint, zoom: zoom, rotationAngle: rotation)

        var refinedFlat: [CGPoint] = [firstPoint]
        refinedFlat.reserveCapacity(pending.reduce(0) { $0 + $1.rawScreenPoints.count })

        for (strokeIndex, capture) in pending.enumerated() {
            let pts = capture.rawScreenPoints
            for (i, p) in pts.enumerated() {
                if strokeIndex == 0 && i == 0 { continue }
                let isStrokeEnd = (i == pts.count - 1)
                let refined = try session.addPoint(p, isFinal: isStrokeEnd)
                refinedFlat.append(refined)
            }
        }

        var perStroke: [[CGPoint]] = []
        perStroke.reserveCapacity(pending.count)

        var offset = 0
        for capture in pending {
            let count = capture.rawScreenPoints.count
            if count == 0 {
                perStroke.append([])
                continue
            }
            perStroke.append(Array(refinedFlat[offset..<(offset + count)]))
            offset += count
        }
        return perStroke
    }

    private func replaceStrokeReferences(oldStrokeID: UUID, with newStroke: Stroke) {
        func map(_ action: UndoAction) -> UndoAction {
            switch action {
            case .drawStroke(let stroke, let target) where stroke.id == oldStrokeID:
                return .drawStroke(stroke: newStroke, target: target)
            case .eraseStroke(let stroke, let strokeIndex, let target) where stroke.id == oldStrokeID:
                return .eraseStroke(stroke: newStroke, strokeIndex: strokeIndex, target: target)
            default:
                return action
            }
        }
        undoStack = undoStack.map(map)
        redoStack = redoStack.map(map)
    }

    private func applyHandwritingRefinement(pending: [PendingHandwritingStroke], refinedPoints: [[CGPoint]]) {
        guard pending.count == refinedPoints.count else { return }

        for (capture, refinedRawPoints) in zip(pending, refinedPoints) {
            let oldStroke = capture.stroke
            let denoised = denoiseRefinedStrokePoints(refinedRawPoints)
            let smoothed = smoothStrokePointsForCommit(denoised)

            switch capture.target {
            case .canvas(let frame):
                guard let index = frame.strokes.firstIndex(where: { $0.id == oldStroke.id }) else { continue }

                let refinedStroke = Stroke(
                    id: oldStroke.id,
                    screenPoints: smoothed,
                    zoomAtCreation: capture.zoomAtCreation,
                    panAtCreation: capture.panAtCreation,
                    viewSize: capture.viewSize,
                    rotationAngle: capture.rotationAngle,
                    color: oldStroke.color,
                    baseWidth: capture.baseWidth,
                    zoomEffectiveAtCreation: oldStroke.zoomEffectiveAtCreation,
                    device: device,
                    depthID: oldStroke.depthID,
                    depthWriteEnabled: oldStroke.depthWriteEnabled,
                    constantScreenSize: capture.constantScreenSize
                )

                refinedStroke.layerID = oldStroke.layerID ?? selectedLayerID
                refinedStroke.maskAppliesToAllLayers = oldStroke.maskAppliesToAllLayers
                refinedStroke.link = oldStroke.link
                refinedStroke.linkSectionID = oldStroke.linkSectionID
                refinedStroke.linkTargetSectionID = oldStroke.linkTargetSectionID
                refinedStroke.linkTargetCardID = oldStroke.linkTargetCardID

                let anchor = strokeMembershipAnchorPointInFrame(refinedStroke)
                refinedStroke.sectionID = resolveSectionIDForPointInFrameHierarchy(pointInFrame: anchor, frame: frame)

                frame.strokes[index] = refinedStroke
                replaceStrokeReferences(oldStrokeID: oldStroke.id, with: refinedStroke)

            case .card(let card, _):
                // Not yet supported (card-local stroke conversion differs); keep raw.
                _ = card
                continue
            }
        }
    }

    private func buildLassoScreenPoints() -> [CGPoint]? {
        guard !lassoDrawingPoints.isEmpty else { return nil }

        var screenPoints = lassoDrawingPoints
        if let last = screenPoints.last,
           let firstPredicted = lassoPredictedPoints.first,
           last == firstPredicted {
            screenPoints.append(contentsOf: lassoPredictedPoints.dropFirst())
        } else {
            screenPoints.append(contentsOf: lassoPredictedPoints)
        }

        guard !screenPoints.isEmpty else { return nil }

        let maxScreenPoints = 1000
        if screenPoints.count > maxScreenPoints {
            let step = max(1, screenPoints.count / maxScreenPoints)
            var downsampled: [CGPoint] = []
            downsampled.reserveCapacity(maxScreenPoints + 1)
            for i in stride(from: 0, to: screenPoints.count, by: step) {
                downsampled.append(screenPoints[i])
            }
            if let last = screenPoints.last, last != downsampled.last {
                downsampled.append(last)
            }
            screenPoints = downsampled
        }

        return screenPoints
    }

    private func buildBoxLassoScreenPoints(start: CGPoint, end: CGPoint) -> [CGPoint] {
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)

        let width = maxX - minX
        let height = maxY - minY
        guard width.isFinite, height.isFinite else { return [] }
        guard width >= 2.0, height >= 2.0 else { return [] }

        let radiusPx = min(boxLassoCornerRadiusPx, Double(width) * 0.5, Double(height) * 0.5)
        let r = CGFloat(radiusPx)
        let segments = max(1, boxLassoCornerSegments)

        func appendArc(center: CGPoint,
                       radius: CGFloat,
                       startAngle: Double,
                       endAngle: Double,
                       to points: inout [CGPoint],
                       skipFirst: Bool) {
            guard radius > 0 else { return }
            let startIndex = skipFirst ? 1 : 0
            for i in startIndex...segments {
                let t = Double(i) / Double(segments)
                let angle = startAngle + (endAngle - startAngle) * t
                let x = Double(center.x) + Double(radius) * cos(angle)
                let y = Double(center.y) + Double(radius) * sin(angle)
                points.append(CGPoint(x: x, y: y))
            }
        }

        var points: [CGPoint] = []
        points.reserveCapacity(4 * (segments + 2) + 1)

        points.append(CGPoint(x: minX + r, y: minY))
        points.append(CGPoint(x: maxX - r, y: minY))
        appendArc(center: CGPoint(x: maxX - r, y: minY + r),
                  radius: r,
                  startAngle: -Double.pi / 2.0,
                  endAngle: 0.0,
                  to: &points,
                  skipFirst: true)

        points.append(CGPoint(x: maxX, y: maxY - r))
        appendArc(center: CGPoint(x: maxX - r, y: maxY - r),
                  radius: r,
                  startAngle: 0.0,
                  endAngle: Double.pi / 2.0,
                  to: &points,
                  skipFirst: true)

        points.append(CGPoint(x: minX + r, y: maxY))
        appendArc(center: CGPoint(x: minX + r, y: maxY - r),
                  radius: r,
                  startAngle: Double.pi / 2.0,
                  endAngle: Double.pi,
                  to: &points,
                  skipFirst: true)

        points.append(CGPoint(x: minX, y: minY + r))
        appendArc(center: CGPoint(x: minX + r, y: minY + r),
                  radius: r,
                  startAngle: Double.pi,
                  endAngle: 3.0 * Double.pi / 2.0,
                  to: &points,
                  skipFirst: true)

        if let first = points.first, let last = points.last, first != last {
            points.append(first)
        }

        return points
    }

    private func updateLassoPreviewFromScreenPoints(_ screenPoints: [CGPoint], close: Bool, viewSize: CGSize) {
        let worldPoints = screenPoints.map {
            screenToWorldPixels_PureDouble(
                $0,
                viewSize: viewSize,
                panOffset: panOffset,
                zoomScale: zoomScale,
                rotationAngle: rotationAngle
            )
        }

        switch lassoTarget {
        case .card(let card, let frame):
            guard let transform = transformFromActive(to: frame) else {
                updateLassoPreview(for: worldPoints, close: close)
                return
            }
            let cardPoints = worldPoints.map { activePoint in
                let framePoint = SIMD2<Double>(
                    activePoint.x * transform.scale + transform.translation.x,
                    activePoint.y * transform.scale + transform.translation.y
                )
                return framePointToCardLocal(framePoint, card: card)
            }
            let zoomInFrame = zoomScale / max(transform.scale, 1e-6)
            updateLassoPreview(for: cardPoints, close: close, card: card, frame: frame, zoom: zoomInFrame)
        default:
            updateLassoPreview(for: worldPoints, close: close)
        }
    }

    private func renderLiveStroke(view: MTKView, encoder enc: MTLRenderCommandEncoder, cameraCenterWorld: SIMD2<Double>, tempOrigin: SIMD2<Double>) {
        guard brushSettings.toolMode == .paint else { return }
        guard let target = currentDrawingTarget else { return }
        guard let screenPoints = buildLiveScreenPoints() else { return }
        guard let firstScreenPoint = screenPoints.first else { return }
        let previewColor = brushSettings.color
        enc.setCullMode(.none)

        switch target {
        case .canvas(let frame):
            let layerID = selectedLayerID ?? layers.first?.id
            let band = layerID.map { zDepthBand(for: .layer($0)) } ?? (bias: 0.0, scale: 1.0)
            let zoom: Double
            let cameraCenterInTarget: SIMD2<Double>
            if frame === activeFrame {
                zoom = max(zoomScale, 1e-6)
                cameraCenterInTarget = cameraCenterWorld
            } else if let transform = transformFromActive(to: frame) {
                zoom = max(zoomScale / transform.scale, 1e-6)
                cameraCenterInTarget = cameraCenterWorld * transform.scale + transform.translation
            } else {
                zoom = max(zoomScale, 1e-6)
                cameraCenterInTarget = cameraCenterWorld
            }
            let angle = Double(rotationAngle)
            let c = cos(angle)
            let s = sin(angle)

            let localPoints: [SIMD2<Float>] = screenPoints.map { pt in
                let dx = Double(pt.x) - Double(firstScreenPoint.x)
                let dy = Double(pt.y) - Double(firstScreenPoint.y)

                // Inverse of shader's CW matrix: [c, s; -s, c]
                let unrotatedX = dx * c + dy * s
                let unrotatedY = -dx * s + dy * c

                return SIMD2<Float>(Float(unrotatedX / zoom), Float(unrotatedY / zoom))
            }

            let segments = Stroke.buildSegments(from: localPoints, color: previewColor)
            guard !segments.isEmpty else { return }
            guard let segmentBuffer = device.makeBuffer(bytes: segments,
                                                        length: segments.count * MemoryLayout<StrokeSegmentInstance>.stride,
                                                        options: .storageModeShared) else { return }

            let dx = tempOrigin.x - cameraCenterInTarget.x
            let dy = tempOrigin.y - cameraCenterInTarget.y
            let rotatedOffsetScreen = SIMD2<Float>(
                Float((dx * c - dy * s) * zoom),
                Float((dx * s + dy * c) * zoom)
            )

            let basePixelWidth: Float
            if brushSettings.constantScreenSize {
                basePixelWidth = Float(brushSettings.size)
            } else {
                basePixelWidth = Float(brushSettings.size) * Float(zoom)
            }
            let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

            // Canvas live stroke depth: use peek for current drawing stroke
            let canvasLiveStrokeDepth = band.bias + strokeDepth(for: peekStrokeDepthID()) * band.scale

            var transform = StrokeTransform(
                relativeOffset: .zero,
                rotatedOffsetScreen: rotatedOffsetScreen,
                zoomScale: Float(zoom),
                screenWidth: Float(view.bounds.size.width),
                screenHeight: Float(view.bounds.size.height),
                rotationAngle: rotationAngle,
                halfPixelWidth: halfPixelWidth,
                featherPx: 1.0,
                depth: canvasLiveStrokeDepth
            )

            enc.setRenderPipelineState(strokeSegmentPipelineState)
            // Use the same depth state as the final stroke will use
            enc.setDepthStencilState(brushSettings.depthWriteEnabled ? strokeDepthStateWrite : strokeDepthStateNoWrite)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            enc.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            enc.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segments.count)

        case .card(let card, let frame):
            let band = zDepthBand(for: .card(card.id))
            // Determine the camera transform in the target frame (linked list chain).
            var cameraCenterInTarget = cameraCenterWorld
            var zoomInTarget = zoomScale
            if let transform = transformFromActive(to: frame) {
                cameraCenterInTarget = cameraCenterWorld * transform.scale + transform.translation
                zoomInTarget = zoomScale / transform.scale
            }

            let liveStroke = createStrokeForCard(screenPoints: screenPoints,
                                                 card: card,
                                                 frame: frame,
                                                 viewSize: view.bounds.size,
                                                 depthID: peekStrokeDepthID(),
                                                 color: previewColor)
            guard !liveStroke.segments.isEmpty, let segmentBuffer = liveStroke.segmentBuffer else { return }

            // 1) Write stencil for the card region without affecting color output.
            let cardOffsetLocal = cardOffsetFromCameraInLocalSpace(card: card,
                                                                   cameraCenter: cameraCenterInTarget)
            let relativeOffset = SIMD2<Float>(Float(cardOffsetLocal.x), Float(cardOffsetLocal.y))
            let finalRotation = rotationAngle + card.rotation
	            let cardHalfSize = SIMD2<Float>(Float(card.size.x * 0.5), Float(card.size.y * 0.5))
	            var style = CardStyleUniforms(
	                cardHalfSize: cardHalfSize,
	                zoomScale: Float(zoomInTarget),
	                cornerRadiusPx: cardCornerRadiusPx,
	                shadowBlurPx: cardShadowBlurPx * Float(zoomInTarget),
	                shadowOpacity: cardShadowOpacity,
	                cardOpacity: card.opacity
	            )

            var cardTransform = CardTransform(
                relativeOffset: relativeOffset,
                zoomScale: Float(zoomInTarget),
                screenWidth: Float(view.bounds.size.width),
                screenHeight: Float(view.bounds.size.height),
                rotationAngle: finalRotation,
                depth: band.bias + StrokeDepth.metalDepth(for: 0) * band.scale
            )

            let cardVertexBuffer = device.makeBuffer(bytes: card.localVertices,
                                                     length: card.localVertices.count * MemoryLayout<StrokeVertex>.stride,
                                                     options: .storageModeShared)

            enc.setDepthStencilState(stencilStateWriteNoDepth)
            enc.setStencilReferenceValue(1)
            enc.setRenderPipelineState(cardSolidPipelineState)
            enc.setVertexBytes(&cardTransform, length: MemoryLayout<CardTransform>.stride, index: 1)
            var transparent = SIMD4<Float>(0, 0, 0, 0)
            enc.setFragmentBytes(&transparent, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
            enc.setVertexBuffer(cardVertexBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // 2) Draw the live stroke clipped to stencil.
            enc.setRenderPipelineState(strokeSegmentPipelineState)
            enc.setDepthStencilState(cardStrokeDepthStateNoWrite)
            enc.setStencilReferenceValue(1)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

            let totalRotation = rotationAngle + card.rotation
            let offset = SIMD2<Float>(Float(cardOffsetLocal.x), Float(cardOffsetLocal.y))

            let strokeOffset = liveStroke.origin
            let strokeRelativeOffset = offset + SIMD2<Float>(Float(strokeOffset.x), Float(strokeOffset.y))

            let basePixelWidth = Float(liveStroke.worldWidth * zoomInTarget)
            let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

            // Live stroke depth: use peekStrokeDepthID (creation order)
            let liveStrokeDepth = band.bias + strokeDepth(for: peekStrokeDepthID()) * band.scale

            var strokeTransform = StrokeTransform(
                relativeOffset: strokeRelativeOffset,
                rotatedOffsetScreen: SIMD2<Float>(
                    Float((Double(strokeRelativeOffset.x) * cos(Double(totalRotation)) - Double(strokeRelativeOffset.y) * sin(Double(totalRotation))) * zoomInTarget),
                    Float((Double(strokeRelativeOffset.x) * sin(Double(totalRotation)) + Double(strokeRelativeOffset.y) * cos(Double(totalRotation))) * zoomInTarget)
                ),
                zoomScale: Float(zoomInTarget),
                screenWidth: Float(view.bounds.size.width),
                screenHeight: Float(view.bounds.size.height),
                rotationAngle: totalRotation,
                halfPixelWidth: halfPixelWidth,
                featherPx: 1.0,
                depth: liveStrokeDepth
            )

            enc.setVertexBytes(&strokeTransform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            enc.setFragmentBytes(&strokeTransform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            enc.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: liveStroke.segments.count)

            // 3) Clear stencil for subsequent draws.
            enc.setRenderPipelineState(cardSolidPipelineState)
            enc.setDepthStencilState(stencilStateClear)
            enc.setStencilReferenceValue(0)
            enc.setVertexBytes(&cardTransform, length: MemoryLayout<CardTransform>.stride, index: 1)
            enc.setFragmentBytes(&transparent, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentBytes(&style, length: MemoryLayout<CardStyleUniforms>.stride, index: 2)
            enc.setVertexBuffer(cardVertexBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            enc.setDepthStencilState(stencilStateDefault)
        }
    }
    // Note: ICB encoding functions removed - using simple GPU-offset rendering

    private func renderLassoOverlay(view: MTKView,
                                    encoder enc: MTLRenderCommandEncoder,
                                    cameraCenterWorld: SIMD2<Double>) {
        guard lassoPreviewCard == nil else { return }
        guard let stroke = lassoPreviewStroke, lassoPreviewFrame === activeFrame else { return }
        guard !stroke.segments.isEmpty, let segmentBuffer = stroke.segmentBuffer else { return }

        enc.setRenderPipelineState(strokeSegmentPipelineState)
        enc.setDepthStencilState(strokeDepthStateNoWrite)
        enc.setCullMode(.none)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        let zoom = max(zoomScale, 1e-6)
        let angle = Double(rotationAngle)
        let c = cos(angle)
        let s = sin(angle)

        let dx = stroke.origin.x - cameraCenterWorld.x
        let dy = stroke.origin.y - cameraCenterWorld.y
        let rotatedOffsetScreen = SIMD2<Float>(
            Float((dx * c - dy * s) * zoom),
            Float((dx * s + dy * c) * zoom)
        )

        let basePixelWidth = Float(stroke.worldWidth * zoom)
        let halfPixelWidth = max(basePixelWidth * 0.5, 0.5)

        var transform = StrokeTransform(
            relativeOffset: .zero,
            rotatedOffsetScreen: rotatedOffsetScreen,
            zoomScale: Float(zoom),
            screenWidth: Float(view.bounds.size.width),
            screenHeight: Float(view.bounds.size.height),
            rotationAngle: rotationAngle,
            halfPixelWidth: halfPixelWidth,
            featherPx: 1.0,
            depth: 0.0
        )

        enc.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
        enc.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
        enc.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: stroke.segments.count)
    }

    private func drawLiveEraserOnCanvasIfNeeded(frame: Frame,
                                                cameraCenterInThisFrame: SIMD2<Double>,
                                                viewSize: CGSize,
                                                currentZoom: Double,
                                                currentRotation: Float,
                                                zDepthBias: Float,
                                                zDepthScale: Float,
                                                encoder: MTLRenderCommandEncoder) {
        guard brushSettings.isMaskEraser else { return }
        guard let target = currentDrawingTarget else { return }
        guard case .canvas(let targetFrame) = target else { return }
        guard targetFrame === frame else { return }
        guard let tempOrigin = liveStrokeOrigin else { return }
        guard let screenPoints = buildLiveScreenPoints() else { return }
        guard let firstScreenPoint = screenPoints.first else { return }

        let zoom = max(currentZoom, 1e-6)
        let angle = Double(currentRotation)
        let c = cos(angle)
        let s = sin(angle)

        let localPoints: [SIMD2<Float>] = screenPoints.map { pt in
            let dx = Double(pt.x) - Double(firstScreenPoint.x)
            let dy = Double(pt.y) - Double(firstScreenPoint.y)

            let unrotatedX = dx * c + dy * s
            let unrotatedY = -dx * s + dy * c

            return SIMD2<Float>(Float(unrotatedX / zoom), Float(unrotatedY / zoom))
        }

        let segments = Stroke.buildSegments(from: localPoints, color: SIMD4<Float>(0, 0, 0, 0))
        guard !segments.isEmpty else { return }
        guard let segmentBuffer = device.makeBuffer(bytes: segments,
                                                    length: segments.count * MemoryLayout<StrokeSegmentInstance>.stride,
                                                    options: .storageModeShared) else { return }

        let dx = tempOrigin.x - cameraCenterInThisFrame.x
        let dy = tempOrigin.y - cameraCenterInThisFrame.y
        let rotatedOffsetScreen = SIMD2<Float>(
            Float((dx * c - dy * s) * zoom),
            Float((dx * s + dy * c) * zoom)
        )

        let halfPixelWidth = max(Float(brushSettings.size) * 0.5, 0.5)
        let liveDepth = zDepthBias + strokeDepth(for: peekStrokeDepthID()) * zDepthScale

        var transform = StrokeTransform(
            relativeOffset: .zero,
            rotatedOffsetScreen: rotatedOffsetScreen,
            zoomScale: Float(zoom),
            screenWidth: Float(viewSize.width),
            screenHeight: Float(viewSize.height),
            rotationAngle: currentRotation,
            halfPixelWidth: halfPixelWidth,
            featherPx: 1.0,
            depth: liveDepth
        )

        encoder.setRenderPipelineState(strokeSegmentPipelineState)
        encoder.setDepthStencilState(strokeDepthStateWrite)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
        encoder.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
        encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segments.count)
    }

    ///  CONSTANT SCREEN SIZE HANDLES
    /// Draws resize handles at card corners that maintain constant screen size regardless of zoom.
    /// Rendered as rounded line segments inset from the card edges.
    ///
    /// - Parameters:
    ///   - card: The card to draw handles for
    ///   - cameraCenter: Camera position in frame coordinates
    ///   - viewSize: Screen dimensions
    ///   - zoom: Current zoom level
    ///   - rotation: Camera rotation (card rotation is baked into corner positions)
    ///   - encoder: Metal render encoder
    func drawCardHandles(card: Card,
                         cameraCenter: SIMD2<Double>,
                         viewSize: CGSize,
                         zoom: Double,
                         rotation: Float,
                         encoder: MTLRenderCommandEncoder) {

        guard zoom.isFinite, zoom > 0 else { return }

        let handleInsetPx: Float = 5.0
        let handleLengthPx: Float = 12.0
        let handleThicknessPx: Float = 3.0
        let handleColor = cardHandleColor(for: card)

        let insetWorld = handleInsetPx / Float(zoom)
        let outerCornerRadiusWorld = cardCornerRadiusPx / Float(zoom)
        let handleArcRadiusPx = max(cardCornerRadiusPx - handleInsetPx, 0.0)
        let handleArcRadiusWorld = handleArcRadiusPx / Float(zoom)
        let joinInsetWorld = handleArcRadiusWorld
        let straightLengthPx = max(handleLengthPx - handleArcRadiusPx, handleThicknessPx)

        let maxLengthX = max(0.0, Float(card.size.x) - insetWorld * 2.0 - joinInsetWorld)
        let maxLengthY = max(0.0, Float(card.size.y) - insetWorld * 2.0 - joinInsetWorld)
        let lengthWorldX = min(straightLengthPx / Float(zoom), maxLengthX)
        let lengthWorldY = min(straightLengthPx / Float(zoom), maxLengthY)

        if lengthWorldX <= 0 || lengthWorldY <= 0 { return }

        let halfW = Float(card.size.x) * 0.5
        let halfH = Float(card.size.y) * 0.5
        let xRight = halfW - insetWorld
        let yBottom = halfH - insetWorld
        let xRightStart = xRight - joinInsetWorld
        let yBottomStart = yBottom - joinInsetWorld

        struct HandleSegment {
            let p0: SIMD2<Double>
            let p1: SIMD2<Double>
        }

        let segments: [HandleSegment] = [
            // Bottom-right only (L shape)
            HandleSegment(p0: SIMD2<Double>(Double(xRightStart), Double(yBottom)),
                          p1: SIMD2<Double>(Double(xRightStart - lengthWorldX), Double(yBottom))),
            HandleSegment(p0: SIMD2<Double>(Double(xRight), Double(yBottomStart)),
                          p1: SIMD2<Double>(Double(xRight), Double(yBottomStart - lengthWorldY)))
        ]

        let angle = Double(rotation)
        let c = cos(angle)
        let s = sin(angle)

        encoder.setRenderPipelineState(strokeSegmentPipelineState)
        encoder.setDepthStencilState(stencilStateDefault)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        let drawSegment: (SIMD2<Double>, SIMD2<Double>, Float) -> Void = { p0Local, p1Local, radiusPx in
            let p0Frame = self.cardLocalToFramePoint(p0Local, card: card)
            let p1Frame = self.cardLocalToFramePoint(p1Local, card: card)
            let origin = SIMD2<Double>((p0Frame.x + p1Frame.x) * 0.5,
                                       (p0Frame.y + p1Frame.y) * 0.5)

            let localP0 = SIMD2<Float>(Float(p0Frame.x - origin.x),
                                       Float(p0Frame.y - origin.y))
            let localP1 = SIMD2<Float>(Float(p1Frame.x - origin.x),
                                       Float(p1Frame.y - origin.y))

            var segmentInstance = StrokeSegmentInstance(p0: localP0, p1: localP1, color: handleColor)
            guard let segmentBuffer = self.device.makeBuffer(bytes: &segmentInstance,
                                                        length: MemoryLayout<StrokeSegmentInstance>.stride,
                                                        options: .storageModeShared) else { return }

            let dx = origin.x - cameraCenter.x
            let dy = origin.y - cameraCenter.y
            let rotatedOffsetScreen = SIMD2<Float>(
                Float((dx * c - dy * s) * zoom),
                Float((dx * s + dy * c) * zoom)
            )

            var transform = StrokeTransform(
                relativeOffset: .zero,
                rotatedOffsetScreen: rotatedOffsetScreen,
                zoomScale: Float(zoom),
                screenWidth: Float(viewSize.width),
                screenHeight: Float(viewSize.height),
                rotationAngle: rotation,
                halfPixelWidth: radiusPx,
                featherPx: 1.0,
                depth: 0.0
            )

            encoder.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            encoder.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }

        for segment in segments {
            drawSegment(segment.p0, segment.p1, handleThicknessPx * 0.5)
        }

        // Only draw corner arcs if they're visually meaningful (at least 2px)
        // This prevents overlap with straight segment end caps
        if handleArcRadiusPx >= 2.0 {
            let brCenter = SIMD2<Double>(Double(halfW - outerCornerRadiusWorld),
                                         Double(halfH - outerCornerRadiusWorld))

            let arcSegments = 6
            func arcPoints(center: SIMD2<Double>, startAngle: Double, endAngle: Double) -> [SIMD2<Double>] {
                guard arcSegments > 0 else { return [] }
                var points: [SIMD2<Double>] = []
                points.reserveCapacity(arcSegments + 1)
                for i in 0...arcSegments {
                    let t = Double(i) / Double(arcSegments)
                    let angle = startAngle + (endAngle - startAngle) * t
                    let x = center.x + Double(handleArcRadiusWorld) * cos(angle)
                    let y = center.y + Double(handleArcRadiusWorld) * sin(angle)
                    points.append(SIMD2<Double>(x, y))
                }
                return points
            }

            let arcs: [[SIMD2<Double>]] = [
                arcPoints(center: brCenter, startAngle: 0.0, endAngle: 0.5 * .pi)
            ]

            for arc in arcs {
                guard arc.count >= 2 else { continue }
                for i in 0..<(arc.count - 1) {
                    drawSegment(arc[i], arc[i + 1], handleThicknessPx * 0.5)
                }
            }
        }
    }

    func drawCardLockIcon(card: Card,
                          cameraCenter: SIMD2<Double>,
                          viewSize: CGSize,
                          zoom: Double,
                          rotation: Float,
                          encoder: MTLRenderCommandEncoder) {
        guard zoom.isFinite, zoom > 0 else { return }

        let iconWidthPx: Double = 18.0
        let iconHeightPx: Double = 20.0
        let paddingPx: Double = 8.0
        let strokePx: Float = 2.0
        let shackleInsetPx: Double = 4.0
        let shackleHeightPx: Double = 7.0

        let iconWidthWorld = iconWidthPx / zoom
        let iconHeightWorld = iconHeightPx / zoom
        let paddingWorld = paddingPx / zoom

        let minWidth = iconWidthWorld + paddingWorld * 2.0
        let minHeight = iconHeightWorld + paddingWorld * 2.0
        guard card.size.x > minWidth, card.size.y > minHeight else { return }

        let halfW = card.size.x * 0.5
        let halfH = card.size.y * 0.5

        let right = halfW - paddingWorld
        let left = right - iconWidthWorld
        let top = -halfH + paddingWorld
        let bottom = top + iconHeightWorld

        let shackleInsetWorld = shackleInsetPx / zoom
        let shackleHeightWorld = shackleHeightPx / zoom
        let shackleLeft = left + shackleInsetWorld
        let shackleRight = right - shackleInsetWorld
        let shackleBottom = top + shackleHeightWorld

        struct LockSegment {
            let p0: SIMD2<Double>
            let p1: SIMD2<Double>
        }

        let segments: [LockSegment] = [
            // Shackle
            LockSegment(p0: SIMD2<Double>(shackleLeft, top),
                        p1: SIMD2<Double>(shackleRight, top)),
            LockSegment(p0: SIMD2<Double>(shackleLeft, top),
                        p1: SIMD2<Double>(shackleLeft, shackleBottom)),
            LockSegment(p0: SIMD2<Double>(shackleRight, top),
                        p1: SIMD2<Double>(shackleRight, shackleBottom)),

            // Body
            LockSegment(p0: SIMD2<Double>(left, shackleBottom),
                        p1: SIMD2<Double>(right, shackleBottom)),
            LockSegment(p0: SIMD2<Double>(left, shackleBottom),
                        p1: SIMD2<Double>(left, bottom)),
            LockSegment(p0: SIMD2<Double>(right, shackleBottom),
                        p1: SIMD2<Double>(right, bottom)),
            LockSegment(p0: SIMD2<Double>(left, bottom),
                        p1: SIMD2<Double>(right, bottom))
        ]

        let iconColor = cardHandleColor(for: card)
        let angle = Double(rotation)
        let c = cos(angle)
        let s = sin(angle)

        encoder.setRenderPipelineState(strokeSegmentPipelineState)
        encoder.setDepthStencilState(stencilStateDefault)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        let drawSegment: (SIMD2<Double>, SIMD2<Double>) -> Void = { p0Local, p1Local in
            let p0Frame = self.cardLocalToFramePoint(p0Local, card: card)
            let p1Frame = self.cardLocalToFramePoint(p1Local, card: card)
            let origin = SIMD2<Double>((p0Frame.x + p1Frame.x) * 0.5,
                                       (p0Frame.y + p1Frame.y) * 0.5)

            let localP0 = SIMD2<Float>(Float(p0Frame.x - origin.x),
                                       Float(p0Frame.y - origin.y))
            let localP1 = SIMD2<Float>(Float(p1Frame.x - origin.x),
                                       Float(p1Frame.y - origin.y))

            var segmentInstance = StrokeSegmentInstance(p0: localP0, p1: localP1, color: iconColor)
            guard let segmentBuffer = self.device.makeBuffer(bytes: &segmentInstance,
                                                             length: MemoryLayout<StrokeSegmentInstance>.stride,
                                                             options: .storageModeShared) else { return }

            let dx = origin.x - cameraCenter.x
            let dy = origin.y - cameraCenter.y
            let rotatedOffsetScreen = SIMD2<Float>(
                Float((dx * c - dy * s) * zoom),
                Float((dx * s + dy * c) * zoom)
            )

            var transform = StrokeTransform(
                relativeOffset: .zero,
                rotatedOffsetScreen: rotatedOffsetScreen,
                zoomScale: Float(zoom),
                screenWidth: Float(viewSize.width),
                screenHeight: Float(viewSize.height),
                rotationAngle: rotation,
                halfPixelWidth: strokePx * 0.5,
                featherPx: 1.0,
                depth: 0.0
            )

            encoder.setVertexBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            encoder.setFragmentBytes(&transform, length: MemoryLayout<StrokeTransform>.stride, index: 1)
            encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }

        for segment in segments {
            drawSegment(segment.p0, segment.p1)
        }
    }

    private func cardHandleColor(for card: Card) -> SIMD4<Float> {
        let base = card.handleBaseColor()
        let luminance = 0.299 * base.x + 0.587 * base.y + 0.114 * base.z
        if luminance > 0.5 {
            return SIMD4<Float>(0, 0, 0, 1.0)
        }
        return SIMD4<Float>(1, 1, 1, 1.0)
    }

    func draw(in view: MTKView) {
        resizeOffscreenTexturesIfNeeded(drawableSize: view.drawableSize)
        guard let offscreenColor = offscreenColorTexture,
              let offscreenDepthStencil = offscreenDepthStencilTexture else { return }

        inFlightSemaphore.wait()
        var didCommitFrame = false
        defer {
            if !didCommitFrame {
                inFlightSemaphore.signal()
            }
        }

        guard let mainCommandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              let drawableRPD = view.currentRenderPassDescriptor else { return }

        mainCommandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        beginBatchedSegmentUploadsForFrame()

        // PASS 1: Render the full scene into an offscreen texture (no MSAA, hard stroke coverage).
        let sceneRPD = MTLRenderPassDescriptor()
        sceneRPD.colorAttachments[0].texture = offscreenColor
        sceneRPD.colorAttachments[0].loadAction = .clear
        sceneRPD.colorAttachments[0].storeAction = .store
        sceneRPD.colorAttachments[0].clearColor = view.clearColor

        sceneRPD.depthAttachment.texture = offscreenDepthStencil
        sceneRPD.depthAttachment.loadAction = .clear
        sceneRPD.depthAttachment.storeAction = .dontCare
        sceneRPD.depthAttachment.clearDepth = view.clearDepth

        sceneRPD.stencilAttachment.texture = offscreenDepthStencil
        sceneRPD.stencilAttachment.loadAction = .clear
        sceneRPD.stencilAttachment.storeAction = .dontCare
        sceneRPD.stencilAttachment.clearStencil = view.clearStencil

	        guard let sceneEnc = mainCommandBuffer.makeRenderCommandEncoder(descriptor: sceneRPD) else { return }

		        let viewSize = view.bounds.size
		        let cameraCenterWorld = calculateCameraCenterWorld(viewSize: viewSize)
			        let extent = fractalFrameExtent
			        visibleFractalFrameTransforms.removeAll(keepingCapacity: true)
			        visibleFractalFramesDrawOrder.removeAll(keepingCapacity: true)
			        linkHighlightBoundsByKeyActiveThisFrame.removeAll(keepingCapacity: true)
			        debugDrawnVerticesThisFrame = 0
			        debugDrawnNodesThisFrame = 0

		        // Collect the full 5x5 same-depth neighborhood around the active frame.
		        //
		        // Why: content can be stored in neighbor frames while still being visible on screen
		        // (large cards / long strokes crossing tile boundaries). If we only render "potentially
		        // visible" tiles based on screen corners, those neighbor frames can pop/flicker as the
		        // camera pans even when the active frame doesn't change.
		        let visible: (dx: ClosedRange<Int>, dy: ClosedRange<Int>) = (dx: -2...2, dy: -2...2)

		        var renderedFrames = Set<ObjectIdentifier>()
				        for dy in visible.dy {
				            for dx in visible.dx {
				                guard let frame = frameAtOffsetFromActiveIfExists(dx: dx, dy: dy) else { continue }
				                let offset = SIMD2<Double>(Double(dx) * extent.x, Double(dy) * extent.y)
				                collectDepthNeighborhood(baseFrame: frame,
				                                         cameraCenterInBaseFrame: cameraCenterWorld - offset,
				                                         cameraCenterInActiveFrame: cameraCenterWorld,
				                                         viewSize: viewSize,
				                                         zoomActive: zoomScale,
				                                         visited: &renderedFrames)
				            }
				        }

		        // Draw debug grid first so sections/strokes/cards render above it.
		        drawFractalGridOverlay(encoder: sceneEnc,
		                               viewSize: viewSize,
		                               cameraCenterWorld: cameraCenterWorld,
		                               zoom: zoomScale,
		                               rotation: rotationAngle)

		        // Sections are a global bottom layer (always below strokes/cards).
		        renderVisibleSections(encoder: sceneEnc,
		                              viewSize: viewSize,
		                              cameraCenterWorld: cameraCenterWorld,
		                              zoomActive: zoomScale,
		                              rotation: rotationAngle)

		        // Global z-stack (layers + cards) across all visible frames/depths.
		        renderVisibleZStack(encoder: sceneEnc,
		                            viewSize: viewSize,
		                            cameraCenterWorld: cameraCenterWorld,
		                            zoomActive: zoomScale,
		                            rotation: rotationAngle)

		        // Link highlights (persist for linked strokes; selection gets an extra overlay).
		        renderLinkHighlightOverlays(encoder: sceneEnc,
		                                    viewSize: viewSize,
		                                    cameraCenterWorld: cameraCenterWorld,
		                                    zoom: zoomScale,
		                                    rotation: rotationAngle)

			        /*
			        // Live stroke previews are rendered in-layer (or in-card) during the main z-stack pass.
			        // This keeps previews consistent with the global draw order and prevents invisible
			        // pixel-eraser depth writes from hiding the preview.
			        //
			        // renderLiveStroke(view:encoder:cameraCenterWorld:tempOrigin:) remains as reference.
			        */

	        renderLassoOverlay(view: view, encoder: sceneEnc, cameraCenterWorld: cameraCenterWorld)

        sceneEnc.endEncoding()

        // PASS 2: FXAA fullscreen pass into the drawable.
        guard let postEnc = mainCommandBuffer.makeRenderCommandEncoder(descriptor: drawableRPD) else { return }
        postEnc.setRenderPipelineState(postProcessPipelineState)
        postEnc.setDepthStencilState(stencilStateDefault)
        postEnc.setCullMode(.none)

        postEnc.setFragmentTexture(offscreenColor, index: 0)
        postEnc.setFragmentSamplerState(samplerState, index: 0)
        var invResolution = SIMD2<Float>(1.0 / Float(offscreenTextureWidth),
                                         1.0 / Float(offscreenTextureHeight))
        postEnc.setFragmentBytes(&invResolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        postEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        postEnc.endEncoding()

        mainCommandBuffer.present(drawable)
        didCommitFrame = true
        mainCommandBuffer.commit()

        updateDebugHUD(view: view)
    }
    func updateDebugHUD(view: MTKView) {
        // Access debugLabel through the stored metalView reference
        guard let mtkView = metalView else { return }

        // Find the debug label subview
        guard let debugLabel = mtkView.subviews.compactMap({ $0 as? UILabel }).first else { return }

        // Get stored depth from the frame
        let depth = activeFrame.depthFromRoot

        let tileText: String = {
            guard let idx = activeFrame.indexInParent else { return "root" }
            return "(\(idx.col), \(idx.row))"
        }()

        let pathText: String = {
            var indices: [GridIndex] = []
            var current: Frame? = activeFrame
            while let frame = current, let idx = frame.indexInParent {
                indices.append(idx)
                current = frame.parent
            }
            indices.reverse()
            if indices.isEmpty { return "root" }
            return indices.map { "(\($0.col),\($0.row))" }.joined(separator: " → ")
        }()

        // Format zoom scale nicely
        let zoomText: String
        if zoomScale >= 1000.0 {
            zoomText = String(format: "%.1fk×", zoomScale / 1000.0)
        } else if zoomScale >= 1.0 {
            zoomText = String(format: "%.1f×", zoomScale)
        } else {
            zoomText = String(format: "%.3f×", zoomScale)
        }

        // Calculate effective zoom (depth multiplier)
        // pow(scale, -1) shrinks, so negative depths work correctly.
        let effectiveZoom = pow(FractalGrid.scale, Double(depth)) * zoomScale
        let effectiveText: String
        if effectiveZoom >= 1e12 {
            let exponent = Int(log10(effectiveZoom))
            effectiveText = String(format: "10^%d", exponent)
        } else if effectiveZoom >= 1e9 {
            effectiveText = String(format: "%.1fB×", effectiveZoom / 1e9)
        } else if effectiveZoom >= 1e6 {
            effectiveText = String(format: "%.1fM×", effectiveZoom / 1e6)
        } else if effectiveZoom >= 1e3 {
            effectiveText = String(format: "%.1fk×", effectiveZoom / 1e3)
        } else if effectiveZoom >= 1.0 {
            effectiveText = String(format: "%.1f×", effectiveZoom)
        } else if effectiveZoom >= 0.001 {
            effectiveText = String(format: "%.3f×", effectiveZoom)
        } else {
            let exponent = Int(log10(effectiveZoom))
            effectiveText = String(format: "10^%d", exponent)
        }

        // Calculate camera position in current frame
        let cameraPos = calculateCameraCenterWorld(viewSize: view.bounds.size)
        let cameraPosText = String(format: "(%.1f, %.1f)", cameraPos.x, cameraPos.y)

        let updateUI = {
            (mtkView as? TouchableMTKView)?.updateWebCardOverlays()
            (mtkView as? TouchableMTKView)?.updateYouTubeOverlay()
            (mtkView as? TouchableMTKView)?.updateYouTubeCloseButtonOverlay()
            (mtkView as? TouchableMTKView)?.updateLinkSelectionOverlay()
            (mtkView as? TouchableMTKView)?.updateSectionNameEditorOverlay()
            (mtkView as? TouchableMTKView)?.updateCardNameEditorOverlay()

            let refs: String = {
                let edges = self.internalLinkReferenceEdges
                guard !edges.isEmpty else { return "Refs: 0" }

                let names = self.internalLinkReferenceNamesByID
                let maxLines = 6
                var lines: [String] = []
                lines.reserveCapacity(min(edges.count, maxLines))

                for edge in edges.prefix(maxLines) {
                    let src = (names[edge.sourceID] ?? "(\(edge.sourceID.uuidString.prefix(6)))")
                    let dst = (names[edge.targetID] ?? "(\(edge.targetID.uuidString.prefix(6)))")
                    lines.append("\(src) -> \(dst)")
                }

                if edges.count > maxLines {
                    lines.append("+\(edges.count - maxLines) more")
                }

                return "Refs: \(edges.count)\n" + lines.joined(separator: "\n")
            }()

            debugLabel.text = """
            Depth: \(depth) | Tile: \(tileText) | Zoom: \(zoomText)
            Path: \(pathText)
            Effective: \(effectiveText)
            Strokes: \(self.activeFrame.strokes.count)
            Camera: \(cameraPosText)
            Vertices: \(self.debugDrawnVerticesThisFrame) | Draws: \(self.debugDrawnNodesThisFrame)
            \((mtkView as? TouchableMTKView)?.youtubeHUDText() ?? "")
            \(refs)
            """
            mtkView.bringSubviewToFront(debugLabel)
        }

        if Thread.isMainThread {
            updateUI()
        } else {
            DispatchQueue.main.async(execute: updateUI)
        }
	    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resizeOffscreenTexturesIfNeeded(drawableSize: size)
    }

    private func resizeOffscreenTexturesIfNeeded(drawableSize: CGSize) {
        let width = max(Int(drawableSize.width.rounded(.down)), 1)
        let height = max(Int(drawableSize.height.rounded(.down)), 1)
        guard width != offscreenTextureWidth ||
              height != offscreenTextureHeight ||
              offscreenColorTexture == nil ||
              offscreenDepthStencilTexture == nil else { return }

        offscreenTextureWidth = width
        offscreenTextureHeight = height

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        colorDesc.sampleCount = 1
        offscreenColorTexture = device.makeTexture(descriptor: colorDesc)

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        depthDesc.sampleCount = 1
        offscreenDepthStencilTexture = device.makeTexture(descriptor: depthDesc)
    }

    private func makeQuadVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        vd.layouts[0].stepFunction = .perVertex
        return vd
    }

    func makePipeLine() {
        let library = device.makeDefaultLibrary()!
        // Single-sample render target (FXAA handles anti-aliasing as a post-process).
        // Must match `MTKView.sampleCount`.
        let viewSampleCount = 1
        let depthStencilFormat: MTLPixelFormat = .depth32Float_stencil8

        let quadVertexDesc = makeQuadVertexDescriptor()

        // Stroke Pipeline (Instanced SDF segments)
        let segDesc = MTLRenderPipelineDescriptor()
        segDesc.vertexFunction   = library.makeFunction(name: "vertex_segment_sdf")
        segDesc.fragmentFunction = library.makeFunction(name: "fragment_segment_sdf")
        segDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        segDesc.sampleCount = viewSampleCount

        let segAttachment = segDesc.colorAttachments[0]!
        segAttachment.isBlendingEnabled = true
        segAttachment.rgbBlendOperation = .add
        segAttachment.alphaBlendOperation = .add
        segAttachment.sourceRGBBlendFactor = .sourceAlpha
        segAttachment.sourceAlphaBlendFactor = .sourceAlpha
        segAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        segAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        segDesc.vertexDescriptor = quadVertexDesc
        segDesc.depthAttachmentPixelFormat = depthStencilFormat
        segDesc.stencilAttachmentPixelFormat = depthStencilFormat
        do {
            strokeSegmentPipelineState = try device.makeRenderPipelineState(descriptor: segDesc)
        } catch {
            fatalError("Failed to create strokeSegmentPipelineState: \(error)")
        }

        // Batched Stroke Pipeline (Instanced SDF segments with per-instance width/depth)
        let batchedSegDesc = MTLRenderPipelineDescriptor()
        batchedSegDesc.vertexFunction = library.makeFunction(name: "vertex_segment_sdf_batched")
        batchedSegDesc.fragmentFunction = library.makeFunction(name: "fragment_segment_sdf_batched")
        batchedSegDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        batchedSegDesc.sampleCount = viewSampleCount

        let batchedAttachment = batchedSegDesc.colorAttachments[0]!
        batchedAttachment.isBlendingEnabled = true
        batchedAttachment.rgbBlendOperation = .add
        batchedAttachment.alphaBlendOperation = .add
        batchedAttachment.sourceRGBBlendFactor = .sourceAlpha
        batchedAttachment.sourceAlphaBlendFactor = .sourceAlpha
        batchedAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        batchedAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        batchedSegDesc.vertexDescriptor = quadVertexDesc
        batchedSegDesc.depthAttachmentPixelFormat = depthStencilFormat
        batchedSegDesc.stencilAttachmentPixelFormat = depthStencilFormat
        do {
            strokeSegmentBatchedPipelineState = try device.makeRenderPipelineState(descriptor: batchedSegDesc)
        } catch {
            fatalError("Failed to create strokeSegmentBatchedPipelineState: \(error)")
        }

        // Setup vertex descriptor for StrokeVertex structure (shared by both card pipelines)
        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float2
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.attributes[1].format = .float2
        vertexDesc.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDesc.attributes[1].bufferIndex = 0
        vertexDesc.layouts[0].stride = MemoryLayout<StrokeVertex>.stride
        vertexDesc.layouts[0].stepFunction = .perVertex

        // Textured Card Pipeline (for images, PDFs)
        let cardDesc = MTLRenderPipelineDescriptor()
        cardDesc.vertexFunction   = library.makeFunction(name: "vertex_card")
        cardDesc.fragmentFunction = library.makeFunction(name: "fragment_card_texture")
        cardDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        cardDesc.sampleCount = viewSampleCount
        cardDesc.colorAttachments[0].isBlendingEnabled = true
        cardDesc.colorAttachments[0].rgbBlendOperation = .add
        cardDesc.colorAttachments[0].alphaBlendOperation = .add
        cardDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cardDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        cardDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cardDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cardDesc.vertexDescriptor = vertexDesc
        cardDesc.depthAttachmentPixelFormat = depthStencilFormat
        cardDesc.stencilAttachmentPixelFormat = depthStencilFormat // Required for stencil buffer
        do {
            cardPipelineState = try device.makeRenderPipelineState(descriptor: cardDesc)
        } catch {
            fatalError("Failed to create cardPipelineState: \(error)")
        }

        // Solid Color Card Pipeline (for placeholders, backgrounds)
        let cardSolidDesc = MTLRenderPipelineDescriptor()
        cardSolidDesc.vertexFunction   = library.makeFunction(name: "vertex_card")
        cardSolidDesc.fragmentFunction = library.makeFunction(name: "fragment_card_solid")
        cardSolidDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        cardSolidDesc.sampleCount = viewSampleCount
        cardSolidDesc.colorAttachments[0].isBlendingEnabled = true
        cardSolidDesc.colorAttachments[0].rgbBlendOperation = .add
        cardSolidDesc.colorAttachments[0].alphaBlendOperation = .add
        cardSolidDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cardSolidDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        cardSolidDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cardSolidDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cardSolidDesc.vertexDescriptor = vertexDesc
        cardSolidDesc.depthAttachmentPixelFormat = depthStencilFormat
        cardSolidDesc.stencilAttachmentPixelFormat = depthStencilFormat // Required for stencil buffer

        do {
            cardSolidPipelineState = try device.makeRenderPipelineState(descriptor: cardSolidDesc)
        } catch {
            fatalError("Failed to create solid card pipeline: \(error)")
        }

        // Section Fill Pipeline (Unmasked Solid Triangles)
        let sectionFillDesc = MTLRenderPipelineDescriptor()
        sectionFillDesc.vertexFunction = library.makeFunction(name: "vertex_card")
        sectionFillDesc.fragmentFunction = library.makeFunction(name: "fragment_solid_unmasked")
        sectionFillDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        sectionFillDesc.sampleCount = viewSampleCount
        sectionFillDesc.colorAttachments[0].isBlendingEnabled = true
        sectionFillDesc.colorAttachments[0].rgbBlendOperation = .add
        sectionFillDesc.colorAttachments[0].alphaBlendOperation = .add
        sectionFillDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        sectionFillDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        sectionFillDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        sectionFillDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        sectionFillDesc.vertexDescriptor = vertexDesc
        sectionFillDesc.depthAttachmentPixelFormat = depthStencilFormat
        sectionFillDesc.stencilAttachmentPixelFormat = depthStencilFormat

        do {
            sectionFillPipelineState = try device.makeRenderPipelineState(descriptor: sectionFillDesc)
        } catch {
            fatalError("Failed to create sectionFillPipelineState: \(error)")
        }

        // Lined Card Pipeline (Procedural horizontal lines)
        let linedDesc = MTLRenderPipelineDescriptor()
        linedDesc.vertexFunction = library.makeFunction(name: "vertex_card")
        linedDesc.fragmentFunction = library.makeFunction(name: "fragment_card_lined")
        linedDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        linedDesc.sampleCount = viewSampleCount
        linedDesc.colorAttachments[0].isBlendingEnabled = true
        linedDesc.colorAttachments[0].rgbBlendOperation = .add
        linedDesc.colorAttachments[0].alphaBlendOperation = .add
        linedDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        linedDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        linedDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        linedDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        linedDesc.vertexDescriptor = vertexDesc
        linedDesc.depthAttachmentPixelFormat = depthStencilFormat
        linedDesc.stencilAttachmentPixelFormat = depthStencilFormat

        do {
            cardLinedPipelineState = try device.makeRenderPipelineState(descriptor: linedDesc)
        } catch {
            fatalError("Failed to create lined card pipeline: \(error)")
        }

        // Grid Card Pipeline (Procedural horizontal and vertical lines)
        let gridDesc = MTLRenderPipelineDescriptor()
        gridDesc.vertexFunction = library.makeFunction(name: "vertex_card")
        gridDesc.fragmentFunction = library.makeFunction(name: "fragment_card_grid")
        gridDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        gridDesc.sampleCount = viewSampleCount
        gridDesc.colorAttachments[0].isBlendingEnabled = true
        gridDesc.colorAttachments[0].rgbBlendOperation = .add
        gridDesc.colorAttachments[0].alphaBlendOperation = .add
        gridDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        gridDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        gridDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        gridDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        gridDesc.vertexDescriptor = vertexDesc
        gridDesc.depthAttachmentPixelFormat = depthStencilFormat
        gridDesc.stencilAttachmentPixelFormat = depthStencilFormat

        do {
            cardGridPipelineState = try device.makeRenderPipelineState(descriptor: gridDesc)
        } catch {
            fatalError("Failed to create grid card pipeline: \(error)")
        }

        // Card Shadow Pipeline
        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.vertexFunction = library.makeFunction(name: "vertex_card")
        shadowDesc.fragmentFunction = library.makeFunction(name: "fragment_card_shadow")
        shadowDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        shadowDesc.sampleCount = viewSampleCount
        shadowDesc.colorAttachments[0].isBlendingEnabled = true
        shadowDesc.colorAttachments[0].rgbBlendOperation = .add
        shadowDesc.colorAttachments[0].alphaBlendOperation = .add
        shadowDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        shadowDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        shadowDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        shadowDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        shadowDesc.vertexDescriptor = vertexDesc
        shadowDesc.depthAttachmentPixelFormat = depthStencilFormat
        shadowDesc.stencilAttachmentPixelFormat = depthStencilFormat

        do {
            cardShadowPipelineState = try device.makeRenderPipelineState(descriptor: shadowDesc)
        } catch {
            fatalError("Failed to create card shadow pipeline: \(error)")
        }

        // Post-process Pipeline (FXAA fullscreen pass)
        let fxaaDesc = MTLRenderPipelineDescriptor()
        fxaaDesc.vertexFunction = library.makeFunction(name: "vertex_fullscreen_triangle")
        fxaaDesc.fragmentFunction = library.makeFunction(name: "fragment_fxaa")
        fxaaDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        fxaaDesc.sampleCount = viewSampleCount
        fxaaDesc.depthAttachmentPixelFormat = depthStencilFormat
        fxaaDesc.stencilAttachmentPixelFormat = depthStencilFormat

        do {
            postProcessPipelineState = try device.makeRenderPipelineState(descriptor: fxaaDesc)
        } catch {
            fatalError("Failed to create postProcessPipelineState: \(error)")
        }

        // Depth clear pipeline (no color writes) for resetting depth between global z-stack items.
        let depthClearDesc = MTLRenderPipelineDescriptor()
        depthClearDesc.vertexFunction = library.makeFunction(name: "vertex_fullscreen_triangle_depth_clear")
        depthClearDesc.fragmentFunction = library.makeFunction(name: "fragment_depth_clear")
        depthClearDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        depthClearDesc.colorAttachments[0].writeMask = []
        depthClearDesc.sampleCount = viewSampleCount
        depthClearDesc.depthAttachmentPixelFormat = depthStencilFormat
        depthClearDesc.stencilAttachmentPixelFormat = depthStencilFormat

        do {
            depthClearPipelineState = try device.makeRenderPipelineState(descriptor: depthClearDesc)
        } catch {
            fatalError("Failed to create depthClearPipelineState: \(error)")
        }

        // Create Sampler for card textures
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samplerDesc)

        // Initialize stencil states for card clipping
        makeDepthStencilStates()
    }

    func makeDepthStencilStates() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .always
        desc.isDepthWriteEnabled = false

        // 0. DEFAULT State (Passthrough - no stencil testing or writing)
        // "Always pass, keep everything as-is"
        let stencilDefault = MTLStencilDescriptor()
        stencilDefault.stencilCompareFunction = .always
        stencilDefault.stencilFailureOperation = .keep
        stencilDefault.depthFailureOperation = .keep
        stencilDefault.depthStencilPassOperation = .keep
        desc.frontFaceStencil = stencilDefault
        desc.backFaceStencil = stencilDefault
        stencilStateDefault = device.makeDepthStencilState(descriptor: desc)

        // 1. WRITE State (Used when drawing the Card Background)
        // "Always pass, replace stencil with the reference (1), and reset depth to far"
        let stencilWrite = MTLStencilDescriptor()
        stencilWrite.stencilCompareFunction = .always
        stencilWrite.stencilFailureOperation = .keep
        stencilWrite.depthFailureOperation = .keep
        stencilWrite.depthStencilPassOperation = .replace
        let stencilWriteDesc = MTLDepthStencilDescriptor()
        stencilWriteDesc.depthCompareFunction = .always
        stencilWriteDesc.isDepthWriteEnabled = true
        stencilWriteDesc.frontFaceStencil = stencilWrite
        stencilWriteDesc.backFaceStencil = stencilWrite
        stencilStateWrite = device.makeDepthStencilState(descriptor: stencilWriteDesc)

        // 1.5 WRITE State (Depth-tested stencil write, no depth writes)
        // Used for overlay draws where we must not clobber existing depth values.
        let stencilWriteNoDepthDesc = MTLDepthStencilDescriptor()
        // Use `.lessEqual` so we can re-stencil at the exact same depth (e.g. live stroke previews)
        // without failing the depth test due to equality.
        stencilWriteNoDepthDesc.depthCompareFunction = .lessEqual
        stencilWriteNoDepthDesc.isDepthWriteEnabled = false
        stencilWriteNoDepthDesc.frontFaceStencil = stencilWrite
        stencilWriteNoDepthDesc.backFaceStencil = stencilWrite
        stencilStateWriteNoDepth = device.makeDepthStencilState(descriptor: stencilWriteNoDepthDesc)

        // 2. READ State (Stencil-only, no depth testing)
        // "Only pass if the stencil value equals the reference (1)"
        let stencilRead = MTLStencilDescriptor()
        stencilRead.stencilCompareFunction = .equal
        stencilRead.stencilFailureOperation = .keep
        stencilRead.depthFailureOperation = .keep
        stencilRead.depthStencilPassOperation = .keep
        desc.frontFaceStencil = stencilRead
        desc.backFaceStencil = stencilRead
        stencilStateRead = device.makeDepthStencilState(descriptor: desc)

        // 3. CLEAR State (Used to clean up after a card)
        // "Always pass, and replace stencil with 0"
        let stencilClear = MTLStencilDescriptor()
        stencilClear.stencilCompareFunction = .always
        stencilClear.depthStencilPassOperation = .zero // Reset to 0
        desc.frontFaceStencil = stencilClear
        desc.backFaceStencil = stencilClear
        stencilStateClear = device.makeDepthStencilState(descriptor: desc)

        // Depth-only states for strokes (no stencil).
        let strokeWriteDesc = MTLDepthStencilDescriptor()
        strokeWriteDesc.depthCompareFunction = .less
        strokeWriteDesc.isDepthWriteEnabled = true
        strokeDepthStateWrite = device.makeDepthStencilState(descriptor: strokeWriteDesc)

        let strokeNoWriteDesc = MTLDepthStencilDescriptor()
        strokeNoWriteDesc.depthCompareFunction = .less
        strokeNoWriteDesc.isDepthWriteEnabled = false
        strokeDepthStateNoWrite = device.makeDepthStencilState(descriptor: strokeNoWriteDesc)

        let cardStencilRead = MTLStencilDescriptor()
        cardStencilRead.stencilCompareFunction = .equal
        cardStencilRead.stencilFailureOperation = .keep
        cardStencilRead.depthFailureOperation = .keep
        cardStencilRead.depthStencilPassOperation = .keep

        let cardStrokeWriteDesc = MTLDepthStencilDescriptor()
        cardStrokeWriteDesc.depthCompareFunction = .less
        cardStrokeWriteDesc.isDepthWriteEnabled = true
        cardStrokeWriteDesc.frontFaceStencil = cardStencilRead
        cardStrokeWriteDesc.backFaceStencil = cardStencilRead
        cardStrokeDepthStateWrite = device.makeDepthStencilState(descriptor: cardStrokeWriteDesc)

        let cardStrokeNoWriteDesc = MTLDepthStencilDescriptor()
        cardStrokeNoWriteDesc.depthCompareFunction = .less
        cardStrokeNoWriteDesc.isDepthWriteEnabled = false
        cardStrokeNoWriteDesc.frontFaceStencil = cardStencilRead
        cardStrokeNoWriteDesc.backFaceStencil = cardStencilRead
        cardStrokeDepthStateNoWrite = device.makeDepthStencilState(descriptor: cardStrokeNoWriteDesc)
	    }

    func makeVertexBuffer() {
        var positions: [SIMD2<Float>] = [
            SIMD2<Float>(-0.8,  0.5),
            SIMD2<Float>(-0.3, -0.5),
            SIMD2<Float>(-0.8, -0.5),
            SIMD2<Float>(-0.3, -0.5),
            SIMD2<Float>(-0.3,  0.5),
            SIMD2<Float>(-0.8,  0.5),
        ]
        vertexBuffer = device.makeBuffer(bytes: &positions,
                                         length: positions.count * MemoryLayout<SIMD2<Float>>.stride,
                                         options: [])
    }

    func updateVertexBuffer(with vertices: [SIMD2<Float>]) {
        guard !vertices.isEmpty else { return }
        let bufferSize = vertices.count * MemoryLayout<SIMD2<Float>>.stride
        vertexBuffer = device.makeBuffer(bytes: vertices, length: bufferSize, options: .storageModeShared)
    }

    func makeQuadVertexBuffer() {
        let quadVertices: [QuadVertex] = [
            QuadVertex(corner: SIMD2<Float>(0, 0)),
            QuadVertex(corner: SIMD2<Float>(1, 0)),
            QuadVertex(corner: SIMD2<Float>(0, 1)),
            QuadVertex(corner: SIMD2<Float>(1, 1)),
        ]

        quadVertexBuffer = device.makeBuffer(bytes: quadVertices,
                                             length: quadVertices.count * MemoryLayout<QuadVertex>.stride,
                                             options: .storageModeShared)
    }

	    // MARK: - Camera Center Calculation

	    /// Initialize fractal frame extent once from the view size.
	    /// The extent defines the bounded coordinate domain of a single same-depth tile.
	    func ensureFractalExtent(viewSize: CGSize) {
	        if fractalFrameExtent.x <= 0.0 || fractalFrameExtent.y <= 0.0 {
	            fractalFrameExtent = SIMD2<Double>(Double(viewSize.width), Double(viewSize.height))
	        }
	    }

	    /// Calculate the camera center in world coordinates using Double precision.
	    /// This is the inverse of the pan/zoom/rotate transform applied to strokes.
	    func calculateCameraCenterWorld(viewSize: CGSize) -> SIMD2<Double> {
	        ensureFractalExtent(viewSize: viewSize)
	        // The center of the screen in screen coordinates
	        let screenCenter = CGPoint(x: viewSize.width / 2.0, y: viewSize.height / 2.0)

        //  USE PURE DOUBLE HELPER
        // Pass Double panOffset and zoomScale directly without casting to Float
        // This prevents precision loss at extreme zoom levels (1,000,000x+)
        return screenToWorldPixels_PureDouble(screenCenter,
                                              viewSize: viewSize,
                                              panOffset: panOffset,       // Now passing SIMD2<Double>
                                              zoomScale: zoomScale,       // Now passing Double
                                              rotationAngle: rotationAngle)
    }

    private func cameraCenterInFrame(_ frame: Frame,
                                     cameraCenterActive: SIMD2<Double>) -> SIMD2<Double> {
        guard frame !== activeFrame, let transform = transformFromActive(to: frame) else {
            return cameraCenterActive
        }
        return cameraCenterActive * transform.scale + transform.translation
    }

    private func cameraCenterAndZoom(in frame: Frame,
                                     cameraCenterActive: SIMD2<Double>) -> (SIMD2<Double>, Double) {
        guard frame !== activeFrame, let transform = transformFromActive(to: frame) else {
            return (cameraCenterActive, max(zoomScale, 1e-6))
        }
        let cameraCenter = cameraCenterActive * transform.scale + transform.translation
        let effectiveZoom = max(zoomScale / transform.scale, 1e-6)
        return (cameraCenter, effectiveZoom)
    }

    private func randomStrokePoints(center: SIMD2<Double>, maxOffset: Double) -> [SIMD2<Double>] {
        let pointCount = Int.random(in: 2...6)
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(pointCount)

        var x = center.x + Double.random(in: -maxOffset...maxOffset)
        var y = center.y + Double.random(in: -maxOffset...maxOffset)
        points.append(SIMD2<Double>(x, y))

        let stepRange = maxOffset * 0.1
        for _ in 1..<pointCount {
            x += Double.random(in: -stepRange...stepRange)
            y += Double.random(in: -stepRange...stepRange)
            x = min(center.x + maxOffset, max(center.x - maxOffset, x))
            y = min(center.y + maxOffset, max(center.y - maxOffset, y))
            points.append(SIMD2<Double>(x, y))
        }

        return points
    }

    // MARK: - Stroke Simplification

    /// Simplify a stroke in screen space by removing points that are too close
    /// or nearly collinear with neighbors.
    /// This prevents vertex explosion and reduces overdraw without noticeable quality loss.
    ///
    /// - Parameters:
    ///   - points: Input stroke points in screen space
    ///   - minScreenDist: Minimum distance between points in screen pixels (default: 1.5)
    ///   - minAngleDeg: Minimum angle change to keep a point in degrees (default: 5.0)
    /// - Returns: Simplified array of points
    func simplifyStroke(
        _ points: [CGPoint],
        minScreenDist: CGFloat = 1.5,
        minAngleDeg: CGFloat = 5.0
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var result: [CGPoint] = [points[0]]

        for i in 1..<(points.count - 1) {
            let prev = result.last!
            let cur  = points[i]
            let next = points[i + 1]

            // Distance filter
            let dx = cur.x - prev.x
            let dy = cur.y - prev.y
            let dist2 = dx*dx + dy*dy
            if dist2 < minScreenDist * minScreenDist {
                continue
            }

            // Angle filter
            let v1 = CGPoint(x: cur.x - prev.x, y: cur.y - prev.y)
            let v2 = CGPoint(x: next.x - cur.x, y: next.y - cur.y)
            let len1 = hypot(v1.x, v1.y)
            let len2 = hypot(v2.x, v2.y)
            if len1 > 0, len2 > 0 {
                let dot = (v1.x * v2.x + v1.y * v2.y) / (len1 * len2)
                let clampedDot = max(-1.0, min(1.0, dot))
                let angle = acos(clampedDot) * 180.0 / .pi

                if angle < minAngleDeg {
                    // Almost straight line – skip
                    continue
                }
            }

            result.append(cur)
        }

        if let last = points.last, last != result.last {
            result.append(last)
        }

        return result
    }

    // MARK: - Lasso Selection

    func clearLassoSelection() {
        lassoSelection = nil
        lassoPreviewStroke = nil
        lassoPreviewFrame = nil
        lassoTransformState = nil
        lassoTarget = nil
        lassoPreviewCard = nil
        lassoPreviewCardFrame = nil
    }

    func createSectionFromLasso(name: String, color: SIMD4<Float>) {
        guard let selection = lassoSelection else { return }
        guard selection.cardStrokes.isEmpty else { return } // Section MVP: canvas-only

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
	        ? nextNumberedName(base: "Section", existingNames: allSectionsInCanvas(from: rootFrame).map(\.name))
	        : trimmed

        let section = Section(
            name: finalName,
            color: color,
            fillOpacity: 0.3,
            polygon: selection.points
        )
        section.ensureLabelTexture(device: device)
        activeFrame.sections.append(section)

        // Reassign existing content in this frame so the new section captures what it contains.
        regroupSectionMembership(in: activeFrame)
        if internalLinkTargetsPresent {
            rebuildInternalLinkReferenceCache()
        }

        clearLassoSelection()
    }

    func deleteSection(_ section: Section) {
        // Remove from active frame
        if let index = activeFrame.sections.firstIndex(where: { $0.id == section.id }) {
            activeFrame.sections.remove(at: index)
        }
        // Also check parent frame
        if let parent = activeFrame.parent,
           let index = parent.sections.firstIndex(where: { $0.id == section.id }) {
            parent.sections.remove(at: index)
        }
        // Check child frames
        for row in 0..<5 {
            for col in 0..<5 {
                let index = GridIndex(col: col, row: row)
                if let child = activeFrame.childIfExists(at: index),
                   let sectionIndex = child.sections.firstIndex(where: { $0.id == section.id }) {
                    child.sections.remove(at: sectionIndex)
                }
            }
        }
    }

    func handleLassoTap(screenPoint: CGPoint, viewSize: CGSize) -> Bool {
        guard let selection = lassoSelection else { return false }
        let pointWorld = screenToWorldPixels_PureDouble(
            screenPoint,
            viewSize: viewSize,
            panOffset: panOffset,
            zoomScale: zoomScale,
            rotationAngle: rotationAngle
        )

        if !pointInPolygon(pointWorld, polygon: selection.points) {
            clearLassoSelection()
        }
        return true
    }

    func lassoContains(screenPoint: CGPoint, viewSize: CGSize) -> Bool {
        guard let selection = lassoSelection else { return false }
        let pointWorld = screenToWorldPixels_PureDouble(
            screenPoint,
            viewSize: viewSize,
            panOffset: panOffset,
            zoomScale: zoomScale,
            rotationAngle: rotationAngle
        )
        return pointInPolygon(pointWorld, polygon: selection.points)
    }

    func translateLassoSelection(by delta: SIMD2<Double>) {
        guard var selection = lassoSelection else { return }

        for frameSelection in selection.frames {
            guard let transform = transformFromActive(to: frameSelection.frame) else { continue }
            let deltaFrame = SIMD2<Double>(delta.x * transform.scale, delta.y * transform.scale)

		            for (index, stroke) in frameSelection.frame.strokes.enumerated() {
		                guard frameSelection.strokeIDs.contains(stroke.id) else { continue }
		                let newOrigin = SIMD2<Double>(stroke.origin.x + deltaFrame.x, stroke.origin.y + deltaFrame.y)
		                let newStroke = Stroke(
		                    id: stroke.id,
		                    origin: newOrigin,
		                    worldWidth: stroke.worldWidth,
		                    color: stroke.color,
		                    zoomEffectiveAtCreation: stroke.zoomEffectiveAtCreation,
		                    segments: stroke.segments,
		                    localBounds: stroke.localBounds,
		                    segmentBounds: stroke.segmentBounds,
		                    device: device,
		                    depthID: stroke.depthID,
		                    depthWriteEnabled: stroke.depthWriteEnabled,
		                    layerID: stroke.layerID,
		                    sectionID: stroke.sectionID,
		                    link: stroke.link,
		                    linkSectionID: stroke.linkSectionID,
		                    linkTargetSectionID: stroke.linkTargetSectionID,
		                    linkTargetCardID: stroke.linkTargetCardID
		                )
		                frameSelection.frame.strokes[index] = newStroke
		            }
	        }

        for cardSelection in selection.cards {
            if cardSelection.card.isLocked { continue }
            guard let transform = transformFromActive(to: cardSelection.frame) else { continue }
            let deltaFrame = SIMD2<Double>(delta.x * transform.scale, delta.y * transform.scale)
            cardSelection.card.origin.x += deltaFrame.x
            cardSelection.card.origin.y += deltaFrame.y
        }

        for cardStrokeSelection in selection.cardStrokes {
            if cardStrokeSelection.card.isLocked { continue }
            guard let transform = transformFromActive(to: cardStrokeSelection.frame) else { continue }
            let deltaFrame = SIMD2<Double>(delta.x * transform.scale, delta.y * transform.scale)
            let c = cos(Double(-cardStrokeSelection.card.rotation))
            let s = sin(Double(-cardStrokeSelection.card.rotation))
            let localDx = deltaFrame.x * c - deltaFrame.y * s
            let localDy = deltaFrame.x * s + deltaFrame.y * c

		            for (index, stroke) in cardStrokeSelection.card.strokes.enumerated() {
		                guard cardStrokeSelection.strokeIDs.contains(stroke.id) else { continue }
		                let newOrigin = SIMD2<Double>(stroke.origin.x + localDx, stroke.origin.y + localDy)
		                let newStroke = Stroke(
		                    id: stroke.id,
		                    origin: newOrigin,
		                    worldWidth: stroke.worldWidth,
		                    color: stroke.color,
		                    zoomEffectiveAtCreation: stroke.zoomEffectiveAtCreation,
		                    segments: stroke.segments,
		                    localBounds: stroke.localBounds,
		                    segmentBounds: stroke.segmentBounds,
		                    device: device,
		                    depthID: stroke.depthID,
		                    depthWriteEnabled: stroke.depthWriteEnabled,
		                    layerID: stroke.layerID,
		                    sectionID: stroke.sectionID,
		                    link: stroke.link,
		                    linkSectionID: stroke.linkSectionID,
		                    linkTargetSectionID: stroke.linkTargetSectionID,
		                    linkTargetCardID: stroke.linkTargetCardID
		                )
		                cardStrokeSelection.card.strokes[index] = newStroke
		            }
	        }

        selection.points = selection.points.map { SIMD2<Double>($0.x + delta.x, $0.y + delta.y) }
        selection.bounds = selection.bounds.offsetBy(dx: delta.x, dy: delta.y)
        selection.center = SIMD2<Double>(selection.center.x + delta.x, selection.center.y + delta.y)
        lassoSelection = selection
        updateLassoPreview(for: selection)
    }

    func beginLassoTransformIfNeeded() {
        guard lassoTransformState == nil,
              let selection = lassoSelection else { return }

        var snapshots: [StrokeSnapshot] = []
        var cardSnapshots: [CardSnapshot] = []
        var cardStrokeSnapshots: [CardStrokeSnapshot] = []

        for frameSelection in selection.frames {
            guard let transform = transformFromActive(to: frameSelection.frame) else { continue }
            let invScale = transform.scale != 0 ? (1.0 / transform.scale) : 1.0

            for (index, stroke) in frameSelection.frame.strokes.enumerated() {
                guard frameSelection.strokeIDs.contains(stroke.id) else { continue }
                let worldPointsFrame = stroke.rawPoints.map {
                    SIMD2<Double>(
                        stroke.origin.x + Double($0.x),
                        stroke.origin.y + Double($0.y)
                    )
                }
                let worldPointsActive = worldPointsFrame.map {
                    SIMD2<Double>(
                        ($0.x - transform.translation.x) * invScale,
                        ($0.y - transform.translation.y) * invScale
                    )
                }

		                snapshots.append(
		                    StrokeSnapshot(
		                        id: stroke.id,
		                        frame: frameSelection.frame,
		                        index: index,
		                        activePoints: worldPointsActive,
		                        color: stroke.color,
		                        worldWidth: stroke.worldWidth,
		                        zoomEffectiveAtCreation: stroke.zoomEffectiveAtCreation,
		                        depthID: stroke.depthID,
		                        depthWriteEnabled: stroke.depthWriteEnabled,
		                        layerID: stroke.layerID,
		                        sectionID: stroke.sectionID,
		                        link: stroke.link,
		                        linkSectionID: stroke.linkSectionID,
		                        linkTargetSectionID: stroke.linkTargetSectionID,
		                        linkTargetCardID: stroke.linkTargetCardID,
		                        frameScale: transform.scale,
		                        frameTranslation: transform.translation
		                    )
		                )
            }
        }

        for cardSelection in selection.cards {
            if cardSelection.card.isLocked { continue }
            guard let transform = transformFromActive(to: cardSelection.frame) else { continue }
            let invScale = transform.scale != 0 ? (1.0 / transform.scale) : 1.0
            let originActive = SIMD2<Double>(
                (cardSelection.card.origin.x - transform.translation.x) * invScale,
                (cardSelection.card.origin.y - transform.translation.y) * invScale
            )
            cardSnapshots.append(
                CardSnapshot(
                    card: cardSelection.card,
                    frameScale: transform.scale,
                    frameTranslation: transform.translation,
                    originActive: originActive,
                    size: cardSelection.card.size,
                    rotation: cardSelection.card.rotation
                )
            )
        }

        for cardStrokeSelection in selection.cardStrokes {
            if cardStrokeSelection.card.isLocked { continue }
            guard let transform = transformFromActive(to: cardStrokeSelection.frame) else { continue }
            let invScale = transform.scale != 0 ? (1.0 / transform.scale) : 1.0
            let cardOrigin = cardStrokeSelection.card.origin
            let cardRotation = Double(cardStrokeSelection.card.rotation)
            let c = cos(cardRotation)
            let s = sin(cardRotation)

            for (index, stroke) in cardStrokeSelection.card.strokes.enumerated() {
                guard cardStrokeSelection.strokeIDs.contains(stroke.id) else { continue }

                let localPoints = stroke.rawPoints.map {
                    SIMD2<Double>(
                        stroke.origin.x + Double($0.x),
                        stroke.origin.y + Double($0.y)
                    )
                }

                let framePoints = localPoints.map {
                    let rotX = $0.x * c - $0.y * s
                    let rotY = $0.x * s + $0.y * c
                    return SIMD2<Double>(cardOrigin.x + rotX, cardOrigin.y + rotY)
                }

                let activePoints = framePoints.map {
                    SIMD2<Double>(
                        ($0.x - transform.translation.x) * invScale,
                        ($0.y - transform.translation.y) * invScale
                    )
                }

		                cardStrokeSnapshots.append(
		                    CardStrokeSnapshot(
		                        card: cardStrokeSelection.card,
		                        frame: cardStrokeSelection.frame,
		                        index: index,
		                        activePoints: activePoints,
		                        color: stroke.color,
		                        worldWidth: stroke.worldWidth,
		                        zoomEffectiveAtCreation: stroke.zoomEffectiveAtCreation,
		                        depthID: stroke.depthID,
		                        depthWriteEnabled: stroke.depthWriteEnabled,
		                        layerID: stroke.layerID,
		                        link: stroke.link,
		                        linkSectionID: stroke.linkSectionID,
		                        linkTargetSectionID: stroke.linkTargetSectionID,
		                        linkTargetCardID: stroke.linkTargetCardID,
		                        frameScale: transform.scale,
		                        frameTranslation: transform.translation,
		                        cardOrigin: cardOrigin,
		                        cardRotation: cardRotation
		                    )
		                )
            }
        }

        lassoTransformState = LassoTransformState(
            basePoints: selection.points,
            baseCenter: selection.center,
            baseStrokes: snapshots,
            baseCards: cardSnapshots,
            baseCardStrokes: cardStrokeSnapshots,
            currentScale: 1.0,
            currentRotation: 0.0
        )
    }

    func updateLassoTransformScale(delta: Double) {
        guard var state = lassoTransformState else { return }
        guard delta.isFinite, delta > 0 else { return }
        state.currentScale *= delta
        lassoTransformState = state
        applyLassoTransform(state)
    }

	    func updateLassoTransformRotation(delta: Double) {
	        guard var state = lassoTransformState else { return }
	        guard delta.isFinite else { return }
	        state.currentRotation += delta
	        lassoTransformState = state
	        applyLassoTransform(state)
	    }
	
		    func endLassoTransformIfNeeded() {
		        lassoTransformState = nil
		        endLassoDrag()
		    }

		    func endLassoDrag() {
		        normalizeLassoSelectedCanvasStrokes()
		        normalizeLassoSelectedCards()
		        if internalLinkTargetsPresent {
		            rebuildInternalLinkReferenceCache()
		        }
		        if let selection = lassoSelection {
		            updateLassoPreview(for: selection)
		        }
		    }

	    /// After a lasso scale/rotate, selected strokes can end up outside the local frame bounds.
	    /// If we leave them there, navigating (wrapping/drilling) moves into neighbor frames and the
	    /// strokes appear to "vanish" because they're still stored in the old frame.
	    ///
	    /// Fix: re-home each selected stroke into the same-depth neighbor frame that contains its bounds center.
		    private func normalizeLassoSelectedCanvasStrokes() {
		        guard var selection = lassoSelection else { return }
	        guard let view = metalView else { return }
	        let viewSize = view.bounds.size
	        guard viewSize.width > 0.0, viewSize.height > 0.0 else { return }
	
	        ensureFractalExtent(viewSize: viewSize)
	        let extent = fractalFrameExtent
	        guard extent.x > 0.0, extent.y > 0.0 else { return }
	
	        var regrouped: [ObjectIdentifier: (frame: Frame, strokeIDs: Set<UUID>)] = [:]

	        func removeStroke(with id: UUID, from frame: Frame) -> Stroke? {
	            if let index = frame.strokes.firstIndex(where: { $0.id == id }) {
	                return frame.strokes.remove(at: index)
	            }
	            return nil
	        }
	
	        for frameSelection in selection.frames {
	            let originalFrame = frameSelection.frame
	            for id in frameSelection.strokeIDs {
	                guard let stroke = removeStroke(with: id, from: originalFrame) else { continue }
	
	                let (newFrame, newStroke) = rehomeCanvasStrokeIfNeeded(stroke, from: originalFrame, viewSize: viewSize)
	                _ = appendCanvasStroke(newStroke, to: newFrame)
	
	                let key = ObjectIdentifier(newFrame)
	                if var entry = regrouped[key] {
	                    entry.strokeIDs.insert(id)
	                    regrouped[key] = entry
	                } else {
	                    regrouped[key] = (frame: newFrame, strokeIDs: [id])
	                }
	            }
	        }
	
		        selection.frames = regrouped.values.map { LassoFrameSelection(frame: $0.frame, strokeIDs: $0.strokeIDs) }
		        lassoSelection = selection
		    }

		    /// Same re-homing logic as canvas strokes, but for whole cards that were lasso-transformed.
		    /// Cards can be moved outside the local frame bounds by a scale/rotate about a distant center.
		    /// If we don't re-home them, they'll "disappear" when the user wraps/drills into the neighbor frame.
		    private func normalizeLassoSelectedCards() {
		        guard var selection = lassoSelection else { return }
		        guard !selection.cards.isEmpty else { return }
		        guard let view = metalView else { return }
		        let viewSize = view.bounds.size
		        guard viewSize.width > 0.0, viewSize.height > 0.0 else { return }
		
		        ensureFractalExtent(viewSize: viewSize)
		        let extent = fractalFrameExtent
		        guard extent.x > 0.0, extent.y > 0.0 else { return }
		
		        var updated: [LassoCardSelection] = []
		        updated.reserveCapacity(selection.cards.count)
		
		        for cardSelection in selection.cards {
		            let card = cardSelection.card
		            if card.isLocked {
		                updated.append(cardSelection)
		                continue
		            }
		
		            let originalFrame = cardSelection.frame
		            let resolved = resolveSameDepthFrame(start: originalFrame, anchor: card.origin, viewSize: viewSize)
		            if resolved.frame !== originalFrame {
		                // Move the card into the destination frame and keep its world position stable.
		                card.origin = card.origin + resolved.shift

		                if let index = originalFrame.cards.firstIndex(where: { $0.id == card.id }) {
		                    originalFrame.cards.remove(at: index)
		                }

		                appendCard(card, to: resolved.frame)
		
		                updated.append(LassoCardSelection(card: card, frame: resolved.frame))
		            } else {
		                reassignCardMembershipIfNeeded(card: card, frame: originalFrame)
		                updated.append(cardSelection)
		            }
		        }
		
		        selection.cards = updated
		        lassoSelection = selection
		    }

	    private func rehomeCanvasStrokeIfNeeded(_ stroke: Stroke,
	                                           from frame: Frame,
	                                           viewSize: CGSize) -> (frame: Frame, stroke: Stroke) {
	        ensureFractalExtent(viewSize: viewSize)
	        let extent = fractalFrameExtent
	        guard extent.x > 0.0, extent.y > 0.0 else { return (frame: frame, stroke: stroke) }
	
	        let bounds = stroke.localBounds
	        let centerLocal = SIMD2<Double>(Double(bounds.midX), Double(bounds.midY))
	        let center = stroke.origin + centerLocal
	
	        let resolved = resolveSameDepthFrame(start: frame, anchor: center, viewSize: viewSize)
	        if resolved.frame === frame { return (frame: frame, stroke: stroke) }
	
	        let shiftedOrigin = stroke.origin + resolved.shift
		        let shiftedStroke = Stroke(id: stroke.id,
			                                   origin: shiftedOrigin,
			                                   worldWidth: stroke.worldWidth,
			                                   color: stroke.color,
			                                   zoomEffectiveAtCreation: stroke.zoomEffectiveAtCreation,
			                                   segments: stroke.segments,
			                                   localBounds: stroke.localBounds,
			                                   segmentBounds: stroke.segmentBounds,
			                                   device: device,
			                                   depthID: stroke.depthID,
			                                   depthWriteEnabled: stroke.depthWriteEnabled,
			                                   layerID: stroke.layerID,
			                                   sectionID: stroke.sectionID,
			                                   link: stroke.link,
			                                   linkSectionID: stroke.linkSectionID,
			                                   linkTargetSectionID: stroke.linkTargetSectionID,
			                                   linkTargetCardID: stroke.linkTargetCardID)
		        return (frame: resolved.frame, stroke: shiftedStroke)
		    }

	    private func resolveSameDepthFrame(start: Frame,
	                                       anchor: SIMD2<Double>,
	                                       viewSize: CGSize) -> (frame: Frame, shift: SIMD2<Double>) {
	        ensureFractalExtent(viewSize: viewSize)
	        let extent = fractalFrameExtent
	        let half = extent * 0.5
	
	        var frame = start
	        var point = anchor
	        var shift = SIMD2<Double>(0, 0)
	
	        while point.x > half.x {
	            frame = neighborFrame(from: frame, direction: .right)
	            point.x -= extent.x
	            shift.x -= extent.x
	        }
	        while point.x < -half.x {
	            frame = neighborFrame(from: frame, direction: .left)
	            point.x += extent.x
	            shift.x += extent.x
	        }
	        while point.y > half.y {
	            frame = neighborFrame(from: frame, direction: .down)
	            point.y -= extent.y
	            shift.y -= extent.y
	        }
	        while point.y < -half.y {
	            frame = neighborFrame(from: frame, direction: .up)
	            point.y += extent.y
	            shift.y += extent.y
	        }
	
	        return (frame: frame, shift: shift)
	    }

	    /// If a card's origin exits the local frame bounds (±extent/2), move it into the
	    /// correct same-depth neighbor frame and keep its world position stable.
	    ///
	    /// This prevents cards from living "out of bounds" in their old frame, which can
	    /// cause pop/flicker when rendering the 5x5 neighborhood while panning.
	    @discardableResult
	    func normalizeCardAcrossFramesIfNeeded(card: Card, from frame: Frame, viewSize: CGSize) -> Frame {
	        ensureFractalExtent(viewSize: viewSize)
	        let extent = fractalFrameExtent
	        guard extent.x > 0.0, extent.y > 0.0 else {
	            reassignCardMembershipIfNeeded(card: card, frame: frame)
	            return frame
	        }

	        let resolved = resolveSameDepthFrame(start: frame, anchor: card.origin, viewSize: viewSize)
	        if resolved.frame === frame {
	            reassignCardMembershipIfNeeded(card: card, frame: frame)
	            return frame
	        }

	        card.origin = card.origin + resolved.shift

	        if let index = frame.cards.firstIndex(where: { $0.id == card.id }) {
	            frame.cards.remove(at: index)
	        }
	        appendCard(card, to: resolved.frame)
	        return resolved.frame
	    }

    private func applyLassoTransform(_ state: LassoTransformState) {
        guard var selection = lassoSelection else { return }

        let cosR = cos(state.currentRotation)
        let sinR = sin(state.currentRotation)
        let scale = max(state.currentScale, 1e-6)

        func transformPoint(_ point: SIMD2<Double>) -> SIMD2<Double> {
            let dx = point.x - state.baseCenter.x
            let dy = point.y - state.baseCenter.y
            let sx = dx * scale
            let sy = dy * scale
            let rx = sx * cosR - sy * sinR
            let ry = sx * sinR + sy * cosR
            return SIMD2<Double>(state.baseCenter.x + rx, state.baseCenter.y + ry)
        }

        let transformedSelection = state.basePoints.map(transformPoint)
        selection.points = transformedSelection
        selection.bounds = polygonBounds(transformedSelection)
        selection.center = state.baseCenter
        lassoSelection = selection
        updateLassoPreview(for: selection)

        for snapshot in state.baseStrokes {
            guard snapshot.index < snapshot.frame.strokes.count else { continue }

            let transformedActivePoints = snapshot.activePoints.map(transformPoint)
            let transformedFramePoints = transformedActivePoints.map {
                SIMD2<Double>(
                    $0.x * snapshot.frameScale + snapshot.frameTranslation.x,
                    $0.y * snapshot.frameScale + snapshot.frameTranslation.y
                )
            }

            guard let first = transformedFramePoints.first else { continue }
            let origin = first
            let localPoints: [SIMD2<Float>] = transformedFramePoints.map {
                SIMD2<Float>(Float($0.x - origin.x), Float($0.y - origin.y))
            }

		            let segments = Stroke.buildSegments(from: localPoints, color: snapshot.color)
		            let bounds = Stroke.calculateBounds(for: localPoints, radius: Float(snapshot.worldWidth * scale) * 0.5)
			            let newStroke = Stroke(
			                id: snapshot.id,
			                origin: origin,
			                worldWidth: snapshot.worldWidth * scale,
			                color: snapshot.color,
			                zoomEffectiveAtCreation: snapshot.zoomEffectiveAtCreation,
			                segments: segments,
			                localBounds: bounds,
			                segmentBounds: bounds,
			                device: device,
			                depthID: snapshot.depthID,
			                depthWriteEnabled: snapshot.depthWriteEnabled,
			                layerID: snapshot.layerID,
			                sectionID: snapshot.sectionID,
			                link: snapshot.link,
			                linkSectionID: snapshot.linkSectionID,
			                linkTargetSectionID: snapshot.linkTargetSectionID,
			                linkTargetCardID: snapshot.linkTargetCardID
			            )
			            snapshot.frame.strokes[snapshot.index] = newStroke
			        }

        for cardSnapshot in state.baseCards {
            if cardSnapshot.card.isLocked { continue }
            let transformedOriginActive = transformPoint(cardSnapshot.originActive)
            let originFrame = SIMD2<Double>(
                transformedOriginActive.x * cardSnapshot.frameScale + cardSnapshot.frameTranslation.x,
                transformedOriginActive.y * cardSnapshot.frameScale + cardSnapshot.frameTranslation.y
            )

            cardSnapshot.card.origin = originFrame
            cardSnapshot.card.rotation = cardSnapshot.rotation + Float(state.currentRotation)
            cardSnapshot.card.size = SIMD2<Double>(
                cardSnapshot.size.x * scale,
                cardSnapshot.size.y * scale
            )
            cardSnapshot.card.rebuildGeometry()
        }

        for snapshot in state.baseCardStrokes {
            if snapshot.card.isLocked { continue }
            guard snapshot.index < snapshot.card.strokes.count else { continue }

            let transformedActivePoints = snapshot.activePoints.map(transformPoint)
            let transformedFramePoints = transformedActivePoints.map {
                SIMD2<Double>(
                    $0.x * snapshot.frameScale + snapshot.frameTranslation.x,
                    $0.y * snapshot.frameScale + snapshot.frameTranslation.y
                )
            }

            let cInv = cos(-snapshot.cardRotation)
            let sInv = sin(-snapshot.cardRotation)
            let transformedCardLocal = transformedFramePoints.map {
                let dx = $0.x - snapshot.cardOrigin.x
                let dy = $0.y - snapshot.cardOrigin.y
                let localX = dx * cInv - dy * sInv
                let localY = dx * sInv + dy * cInv
                return SIMD2<Double>(localX, localY)
            }

            guard let first = transformedCardLocal.first else { continue }
            let origin = first
            let localPoints: [SIMD2<Float>] = transformedCardLocal.map {
                SIMD2<Float>(Float($0.x - origin.x), Float($0.y - origin.y))
            }

		            let segments = Stroke.buildSegments(from: localPoints, color: snapshot.color)
		            let bounds = Stroke.calculateBounds(for: localPoints, radius: Float(snapshot.worldWidth * scale) * 0.5)
			            let newStroke = Stroke(
			                id: snapshot.card.strokes[snapshot.index].id,
			                origin: origin,
			                worldWidth: snapshot.worldWidth * scale,
			                color: snapshot.color,
			                zoomEffectiveAtCreation: snapshot.zoomEffectiveAtCreation,
			                segments: segments,
			                localBounds: bounds,
			                segmentBounds: bounds,
			                device: device,
			                depthID: snapshot.depthID,
			                depthWriteEnabled: snapshot.depthWriteEnabled,
			                layerID: snapshot.layerID,
			                link: snapshot.link,
			                linkSectionID: snapshot.linkSectionID,
			                linkTargetSectionID: snapshot.linkTargetSectionID,
			                linkTargetCardID: snapshot.linkTargetCardID
			            )
			            snapshot.card.strokes[snapshot.index] = newStroke
			        }
    }

    private func updateLassoPreview(for points: [SIMD2<Double>],
                                    close: Bool,
                                    card: Card? = nil,
                                    frame: Frame? = nil,
                                    zoom: Double? = nil) {
        let resolvedZoom = zoom ?? max(zoomScale, 1e-6)
        lassoPreviewStroke = buildLassoPreviewStroke(points: points, close: close, zoom: resolvedZoom)
        lassoPreviewFrame = activeFrame
        lassoPreviewCard = card
        lassoPreviewCardFrame = frame
    }

    private func updateLassoPreview(for selection: LassoSelection) {
        if let cardSelection = selection.cardStrokes.first {
            guard let transform = transformFromActive(to: cardSelection.frame) else {
                updateLassoPreview(for: selection.points, close: true)
                return
            }
            let cardPoints = selection.points.map { activePoint in
                let framePoint = SIMD2<Double>(
                    activePoint.x * transform.scale + transform.translation.x,
                    activePoint.y * transform.scale + transform.translation.y
                )
                return framePointToCardLocal(framePoint, card: cardSelection.card)
            }
            let zoomInFrame = zoomScale / max(transform.scale, 1e-6)
            updateLassoPreview(for: cardPoints,
                               close: true,
                               card: cardSelection.card,
                               frame: cardSelection.frame,
                               zoom: zoomInFrame)
        } else {
            updateLassoPreview(for: selection.points, close: true)
        }
    }

    private func buildLassoPreviewStroke(points: [SIMD2<Double>], close: Bool, zoom: Double) -> Stroke? {
        guard points.count >= 2 else { return nil }

        var path = points
        if close, let first = points.first, let last = points.last {
            let dx = last.x - first.x
            let dy = last.y - first.y
            if (dx * dx + dy * dy) > 1e-12 {
                path.append(first)
            }
        }

        let safeZoom = max(zoom, 1e-6)
        let dashWorld = lassoDashLengthPx / safeZoom
        let gapWorld = lassoGapLengthPx / safeZoom
        let widthWorld = lassoLineWidthPx / safeZoom

        let origin = path[0]
        var segments: [StrokeSegmentInstance] = []
        var boundPoints: [SIMD2<Float>] = []

        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = sqrt(dx * dx + dy * dy)
            if len <= 0 { continue }

            let ux = dx / len
            let uy = dy / len
            var t = 0.0
            while t < len {
                let segLen = min(dashWorld, len - t)
                let start = t
                let end = t + segLen

                let p0World = SIMD2<Double>(a.x + ux * start, a.y + uy * start)
                let p1World = SIMD2<Double>(a.x + ux * end, a.y + uy * end)

                let p0Local = SIMD2<Float>(Float(p0World.x - origin.x), Float(p0World.y - origin.y))
                let p1Local = SIMD2<Float>(Float(p1World.x - origin.x), Float(p1World.y - origin.y))

                segments.append(StrokeSegmentInstance(p0: p0Local, p1: p1Local, color: lassoColor))
                boundPoints.append(p0Local)
                boundPoints.append(p1Local)

                t += dashWorld + gapWorld
            }
        }

        guard !segments.isEmpty else { return nil }
        let bounds = Stroke.calculateBounds(for: boundPoints, radius: Float(widthWorld) * 0.5)
        return Stroke(
            id: UUID(),
            origin: origin,
            worldWidth: widthWorld,
            color: lassoColor,
            zoomEffectiveAtCreation: Float(max(zoomScale, 1e-6)),
            segments: segments,
            localBounds: bounds,
            segmentBounds: bounds,
            device: device,
            depthID: StrokeDepth.slotCount - 1,
            depthWriteEnabled: false
        )
    }

    private func polygonBounds(_ points: [SIMD2<Double>]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func framePointToCardLocal(_ point: SIMD2<Double>, card: Card) -> SIMD2<Double> {
        let dx = point.x - card.origin.x
        let dy = point.y - card.origin.y
        let c = cos(Double(-card.rotation))
        let s = sin(Double(-card.rotation))
        let localX = dx * c - dy * s
        let localY = dx * s + dy * c
        return SIMD2<Double>(localX, localY)
    }

    /// Check if a point in frame coordinates is on the card's resize handle (bottom-right corner)
    /// Returns true if the point is within the handle hit area
    func isPointOnCardHandle(_ pointInFrame: SIMD2<Double>, card: Card, zoom: Double) -> Bool {
        // Convert to card-local coordinates
        let localPoint = framePointToCardLocal(pointInFrame, card: card)

        // Handle is in bottom-right corner
        let halfW = card.size.x / 2.0
        let halfH = card.size.y / 2.0

        // Define handle hit area size (in world units)
        // Make it screen-size independent by dividing by zoom
        let handleSizePx: Double = 40.0 // 40px hit area
        let handleSize = handleSizePx / max(zoom, 1e-6)

        // Check if point is in bottom-right corner region
        let isInRightEdge = localPoint.x >= (halfW - handleSize) && localPoint.x <= halfW
        let isInBottomEdge = localPoint.y >= (halfH - handleSize) && localPoint.y <= halfH

        return isInRightEdge && isInBottomEdge
    }

    private func cardOffsetFromCameraInLocalSpace(card: Card, cameraCenter: SIMD2<Double>) -> SIMD2<Double> {
        let cameraLocal = framePointToCardLocal(cameraCenter, card: card)
        return SIMD2<Double>(-cameraLocal.x, -cameraLocal.y)
    }

    private func shadowOffsetInCardLocalSpace(offsetPx: SIMD2<Float>,
                                              rotation: Float,
                                              zoom: Double) -> SIMD2<Double> {
        let dx = Double(offsetPx.x) / max(zoom, 1e-6)
        let dy = Double(offsetPx.y) / max(zoom, 1e-6)
        let angle = Double(rotation)
        let c = cos(angle)
        let s = sin(angle)
        let localX = dx * c + dy * s
        let localY = -dx * s + dy * c
        return SIMD2<Double>(localX, localY)
    }

	    private func cardLocalToFramePoint(_ point: SIMD2<Double>, card: Card) -> SIMD2<Double> {
	        let c = cos(Double(card.rotation))
	        let s = sin(Double(card.rotation))
	        let rotX = point.x * c - point.y * s
	        let rotY = point.x * s + point.y * c
	        return SIMD2<Double>(card.origin.x + rotX, card.origin.y + rotY)
	    }

	    // MARK: - Link Highlight Bounds (World-Space, Axis-Aligned)

	    private func strokeBoundsRectInContainerSpace(_ stroke: Stroke) -> CGRect? {
	        let b = stroke.localBounds
	        guard !b.isNull, !b.isInfinite else { return nil }
	        return CGRect(x: stroke.origin.x + b.minX,
	                      y: stroke.origin.y + b.minY,
	                      width: b.width,
	                      height: b.height)
	    }

	    private func frameRectInActiveWorld(_ rectInFrame: CGRect, frame: Frame) -> CGRect? {
	        if frame === activeFrame { return rectInFrame }
	        guard let transform = transformFromActive(to: frame) else { return nil }
	        let inv = transform.scale != 0 ? (1.0 / transform.scale) : 1.0

	        let minFrame = SIMD2<Double>(rectInFrame.minX, rectInFrame.minY)
	        let maxFrame = SIMD2<Double>(rectInFrame.maxX, rectInFrame.maxY)
	        let minActive = (minFrame - transform.translation) * inv
	        let maxActive = (maxFrame - transform.translation) * inv

	        return CGRect(x: minActive.x,
	                      y: minActive.y,
	                      width: maxActive.x - minActive.x,
	                      height: maxActive.y - minActive.y)
	    }

	    private func cardLocalRectToFrameAABB(_ rectInCard: CGRect, card: Card) -> CGRect {
	        let corners = [
	            SIMD2<Double>(rectInCard.minX, rectInCard.minY),
	            SIMD2<Double>(rectInCard.maxX, rectInCard.minY),
	            SIMD2<Double>(rectInCard.minX, rectInCard.maxY),
	            SIMD2<Double>(rectInCard.maxX, rectInCard.maxY)
	        ]

	        let angle = Double(card.rotation)
	        let c = cos(angle)
	        let s = sin(angle)

	        var minX = Double.greatestFiniteMagnitude
	        var maxX = -Double.greatestFiniteMagnitude
	        var minY = Double.greatestFiniteMagnitude
	        var maxY = -Double.greatestFiniteMagnitude

	        for p in corners {
	            let x = p.x * c - p.y * s
	            let y = p.x * s + p.y * c
	            let frameX = card.origin.x + x
	            let frameY = card.origin.y + y
	            minX = min(minX, frameX)
	            maxX = max(maxX, frameX)
	            minY = min(minY, frameY)
	            maxY = max(maxY, frameY)
	        }

	        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
	    }

	    private func linkedStrokeBoundsActiveWorld(_ ref: LinkedStrokeRef) -> CGRect? {
	        guard let stroke = resolveCurrentStroke(for: ref) else { return nil }

	        switch ref.container {
	        case .canvas(let frame):
	            guard let rectFrame = strokeBoundsRectInContainerSpace(stroke) else { return nil }
	            return frameRectInActiveWorld(rectFrame, frame: frame)

	        case .card(let card, let frame):
	            guard let rectCard = strokeBoundsRectInContainerSpace(stroke) else { return nil }
	            let rectFrame = cardLocalRectToFrameAABB(rectCard, card: card)
	            return frameRectInActiveWorld(rectFrame, frame: frame)
	        }
	    }

			    private func paddedActiveRect(_ rectActive: CGRect,
			                                  frame: Frame,
			                                  paddingInFrameWorld: Double) -> CGRect {
			        // Pad in the *originating frame's* coordinate system (world units),
			        // then express that padding in active-world units using the cached
			        // transform scale. This keeps padding proportional when the same
			        // content is viewed from different depths (zooming out to a parent,
			        // or seeing descendants).
			        let paddingActive: Double
			        if frame === activeFrame {
			            paddingActive = paddingInFrameWorld
			        } else if let transform = transformFromActive(to: frame) {
			            paddingActive = paddingInFrameWorld / max(transform.scale, 1e-12)
			        } else {
			            paddingActive = paddingInFrameWorld
			        }
			        return rectActive.insetBy(dx: -paddingActive, dy: -paddingActive)
			    }

		    private func linkHighlightKey(link: String?, sectionID: UUID?) -> LinkHighlightKey? {
		        if let id = sectionID { return .section(id) }
		        let normalized = (link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		        guard !normalized.isEmpty else { return nil }
		        return .legacy(normalized)
		    }

		    private func recordLinkHighlightBounds(link: String?, sectionID: UUID?, rectActive: CGRect) {
		        guard let key = linkHighlightKey(link: link, sectionID: sectionID) else { return }
		        guard rectActive.minX.isFinite,
		              rectActive.minY.isFinite,
		              rectActive.maxX.isFinite,
		              rectActive.maxY.isFinite else { return }
		        guard rectActive.width.isFinite,
		              rectActive.height.isFinite,
		              rectActive.width >= 0,
		              rectActive.height >= 0 else { return }

		        if let existing = linkHighlightBoundsByKeyActiveThisFrame[key] {
		            linkHighlightBoundsByKeyActiveThisFrame[key] = existing.union(rectActive)
		        } else {
		            linkHighlightBoundsByKeyActiveThisFrame[key] = rectActive
		        }
		    }

		    private func framesInActiveChain() -> [Frame] {
		        if !visibleFractalFramesDrawOrder.isEmpty {
		            return visibleFractalFramesDrawOrder
		        }
	        guard let view = metalView else { return [activeFrame] }
	        ensureFractalExtent(viewSize: view.bounds.size)

	        let radius = 2
	        var frames: [Frame] = []
	        frames.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
	        for dy in -radius...radius {
	            for dx in -radius...radius {
	                guard let frame = frameAtOffsetFromActiveIfExists(dx: dx, dy: dy) else { continue }
	                frames.append(frame)
	            }
	        }
	        return frames
	    }

    private func pointInPolygon(_ point: SIMD2<Double>, polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            let denom = pj.y - pi.y
            if abs(denom) > 1e-12 {
                let intersect = ((pi.y > point.y) != (pj.y > point.y)) &&
                    (point.x < (pj.x - pi.x) * (point.y - pi.y) / denom + pi.x)
                if intersect {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    private func polygonEdges(_ points: [SIMD2<Double>]) -> [(SIMD2<Double>, SIMD2<Double>)] {
        guard points.count >= 2 else { return [] }
        var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
        edges.reserveCapacity(points.count)
        for i in 0..<(points.count - 1) {
            edges.append((points[i], points[i + 1]))
        }
        if let first = points.first, let last = points.last, first != last {
            edges.append((last, first))
        }
        return edges
    }

    private func segmentsIntersect(_ p1: SIMD2<Double>, _ q1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
        let eps = 1e-12

        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            min(a.x, c.x) - eps <= b.x && b.x <= max(a.x, c.x) + eps &&
            min(a.y, c.y) - eps <= b.y && b.y <= max(a.y, c.y) + eps
        }

        let o1 = cross(p1, q1, p2)
        let o2 = cross(p1, q1, q2)
        let o3 = cross(p2, q2, p1)
        let o4 = cross(p2, q2, q1)

        if (o1 * o2 < 0) && (o3 * o4 < 0) {
            return true
        }

        if abs(o1) <= eps && onSegment(p1, p2, q1) { return true }
        if abs(o2) <= eps && onSegment(p1, q2, q1) { return true }
        if abs(o3) <= eps && onSegment(p2, p1, q2) { return true }
        if abs(o4) <= eps && onSegment(p2, q1, q2) { return true }

        return false
    }

    private func strokeIntersectsPolygon(_ stroke: Stroke,
                                         polygon: [SIMD2<Double>],
                                         polygonBounds: CGRect,
                                         edges: [(SIMD2<Double>, SIMD2<Double>)]) -> Bool {
        let sBounds = stroke.localBounds
        if sBounds == .null { return false }

        let strokeBoundsWorld = CGRect(
            x: stroke.origin.x + Double(sBounds.minX),
            y: stroke.origin.y + Double(sBounds.minY),
            width: Double(sBounds.width),
            height: Double(sBounds.height)
        )

        if !strokeBoundsWorld.intersects(polygonBounds) {
            return false
        }

        for seg in stroke.segments {
            let p0 = SIMD2<Double>(stroke.origin.x + Double(seg.p0.x),
                                   stroke.origin.y + Double(seg.p0.y))
            let p1 = SIMD2<Double>(stroke.origin.x + Double(seg.p1.x),
                                   stroke.origin.y + Double(seg.p1.y))

            if pointInPolygon(p0, polygon: polygon) || pointInPolygon(p1, polygon: polygon) {
                return true
            }

            for edge in edges {
                if segmentsIntersect(p0, p1, edge.0, edge.1) {
                    return true
                }
            }
        }

        return false
    }

    private func selectStrokes(from strokes: [Stroke],
                               polygon: [SIMD2<Double>],
                               strokeLayerFilterID: UUID? = nil) -> Set<UUID> {
        guard polygon.count >= 3 else { return [] }
        let bounds = polygonBounds(polygon)
        let edges = polygonEdges(polygon)

        var ids = Set<UUID>()
        for stroke in strokes {
            if let strokeLayerFilterID {
                let effective = stroke.layerID ?? layers.first?.id
                if effective != strokeLayerFilterID {
                    continue
                }
            }
            if strokeIntersectsPolygon(stroke, polygon: polygon, polygonBounds: bounds, edges: edges) {
                ids.insert(stroke.id)
            }
        }
        return ids
    }

    private func selectStrokes(in frame: Frame,
                               polygon: [SIMD2<Double>],
                               strokeLayerFilterID: UUID? = nil) -> Set<UUID> {
        selectStrokes(from: frame.strokes, polygon: polygon, strokeLayerFilterID: strokeLayerFilterID)
    }

    private func polygonIntersectsCard(_ polygonActive: [SIMD2<Double>],
                                       card: Card,
                                       transform: (scale: Double, translation: SIMD2<Double>)) -> Bool {
        guard polygonActive.count >= 3 else { return false }
        let polygonCard = polygonActive.map { activePoint in
            let framePoint = SIMD2<Double>(
                activePoint.x * transform.scale + transform.translation.x,
                activePoint.y * transform.scale + transform.translation.y
            )
            return framePointToCardLocal(framePoint, card: card)
        }

        let bounds = polygonBounds(polygonCard)
        let halfW = card.size.x * 0.5
        let halfH = card.size.y * 0.5
        let cardRect = CGRect(x: -halfW, y: -halfH, width: card.size.x, height: card.size.y)
        if !bounds.intersects(cardRect) {
            return false
        }

        // Any polygon point inside card rect?
        if polygonCard.contains(where: { cardRect.contains(CGPoint(x: $0.x, y: $0.y)) }) {
            return true
        }

        // Any card corner inside polygon?
        let corners = [
            SIMD2<Double>(-halfW, -halfH),
            SIMD2<Double>(halfW, -halfH),
            SIMD2<Double>(halfW, halfH),
            SIMD2<Double>(-halfW, halfH)
        ]
        if corners.contains(where: { pointInPolygon($0, polygon: polygonCard) }) {
            return true
        }

        // Edge intersection test.
        let polygonEdges = polygonEdges(polygonCard)
        let cardEdges: [(SIMD2<Double>, SIMD2<Double>)] = [
            (corners[0], corners[1]),
            (corners[1], corners[2]),
            (corners[2], corners[3]),
            (corners[3], corners[0])
        ]

        for edge in polygonEdges {
            for cardEdge in cardEdges {
                if segmentsIntersect(edge.0, edge.1, cardEdge.0, cardEdge.1) {
                    return true
                }
            }
        }

        return false
    }

	    // MARK: - Touch Handling

	    private var isRunningOnMac: Bool {
	#if targetEnvironment(macCatalyst)
	        return true
	#else
	        if #available(iOS 14.0, *) {
	            return ProcessInfo.processInfo.isiOSAppOnMac
	        }
	        return false
	#endif
	    }

	    private func isDrawingTouchType(_ touchType: UITouch.TouchType) -> Bool {
	        if touchType == .pencil { return true }
	        guard isRunningOnMac else { return false }

	        // iOS app on Mac / Mac Catalyst: allow mouse/trackpad drawing.
	        if #available(iOS 13.4, macCatalyst 13.4, *) {
	            return touchType == .indirectPointer || touchType == .direct
	        }
	        return touchType == .direct
	    }
	
    func handleTouchBegan(at point: CGPoint, touchType: UITouch.TouchType) {
        // MODAL INPUT: Pencil on iPad; mouse/trackpad on Mac Catalyst.
        guard isDrawingTouchType(touchType) else { return }

        guard let view = metalView else { return }

        if brushSettings.isLasso {
            clearLassoSelection()
            // Card-local strokes are not part of layers and should always be selectable/editable
            // when the lasso starts inside the card.
            if let (card, frame, _, _) = hitTestHierarchy(screenPoint: point, viewSize: view.bounds.size, ignoringLocked: true) {
                lassoTarget = .card(card, frame)
            } else {
                lassoTarget = .canvas
            }
            lassoDrawingPoints = [point]
            lassoPredictedPoints = []
            if brushSettings.isBoxLasso {
                let screenPoints = buildBoxLassoScreenPoints(start: point, end: point)
                if !screenPoints.isEmpty {
                    updateLassoPreviewFromScreenPoints(screenPoints, close: true, viewSize: view.bounds.size)
                }
            } else if let screenPoints = buildLassoScreenPoints() {
                updateLassoPreviewFromScreenPoints(screenPoints, close: false, viewSize: view.bounds.size)
            }
            currentTouchPoints = []
            predictedTouchPoints = []
            liveStrokeOrigin = nil
            currentDrawingTarget = nil
            lastSavedPoint = nil
            return
        }

        if brushSettings.isStrokeEraser {
            eraseStrokeAtPoint(screenPoint: point, viewSize: view.bounds.size)
            currentTouchPoints = []
            predictedTouchPoints = []
            liveStrokeOrigin = nil
            currentDrawingTarget = nil
            lastSavedPoint = nil
            return
        }

        if brushSettings.isMaskEraser {
            let hitTestAllLayers = brushSettings.hitTestAllLayers
            let layerFilterID = hitTestAllLayers ? nil : (selectedLayerID ?? layers.first?.id)
            maskEraserLayerOverrideID = nil

            // Card-local strokes are not part of layers and should always be erasable inside the card.
            if let (card, frame, _, _) = hitTestHierarchy(screenPoint: point, viewSize: view.bounds.size, ignoringLocked: true) {
                // If we're over a card, always target that card's strokes.
                currentDrawingTarget = .card(card, frame)
                liveStrokeOrigin = screenToWorldPixels_PureDouble(
                    point,
                    viewSize: view.bounds.size,
                    panOffset: panOffset,
                    zoomScale: zoomScale,
                    rotationAngle: rotationAngle
                )
            } else if let strokeHit = hitTestStrokeHierarchy(screenPoint: point,
                                                             viewSize: view.bounds.size,
                                                             radiusPx: brushSettings.size * 0.5,
                                                             includeCardStrokes: false,
                                                             strokeLayerFilterID: layerFilterID) {
                switch strokeHit.target {
                case .canvas(let frame, let pointInFrame):
                    currentDrawingTarget = .canvas(frame)
                    liveStrokeOrigin = pointInFrame
                    if hitTestAllLayers {
                        maskEraserLayerOverrideID = strokeHit.stroke.layerID ?? layers.first?.id
                    }
                case .card:
                    break
                }
            } else {
                let pointActive = screenToWorldPixels_PureDouble(
                    point,
                    viewSize: view.bounds.size,
                    panOffset: panOffset,
                    zoomScale: zoomScale,
                    rotationAngle: rotationAngle
                )
                let resolved = resolveFrameForActivePoint(pointActive, viewSize: view.bounds.size)
                currentDrawingTarget = .canvas(resolved.frame)
                liveStrokeOrigin = resolved.pointInFrame
                maskEraserLayerOverrideID = hitTestAllLayers ? (selectedLayerID ?? layers.first?.id) : nil
            }
        } else {
            // USE HIERARCHICAL CARD HIT TEST
            if let (card, frame, _, _) = hitTestHierarchy(screenPoint: point, viewSize: view.bounds.size, ignoringLocked: true) {
                // Found a card (in active, parent, or child frame)
                // Store BOTH the card AND the frame it belongs to for correct coordinate transforms
                currentDrawingTarget = .card(card, frame)

                // For live rendering, we need the origin in ACTIVE World Space
                liveStrokeOrigin = screenToWorldPixels_PureDouble(
                    point,
                    viewSize: view.bounds.size,
                    panOffset: panOffset,
                    zoomScale: zoomScale,
                    rotationAngle: rotationAngle
                )

            } else {
                let pointActive = screenToWorldPixels_PureDouble(
                    point,
                    viewSize: view.bounds.size,
                    panOffset: panOffset,
                    zoomScale: zoomScale,
                    rotationAngle: rotationAngle
                )
                let resolved = resolveFrameForActivePoint(pointActive, viewSize: view.bounds.size)
                currentDrawingTarget = .canvas(resolved.frame)
                liveStrokeOrigin = resolved.pointInFrame
            }
        }

        // Keep points in SCREEN space during drawing
        currentTouchPoints = [point]
        // Cancel any pending refinement; this stroke continues the phrase.
        handwritingRefinementWorkItem?.cancel()
        handwritingRefinementWorkItem = nil
    }

    func handleTouchMoved(at point: CGPoint, predicted: [CGPoint], touchType: UITouch.TouchType) {
        // MODAL INPUT: Pencil on iPad; mouse/trackpad on Mac Catalyst.
        guard isDrawingTouchType(touchType) else { return }

        if brushSettings.isLasso {
            if brushSettings.isBoxLasso {
                guard let start = lassoDrawingPoints.first else { return }
                lassoDrawingPoints = [start, point]
                lassoPredictedPoints = []
                if let view = metalView {
                    let screenPoints = buildBoxLassoScreenPoints(start: start, end: point)
                    if !screenPoints.isEmpty {
                        updateLassoPreviewFromScreenPoints(screenPoints, close: true, viewSize: view.bounds.size)
                    } else {
                        lassoPreviewStroke = nil
                        lassoPreviewFrame = nil
                    }
                }
                return
            }

            let minimumDistance: CGFloat = 2.0
            var shouldAdd = false
            if let last = lassoDrawingPoints.last {
                let dist = hypot(point.x - last.x, point.y - last.y)
                if dist > minimumDistance {
                    shouldAdd = true
                }
            } else {
                shouldAdd = true
            }

            if shouldAdd {
                lassoDrawingPoints.append(point)
            }

            lassoPredictedPoints = predicted
            if let view = metalView, let screenPoints = buildLassoScreenPoints() {
                updateLassoPreviewFromScreenPoints(screenPoints, close: false, viewSize: view.bounds.size)
            }
            return
        }

        if brushSettings.isStrokeEraser {
            guard let view = metalView else { return }
            eraseStrokeAtPoint(screenPoint: point, viewSize: view.bounds.size)
            return
        }

        //  OPTIMIZATION: Distance Filter
        // Only add the point if it's far enough from the last one (e.g., 2.0 pixels)
        // This prevents "vertex explosion" when drawing slowly at 120Hz/240Hz.
        let minimumDistance: CGFloat = 2.0

        var shouldAdd = false
        if let last = currentTouchPoints.last {
            let dist = hypot(point.x - last.x, point.y - last.y)
            if dist > minimumDistance {
                shouldAdd = true
            }
        } else {
            shouldAdd = true // Always add the first point
        }

        if shouldAdd {
            currentTouchPoints.append(point)
            lastSavedPoint = point
        }

        // Update prediction (always do this for responsiveness, even if we filter the real point)
        predictedTouchPoints = predicted
    }

    func handleTouchEnded(at point: CGPoint, touchType: UITouch.TouchType) {
        // MODAL INPUT: Pencil on iPad; mouse/trackpad on Mac Catalyst.
        guard isDrawingTouchType(touchType) else { return }
        guard let view = metalView else { return }

        if brushSettings.isLasso {
            lassoPredictedPoints = []
            let closedPoints: [SIMD2<Double>]
            if brushSettings.isBoxLasso {
                guard let start = lassoDrawingPoints.first else {
                    clearLassoSelection()
                    lassoTarget = nil
                    return
                }
                lassoDrawingPoints = []

                let screenPoints = buildBoxLassoScreenPoints(start: start, end: point)
                guard screenPoints.count >= 4 else {
                    clearLassoSelection()
                    lassoTarget = nil
                    return
                }

                let worldPoints = screenPoints.map {
                    screenToWorldPixels_PureDouble(
                        $0,
                        viewSize: view.bounds.size,
                        panOffset: panOffset,
                        zoomScale: zoomScale,
                        rotationAngle: rotationAngle
                    )
                }

                var closed = worldPoints
                if let first = worldPoints.first, let last = worldPoints.last {
                    let dx = last.x - first.x
                    let dy = last.y - first.y
                    if (dx * dx + dy * dy) > 1e-12 {
                        closed.append(first)
                    }
                }
                closedPoints = closed
            } else {
                lassoDrawingPoints.append(point)
                let rawScreenPoints = lassoDrawingPoints
                lassoDrawingPoints = []

                let simplified = simplifyStroke(rawScreenPoints, minScreenDist: 2.0, minAngleDeg: 5.0)
                guard simplified.count >= 3 else {
                    clearLassoSelection()
                    lassoTarget = nil
                    return
                }

                let worldPoints = simplified.map {
                    screenToWorldPixels_PureDouble(
                        $0,
                        viewSize: view.bounds.size,
                        panOffset: panOffset,
                        zoomScale: zoomScale,
                        rotationAngle: rotationAngle
                    )
                }

                var closed = worldPoints
                if let first = worldPoints.first, let last = worldPoints.last {
                    let dx = last.x - first.x
                    let dy = last.y - first.y
                    if (dx * dx + dy * dy) > 1e-12 {
                        closed.append(first)
                    }
                }
                closedPoints = closed
            }

            let bounds = polygonBounds(closedPoints)
            let center = SIMD2<Double>(Double(bounds.midX), Double(bounds.midY))

            let hitTestAllLayers = brushSettings.hitTestAllLayers
            let layerFilterID = hitTestAllLayers ? nil : (selectedLayerID ?? layers.first?.id)

        switch lassoTarget {
        case .card(let card, let frame):
            guard !card.isHidden else {
                clearLassoSelection()
                lassoTarget = nil
                return
            }
            guard !card.isLocked else {
                clearLassoSelection()
                lassoTarget = nil
                return
            }
            guard let transform = transformFromActive(to: frame) else {
                clearLassoSelection()
                return
            }

                let polygonInCard = closedPoints.map { activePoint in
                    let framePoint = SIMD2<Double>(
                        activePoint.x * transform.scale + transform.translation.x,
                        activePoint.y * transform.scale + transform.translation.y
                    )
                    return framePointToCardLocal(framePoint, card: card)
                }

                let selectedIDs = selectStrokes(from: card.strokes, polygon: polygonInCard)

                lassoSelection = LassoSelection(
                    points: closedPoints,
                    bounds: bounds,
                    center: center,
                    frames: [],
                    cards: [],
                    cardStrokes: [LassoCardStrokeSelection(card: card, frame: frame, strokeIDs: selectedIDs)]
                )

            default:
                var selections: [LassoFrameSelection] = []
                var cardSelections: [LassoCardSelection] = []

                for frame in framesInActiveChain() {
                    guard let transform = transformFromActive(to: frame) else { continue }
                    let polygonInFrame = closedPoints.map {
                        SIMD2<Double>(
                            $0.x * transform.scale + transform.translation.x,
                            $0.y * transform.scale + transform.translation.y
                        )
                    }
                    let selectedIDs = selectStrokes(in: frame, polygon: polygonInFrame, strokeLayerFilterID: layerFilterID)
                    if !selectedIDs.isEmpty {
                        selections.append(LassoFrameSelection(frame: frame, strokeIDs: selectedIDs))
                    }

                    if hitTestAllLayers {
                        let cardsToTest = frame.cards
                        for card in cardsToTest where !card.isLocked && !card.isHidden {
                            if polygonIntersectsCard(closedPoints, card: card, transform: transform) {
                                cardSelections.append(LassoCardSelection(card: card, frame: frame))
                            }
                        }
                    }
                }

                lassoSelection = LassoSelection(
                    points: closedPoints,
                    bounds: bounds,
                    center: center,
                    frames: selections,
                    cards: cardSelections,
                    cardStrokes: []
                )
            }

            if let selection = lassoSelection {
                updateLassoPreview(for: selection)

                // Show "Create Section" menu on lasso completion (canvas lasso only).
                if selection.cardStrokes.isEmpty, let touchView = view as? TouchableMTKView {
                    let anchorWorld = SIMD2<Double>(Double(selection.bounds.maxX), Double(selection.bounds.maxY))
                    let anchorScreen = worldToScreenPixels_PureDouble(
                        anchorWorld,
                        viewSize: view.bounds.size,
                        panOffset: panOffset,
                        zoomScale: zoomScale,
                        rotationAngle: rotationAngle
                    )
                    let anchorRect = CGRect(x: anchorScreen.x - 2, y: anchorScreen.y - 2, width: 4, height: 4)
                    touchView.showLassoSectionMenuIfNeeded(anchorRect: anchorRect)
                }
            }
            lassoTarget = nil
            return
        }

        if brushSettings.isStrokeEraser {
            eraseStrokeAtPoint(screenPoint: point, viewSize: view.bounds.size)
            predictedTouchPoints = []
            currentTouchPoints = []
            liveStrokeOrigin = nil
            currentDrawingTarget = nil
            lastSavedPoint = nil
            return
        }

        guard let target = currentDrawingTarget else { return }

        // Clear predictions (no longer needed)
        predictedTouchPoints = []

        // Keep final point in SCREEN space
        currentTouchPoints.append(point)
        let rawStrokePoints = currentTouchPoints
        let sourceScreenPoints = rawStrokePoints

        //  FIX 1: Allow dots (Don't return if count < 4)
        guard !sourceScreenPoints.isEmpty else {
            currentTouchPoints = []
            liveStrokeOrigin = nil
            currentDrawingTarget = nil
            return
        }

        var smoothScreenPoints: [CGPoint]
        //  FIX 2: Phantom Points for Catmull-Rom
        // Extrapolate phantom points to ensure the spline reaches the start and end
        if sourceScreenPoints.count < 3 {
            // Too few points for a spline, just use lines/dots
            smoothScreenPoints = sourceScreenPoints
        } else {
            // Extrapolate phantom points instead of duplicating
            // First phantom: A - (B - A) = 2A - B (extends backward from A)
            // Last phantom: D + (D - C) = 2D - C (extends forward from D)
            var paddedPoints = sourceScreenPoints

            // Add phantom point at the start
            if paddedPoints.count >= 2 {
                let first = paddedPoints[0]
                let second = paddedPoints[1]
                let phantomStart = CGPoint(
                    x: 2 * first.x - second.x,
                    y: 2 * first.y - second.y
                )
                paddedPoints.insert(phantomStart, at: 0)
            }

            // Add phantom point at the end
            if paddedPoints.count >= 3 {  // Now at least 3 because we added one
                let last = paddedPoints[paddedPoints.count - 1]
                let secondLast = paddedPoints[paddedPoints.count - 2]
                let phantomEnd = CGPoint(
                    x: 2 * last.x - secondLast.x,
                    y: 2 * last.y - secondLast.y
                )
                paddedPoints.append(phantomEnd)
            }

            smoothScreenPoints = catmullRomPoints(points: paddedPoints,
                                                  closed: false,
                                                  alpha: 0.5,
                                                  segmentsPerCurve: 20)

            // Apply simplification to reduce vertex count
            smoothScreenPoints = simplifyStroke(
                smoothScreenPoints,
                minScreenDist: 1.5,
                minAngleDeg: 5.0
            )
        }

        //  MODAL INPUT: Route stroke to correct target
        let isMaskEraser = brushSettings.isMaskEraser
        let strokeColor = isMaskEraser ? SIMD4<Float>(0, 0, 0, 0) : brushSettings.color
        let strokeDepthWriteEnabled = isMaskEraser ? true : brushSettings.depthWriteEnabled
        switch target {
        case .canvas(let frame):
            if frame === activeFrame {
                // DRAW ON CANVAS (Active Frame)
		                let stroke = Stroke(screenPoints: smoothScreenPoints,
		                                    zoomAtCreation: zoomScale,
		                                    panAtCreation: panOffset,
		                                    viewSize: view.bounds.size,
		                                    rotationAngle: rotationAngle,
		                                    color: strokeColor,
		                                    baseWidth: brushSettings.size,
		                                    zoomEffectiveAtCreation: Float(max(zoomScale, 1e-6)),
		                                    device: device,
		                                    depthID: allocateStrokeDepthID(),
		                                    depthWriteEnabled: strokeDepthWriteEnabled,
		                                    constantScreenSize: brushSettings.constantScreenSize)
		                if isMaskEraser {
		                    stroke.maskAppliesToAllLayers = brushSettings.hitTestAllLayers
		                }
		                let routedTarget = appendCanvasStroke(stroke, to: frame)
		                pushUndo(.drawStroke(stroke: stroke, target: routedTarget))

                        if handwritingRefinementEnabled,
                           brushSettings.toolMode == .paint {
                            if let firstPending = pendingHandwritingStrokes.first,
                               !handwritingTargetsMatch(firstPending.target, routedTarget) {
                                flushPendingHandwritingRefinement()
                            }
                            pendingHandwritingStrokes.append(PendingHandwritingStroke(
                                stroke: stroke,
                                target: routedTarget,
                                rawScreenPoints: rawStrokePoints,
                                viewSize: view.bounds.size,
                                zoomAtCreation: zoomScale,
                                panAtCreation: panOffset,
                                rotationAngle: rotationAngle,
                                baseWidth: brushSettings.size,
                                constantScreenSize: brushSettings.constantScreenSize
                            ))
                            scheduleHandwritingRefinement()
                        }
            } else {
                // DRAW ON CANVAS (Other Frame in Telescope Chain)
                let stroke = createStrokeForFrame(
                    screenPoints: smoothScreenPoints,
                    frame: frame,
                    viewSize: view.bounds.size,
                    depthID: allocateStrokeDepthID(),
                    color: strokeColor,
                    depthWriteEnabled: strokeDepthWriteEnabled
                )
                if isMaskEraser {
                    stroke.maskAppliesToAllLayers = brushSettings.hitTestAllLayers
                }
                let routedTarget = appendCanvasStroke(stroke, to: frame)
                pushUndo(.drawStroke(stroke: stroke, target: routedTarget))
            }

        case .card(let card, let frame):
            // DRAW ON CARD (Cross-Depth Compatible)
            // Transform points into card-local space accounting for which frame the card is in
	            let cardStroke = createStrokeForCard(
	                screenPoints: smoothScreenPoints,
	                card: card,
	                frame: frame,
	                viewSize: view.bounds.size,
	                depthID: allocateStrokeDepthID(),
	                color: strokeColor,
	                depthWriteEnabled: strokeDepthWriteEnabled
	            )
	            card.strokes.append(cardStroke)
	            pushUndo(.drawStroke(stroke: cardStroke, target: target))
        }

        currentTouchPoints = []
        liveStrokeOrigin = nil
        currentDrawingTarget = nil
        maskEraserLayerOverrideID = nil
        lastSavedPoint = nil  // Clear for next stroke
    }

    func handleTouchCancelled(touchType: UITouch.TouchType) {
        // MODAL INPUT: Pencil on iPad; mouse/trackpad on Mac Catalyst.
        guard isDrawingTouchType(touchType) else { return }
        if brushSettings.isLasso {
            lassoDrawingPoints = []
            lassoPredictedPoints = []
            if let selection = lassoSelection {
                updateLassoPreview(for: selection)
            } else {
                lassoPreviewStroke = nil
                lassoPreviewFrame = nil
            }
            return
        }
        predictedTouchPoints = []  // Clear predictions
        currentTouchPoints = []
        liveStrokeOrigin = nil  // Clear temporary origin
        maskEraserLayerOverrideID = nil
        lastSavedPoint = nil  // Clear for next stroke
    }

    // MARK: - Hit Testing (Fractal Grid MVP)

    private struct StrokeHit {
        enum Target {
            case canvas(frame: Frame, pointInFrame: SIMD2<Double>)
            case card(card: Card, frame: Frame)
        }

        let target: Target
        let stroke: Stroke
        let depthID: UInt32
    }

    /*
    // MARK: - Legacy Telescoping Hit Testing (Reference Only)
    //
    // This section relied on linked-list frames (single child), plus:
    // - `originInParent`
    // - `scaleRelativeToParent`
    //
    // private struct FrameTransform { ... }
    // private func childFrame(of:) -> Frame?
    // private func collectFrameTransforms(pointActive:) -> (ancestors, descendants)
    // private func transformFromActive(to:) -> (scale, translation)?
    // private func pointInFrame(screenPoint:viewSize:frame:) -> SIMD2<Double>?
    */

	    /// Supports same-depth transforms within the visible 5x5 neighborhood around the active frame.
	    private func transformFromActive(to target: Frame) -> (scale: Double, translation: SIMD2<Double>)? {
	        if target === activeFrame {
	            return (scale: 1.0, translation: .zero)
	        }

	        let targetID = ObjectIdentifier(target)
	        if let cached = visibleFractalFrameTransforms[targetID] {
	            return cached
	        }

	        guard let view = metalView else { return nil }
	        ensureFractalExtent(viewSize: view.bounds.size)
	        let extent = fractalFrameExtent
	        guard extent.x > 0.0, extent.y > 0.0 else { return nil }

        let radius = 2
        for dy in -radius...radius {
            for dx in -radius...radius {
                guard let f = frameAtOffsetFromActiveIfExists(dx: dx, dy: dy) else { continue }
                if f === target {
                    return (scale: 1.0,
                            translation: SIMD2<Double>(-Double(dx) * extent.x, -Double(dy) * extent.y))
                }
            }
        }

        return nil
    }

    private func resolveFrameForActivePoint(_ pointActive: SIMD2<Double>,
                                            viewSize: CGSize) -> (frame: Frame, pointInFrame: SIMD2<Double>, conversionScale: Double) {
        ensureFractalExtent(viewSize: viewSize)
        let extent = fractalFrameExtent
        let half = extent * 0.5

        var frame = activeFrame
        var point = pointActive

        while point.x > half.x {
            frame = neighborFrame(from: frame, direction: .right)
            point.x -= extent.x
        }
        while point.x < -half.x {
            frame = neighborFrame(from: frame, direction: .left)
            point.x += extent.x
        }
        while point.y > half.y {
            frame = neighborFrame(from: frame, direction: .down)
            point.y -= extent.y
        }
        while point.y < -half.y {
            frame = neighborFrame(from: frame, direction: .up)
            point.y += extent.y
        }

        return (frame: frame, pointInFrame: point, conversionScale: 1.0)
    }

    private func eraserRadiusWorld(forScale scale: Double) -> Double {
        let safeZoom = max(zoomScale, 1e-6)
        return (brushSettings.size * 0.5) * scale / safeZoom
    }

    private func hitTestStroke(_ stroke: Stroke,
                               pointInFrame: SIMD2<Double>,
                               eraserRadius: Double) -> Bool {
        let localX = pointInFrame.x - stroke.origin.x
        let localY = pointInFrame.y - stroke.origin.y

        if stroke.localBounds != .null {
            // Broad-phase: skip per-segment math if eraser bounds don't overlap stroke bounds.
            let sBounds = stroke.localBounds
            let eMinX = localX - eraserRadius
            let eMaxX = localX + eraserRadius
            let eMinY = localY - eraserRadius
            let eMaxY = localY + eraserRadius

            if eMaxX < Double(sBounds.minX) ||
                eMinX > Double(sBounds.maxX) ||
                eMaxY < Double(sBounds.minY) ||
                eMinY > Double(sBounds.maxY) {
                return false
            }
        }

        let radius = Float(stroke.worldWidth * 0.5 + eraserRadius)
        let radiusSq = radius * radius
        let p = SIMD2<Float>(Float(localX), Float(localY))

        for seg in stroke.segments {
            let a = seg.p0
            let b = seg.p1
            let ab = b - a
            let ap = p - a
            let denom = simd_dot(ab, ab)
            let t = denom > 0 ? max(0.0, min(1.0, simd_dot(ap, ab) / denom)) : 0.0
            let closest = a + ab * t
            let d = p - closest
            let distSq = simd_dot(d, d)
            if distSq <= radiusSq {
                return true
            }
        }

        return false
    }

    private func hitTestCardStroke(card: Card,
                                   pointInFrame: SIMD2<Double>,
                                   eraserRadius: Double,
                                   minimumDepthID: UInt32? = nil) -> Stroke? {
        guard !card.isHidden else { return nil }
        guard !card.isLocked else { return nil }
        guard !card.strokes.isEmpty else { return nil }
        guard card.hitTest(pointInFrame: pointInFrame) else { return nil }

        let dx = pointInFrame.x - card.origin.x
        let dy = pointInFrame.y - card.origin.y
        let c = cos(-card.rotation)
        let s = sin(-card.rotation)
        let localX = dx * Double(c) - dy * Double(s)
        let localY = dx * Double(s) + dy * Double(c)
        let pointInCard = SIMD2<Double>(localX, localY)

        for stroke in card.strokes.reversed() {
            if let minimumDepthID, stroke.depthID <= minimumDepthID {
                break
            }
            if hitTestStroke(stroke,
                             pointInFrame: pointInCard,
                             eraserRadius: eraserRadius) {
                return stroke
            }
        }

        return nil
    }

		    private func hitTestStrokeHierarchy(screenPoint: CGPoint, viewSize: CGSize) -> StrokeHit? {
		        hitTestStrokeHierarchy(screenPoint: screenPoint,
		                               viewSize: viewSize,
		                               radiusPx: brushSettings.size * 0.5)
		    }

		    private func hitTestStrokeHierarchy(screenPoint: CGPoint,
		                                        viewSize: CGSize,
		                                        radiusPx: Double,
		                                        includeCardStrokes: Bool = true,
		                                        strokeLayerFilterID: UUID? = nil) -> StrokeHit? {
		        let pointActive = screenToWorldPixels_PureDouble(
		            screenPoint,
		            viewSize: viewSize,
		            panOffset: panOffset,
		            zoomScale: zoomScale,
		            rotationAngle: rotationAngle
		        )

		        let hiddenLayerIDs: Set<UUID> = {
		            guard strokeLayerFilterID == nil else { return [] }
		            return Set(layers.filter { $0.isHidden }.map(\.id))
		        }()

		        var bestDepthID: UInt32?
		        var bestTarget: StrokeHit.Target?
		        var bestStroke: Stroke?

		        func considerCanvasStrokes(in frame: Frame,
		                                   pointInFrame: SIMD2<Double>,
		                                   eraserRadius: Double) {
		            func consider(_ strokes: [Stroke]) {
		                guard !strokes.isEmpty else { return }
		                for stroke in strokes.reversed() {
                            if strokeLayerFilterID == nil, let effective = stroke.layerID ?? layers.first?.id {
                                if hiddenLayerIDs.contains(effective) {
                                    continue
                                }
                            }
                            if let strokeLayerFilterID {
                                let effective = stroke.layerID ?? layers.first?.id
                                if effective != strokeLayerFilterID {
                                    continue
                                }
                            }
		                    if let best = bestDepthID, stroke.depthID <= best {
		                        break
		                    }
		                    if hitTestStroke(stroke,
		                                     pointInFrame: pointInFrame,
		                                     eraserRadius: eraserRadius) {
		                        bestDepthID = stroke.depthID
		                        bestTarget = .canvas(frame: frame, pointInFrame: pointInFrame)
		                        bestStroke = stroke
		                        break
		                    }
		                }
		            }

		            consider(frame.strokes)
		        }

		        func considerCardStrokes(in frame: Frame,
		                                 pointInFrame: SIMD2<Double>,
		                                 eraserRadius: Double) {
                    guard includeCardStrokes else { return }
		            func consider(_ cards: [Card]) {
		                guard !cards.isEmpty else { return }
		                for card in cards.reversed() {
		                    if card.isHidden { continue }
		                    if card.isLocked { continue }
		                    guard let newest = card.strokes.last?.depthID else { continue }
		                    if let best = bestDepthID, newest <= best {
		                        continue
		                    }
		                    if let stroke = hitTestCardStroke(card: card,
		                                                      pointInFrame: pointInFrame,
		                                                      eraserRadius: eraserRadius,
		                                                      minimumDepthID: bestDepthID) {
		                        bestDepthID = stroke.depthID
		                        bestTarget = .card(card: card, frame: frame)
		                        bestStroke = stroke
		                        break
		                    }
		                }
		            }

		            consider(frame.cards)
		        }

		        let safeZoom = max(zoomScale, 1e-6)
		        let safeRadiusPx = max(radiusPx, 1.0)

		        if !visibleFractalFramesDrawOrder.isEmpty {
		            for frame in visibleFractalFramesDrawOrder {
		                guard let transform = transformFromActive(to: frame) else { continue }
		                let pointInFrame = pointActive * transform.scale + transform.translation
		                let eraserRadius = safeRadiusPx * transform.scale / safeZoom
		                considerCanvasStrokes(in: frame,
		                                      pointInFrame: pointInFrame,
		                                      eraserRadius: eraserRadius)
		                considerCardStrokes(in: frame,
		                                    pointInFrame: pointInFrame,
		                                    eraserRadius: eraserRadius)
		            }
		        } else {
		            let resolved = resolveFrameForActivePoint(pointActive, viewSize: viewSize)
		            let eraserRadius = safeRadiusPx * resolved.conversionScale / safeZoom
		            considerCanvasStrokes(in: resolved.frame,
		                                  pointInFrame: resolved.pointInFrame,
		                                  eraserRadius: eraserRadius)
		            considerCardStrokes(in: resolved.frame,
		                                pointInFrame: resolved.pointInFrame,
		                                eraserRadius: eraserRadius)
		        }

		        guard let depthID = bestDepthID, let target = bestTarget, let stroke = bestStroke else { return nil }
		        return StrokeHit(target: target, stroke: stroke, depthID: depthID)
		    }

    private func eraseStrokeAtPoint(screenPoint: CGPoint, viewSize: CGSize) {
        // Card-local strokes are not part of layers and should always be erasable inside the card.
        // Cards sit on top of the canvas; when covered, only card strokes are eligible.
        if let (card, frame, conversionScale, pointInFrame) = hitTestHierarchy(screenPoint: screenPoint,
                                                                              viewSize: viewSize,
                                                                              ignoringLocked: true) {
            let eraserRadius = eraserRadiusWorld(forScale: conversionScale)
            if let stroke = hitTestCardStroke(card: card,
                                              pointInFrame: pointInFrame,
                                              eraserRadius: eraserRadius),
               let index = card.strokes.firstIndex(where: { $0 === stroke }) {
                let strokeCopy = stroke // Keep reference before removing
                card.strokes.remove(at: index)
                pushUndo(.eraseStroke(stroke: strokeCopy, strokeIndex: index, target: .card(card, frame)))
            }
            return
        }

        if brushSettings.hitTestAllLayers {
            guard let hit = hitTestStrokeHierarchy(screenPoint: screenPoint,
                                                   viewSize: viewSize,
                                                   radiusPx: brushSettings.size * 0.5,
                                                   includeCardStrokes: false,
                                                   strokeLayerFilterID: nil) else { return }
            switch hit.target {
            case .canvas(let frame, _):
                if let index = frame.strokes.firstIndex(where: { $0 === hit.stroke }) {
                    let strokeCopy = hit.stroke // Keep reference before removing
                    frame.strokes.remove(at: index)
                    pushUndo(.eraseStroke(stroke: strokeCopy, strokeIndex: index, target: .canvas(frame)))
                }
            case .card:
                break
            }
            return
        }

        let layerID = selectedLayerID ?? layers.first?.id
        guard let layerID else { return }

        guard let hit = hitTestStrokeHierarchy(screenPoint: screenPoint,
                                               viewSize: viewSize,
                                               radiusPx: brushSettings.size * 0.5,
                                               includeCardStrokes: false,
                                               strokeLayerFilterID: layerID) else { return }

        switch hit.target {
        case .canvas(let frame, _):
            if let index = frame.strokes.firstIndex(where: { $0 === hit.stroke }) {
                let strokeCopy = hit.stroke // Keep reference before removing
                frame.strokes.remove(at: index)
                pushUndo(.eraseStroke(stroke: strokeCopy, strokeIndex: index, target: .canvas(frame)))
            }
        case .card:
            break
        }
    }

    // MARK: - Card Management

		    /// Hit test cards in the visible 5x5 neighborhood (same-depth).
	    /// Returns: The Card, The Frame it belongs to, and the Coordinate Conversion Scale
	    /// The conversion scale is used to translate movement deltas between coordinate systems:
	    ///   - Parent cards: scale < 1.0 (move slower - parent coords are smaller)
	    ///   - Active cards: scale = 1.0 (normal movement)
	    ///   - Child cards: scale > 1.0 (move faster - child coords are larger)
		    func hitTestHierarchy(screenPoint: CGPoint,
		                          viewSize: CGSize,
		                          ignoringLocked: Bool = false) -> (card: Card, frame: Frame, conversionScale: Double, pointInFrame: SIMD2<Double>)? {

	        // 1. Calculate Point in Active Frame (World Space)
	        let pointActive = screenToWorldPixels_PureDouble(
	            screenPoint,
	            viewSize: viewSize,
	            panOffset: panOffset,
	            zoomScale: zoomScale,
	            rotationAngle: rotationAngle
	        )

	        // Prefer the render-derived cache so cards can be interacted with across depths.
	        if !visibleFractalFramesDrawOrder.isEmpty {
	            for frame in visibleFractalFramesDrawOrder.reversed() {
	                let cardsToHitTest = frame.cards
	                guard !cardsToHitTest.isEmpty else { continue }
	                guard let transform = transformFromActive(to: frame) else { continue }

	                let pointInFrame = pointActive * transform.scale + transform.translation
	                for card in cardsToHitTest.reversed() {
	                    if card.isHidden { continue }
	                    if ignoringLocked, card.isLocked { continue }
	                    if card.hitTest(pointInFrame: pointInFrame) {
	                        return (card, frame, transform.scale, pointInFrame)
	                    }
	                }
	            }
	            return nil
	        }

	        // Fallback: same-depth resolution only.
	        let resolved = resolveFrameForActivePoint(pointActive, viewSize: viewSize)
	        let frame = resolved.frame
	        let pointInFrame = resolved.pointInFrame

	        let cardsToHitTest = frame.cards
	        for card in cardsToHitTest.reversed() {
	            if card.isHidden { continue }
	            if ignoringLocked, card.isLocked { continue }
	            if card.hitTest(pointInFrame: pointInFrame) {
	                return (card, frame, resolved.conversionScale, pointInFrame)
	            }
	        }

	        return nil
		    }

	    /// Hit test sections using the same approach as hitTestHierarchy for cards.
	    func hitTestSectionHierarchy(screenPoint: CGPoint, viewSize: CGSize) -> Section? {
	        let pointActive = screenToWorldPixels_PureDouble(
	            screenPoint,
	            viewSize: viewSize,
	            panOffset: panOffset,
	            zoomScale: zoomScale,
	            rotationAngle: rotationAngle
	        )

	        // Use the render-derived cache (same as card hit testing)
	        for frame in visibleFractalFramesDrawOrder.reversed() {
	            guard !frame.sections.isEmpty else { continue }
	            guard let transform = transformFromActive(to: frame) else { continue }

	            let pointInFrame = pointActive * transform.scale + transform.translation
	            if let section = frame.sectionContaining(pointInFrame: pointInFrame) {
	                return section
	            }
	        }

	        // Always check activeFrame directly as fallback
	        if let section = activeFrame.sectionContaining(pointInFrame: pointActive) {
	            return section
	        }

	        return nil
	    }

	    /// Compute the on-screen rect for a section's name label (if visible).
	    ///
	    /// Matches the Metal render placement:
	    /// - Fixed on-screen label size (independent of zoom).
	    /// - Positioned outside the section bounds (top-left).
	    /// - Hidden when the label would exceed 25% of section width.
	    func sectionLabelScreenRect(section: Section,
	                                frame: Frame,
	                                viewSize: CGSize,
	                                ignoreHideRule: Bool = false) -> CGRect? {
	        let bounds = section.bounds
	        guard bounds != .null else { return nil }
	        guard section.labelWorldSize.x > 0, section.labelWorldSize.y > 0 else { return nil }
	        guard let transform = transformFromActive(to: frame) else { return nil }

	        let safeScaleFromActive = max(transform.scale, 1e-12)
	        let zoomInFrame = max(zoomScale / safeScaleFromActive, 1e-12)

	        let labelSizeWorld = SIMD2<Double>(section.labelWorldSize.x / zoomInFrame,
	                                          section.labelWorldSize.y / zoomInFrame)
	        let maxLabelWidthWorld = Double(bounds.width) * 0.5
	        if !ignoreHideRule,
	           maxLabelWidthWorld.isFinite,
	           maxLabelWidthWorld > 0.0,
	           labelSizeWorld.x > maxLabelWidthWorld {
	            return nil
	        }

	        let labelMarginWorld = sectionLabelMarginPx / zoomInFrame
	        let labelCenterInFrame = SIMD2<Double>(
	            Double(bounds.minX) + labelMarginWorld + labelSizeWorld.x * 0.5,
	            Double(bounds.minY) - labelMarginWorld - labelSizeWorld.y * 0.5
	        )

	        let labelCenterInActive = (labelCenterInFrame - transform.translation) / safeScaleFromActive
	        let labelCenterScreen = worldToScreenPixels_PureDouble(
	            labelCenterInActive,
	            viewSize: viewSize,
	            panOffset: panOffset,
	            zoomScale: zoomScale,
	            rotationAngle: rotationAngle
	        )

	        let labelW = CGFloat(section.labelWorldSize.x)
	        let labelH = CGFloat(section.labelWorldSize.y)
	        return CGRect(x: labelCenterScreen.x - labelW * 0.5,
	                      y: labelCenterScreen.y - labelH * 0.5,
	                      width: labelW,
	                      height: labelH)
	    }

	    /// Compute the on-screen rect for a card's name label (if visible).
	    ///
	    /// Matches the Metal render placement:
	    /// - Fixed on-screen label size (independent of zoom).
	    /// - Positioned outside the card bounds (top-left).
	    /// - Hidden when the label would exceed 25% of card width.
	    func cardLabelScreenRect(card: Card,
	                             frame: Frame,
	                             viewSize: CGSize,
	                             ignoreHideRule: Bool = false) -> CGRect? {
	        guard !card.isHidden else { return nil }
	        guard cardNamesVisible || ignoreHideRule else { return nil }
	        guard card.labelWorldSize.x > 0, card.labelWorldSize.y > 0 else { return nil }
	        guard let transform = transformFromActive(to: frame) else { return nil }

	        let safeScaleFromActive = max(transform.scale, 1e-12)
	        let zoomInFrame = max(zoomScale / safeScaleFromActive, 1e-12)

	        let labelSizeWorld = SIMD2<Double>(card.labelWorldSize.x / zoomInFrame,
	                                          card.labelWorldSize.y / zoomInFrame)
	        let maxLabelWidthWorld = card.size.x * 0.5
	        if !ignoreHideRule,
	           maxLabelWidthWorld.isFinite,
	           maxLabelWidthWorld > 0.0,
	           labelSizeWorld.x > maxLabelWidthWorld {
	            return nil
	        }

	        let cardRectLocal = CGRect(x: -card.size.x * 0.5,
	                                   y: -card.size.y * 0.5,
	                                   width: card.size.x,
	                                   height: card.size.y)
	        let aabbInFrame = cardLocalRectToFrameAABB(cardRectLocal, card: card)

	        let labelMarginWorld = sectionLabelMarginPx / zoomInFrame
	        let labelCenterInFrame = SIMD2<Double>(
	            Double(aabbInFrame.minX) + labelMarginWorld + labelSizeWorld.x * 0.5,
	            Double(aabbInFrame.minY) - labelMarginWorld - labelSizeWorld.y * 0.5
	        )

	        let labelCenterInActive = (labelCenterInFrame - transform.translation) / safeScaleFromActive
	        let labelCenterScreen = worldToScreenPixels_PureDouble(
	            labelCenterInActive,
	            viewSize: viewSize,
	            panOffset: panOffset,
	            zoomScale: zoomScale,
	            rotationAngle: rotationAngle
	        )

	        let labelW = CGFloat(card.labelWorldSize.x)
	        let labelH = CGFloat(card.labelWorldSize.y)
	        return CGRect(x: labelCenterScreen.x - labelW * 0.5,
	                      y: labelCenterScreen.y - labelH * 0.5,
	                      width: labelW,
	                      height: labelH)
	    }

	    /// Compute screen-space placement for an overlay view that should match the card's rendered rect.
	    /// - Returns: center (screen px), size (screen px), rotation (radians, screen-space).
	    func cardScreenTransform(card: Card,
	                             frame: Frame,
	                             viewSize: CGSize) -> (center: CGPoint, size: CGSize, rotation: CGFloat)? {
	        guard !card.isHidden else { return nil }
	        guard let transform = transformFromActive(to: frame) else { return nil }
	        let safeScaleFromActive = max(transform.scale, 1e-12)
	        let zoomInFrame = max(zoomScale / safeScaleFromActive, 1e-12)

	        let cardCenterInActive = (card.origin - transform.translation) / safeScaleFromActive
	        let centerScreen = worldToScreenPixels_PureDouble(
	            cardCenterInActive,
	            viewSize: viewSize,
	            panOffset: panOffset,
	            zoomScale: zoomScale,
	            rotationAngle: rotationAngle
	        )

	        let w = Double(card.size.x) * zoomInFrame
	        let h = Double(card.size.y) * zoomInFrame
	        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }

	        let rotation = CGFloat(Double(rotationAngle) + Double(card.rotation))
	        return (center: centerScreen, size: CGSize(width: CGFloat(w), height: CGFloat(h)), rotation: rotation)
	    }

	    /// Hit test section name labels across all visible frames (depth neighborhood + 5x5).
	    func hitTestSectionLabelHierarchy(screenPoint: CGPoint, viewSize: CGSize) -> (section: Section, frame: Frame)? {
	        // Prefer the render-derived cache so we can hit-test across depths.
	        if !visibleFractalFramesDrawOrder.isEmpty {
	            for frame in visibleFractalFramesDrawOrder.reversed() {
	                guard !frame.sections.isEmpty else { continue }
	                for section in frame.sections.reversed() {
	                    if section.labelWorldSize.x <= 0.0 || section.labelWorldSize.y <= 0.0 {
	                        section.ensureLabelTexture(device: device)
	                    }
	                    guard let rect = sectionLabelScreenRect(section: section, frame: frame, viewSize: viewSize) else { continue }
	                    if rect.contains(screenPoint) {
	                        return (section: section, frame: frame)
	                    }
	                }
	            }
	        }

	        // Fallback: active frame only.
	        for section in activeFrame.sections.reversed() {
	            if section.labelWorldSize.x <= 0.0 || section.labelWorldSize.y <= 0.0 {
	                section.ensureLabelTexture(device: device)
	            }
	            guard let rect = sectionLabelScreenRect(section: section, frame: activeFrame, viewSize: viewSize) else { continue }
	            if rect.contains(screenPoint) {
	                return (section: section, frame: activeFrame)
	            }
	        }

	        return nil
	    }

	    /// Hit test card name labels across all visible frames (depth neighborhood + 5x5).
	    func hitTestCardLabelHierarchy(screenPoint: CGPoint, viewSize: CGSize) -> (card: Card, frame: Frame)? {
	        guard cardNamesVisible else { return nil }
	        if !visibleFractalFramesDrawOrder.isEmpty {
	            for frame in visibleFractalFramesDrawOrder.reversed() {
	                guard !frame.cards.isEmpty else { continue }
	                for card in frame.cards.reversed() {
	                    if card.isHidden { continue }
	                    if card.labelWorldSize.x <= 0.0 || card.labelWorldSize.y <= 0.0 {
	                        card.ensureLabelTexture(device: device)
	                    }
	                    guard let rect = cardLabelScreenRect(card: card, frame: frame, viewSize: viewSize) else { continue }
	                    if rect.contains(screenPoint) {
	                        return (card: card, frame: frame)
	                    }
	                }
	            }
	        }

	        for card in activeFrame.cards.reversed() {
	            if card.isHidden { continue }
	            if card.labelWorldSize.x <= 0.0 || card.labelWorldSize.y <= 0.0 {
	                card.ensureLabelTexture(device: device)
	            }
	            guard let rect = cardLabelScreenRect(card: card, frame: activeFrame, viewSize: viewSize) else { continue }
	            if rect.contains(screenPoint) {
	                return (card: card, frame: activeFrame)
	            }
	        }

	        return nil
	    }

	    /// Handle long press gesture to open card settings
	    /// Uses hierarchical hit testing to find cards at any depth level
	    func handleLongPress(at point: CGPoint) {
	        guard let view = metalView else { return }

	        // Prefer stroke linking selection when the user long-presses a stroke.
	        if beginLinkSelection(at: point, viewSize: view.bounds.size) {
	            return
	        }

	        // Use hierarchical hit test to find card at any depth
	        if let (card, _, _, _) = hitTestHierarchy(screenPoint: point, viewSize: view.bounds.size) {
	            // Found a card! Notify SwiftUI
	            onEditCard?(card)
	        }
	    }

	    // MARK: - Stroke Linking

	    private func linkedStrokeRef(from hit: StrokeHit) -> LinkedStrokeRef {
	        switch hit.target {
	        case .canvas(let frame, _):
	            let key = LinkedStrokeKey(strokeID: hit.stroke.id,
	                                      frameID: ObjectIdentifier(frame),
	                                      cardID: nil)
	            return LinkedStrokeRef(key: key,
	                                   container: .canvas(frame: frame),
	                                   stroke: hit.stroke,
	                                   depthID: hit.depthID)

	        case .card(let card, let frame):
	            let key = LinkedStrokeKey(strokeID: hit.stroke.id,
	                                      frameID: ObjectIdentifier(frame),
	                                      cardID: ObjectIdentifier(card))
	            return LinkedStrokeRef(key: key,
	                                   container: .card(card: card, frame: frame),
	                                   stroke: hit.stroke,
	                                   depthID: hit.depthID)
	        }
	    }

	    private func resolveCurrentStroke(for ref: LinkedStrokeRef) -> Stroke? {
	        switch ref.container {
	        case .canvas(let frame):
	            return frame.strokes.first(where: { $0.id == ref.stroke.id }) ?? ref.stroke
	        case .card(let card, _):
	            return card.strokes.first(where: { $0.id == ref.stroke.id }) ?? ref.stroke
	        }
	    }

	    private func linkHandleEndpointsInActiveWorld(for hit: StrokeHit) -> (SIMD2<Double>, SIMD2<Double>)? {
	        guard !hit.stroke.segments.isEmpty else { return nil }
	        guard metalView != nil else { return nil }

	        let firstLocal = hit.stroke.segments.first?.p0 ?? .zero
	        let lastLocal = hit.stroke.segments.last?.p1 ?? .zero

	        func inverseTransformToActive(frame: Frame, pointInFrame: SIMD2<Double>) -> SIMD2<Double>? {
	            guard let transform = transformFromActive(to: frame) else {
	                return (frame === activeFrame) ? pointInFrame : nil
	            }
	            let inv = transform.scale != 0 ? (1.0 / transform.scale) : 1.0
	            return SIMD2<Double>(
	                (pointInFrame.x - transform.translation.x) * inv,
	                (pointInFrame.y - transform.translation.y) * inv
	            )
	        }

	        switch hit.target {
	        case .canvas(let frame, _):
	            let p0Frame = hit.stroke.origin + SIMD2<Double>(Double(firstLocal.x), Double(firstLocal.y))
	            let p1Frame = hit.stroke.origin + SIMD2<Double>(Double(lastLocal.x), Double(lastLocal.y))
	            guard let a = inverseTransformToActive(frame: frame, pointInFrame: p0Frame),
	                  let b = inverseTransformToActive(frame: frame, pointInFrame: p1Frame) else { return nil }
	            return (a, b)

	        case .card(let card, let frame):
	            let p0Card = hit.stroke.origin + SIMD2<Double>(Double(firstLocal.x), Double(firstLocal.y))
	            let p1Card = hit.stroke.origin + SIMD2<Double>(Double(lastLocal.x), Double(lastLocal.y))

	            let rot = Double(card.rotation)
	            let c = cos(rot)
	            let s = sin(rot)

	            func cardLocalToFrame(_ p: SIMD2<Double>) -> SIMD2<Double> {
	                let x = p.x * c - p.y * s
	                let y = p.x * s + p.y * c
	                return SIMD2<Double>(card.origin.x + x, card.origin.y + y)
	            }

	            let p0Frame = cardLocalToFrame(p0Card)
	            let p1Frame = cardLocalToFrame(p1Card)
	            guard let a = inverseTransformToActive(frame: frame, pointInFrame: p0Frame),
	                  let b = inverseTransformToActive(frame: frame, pointInFrame: p1Frame) else { return nil }
	            return (a, b)
	        }
	    }

		    /// Start a link selection by long-pressing a stroke. Returns `true` when a stroke was selected.
		    func beginLinkSelection(at screenPoint: CGPoint, viewSize: CGSize) -> Bool {
		        guard let hit = hitTestStrokeHierarchy(screenPoint: screenPoint, viewSize: viewSize, radiusPx: linkHitTestRadiusPx) else { return false }
		        let ref = linkedStrokeRef(from: hit)
		        linkSelectionHoverKey = nil

		        let pointActive = screenToWorldPixels_PureDouble(
		            screenPoint,
		            viewSize: viewSize,
		            panOffset: panOffset,
		            zoomScale: zoomScale,
		            rotationAngle: rotationAngle
		        )

		        let endpoints = linkHandleEndpointsInActiveWorld(for: hit)
		        var selection = StrokeLinkSelection(
		            handleActiveWorld: endpoints?.1 ?? pointActive
		        )
		        selection.insert(ref)
		        if let bounds = linkSelectionBoundsActiveWorld(selection: selection) {
		            selection.handleActiveWorld = SIMD2<Double>(bounds.maxX, bounds.maxY)
		        }
		        linkSelection = selection
		        return true
		    }

		    func clearLinkSelection() {
		        linkSelection = nil
		        isDraggingLinkHandle = false
		        linkSelectionHoverKey = nil
		    }

		    func beginLinkSelectionDrag(at screenPoint: CGPoint, viewSize: CGSize) {
		        guard linkSelection != nil else {
		            linkSelectionHoverKey = nil
		            return
		        }
		        guard let hit = hitTestStrokeHierarchy(screenPoint: screenPoint, viewSize: viewSize, radiusPx: linkHitTestRadiusPx) else {
		            linkSelectionHoverKey = nil
		            return
		        }
		        linkSelectionHoverKey = linkedStrokeRef(from: hit).key
		    }

		    func extendLinkSelection(to screenPoint: CGPoint, viewSize: CGSize) {
		        guard var selection = linkSelection else { return }

		        let pointActive = screenToWorldPixels_PureDouble(
		            screenPoint,
		            viewSize: viewSize,
		            panOffset: panOffset,
		            zoomScale: zoomScale,
		            rotationAngle: rotationAngle
		        )

		        selection.handleActiveWorld = pointActive

		        if let hit = hitTestStrokeHierarchy(screenPoint: screenPoint, viewSize: viewSize, radiusPx: linkHitTestRadiusPx) {
		            let ref = linkedStrokeRef(from: hit)
		            if ref.key != linkSelectionHoverKey {
		                if selection.keys.contains(ref.key) {
		                    selection.remove(ref.key)
		                } else {
		                    selection.insert(ref)
		                }
		                linkSelectionHoverKey = ref.key
		            }
		        } else {
		            linkSelectionHoverKey = nil
		        }

		        if selection.strokes.isEmpty {
		            clearLinkSelection()
		            return
		        }

		        linkSelection = selection
		    }

			    private func linkSelectionBoundsActiveWorld(selection: StrokeLinkSelection) -> CGRect? {
			        var bounds: CGRect?
			        for ref in selection.strokes {
			            guard let rect = linkedStrokeBoundsActiveWorld(ref) else { continue }
			            let frame: Frame = {
			                switch ref.container {
			                case .canvas(let f): return f
			                case .card(_, let f): return f
			                }
			            }()
			            let padded = paddedActiveRect(rect, frame: frame, paddingInFrameWorld: linkHighlightPaddingPx)
			            bounds = bounds.map { $0.union(padded) } ?? padded
			        }
			        return bounds
			    }

		    func linkSelectionBoundsActiveWorld() -> CGRect? {
		        guard let selection = linkSelection else { return nil }
		        return linkSelectionBoundsActiveWorld(selection: selection)
		    }

		    func snapLinkSelectionHandleToBounds() {
		        guard var selection = linkSelection else { return }
		        guard let bounds = linkSelectionBoundsActiveWorld(selection: selection) else { return }
		        selection.handleActiveWorld = SIMD2<Double>(bounds.maxX, bounds.maxY)
		        linkSelection = selection
		    }

		    func linkSelectionContains(screenPoint: CGPoint, viewSize: CGSize) -> Bool {
		        guard let bounds = linkSelectionBoundsActiveWorld() else { return false }
		        let pointActive = screenToWorldPixels_PureDouble(
		            screenPoint,
		            viewSize: viewSize,
		            panOffset: panOffset,
		            zoomScale: zoomScale,
		            rotationAngle: rotationAngle
		        )
		        return bounds.contains(CGPoint(x: pointActive.x, y: pointActive.y))
		    }

		    func addLinkToSelection(_ urlString: String) {
		        guard var selection = linkSelection else { return }
		        let sectionID = UUID()
		        for ref in selection.strokes {
		            guard let stroke = resolveCurrentStroke(for: ref) else { continue }
		            stroke.link = urlString
		            stroke.linkTargetSectionID = nil
		            stroke.linkTargetCardID = nil
		            stroke.linkSectionID = sectionID
		        }
		        linkSelection = selection
		        rebuildInternalLinkReferenceCache()
		    }

		    func linkDestinationsInCanvas() -> [CanvasLinkDestination] {
		        var destinations: [CanvasLinkDestination] = []
		        destinations.reserveCapacity(64)

		        var seenSections = Set<UUID>()
		        var seenCards = Set<UUID>()

		        func walk(frame: Frame) {
		            for section in frame.sections {
		                if seenSections.insert(section.id).inserted {
		                    destinations.append(CanvasLinkDestination(kind: .section,
		                                                             id: section.id,
		                                                             name: section.name))
		                }
		            }
		            for card in frame.cards {
		                if seenCards.insert(card.id).inserted {
		                    destinations.append(CanvasLinkDestination(kind: .card,
		                                                             id: card.id,
		                                                             name: card.name))
		                }
		            }
		            for child in frame.children.values {
		                walk(frame: child)
		            }
		        }

		        walk(frame: rootFrame)
		        return destinations
		    }

		    func addInternalLinkToSelection(_ destination: CanvasLinkDestination) {
		        guard var selection = linkSelection else { return }
		        let sectionID = UUID()
		        for ref in selection.strokes {
		            guard let stroke = resolveCurrentStroke(for: ref) else { continue }
		            stroke.link = nil
		            stroke.linkTargetSectionID = (destination.kind == .section) ? destination.id : nil
		            stroke.linkTargetCardID = (destination.kind == .card) ? destination.id : nil
		            stroke.linkSectionID = sectionID
		        }
		        linkSelection = selection
		        rebuildInternalLinkReferenceCache()
		    }

		    /// Refresh cached reference edges + name lookup used by the debug UI (and future graph views).
		    /// Call this after renaming cards/sections or after section membership changes.
		    func refreshInternalLinkReferenceCache() {
		        rebuildInternalLinkReferenceCache()
		    }

		    private func rebuildInternalLinkReferenceCache() {
		        var names: [UUID: String] = [:]
		        names.reserveCapacity(128)

		        var edges = Set<InternalLinkReferenceEdge>()
		        var foundInternalTargets = false

		        func linkTargetID(for stroke: Stroke) -> UUID? {
		            stroke.linkTargetSectionID ?? stroke.linkTargetCardID
		        }

		        func walk(frame: Frame) {
		            for section in frame.sections {
		                names[section.id] = section.name
		            }
		            for card in frame.cards {
		                names[card.id] = card.name
		            }

		            for stroke in frame.strokes {
		                guard let targetID = linkTargetID(for: stroke) else { continue }
		                foundInternalTargets = true
		                guard let sourceID = stroke.sectionID else { continue }
		                edges.insert(InternalLinkReferenceEdge(sourceID: sourceID, targetID: targetID))
		            }

		            for card in frame.cards {
		                for stroke in card.strokes {
		                    guard let targetID = linkTargetID(for: stroke) else { continue }
		                    foundInternalTargets = true
		                    edges.insert(InternalLinkReferenceEdge(sourceID: card.id, targetID: targetID))
		                }
		            }

		            for child in frame.children.values {
		                walk(frame: child)
		            }
		        }

		        walk(frame: rootFrame)

		        internalLinkReferenceNamesByID = names
		        internalLinkTargetsPresent = foundInternalTargets
		        internalLinkReferenceEdges = edges.sorted { lhs, rhs in
		            if lhs.sourceID.uuidString != rhs.sourceID.uuidString {
		                return lhs.sourceID.uuidString < rhs.sourceID.uuidString
		            }
		            return lhs.targetID.uuidString < rhs.targetID.uuidString
		        }
		    }

		    // MARK: - Highlight Section Hit Testing / Removal

		    func hitTestHighlightSection(at screenPoint: CGPoint, viewSize: CGSize) -> LinkHighlightKey? {
		        guard !linkHighlightBoundsByKeyActiveThisFrame.isEmpty else { return nil }

		        let pointActive = screenToWorldPixels_PureDouble(
		            screenPoint,
		            viewSize: viewSize,
		            panOffset: panOffset,
		            zoomScale: zoomScale,
		            rotationAngle: rotationAngle
		        )
		        let p = CGPoint(x: pointActive.x, y: pointActive.y)

			        var best: (key: LinkHighlightKey, area: Double)?
			        for (key, rect) in linkHighlightBoundsByKeyActiveThisFrame {
			            guard rect.contains(p) else { continue }
			            let area = Double(rect.width * rect.height)
			            if let current = best {
			                if area < current.area {
			                    best = (key: key, area: area)
			                }
		            } else {
		                best = (key: key, area: area)
		            }
		        }

		        return best?.key
		    }

		    func removeHighlightSection(_ key: LinkHighlightKey) {
		        func normalized(_ link: String?) -> String? {
		            link?.trimmingCharacters(in: .whitespacesAndNewlines)
		        }

		        func matches(_ stroke: Stroke) -> Bool {
		            switch key {
		            case .section(let id):
		                return stroke.linkSectionID == id
		            case .legacy(let url):
		                return stroke.linkSectionID == nil && normalized(stroke.link) == url
		            }
		        }

		        func clear(_ stroke: Stroke) {
		            stroke.link = nil
		            stroke.linkSectionID = nil
		            stroke.linkTargetSectionID = nil
		            stroke.linkTargetCardID = nil
		        }

		        func walk(frame: Frame) {
		            for stroke in frame.strokes where matches(stroke) {
		                clear(stroke)
		            }
		            for card in frame.cards {
		                for stroke in card.strokes where matches(stroke) {
		                    clear(stroke)
		                }
		            }
		            for child in frame.children.values {
		                walk(frame: child)
		            }
		        }

		        walk(frame: rootFrame)
		        clearLinkSelection()
		        rebuildInternalLinkReferenceCache()
		    }

		    private func findSection(id: UUID, in frame: Frame) -> (section: Section, frame: Frame)? {
		        for section in frame.sections where section.id == id {
		            return (section: section, frame: frame)
		        }
		        for child in frame.children.values {
		            if let found = findSection(id: id, in: child) {
		                return found
		            }
		        }
		        return nil
		    }

		    private func findCard(id: UUID, in frame: Frame) -> (card: Card, frame: Frame)? {
		        for card in frame.cards where card.id == id {
		            return (card: card, frame: frame)
		        }
		        for child in frame.children.values {
		            if let found = findCard(id: id, in: child) {
		                return found
		            }
		        }
		        return nil
		    }

		    private func teleport(to targetFrame: Frame,
		                          focusPointInFrame: SIMD2<Double>,
		                          viewSize: CGSize) {
		        activeFrame = targetFrame
		        let screenCenter = CGPoint(x: viewSize.width * 0.5, y: viewSize.height * 0.5)
		        panOffset = solvePanOffsetForAnchor_Double(
		            anchorWorld: focusPointInFrame,
		            desiredScreen: screenCenter,
		            viewSize: viewSize,
		            zoomScale: zoomScale,
		            rotationAngle: rotationAngle
		        )
		    }

		    private func fadedTeleport(to targetFrame: Frame,
		                               focusPointInFrame: SIMD2<Double>,
		                               viewSize: CGSize) {
		        #if canImport(UIKit)
		        guard let view = metalView else {
		            teleport(to: targetFrame, focusPointInFrame: focusPointInFrame, viewSize: viewSize)
		            return
		        }

		        let overlay = UIView(frame: view.bounds)
		        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		        overlay.backgroundColor = UIColor.black
		        overlay.alpha = 0.0
		        overlay.isUserInteractionEnabled = false
		        view.addSubview(overlay)

		        UIView.animate(withDuration: 0.12,
		                       delay: 0,
		                       options: [.curveEaseInOut],
		                       animations: {
		                           overlay.alpha = 1.0
		                       }, completion: { [weak self] _ in
		                           guard let self else {
		                               overlay.removeFromSuperview()
		                               return
		                           }
		                           self.teleport(to: targetFrame, focusPointInFrame: focusPointInFrame, viewSize: viewSize)
		                           UIView.animate(withDuration: 0.18,
		                                          delay: 0,
		                                          options: [.curveEaseInOut],
		                                          animations: {
		                                              overlay.alpha = 0.0
		                                          }, completion: { _ in
		                                              overlay.removeFromSuperview()
		                                          })
		                       })
		        #else
		        teleport(to: targetFrame, focusPointInFrame: focusPointInFrame, viewSize: viewSize)
		        #endif
		    }

		    func openLinkIfNeeded(at screenPoint: CGPoint,
		                          viewSize: CGSize,
		                          restrictToSelection: Bool) -> Bool {
	        guard let hit = hitTestStrokeHierarchy(screenPoint: screenPoint, viewSize: viewSize, radiusPx: linkHitTestRadiusPx) else { return false }

	        if restrictToSelection {
	            guard let selection = linkSelection else { return false }
	            let ref = linkedStrokeRef(from: hit)
	            guard selection.keys.contains(ref.key) else { return false }
	        }

	        if let sectionID = hit.stroke.linkTargetSectionID,
	           let found = findSection(id: sectionID, in: rootFrame) {
	            fadedTeleport(to: found.frame, focusPointInFrame: found.section.origin, viewSize: viewSize)
	            return true
	        }

	        if let cardID = hit.stroke.linkTargetCardID,
	           let found = findCard(id: cardID, in: rootFrame) {
	            fadedTeleport(to: found.frame, focusPointInFrame: found.card.origin, viewSize: viewSize)
	            return true
	        }

	        guard let url = hit.stroke.linkURL else { return false }

	        #if canImport(UIKit)
	        UIApplication.shared.open(url, options: [:], completionHandler: nil)
	        #endif
	        return true
	    }

	    func deleteCard(_ card: Card) {
	        var topFrame = activeFrame
	        while let parent = topFrame.parent {
	            topFrame = parent
	        }
	        guard let frame = findFrame(containing: card, in: topFrame) else { return }

	        if let index = frame.cards.firstIndex(where: { $0 === card }) {
	            frame.cards.remove(at: index)
	        } else {
	            return
	        }
		        zOrder.removeAll { item in
		            if case .card(let id) = item {
		                return id == card.id
		            }
		            return false
		        }
		        (metalView as? TouchableMTKView)?.deactivateYouTubeOverlayIfTarget(card: card)
		        (metalView as? TouchableMTKView)?.closeWebCardOverlayIfOpen(card: card)
		        card.isEditing = false
		        clearLassoSelection()

	        if case .card(let targetCard, _) = currentDrawingTarget, targetCard === card {
	            currentDrawingTarget = nil
	        }
	    }

	    private func findFrame(containing card: Card, in frame: Frame) -> Frame? {
	        if frame.cards.contains(where: { $0 === card }) {
	            return frame
	        }
	        for child in frame.children.values {
	            if let found = findFrame(containing: card, in: child) {
	                return found
	            }
	        }
	        return nil
	    }

	    // MARK: - Section Membership

	    private func strokeMembershipAnchorPointInFrame(_ stroke: Stroke) -> SIMD2<Double> {
	        let bounds = stroke.localBounds
	        guard bounds != .null else { return stroke.origin }
	        let centerLocal = SIMD2<Double>(Double(bounds.midX), Double(bounds.midY))
	        return stroke.origin + centerLocal
	    }

		    /// Resolve section membership for a point in a specific frame, allowing membership to sections
		    /// defined in any ancestor frame (cross-depth).
		    private func resolveSectionIDForPointInFrameHierarchy(pointInFrame: SIMD2<Double>, frame: Frame) -> UUID? {
		        // Fast path: consult the render-derived visible-frame cache so sections can capture
		        // content drawn in other visible frames/depths (siblings, cousins, descendants).
		        if !visibleFractalFramesDrawOrder.isEmpty {
		            let sourceID = ObjectIdentifier(frame)
		            let sourceTransform = visibleFractalFrameTransforms[sourceID] ?? transformFromActive(to: frame)
		            if let sourceTransform {
		                let invSourceScale = sourceTransform.scale != 0 ? (1.0 / sourceTransform.scale) : 1.0
		                let pointActive = (pointInFrame - sourceTransform.translation) * invSourceScale

		                let sourceScale = max(sourceTransform.scale, 1e-12)
		                var best: (id: UUID, areaInSource: Double, scaleToSource: Double)?

		                for candidateFrame in visibleFractalFramesDrawOrder {
		                    guard !candidateFrame.sections.isEmpty else { continue }
		                    let candidateID = ObjectIdentifier(candidateFrame)
		                    let candidateTransform = visibleFractalFrameTransforms[candidateID] ?? transformFromActive(to: candidateFrame)
		                    guard let candidateTransform else { continue }

		                    let pointInCandidate = pointActive * candidateTransform.scale + candidateTransform.translation
		                    guard let section = candidateFrame.sectionContaining(pointInFrame: pointInCandidate) else { continue }

		                    let candidateScale = max(candidateTransform.scale, 1e-12)
		                    let scaleToSource = sourceScale / candidateScale
		                    let areaInSource = section.absoluteArea * (scaleToSource * scaleToSource)

		                    if let currentBest = best {
		                        if areaInSource < currentBest.areaInSource - 1e-9 ||
		                            (abs(areaInSource - currentBest.areaInSource) <= 1e-9 && scaleToSource < currentBest.scaleToSource) {
		                            best = (id: section.id, areaInSource: areaInSource, scaleToSource: scaleToSource)
		                        }
		                    } else {
		                        best = (id: section.id, areaInSource: areaInSource, scaleToSource: scaleToSource)
		                    }
		                }

		                if let id = best?.id {
		                    return id
		                }
		            }
		        }

		        guard metalView != nil else {
		            return frame.sectionContaining(pointInFrame: pointInFrame)?.id
		        }

	        let viewSize = metalView?.bounds.size ?? .zero
	        if viewSize.width > 0.0, viewSize.height > 0.0 {
	            ensureFractalExtent(viewSize: viewSize)
	        }

	        let extent = fractalFrameExtent
	        let hasExtent = extent.x > 0.0 && extent.y > 0.0
	        let scale = FractalGrid.scale

	        var currentFrame: Frame? = frame
	        var point = pointInFrame
	        var scaleToOriginal: Double = 1.0

	        var best: (section: Section, areaInOriginal: Double, scaleToOriginal: Double)?

	        while let f = currentFrame {
	            if let candidate = f.sectionContaining(pointInFrame: point) {
	                let areaInOriginal = candidate.absoluteArea * (scaleToOriginal * scaleToOriginal)
	                if let currentBest = best {
	                    if areaInOriginal < currentBest.areaInOriginal - 1e-9 ||
	                        (abs(areaInOriginal - currentBest.areaInOriginal) <= 1e-9 && scaleToOriginal < currentBest.scaleToOriginal) {
	                        best = (section: candidate, areaInOriginal: areaInOriginal, scaleToOriginal: scaleToOriginal)
	                    }
	                } else {
	                    best = (section: candidate, areaInOriginal: areaInOriginal, scaleToOriginal: scaleToOriginal)
	                }
	            }

	            guard hasExtent, let parent = f.parent, let index = f.indexInParent else { break }
	            let childCenter = FractalGrid.childCenterInParent(frameExtent: extent, index: index)
	            point = childCenter + (point / scale)
	            scaleToOriginal *= scale
	            currentFrame = parent
	        }

	        return best?.section.id
	    }

	    private func appendCanvasStroke(_ stroke: Stroke, to frame: Frame) -> DrawingTarget {
	        let anchor = strokeMembershipAnchorPointInFrame(stroke)
	        if stroke.layerID == nil {
	            stroke.layerID = selectedLayerID
	        }
	        stroke.sectionID = resolveSectionIDForPointInFrameHierarchy(pointInFrame: anchor, frame: frame)
	        frame.strokes.append(stroke)
	        return .canvas(frame)
	    }

	    private func appendCard(_ card: Card, to frame: Frame) {
	        card.sectionID = resolveSectionIDForPointInFrameHierarchy(pointInFrame: card.origin, frame: frame)
	        frame.cards.append(card)
	    }

	    /// Recompute `sectionID` for all strokes/cards in this frame *and its existing descendants*.
	    private func regroupSectionMembership(in frame: Frame) {
	        func visit(_ f: Frame) {
	            for stroke in f.strokes {
	                let anchor = strokeMembershipAnchorPointInFrame(stroke)
	                stroke.sectionID = resolveSectionIDForPointInFrameHierarchy(pointInFrame: anchor, frame: f)
	            }
	            for card in f.cards {
	                card.sectionID = resolveSectionIDForPointInFrameHierarchy(pointInFrame: card.origin, frame: f)
	            }
	            for child in f.children.values {
	                visit(child)
	            }
	        }

	        visit(frame)
	    }

	    func reassignCardMembershipIfNeeded(card: Card, frame: Frame) {
	        let desired = resolveSectionIDForPointInFrameHierarchy(pointInFrame: card.origin, frame: frame)
	        if card.sectionID == desired { return }
	        card.sectionID = desired
	    }

    /// Add a new card to the canvas at the camera center
    /// The card will be a solid color and can be selected/dragged/edited
    /// Cards are created with constant screen size (300pt) regardless of zoom level
	    func addCard() {
	        guard let view = metalView else {
	            return
	        }

        // 1. Calculate camera center in world coordinates (where the user is looking)
        let cameraCenterWorld = calculateCameraCenterWorld(viewSize: view.bounds.size)

        // 2. Define Desired Screen Size (e.g., 300x200 points)
        // This ensures the card looks the same size to the user whether they are at 1x or 1000x zoom
        let screenWidth: Double = 300.0
        let screenHeight: Double = 200.0

        // 3. Convert to World Units
        // world = screen / zoom
        let worldW = screenWidth / zoomScale
        let worldH = screenHeight / zoomScale
        let cardSize = SIMD2<Double>(worldW, worldH)

	        // 4. Default card color: #333333
	        // let neonPink = SIMD4<Float>(1.0, 0.0, 1.0, 1.0)  // Bright magenta (old default for visibility)
	        let defaultCardColor = SIMD4<Float>(0.2, 0.2, 0.2, 1.0)

	        // 5. Create the card (Default to Solid Color for now)
	        // Capture current zoom so the card can correctly scale procedural backgrounds
	        let defaultName = nextNumberedName(base: "Card", existingNames: allCardsInCanvas(from: rootFrame).map(\.name))
	        let card = Card(
	            name: defaultName,
	            origin: cameraCenterWorld,
	            size: cardSize,
	            rotation: 0,
	            zoom: zoomScale, // Capture current zoom!
	            type: .solidColor(defaultCardColor)
	        )

	        // 6. Add to the appropriate container (frame or section)
	        appendCard(card, to: activeFrame)
	        syncZOrderWithCanvas()
	        zOrder.removeAll { item in
	            if case .card(let id) = item {
	                return id == card.id
	            }
	            return false
	        }
	        zOrder.insert(.card(card.id), at: 0)
	    }

	    func addPluginCard(typeID: String) {
	        guard let view = metalView else {
	            return
	        }

	        let cameraCenterWorld = calculateCameraCenterWorld(viewSize: view.bounds.size)

	        let definition = CardPluginRegistry.shared.definition(for: typeID)
	        let defaultSizePt = definition?.defaultSizePt ?? CGSize(width: 300.0, height: 200.0)
	        let worldW = Double(defaultSizePt.width) / max(zoomScale, 1e-9)
	        let worldH = Double(defaultSizePt.height) / max(zoomScale, 1e-9)
	        let cardSize = SIMD2<Double>(worldW, worldH)

	        let defaultCardColor = SIMD4<Float>(0.2, 0.2, 0.2, 1.0)
	        let baseName = definition?.name ?? "Plugin"
	        let defaultName = nextNumberedName(base: baseName, existingNames: allCardsInCanvas(from: rootFrame).map(\.name))
	        let payload = definition?.defaultPayload ?? Data()

	        let card = Card(
	            name: defaultName,
	            origin: cameraCenterWorld,
	            size: cardSize,
	            rotation: 0,
	            zoom: zoomScale,
	            type: .plugin(typeID: typeID, payload: payload),
	            backgroundColor: defaultCardColor
	        )

	        appendCard(card, to: activeFrame)
	        syncZOrderWithCanvas()
	        zOrder.removeAll { item in
	            if case .card(let id) = item {
	                return id == card.id
	            }
	            return false
	        }
	        zOrder.insert(.card(card.id), at: 0)
	    }

	    #if DEBUG
	    func addSampleWebCard() {
	        let typeID = CardPluginRegistry.shared.allDefinitions.first?.typeID ?? "labyrinth.sample.hello"
	        addPluginCard(typeID: typeID)
	    }
	    #endif

    /// Create a stroke in a target frame's coordinate system (canvas strokes).
    /// Converts screen points into the target frame, even across telescope transitions.
    func createStrokeForFrame(screenPoints: [CGPoint],
                              frame: Frame,
                              viewSize: CGSize,
                              depthID: UInt32,
                              color: SIMD4<Float>? = nil,
                              depthWriteEnabled: Bool? = nil) -> Stroke {
        guard let transform = transformFromActive(to: frame) else {
            return Stroke(
                screenPoints: screenPoints,
                zoomAtCreation: zoomScale,
                panAtCreation: panOffset,
                viewSize: viewSize,
                rotationAngle: rotationAngle,
                color: color ?? brushSettings.color,
                baseWidth: brushSettings.size,
                zoomEffectiveAtCreation: Float(max(zoomScale, 1e-6)),
                device: device,
                depthID: depthID,
                depthWriteEnabled: depthWriteEnabled ?? brushSettings.depthWriteEnabled,
                constantScreenSize: brushSettings.constantScreenSize
            )
        }

        let effectiveZoom = max(zoomScale / transform.scale, 1e-6)
        var virtualScreenPoints: [CGPoint] = []
        virtualScreenPoints.reserveCapacity(screenPoints.count)

        for screenPt in screenPoints {
            let worldPtActive = screenToWorldPixels_PureDouble(
                screenPt,
                viewSize: viewSize,
                panOffset: panOffset,
                zoomScale: zoomScale,
                rotationAngle: rotationAngle
            )
            let targetWorld = worldPtActive * transform.scale + transform.translation
            virtualScreenPoints.append(CGPoint(x: targetWorld.x * effectiveZoom,
                                               y: targetWorld.y * effectiveZoom))
        }

        let finalColor = color ?? brushSettings.color
        let finalDepthWriteEnabled = depthWriteEnabled ?? brushSettings.depthWriteEnabled

        return Stroke(
            screenPoints: virtualScreenPoints,
            zoomAtCreation: effectiveZoom,
            panAtCreation: .zero,
            viewSize: .zero,
            rotationAngle: 0,
            color: finalColor,
            baseWidth: brushSettings.size,
            zoomEffectiveAtCreation: Float(effectiveZoom),
            device: device,
            depthID: depthID,
            depthWriteEnabled: finalDepthWriteEnabled,
            constantScreenSize: brushSettings.constantScreenSize
        )
    }

    /// Create a stroke in card-local coordinates
    /// Transforms screen-space points into the card's local coordinate system
    /// This ensures the stroke "sticks" to the card when it's moved or rotated
    ///
    /// **CROSS-DEPTH COMPATIBLE:**
    /// Supports drawing on cards anywhere in the telescope chain (ancestor/active/descendant).
    ///
    /// - Parameters:
    ///   - screenPoints: Raw screen-space touch points
    ///   - card: The card to draw on
    ///   - frame: The frame the card belongs to (may be parent, active, or child)
    ///   - viewSize: Screen dimensions
    /// - Returns: A stroke with points relative to card center
	    func createStrokeForCard(screenPoints: [CGPoint],
	                             card: Card,
	                             frame: Frame,
	                             viewSize: CGSize,
	                             depthID: UInt32,
	                             color: SIMD4<Float>? = nil,
	                             depthWriteEnabled: Bool? = nil) -> Stroke {
        // 1. Get the Card's World Position & Rotation (in its Frame)
        let cardOrigin = card.origin
        let cardRot = Double(card.rotation)

        // Pre-calculate rotation trig (inverse rotation to convert to card-local)
        let c = cos(-cardRot)
        let s = sin(-cardRot)

        guard let transform = transformFromActive(to: frame) else {
            return Stroke(
                screenPoints: screenPoints,
                zoomAtCreation: zoomScale,
                panAtCreation: panOffset,
                viewSize: viewSize,
                rotationAngle: rotationAngle,
                color: color ?? brushSettings.color,
                baseWidth: brushSettings.size,
                zoomEffectiveAtCreation: Float(max(zoomScale, 1e-6)),
                device: device,
                depthID: depthID,
                depthWriteEnabled: depthWriteEnabled ?? brushSettings.depthWriteEnabled,
                constantScreenSize: brushSettings.constantScreenSize
            )
        }

        // 2. Calculate Effective Zoom for the Card's Frame
        let effectiveZoom = max(zoomScale / transform.scale, 1e-6)

        // 3. Transform Screen Points -> Card Local Points
        var cardLocalPoints: [CGPoint] = []

        for screenPt in screenPoints {
            // A. Screen -> Active World (Standard conversion)
            let worldPtActive = screenToWorldPixels_PureDouble(
                screenPt,
                viewSize: viewSize,
                panOffset: panOffset,
                zoomScale: zoomScale,
                rotationAngle: rotationAngle
            )

            // B. Active World -> Card's Frame World (Apply telescope transform)
            let targetWorldPt = worldPtActive * transform.scale + transform.translation

            // C. Card's Frame World -> Card Local (Translate and Rotate)
            let dx = targetWorldPt.x - cardOrigin.x
            let dy = targetWorldPt.y - cardOrigin.y

            let localX = dx * c - dy * s
            let localY = dx * s + dy * c

            //  CRITICAL: Scale up to "virtual screen space"
            // We multiply by EFFECTIVE zoom so when Stroke.init divides by it,
            // we get back to world units (localX, localY) in the card's frame.
            let virtualScreenX = localX * effectiveZoom
            let virtualScreenY = localY * effectiveZoom

            cardLocalPoints.append(CGPoint(x: virtualScreenX, y: virtualScreenY))
        }

        let finalColor = color ?? brushSettings.color
        let finalDepthWriteEnabled = depthWriteEnabled ?? brushSettings.depthWriteEnabled

        // 5. Create the Stroke with Effective Zoom
	        return Stroke(
	            screenPoints: cardLocalPoints,   // Virtual screen space (world units * effectiveZoom)
	            zoomAtCreation: max(effectiveZoom, 1e-6),   // Use effective zoom for the card's frame!
	            panAtCreation: .zero,            // We handled position manually
	            viewSize: .zero,                 // We handled centering manually
	            rotationAngle: 0,                // We handled rotation manually
	            color: finalColor,               // Use brush settings color unless overridden
	            baseWidth: brushSettings.size,   // Use brush settings size
	            zoomEffectiveAtCreation: Float(max(effectiveZoom, 1e-6)),
	            device: device,                  // Pass device for buffer caching
	            depthID: depthID,
	            depthWriteEnabled: finalDepthWriteEnabled,
	            constantScreenSize: brushSettings.constantScreenSize
	        )
	    }

}

// MARK: - Gesture Delegate
//
// NOTE:
// Gesture delegate conformance lives in `TouchableMTKView.swift` so it can
// gate canvas gestures while inline UITextField editors are active.
