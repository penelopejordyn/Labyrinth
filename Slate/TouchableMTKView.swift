// TouchableMTKView.swift subclasses MTKView to attach gestures, manage anchors,
// and forward user interactions to the coordinator while presenting debug HUD info.
import UIKit
import MetalKit
import ObjectiveC.runtime
import simd
import Combine
#if canImport(YouTubePlayerKit)
import YouTubePlayerKit
#else
import WebKit
#endif

// MARK: - Associated Object Keys for gesture state storage
private struct AssociatedKeys {
    static var dragContext: UInt8 = 0
}

// MARK: - Drag Context for Cross-Depth Dragging
/// Stores the card being dragged and its coordinate conversion scale
/// The conversion scale translates movement between coordinate systems:
///   - Parent cards: scale < 1.0 (move slower)
///   - Active cards: scale = 1.0 (normal movement)
///   - Child cards: scale > 1.0 (move faster)
private class DragContext {
    let card: Card
    let frame: Frame
    let conversionScale: Double
    let isResizing: Bool // True if dragging the handle (resize), false if dragging card body (move)
    let startOrigin: SIMD2<Double>
    let startSize: SIMD2<Double>

    init(card: Card, frame: Frame, conversionScale: Double, isResizing: Bool = false) {
        self.card = card
        self.frame = frame
        self.conversionScale = conversionScale
        self.isResizing = isResizing
        self.startOrigin = card.origin
        self.startSize = card.size
    }
}

// MARK: - TouchableMTKView
    class TouchableMTKView: MTKView {
        private struct ColorChoice {
            let color: SIMD4<Float>
        }

        private static let sectionColorPalette: [ColorChoice] = [
            ColorChoice(color: SIMD4<Float>(1.0, 0.25, 0.25, 1.0)),
            ColorChoice(color: SIMD4<Float>(1.0, 0.55, 0.20, 1.0)),
            ColorChoice(color: SIMD4<Float>(1.0, 0.90, 0.20, 1.0)),
            ColorChoice(color: SIMD4<Float>(0.25, 0.85, 0.35, 1.0)),
            ColorChoice(color: SIMD4<Float>(0.25, 0.60, 1.0, 1.0)),
            ColorChoice(color: SIMD4<Float>(0.70, 0.35, 1.0, 1.0))
        ]

        private static let cardColorPalette: [ColorChoice] = [
            ColorChoice(color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0)),      // White
            ColorChoice(color: SIMD4<Float>(0.95, 0.95, 0.90, 1.0)),   // Cream
            ColorChoice(color: SIMD4<Float>(1.0, 0.95, 0.85, 1.0)),    // Warm
            ColorChoice(color: SIMD4<Float>(0.85, 0.95, 1.0, 1.0)),    // Cool
            ColorChoice(color: SIMD4<Float>(0.9, 0.9, 0.9, 1.0)),      // Light gray
            ColorChoice(color: SIMD4<Float>(0.2, 0.2, 0.2, 1.0))       // Dark
        ]
	
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

    weak var coordinator: Coordinator?

    var panGesture: UIPanGestureRecognizer!
    var tapGesture: UITapGestureRecognizer!
    var pinchGesture: UIPinchGestureRecognizer!
    var rotationGesture: UIRotationGestureRecognizer!
    var longPressGesture: UILongPressGestureRecognizer!
    var cardLongPressGesture: UILongPressGestureRecognizer! // Single-finger long press for card settings
    private var pencilInteraction: UIPencilInteraction?

    // Debug HUD
    var debugLabel: UILabel!

    // MARK: - Stroke Linking UI (Selection Handles + Menu)
    private let linkHandleTouchSize: CGFloat = 44.0
    // private let linkHandleVisibleSize: CGFloat = 18.0
    private let linkHandleLineWidth: CGFloat = 3.0
    private var linkHandleView: UIView?
    private var linkHandlePan: UIPanGestureRecognizer?
    private var lastLinkMenuAnchorRect: CGRect = .null
	    private var ignoreTapsUntilTime: CFTimeInterval = 0
	    private var isPresentingLinkPrompt: Bool = false
	    private var isPresentingInternalLinkPicker: Bool = false
	    private var isShowingRemoveHighlightMenu: Bool = false
	    private var removeHighlightMenuKey: Coordinator.LinkHighlightKey?
	    private var linkHandleLineView: UIView?
	    private var lastLassoMenuAnchorRect: CGRect = .null
        private var isShowingLassoSectionMenu: Bool = false
        private var isShowingSectionColorMenu: Bool = false
        private weak var sectionColorMenuTarget: Section?
        private weak var cardMenuTarget: Card?
        private var cardMenuTargetFrame: Frame?

        // MARK: - Inline Section Name Editing
        private var sectionNameTextField: UITextField?
        private weak var sectionNameEditingTarget: Section?
        private weak var sectionNameEditingFrame: Frame?

        // MARK: - Inline Card Name Editing
        private var cardNameTextField: UITextField?
        private weak var cardNameEditingTarget: Card?
        private weak var cardNameEditingFrame: Frame?

        // MARK: - YouTube Card Overlay (single active player)
        #if canImport(YouTubePlayerKit)
        private var youtubePlayer: YouTubePlayer?
        private var youtubeHostingView: YouTubePlayerHostingView?
        private var youtubeStateCancellable: AnyCancellable?
        private var youtubeEventCancellable: AnyCancellable?
        private var youtubePendingVideoID: String?
        #else
        private var youtubeWebView: WKWebView?
        #endif
        private weak var youtubeCardTarget: Card?
        private weak var youtubeCardFrame: Frame?
        private var youtubeLoadedVideoID: String?
        private var youtubeOverlayLastCenter: CGPoint?
        private var youtubeOverlayLastSize: CGSize?
        private var youtubeOverlayLastRotation: CGFloat?
        private var youtubeLastErrorSummary: String?

    //  UPGRADED: Anchors now use Double for infinite precision at extreme zoom
    var pinchAnchorScreen: CGPoint = .zero
    var pinchAnchorWorld: SIMD2<Double> = .zero
    var panOffsetAtPinchStart: SIMD2<Double> = .zero

    //rotation anchor
    var rotationAnchorScreen: CGPoint = .zero
    var rotationAnchorWorld: SIMD2<Double> = .zero
    var panOffsetAtRotationStart: SIMD2<Double> = .zero

    enum AnchorOwner { case none, pinch, rotation }

    var activeOwner: AnchorOwner = .none
    var anchorWorld: SIMD2<Double> = .zero
    var anchorScreen: CGPoint = .zero

    var lastPinchTouchCount: Int = 0
    var lastRotationTouchCount: Int = 0
    var lassoDragActive: Bool = false
    var lassoPinchActive: Bool = false
    var lassoRotationActive: Bool = false
    var cardPinchActive: Bool = false
    var cardRotationActive: Bool = false
    weak var cardPinchTarget: Card?
    weak var cardRotationTarget: Card?

    // Track lasso operation start state for undo
    // TODO: Implement lasso undo support
    // var lassoMoveStartSnapshot: Coordinator.LassoMoveSnapshot?
    // var lassoTransformStartSnapshot: Coordinator.LassoTransformSnapshot?

    // Pan momentum/inertia
    var panVelocity: SIMD2<Double> = .zero
    var lastPanTime: CFTimeInterval = 0
    var momentumDisplayLink: CADisplayLink?




    func lockAnchor(owner: AnchorOwner, at screenPt: CGPoint, coord: Coordinator) {
        activeOwner = owner
        anchorScreen = screenPt

        //  FIX: Use Pure Double precision.
        // Previously this was using the Float version, causing the "Jump" on rotation.
        anchorWorld = screenToWorldPixels_PureDouble(screenPt,
                                                     viewSize: bounds.size,
                                                     panOffset: coord.panOffset, // SIMD2<Double>
                                                     zoomScale: coord.zoomScale, // Double
                                                     rotationAngle: coord.rotationAngle)
    }

    // Re-lock anchor to a new screen point *without changing the transform*
    func relockAnchorAtCurrentCentroid(owner: AnchorOwner, screenPt: CGPoint, coord: Coordinator) {
        activeOwner = owner
        anchorScreen = screenPt

        //  FIX: Use Pure Double precision here too.
        // This prevents jumps when you add/remove a finger (changing the centroid).
        anchorWorld = screenToWorldPixels_PureDouble(screenPt,
                                                     viewSize: bounds.size,
                                                     panOffset: coord.panOffset,
                                                     zoomScale: coord.zoomScale,
                                                     rotationAngle: coord.rotationAngle)
    }

    func handoffAnchor(to newOwner: AnchorOwner, screenPt: CGPoint, coord: Coordinator) {
        relockAnchorAtCurrentCentroid(owner: newOwner, screenPt: screenPt, coord: coord)
    }

    func clearAnchorIfUnused() { activeOwner = .none }

    /*
    // MARK: - Legacy Telescoping Transitions (Reference Only)

    /// Check if zoom has exceeded thresholds and perform frame transitions if needed.
    /// Returns TRUE if a transition occurred (caller should return early).
    func checkTelescopingTransitions(coord: Coordinator,
                                     anchorWorld: SIMD2<Double>,
                                     anchorScreen: CGPoint) -> Bool {
        // DRILL DOWN
        if coord.zoomScale > 1000.0 {
            drillDownToNewFrame(coord: coord,
                                anchorWorld: anchorWorld,
                                anchorScreen: anchorScreen)
            return true
        }
        // POP UP (Telescope Out - create parent if needed)
        else if coord.zoomScale < 0.5 {
            popUpToParentFrame(coord: coord,
                               anchorWorld: anchorWorld,
                               anchorScreen: anchorScreen)
            return true
        }

        return false
    }

    /// "The Silent Teleport" - Drill down into a child frame.
    ///  FIX: Uses the shared anchor instead of recomputing to prevent micro-jumps.
    func drillDownToNewFrame(coord: Coordinator,
                             anchorWorld: SIMD2<Double>,
                             anchorScreen: CGPoint) {
        print("🚀 ENTER drillDownToNewFrame at depth \(coord.activeFrame.depthFromRoot), zoom \(coord.zoomScale)")

        // 1. CAPTURE STATE (CRITICAL: Do this BEFORE resetting zoom)
        let currentZoom = coord.zoomScale // This should be ~1000.0

        // 2. USE THE EXACT ANCHOR (Don't recompute from screen!)
        // This is the key fix - we use the exact same world point that the gesture handler
        // has been tracking, preventing floating point discrepancies.
        let pinchPointWorld = anchorWorld // EXACT same world point as gesture anchor
        let currentCentroid = anchorScreen // Reuse for solving pan

        // 3. Check for existing child frame
        // In the telescope chain, there should be exactly ONE child per frame
        // We always re-enter it regardless of distance (telescope chain invariant)
        let currentDepth = coord.activeFrame.depthFromRoot

        print("🔍 Checking for child frames at depth \(currentDepth), \(coord.activeFrame.children.count) children")

        var targetFrame: Frame? = nil

        // TELESCOPE CHAIN INVARIANT: If there's exactly one child, always use it
        // This maintains the linked-list structure (no siblings in telescope chain)
        if coord.activeFrame.children.count == 1 {
            targetFrame = coord.activeFrame.children[0]
            print("  ✓ Found single child at depth \(targetFrame!.depthFromRoot) (telescope chain)")
        } else if coord.activeFrame.children.count > 1 {
            // Multiple children exist (should only happen for non-telescope frames)
            // Use search radius to find the closest one
            let searchRadius: Double = 50.0
            for child in coord.activeFrame.children {
                let dist = distance(child.originInParent, pinchPointWorld)
                print("  - Child at depth \(child.depthFromRoot), origin \(child.originInParent), distance \(dist)")
                if dist < searchRadius {
                    targetFrame = child
                    print("  ✓ Selected this child (within search radius)")
                    break
                }
            }
        }

        if let existing = targetFrame {
            //  RE-ENTER EXISTING FRAME
            let oldDepth = coord.activeFrame.depthFromRoot
            coord.activeFrame = existing
            let newDepth = coord.activeFrame.depthFromRoot

            print("🔭 Re-entered existing frame (Telescope In): depth \(oldDepth) → \(newDepth), zoom \(currentZoom) → will be \(currentZoom / existing.scaleRelativeToParent)")

            // 4. Calculate where the FINGER is inside this frame
            // LocalPinch = (ParentPinch - Origin) * Scale
            let diffX = pinchPointWorld.x - existing.originInParent.x
            let diffY = pinchPointWorld.y - existing.originInParent.y

            let localPinchX = diffX * existing.scaleRelativeToParent
            let localPinchY = diffY * existing.scaleRelativeToParent

            // 5. RESET ZOOM
            // We do this AFTER calculating positions
            coord.zoomScale = currentZoom / existing.scaleRelativeToParent

            // 6. SOLVE PAN
            coord.panOffset = solvePanOffsetForAnchor_Double(
                anchorWorld: SIMD2<Double>(localPinchX, localPinchY),
                desiredScreen: currentCentroid,
                viewSize: bounds.size,
                zoomScale: coord.zoomScale, // Now ~1.0
                rotationAngle: coord.rotationAngle
            )

        } else {
            //  CREATE NEW FRAME
            //  This creates a NEW branch (sibling to existing children, if any)
            //  For pure telescoping, this should only happen when there are NO existing children

            //  FIX: Center the new frame exactly on the PINCH POINT (Finger).
            // This prevents exponential coordinate growth (Off-Center Accumulation).
            // OLD: Centered on screen center → 500px offset compounds to 500,000 → 500M → 10^18 → CRASH
            // NEW: Centered on finger → offset resets to 0 at each depth → stays bounded forever
            let newFrameOrigin = pinchPointWorld

            let oldDepth = coord.activeFrame.depthFromRoot
            let newDepth = oldDepth + 1  // Child is always parent + 1

            let newFrame = Frame(
                parent: coord.activeFrame,
                origin: newFrameOrigin,
                scale: currentZoom,  // Use captured high zoom
                depth: newDepth
            )

            coord.activeFrame.children.append(newFrame)
            coord.activeFrame = newFrame
            coord.zoomScale = 1.0

            if coord.activeFrame.parent?.children.count ?? 0 > 1 {
                print("⚠️ WARNING: Created sibling frame (multiple children at depth \(oldDepth))")
            }
            print("🔭 Created new frame (Telescope In): depth \(oldDepth) → \(newDepth), zoom \(currentZoom) → 1.0")

            //  RESULT: The pinch point is now the origin (0,0)
            // diffX = pinchPointWorld - newFrameOrigin = 0
            // diffY = pinchPointWorld - newFrameOrigin = 0
            // localPinch = (0, 0)

            coord.panOffset = solvePanOffsetForAnchor_Double(
                anchorWorld: SIMD2<Double>(0, 0), // Finger is at Local (0,0)
                desiredScreen: currentCentroid,   // Keep Finger at Screen Point
                viewSize: bounds.size,
                zoomScale: 1.0,
                rotationAngle: coord.rotationAngle
            )
        }

        // 7. RE-ANCHOR GESTURES (update with new coordinate system)
        if activeOwner != .none {
            self.anchorWorld = screenToWorldPixels_PureDouble(
                currentCentroid,
                viewSize: bounds.size,
                panOffset: coord.panOffset,
                zoomScale: coord.zoomScale,
                rotationAngle: coord.rotationAngle
            )
            self.anchorScreen = currentCentroid
        }

        print("🏁 EXIT drillDownToNewFrame at depth \(coord.activeFrame.depthFromRoot), zoom \(coord.zoomScale)")
    }

    /// Helper: Calculate Euclidean distance between two points
    func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return sqrt(dx * dx + dy * dy)
    }

    /// "The Reverse Teleport" - Pop up to the parent frame.
    /// If no parent exists, creates a new "Super Root" containing the current universe.
    ///  FIX: Uses the shared anchor instead of recomputing to prevent micro-jumps.
    func popUpToParentFrame(coord: Coordinator,
                            anchorWorld: SIMD2<Double>,
                            anchorScreen: CGPoint) {
        print("🚀 ENTER popUpToParentFrame at depth \(coord.activeFrame.depthFromRoot), zoom \(coord.zoomScale)")

        let currentFrame = coord.activeFrame

        // CREATE PARENT IF NEEDED (Telescope Out Beyond Root)
        let parent: Frame
        if let existingParent = currentFrame.parent {
            parent = existingParent
        } else {
            // Create new "Super Root" that contains the current universe
            let currentDepth = currentFrame.depthFromRoot
            let newParent = Frame(depth: currentDepth - 1)

            // Link them
            currentFrame.parent = newParent
            newParent.children.append(currentFrame)

            // Position: Center the old universe at (0,0) in the new one
            // FLOATING ORIGIN: This resets coordinates to prevent large values
            // Works for BOTH positive (drill in) and negative (telescope out) depths
            currentFrame.originInParent = .zero

            // Scale: 1000x (symmetric with drill-down)
            currentFrame.scaleRelativeToParent = 1000.0

            parent = newParent

            // Debug logging
            print("🔭 Created new parent frame (Telescope Out): depth \(currentDepth) → \(newParent.depthFromRoot), zoom \(coord.zoomScale) → will be \(coord.zoomScale * currentFrame.scaleRelativeToParent)")
        }

        // 1. Calculate new zoom in parent space
        let newZoom = coord.zoomScale * currentFrame.scaleRelativeToParent

        // 2. USE THE EXACT ANCHOR (Don't recompute from screen!)
        // This is in the active (child) frame's coordinates
        let pinchPosInChild = anchorWorld
        let currentCentroid = anchorScreen

        // 3. Convert Child Pinch Position -> Parent Pinch Position
        // Parent = Origin + (Child / Scale)
        let pinchPosInParentX = currentFrame.originInParent.x + (pinchPosInChild.x / currentFrame.scaleRelativeToParent)
        let pinchPosInParentY = currentFrame.originInParent.y + (pinchPosInChild.y / currentFrame.scaleRelativeToParent)

        // 4. Solve Pan to lock FINGER position
        let newPanOffset = solvePanOffsetForAnchor_Double(
            anchorWorld: SIMD2<Double>(pinchPosInParentX, pinchPosInParentY),
            desiredScreen: currentCentroid,
            viewSize: bounds.size,
            zoomScale: newZoom,
            rotationAngle: coord.rotationAngle
        )

        // 5. THE HANDOFF - Switch to parent
        let oldDepth = currentFrame.depthFromRoot
        coord.activeFrame = parent
        coord.zoomScale = newZoom
        coord.panOffset = newPanOffset
        let newDepth = coord.activeFrame.depthFromRoot

        print("🔭 Completed telescope out transition: depth \(oldDepth) → \(newDepth), zoom now \(newZoom)")

        // 6. RE-ANCHOR GESTURES (update with new coordinate system)
        if activeOwner != .none {
            self.anchorWorld = screenToWorldPixels_PureDouble(
                currentCentroid,
                viewSize: bounds.size,
                panOffset: coord.panOffset,
                zoomScale: coord.zoomScale,
                rotationAngle: coord.rotationAngle
            )
            self.anchorScreen = currentCentroid
        }

        print("🏁 EXIT popUpToParentFrame at depth \(coord.activeFrame.depthFromRoot), zoom \(coord.zoomScale)")
    }

    /// Helper: Calculate the depth of a frame relative to root
    /// Returns how far up the tree we've traversed (can be negative if above root)
    func frameDepth(_ frame: Frame) -> Int {
        // Just count total parents for now - positive means "above original root"
        var depth = 0
        var current: Frame? = frame
        while current?.parent != nil {
            depth += 1
            current = current?.parent
        }
        return depth
    }

    /// Helper: Calculate absolute depth (distance from rootFrame)
    /// Positive = drilled down (child of root), Negative = telescoped out (parent of root)
    func relativeDepth(frame: Frame, root: Frame) -> Int {
        if frame === root {
            return 0
        }

        // Check if frame is below root (child)
        var current: Frame? = frame
        var tempDepth = 0
        while let parent = current?.parent {
            tempDepth += 1
            if parent === root {
                return tempDepth  // Positive depth
            }
            current = parent
        }

        // Check if frame is above root (parent)
        current = root
        tempDepth = 0
        while let parent = current?.parent {
            tempDepth -= 1
            if parent === frame {
                return tempDepth  // Negative depth
            }
            current = parent
        }

        return 0  // Shouldn't reach here
    }
    */

    // MARK: - 5x5 Fractal Grid Transitions

    /// Wrap the active frame so `anchorWorld` stays within the current frame bounds.
    /// This enables infinite panning without coordinate growth.
    @discardableResult
    private func wrapFractalIfNeeded(coord: Coordinator,
                                     anchorWorld: SIMD2<Double>,
                                     anchorScreen: CGPoint) -> SIMD2<Double> {
        coord.ensureFractalExtent(viewSize: bounds.size)
        let extent = coord.fractalFrameExtent
        let half = extent * 0.5

        var anchor = anchorWorld
        var moved = false

        while anchor.x > half.x {
            coord.activeFrame = coord.neighborFrame(from: coord.activeFrame, direction: .right)
            anchor.x -= extent.x
            moved = true
        }
        while anchor.x < -half.x {
            coord.activeFrame = coord.neighborFrame(from: coord.activeFrame, direction: .left)
            anchor.x += extent.x
            moved = true
        }
        while anchor.y > half.y {
            coord.activeFrame = coord.neighborFrame(from: coord.activeFrame, direction: .down)
            anchor.y -= extent.y
            moved = true
        }
        while anchor.y < -half.y {
            coord.activeFrame = coord.neighborFrame(from: coord.activeFrame, direction: .up)
            anchor.y += extent.y
            moved = true
        }

        if moved {
            coord.panOffset = solvePanOffsetForAnchor_Double(
                anchorWorld: anchor,
                desiredScreen: anchorScreen,
                viewSize: bounds.size,
                zoomScale: coord.zoomScale,
                rotationAngle: coord.rotationAngle
            )
        }

        return anchor
    }

    /// Check if zoom has exceeded fractal thresholds and transition frames if needed.
    /// Returns TRUE if a transition occurred (caller should return early).
    func checkFractalTransitions(coord: Coordinator,
                                 anchorWorld: SIMD2<Double>,
                                 anchorScreen: CGPoint) -> Bool {
        coord.ensureFractalExtent(viewSize: bounds.size)

        let beforeWrapFrame = coord.activeFrame
        var anchor = wrapFractalIfNeeded(coord: coord, anchorWorld: anchorWorld, anchorScreen: anchorScreen)
        // Treat same-depth wrapping as a "transition" so the caller doesn't overwrite the solved panOffset.
        var transitioned = (coord.activeFrame !== beforeWrapFrame)

        // Drill down while zoom is large (normalize zoom back into [1, 5)).
        while coord.zoomScale >= FractalGrid.scale {
            anchor = drillDownToChildTile(coord: coord, anchorWorld: anchor, anchorScreen: anchorScreen)
            transitioned = true
        }

        // Pop up while zoom is too small (normalize zoom back into [1, 5)).
        while coord.zoomScale < 1.0 {
            anchor = popUpToParentTile(coord: coord, anchorWorld: anchor, anchorScreen: anchorScreen)
            transitioned = true
        }

        // Ensure the anchor remains in-bounds after transitions.
        let beforeFinalWrapFrame = coord.activeFrame
        anchor = wrapFractalIfNeeded(coord: coord, anchorWorld: anchor, anchorScreen: anchorScreen)
        if coord.activeFrame !== beforeFinalWrapFrame {
            transitioned = true
        }

        if transitioned {
            // Keep the gesture anchor consistent with the new active frame.
            self.anchorWorld = screenToWorldPixels_PureDouble(
                anchorScreen,
                viewSize: bounds.size,
                panOffset: coord.panOffset,
                zoomScale: coord.zoomScale,
                rotationAngle: coord.rotationAngle
            )
            self.anchorScreen = anchorScreen
        }

        return transitioned
    }

    /// Drill down into the child tile containing `anchorWorld`.
    private func drillDownToChildTile(coord: Coordinator,
                                      anchorWorld: SIMD2<Double>,
                                      anchorScreen: CGPoint) -> SIMD2<Double> {
        let extent = coord.fractalFrameExtent
        let index = FractalGrid.childIndex(frameExtent: extent, pointInParent: anchorWorld)

        let child = coord.activeFrame.child(at: index)
        let childCenter = FractalGrid.childCenterInParent(frameExtent: extent, index: index)
        let anchorInChild = (anchorWorld - childCenter) * FractalGrid.scale

        coord.activeFrame = child
        coord.zoomScale = coord.zoomScale / FractalGrid.scale
        coord.panOffset = solvePanOffsetForAnchor_Double(
            anchorWorld: anchorInChild,
            desiredScreen: anchorScreen,
            viewSize: bounds.size,
            zoomScale: coord.zoomScale,
            rotationAngle: coord.rotationAngle
        )

        return anchorInChild
    }

    /// Pop up to the parent frame, creating a super-root if needed.
    private func popUpToParentTile(coord: Coordinator,
                                   anchorWorld: SIMD2<Double>,
                                   anchorScreen: CGPoint) -> SIMD2<Double> {
        let extent = coord.fractalFrameExtent

        let child = coord.activeFrame
        if child.parent == nil {
            _ = coord.ensureSuperRootRetained(for: child)
        }

        guard let parent = child.parent, let index = child.indexInParent else {
            return anchorWorld
        }

        let childCenter = FractalGrid.childCenterInParent(frameExtent: extent, index: index)
        let anchorInParent = childCenter + (anchorWorld / FractalGrid.scale)

        coord.activeFrame = parent
        coord.zoomScale = coord.zoomScale * FractalGrid.scale
        coord.panOffset = solvePanOffsetForAnchor_Double(
            anchorWorld: anchorInParent,
            desiredScreen: anchorScreen,
            viewSize: bounds.size,
            zoomScale: coord.zoomScale,
            rotationAngle: coord.rotationAngle
        )

        return anchorInParent
    }




    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setupGestures()
    }
    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }

    func setupGestures() {
        //  MODAL INPUT: PAN (Finger Only - 1 finger for card drag/canvas pan)
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 1
        // Crucial: Ignore Apple Pencil for panning/dragging.
        // On Mac Catalyst, prefer two-finger trackpad scrolling for panning so click-drag can be used for drawing.
        if isRunningOnMac {
            panGesture.allowedTouchTypes = []
            if #available(iOS 13.4, macCatalyst 13.4, *) {
                panGesture.allowedScrollTypesMask = [.continuous, .discrete]
            }
        } else {
            panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
        addGestureRecognizer(panGesture)

        //  MODAL INPUT: TAP (Finger Only - Select/Edit Cards)
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        if isRunningOnMac {
            var tapTouchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            if #available(iOS 13.4, macCatalyst 13.4, *) {
                tapTouchTypes.append(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue))
            }
            tapGesture.allowedTouchTypes = tapTouchTypes
        } else {
            tapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
        addGestureRecognizer(tapGesture)

        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchGesture)

        rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        addGestureRecognizer(rotationGesture)

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.numberOfTouchesRequired = 2
        addGestureRecognizer(longPressGesture)

        // Single-finger long press for card settings
        cardLongPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleCardLongPress(_:)))
        cardLongPressGesture.minimumPressDuration = 0.5
        cardLongPressGesture.numberOfTouchesRequired = 1
        if isRunningOnMac {
            var longPressTouchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            if #available(iOS 13.4, macCatalyst 13.4, *) {
                longPressTouchTypes.append(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue))
            }
            cardLongPressGesture.allowedTouchTypes = longPressTouchTypes
        } else {
            cardLongPressGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)] // Finger only
        }
        addGestureRecognizer(cardLongPressGesture)

        panGesture.delegate = self
        tapGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self
        longPressGesture.delegate = self
        cardLongPressGesture.delegate = self

        // Setup Debug HUD
        setupDebugHUD()

        // Apple Pencil Pro squeeze (iOS 17.5+)
        setupPencilInteractionIfAvailable()
    }

    private func setupPencilInteractionIfAvailable() {
        guard !isRunningOnMac else { return }
        guard #available(iOS 17.5, *) else { return }
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        addInteraction(interaction)
        pencilInteraction = interaction
    }

    func setupDebugHUD() {
        debugLabel = UILabel()
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        debugLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        debugLabel.textColor = .white
        debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        debugLabel.numberOfLines = 0
        debugLabel.textAlignment = .left
        debugLabel.layer.cornerRadius = 8
        debugLabel.layer.masksToBounds = true
        debugLabel.text = "Frame: 0 | Zoom: 1.0×"
        debugLabel.isUserInteractionEnabled = false

        // Add padding to the label
        debugLabel.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        addSubview(debugLabel)

        // Position in top-left corner with padding
        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            debugLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16)
        ])
    }

    private func setupLinkSelectionOverlay() {
        guard linkHandleView == nil else { return }

        func makeHandleView() -> UIView {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: linkHandleTouchSize, height: linkHandleTouchSize))
            container.backgroundColor = .clear
            container.isHidden = true

            /*
            // Legacy handle: circle (reference only)
            let circleOrigin = (linkHandleTouchSize - linkHandleVisibleSize) * 0.5
            let circle = UIView(frame: CGRect(x: circleOrigin, y: circleOrigin, width: linkHandleVisibleSize, height: linkHandleVisibleSize))
            circle.backgroundColor = UIColor.white.withAlphaComponent(0.95)
            circle.layer.cornerRadius = linkHandleVisibleSize * 0.5
            circle.layer.borderWidth = 2.0
            circle.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.9).cgColor
            circle.isUserInteractionEnabled = false
            container.addSubview(circle)
            */

            let lineX = (linkHandleTouchSize - linkHandleLineWidth) * 0.5
            let line = UIView(frame: CGRect(x: lineX, y: 0, width: linkHandleLineWidth, height: container.bounds.height))
            line.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.95)
            line.layer.cornerRadius = linkHandleLineWidth * 0.5
            line.layer.borderWidth = 1.0
            line.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
            line.autoresizingMask = [.flexibleHeight, .flexibleLeftMargin, .flexibleRightMargin]
            line.isUserInteractionEnabled = false
            container.addSubview(line)
            linkHandleLineView = line

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLinkHandlePan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            if isRunningOnMac {
                var touchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                if #available(iOS 13.4, macCatalyst 13.4, *) {
                    touchTypes.append(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue))
                }
                pan.allowedTouchTypes = touchTypes
            } else {
                pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            }
            container.addGestureRecognizer(pan)
            linkHandlePan = pan

            return container
        }

        let handle = makeHandleView()
        addSubview(handle)
        linkHandleView = handle
    }

    func updateLinkSelectionOverlay() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateLinkSelectionOverlay()
            }
            return
        }

        guard let coord = coordinator else { return }
        guard let selection = coord.linkSelection else {
            hideLinkSelectionOverlay()
            return
        }

        setupLinkSelectionOverlay()
        guard let handleView = linkHandleView else { return }

        let anchorRectActive = coord.linkSelectionBoundsActiveWorld()
        let anchor: CGRect

        if let rect = anchorRectActive, rect != .null, rect.width.isFinite, rect.height.isFinite {
            let a0 = SIMD2<Double>(rect.maxX, rect.minY)
            let a1 = SIMD2<Double>(rect.maxX, rect.maxY)

            let p0 = worldToScreenPixels_PureDouble(a0,
                                                    viewSize: bounds.size,
                                                    panOffset: coord.panOffset,
                                                    zoomScale: coord.zoomScale,
                                                    rotationAngle: coord.rotationAngle)
            let p1 = worldToScreenPixels_PureDouble(a1,
                                                    viewSize: bounds.size,
                                                    panOffset: coord.panOffset,
                                                    zoomScale: coord.zoomScale,
                                                    rotationAngle: coord.rotationAngle)

            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let length = max(hypot(dx, dy), 1.0)
            // Our handle "cursor" is authored vertical (along +Y). Rotate so its Y-axis aligns with p0→p1.
            let angle = atan2(dy, dx) - (.pi / 2.0)

            let mid = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
            handleView.transform = .identity
            handleView.bounds = CGRect(x: 0, y: 0, width: linkHandleTouchSize, height: length)
            handleView.center = mid
            handleView.transform = CGAffineTransform(rotationAngle: angle)
            handleView.isHidden = false
            bringSubviewToFront(handleView)

            anchor = CGRect(x: mid.x - 2, y: mid.y - 2, width: 4, height: 4)
        } else {
            let handleScreen = worldToScreenPixels_PureDouble(selection.handleActiveWorld,
                                                              viewSize: bounds.size,
                                                              panOffset: coord.panOffset,
                                                              zoomScale: coord.zoomScale,
                                                              rotationAngle: coord.rotationAngle)
            handleView.transform = .identity
            handleView.bounds = CGRect(x: 0, y: 0, width: linkHandleTouchSize, height: linkHandleTouchSize)
            handleView.center = handleScreen
            handleView.isHidden = false
            bringSubviewToFront(handleView)
            anchor = CGRect(x: handleScreen.x - 2, y: handleScreen.y - 2, width: 4, height: 4)
        }

        if coord.isDraggingLinkHandle {
            hideLinkMenu()
            lastLinkMenuAnchorRect = .null
        } else {
            showLinkMenuIfNeeded(anchorRect: anchor)
        }
    }

    func updateSectionNameEditorOverlay() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateSectionNameEditorOverlay()
            }
            return
        }

        guard let coord = coordinator else { return }
        guard let field = sectionNameTextField,
              let section = sectionNameEditingTarget,
              let frame = sectionNameEditingFrame else { return }

        guard let rect = coord.sectionLabelScreenRect(section: section,
                                                      frame: frame,
                                                      viewSize: bounds.size,
                                                      ignoreHideRule: true) else { return }

        if field.frame != rect {
            field.frame = rect
        }
        bringSubviewToFront(field)
    }

    func updateCardNameEditorOverlay() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateCardNameEditorOverlay()
            }
            return
        }

        guard let coord = coordinator else { return }
        guard let field = cardNameTextField,
              let card = cardNameEditingTarget,
              let frame = cardNameEditingFrame else { return }

        guard let rect = coord.cardLabelScreenRect(card: card,
                                                   frame: frame,
                                                   viewSize: bounds.size,
                                                   ignoreHideRule: true) else { return }

        if field.frame != rect {
            field.frame = rect
        }
        bringSubviewToFront(field)
    }

    func updateYouTubeOverlay() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateYouTubeOverlay()
            }
            return
        }

        guard let coord = coordinator else { return }
        #if canImport(YouTubePlayerKit)
        guard let hostingView = youtubeHostingView else { return }
        guard let card = youtubeCardTarget,
              let frame = youtubeCardFrame else {
            deactivateYouTubeOverlay()
            return
        }
        #else
        guard let webView = youtubeWebView else { return }
        guard let card = youtubeCardTarget,
              let frame = youtubeCardFrame else {
            deactivateYouTubeOverlay()
            return
        }
        guard webView.superview != nil else { return }
        #endif

        guard case .youtube(let videoID, _) = card.type, !videoID.isEmpty else {
            deactivateYouTubeOverlay()
            return
        }

        if youtubeLoadedVideoID != videoID {
            setYouTubeVideo(videoID: videoID)
        }

        guard let placement = coord.cardScreenTransform(card: card, frame: frame, viewSize: bounds.size) else {
            // Keep the player alive; just hide the overlay until the target card is visible again.
            #if canImport(YouTubePlayerKit)
            hostingView.isHidden = true
            #else
            webView.isHidden = true
            #endif
            return
        }

        let size = placement.size
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else {
            #if canImport(YouTubePlayerKit)
            hostingView.isHidden = true
            #else
            webView.isHidden = true
            #endif
            return
        }

        let desiredCenter = placement.center
        let desiredSize = size
        let desiredRotation = placement.rotation

        let shouldUpdateFrame: Bool = {
            guard let lastCenter = youtubeOverlayLastCenter,
                  let lastSize = youtubeOverlayLastSize,
                  let lastRotation = youtubeOverlayLastRotation else {
                return true
            }
            let centerDelta = abs(desiredCenter.x - lastCenter.x) + abs(desiredCenter.y - lastCenter.y)
            let sizeDelta = abs(desiredSize.width - lastSize.width) + abs(desiredSize.height - lastSize.height)
            let rotationDelta = abs(desiredRotation - lastRotation)
            return centerDelta > 0.5 || sizeDelta > 0.5 || rotationDelta > 0.002
        }()

        #if canImport(YouTubePlayerKit)
        hostingView.isHidden = false
        if shouldUpdateFrame {
            hostingView.transform = .identity
            hostingView.bounds = CGRect(x: 0, y: 0, width: desiredSize.width, height: desiredSize.height)
            hostingView.center = desiredCenter
            hostingView.transform = CGAffineTransform(rotationAngle: desiredRotation)
            hostingView.layoutIfNeeded()
            youtubeOverlayLastCenter = desiredCenter
            youtubeOverlayLastSize = desiredSize
            youtubeOverlayLastRotation = desiredRotation
        }
        bringSubviewToFront(hostingView)
        #else
        webView.isHidden = false
        if shouldUpdateFrame {
            webView.transform = .identity
            webView.bounds = CGRect(x: 0, y: 0, width: desiredSize.width, height: desiredSize.height)
            webView.center = desiredCenter
            webView.transform = CGAffineTransform(rotationAngle: desiredRotation)
            youtubeOverlayLastCenter = desiredCenter
            youtubeOverlayLastSize = desiredSize
            youtubeOverlayLastRotation = desiredRotation
        }
        bringSubviewToFront(webView)
        #endif
    }

    func youtubeHUDText() -> String {
        #if canImport(YouTubePlayerKit)
        let activeVideoID: String = {
            guard let card = youtubeCardTarget, case .youtube(let id, _) = card.type else { return "-" }
            return id
        }()
        let state = youtubePlayer.map { String(describing: $0.state) } ?? "nil"
        let originHost = youtubePlayer?.parameters.originURL?.host ?? "nil"
        let err = youtubeLastErrorSummary ?? "ok"
        return "YT: \(activeVideoID) | \(state) | origin: \(originHost) | \(err)"
        #else
        let activeVideoID: String = {
            guard let card = youtubeCardTarget, case .youtube(let id, _) = card.type else { return "-" }
            return id
        }()
        return "YT: \(activeVideoID) | WKWebView"
        #endif
    }

    private func toggleYouTubeOverlay(card: Card, frame: Frame) {
        #if canImport(YouTubePlayerKit)
        let isActive = (youtubeCardTarget === card && youtubeCardFrame === frame && youtubeHostingView?.isHidden == false)
        #else
        let isActive = (youtubeCardTarget === card && youtubeCardFrame === frame && youtubeWebView?.superview != nil)
        #endif

        // A YouTube overlay should only stop when switching to a different YouTube card.
        // Tapping the active YouTube card should never stop playback.
        if !isActive {
            activateYouTubeOverlay(card: card, frame: frame)
        }
    }

    private func activateYouTubeOverlay(card: Card, frame: Frame) {
        guard case .youtube(let videoID, _) = card.type, !videoID.isEmpty else { return }

        #if canImport(YouTubePlayerKit)
        let player: YouTubePlayer = youtubePlayer ?? {
            let origin = preferredYouTubeEmbedOriginURL()
            let userAgent = preferredYouTubeUserAgentString()
            let params = YouTubePlayer.Parameters(
                showControls: true,
                showFullscreenButton: false,
                keyboardControlsDisabled: false,
                originURL: origin,
                referrerURL: nil
            )

            let config = YouTubePlayer.Configuration(
                fullscreenMode: .preferred,
                allowsInlineMediaPlayback: true,
                allowsAirPlayForMediaPlayback: true,
                allowsPictureInPictureMediaPlayback: false,
                useNonPersistentWebsiteDataStore: false,
                automaticallyAdjustsContentInsets: true,
                customUserAgent: userAgent,
                htmlBuilder: .init(),
                openURLAction: .default
            )

            let p = YouTubePlayer(
                source: .video(id: videoID),
                parameters: params,
                configuration: config,
                isLoggingEnabled: false
            )
            #if DEBUG
            p.isLoggingEnabled = true
            #endif

            youtubeEventCancellable = p.eventPublisher.sink { [weak self] event in
                guard let self else { return }
                switch event.name {
                case .error:
                    let payload = event.data?.value ?? "nil"
                    self.youtubeLastErrorSummary = "YT onError(\(payload))"
                case .iFrameApiFailedToLoad:
                    self.youtubeLastErrorSummary = "YT iFrameApiFailedToLoad"
                default:
                    break
                }
            }

            youtubeStateCancellable = p.statePublisher.sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let pending = self.youtubePendingVideoID else { return }
                    self.youtubePendingVideoID = nil
                    self.setYouTubeVideo(videoID: pending)
                case .error(let error):
                    self.youtubeLastErrorSummary = "YT stateError(\(error))"
                case .idle:
                    break
                }
            }

            youtubePlayer = p
            return p
        }()

        let hostingView: YouTubePlayerHostingView = youtubeHostingView ?? {
            let view = YouTubePlayerHostingView(player: player)
            view.backgroundColor = .clear
            view.isOpaque = false
            view.layer.cornerRadius = 12.0
            view.layer.masksToBounds = true
            view.isHidden = true
            addSubview(view)
            youtubeHostingView = view
            return view
        }()

        youtubeCardTarget = card
        youtubeCardFrame = frame

        hostingView.isHidden = false

        youtubeLoadedVideoID = nil
        youtubeLastErrorSummary = nil
        setYouTubeVideo(videoID: videoID)
        updateYouTubeOverlay()
        #else
        let webView: WKWebView = youtubeWebView ?? {
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = false
            configuration.mediaTypesRequiringUserActionForPlayback = []
            if #available(iOS 14.0, *) {
                configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            } else {
                configuration.preferences.javaScriptEnabled = true
            }

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.layer.cornerRadius = 12.0
            webView.layer.masksToBounds = true
            return webView
        }()

        if webView.superview == nil {
            addSubview(webView)
        }

        youtubeWebView = webView
        youtubeCardTarget = card
        youtubeCardFrame = frame

        youtubeLoadedVideoID = nil
        setYouTubeVideo(videoID: videoID)
        updateYouTubeOverlay()
        #endif
    }

    #if canImport(YouTubePlayerKit)
    private func preferredYouTubeEmbedOriginURL() -> URL? {
        if let bundleID = Bundle.main.bundleIdentifier?.lowercased(), !bundleID.isEmpty {
            // Use a stable-looking https origin with a real TLD to satisfy embed identity checks.
            // Bundle IDs aren't valid TLDs; convert to a single DNS label and append `.app`.
            let label = bundleID
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "_", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

            if !label.isEmpty {
                return URL(string: "https://\(label).app")
            }
        }
        return URL(string: "https://example.com")
    }

    private func preferredYouTubeUserAgentString() -> String? {
        // YouTube sometimes blocks playback in "webview" user agents. Provide a Safari-like UA.
        #if targetEnvironment(macCatalyst)
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        #else
        return "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        #endif
    }
    #endif

    private func deactivateYouTubeOverlay() {
        youtubeCardTarget = nil
        youtubeCardFrame = nil
        youtubeLoadedVideoID = nil
        youtubeOverlayLastCenter = nil
        youtubeOverlayLastSize = nil
        youtubeOverlayLastRotation = nil
        #if canImport(YouTubePlayerKit)
        youtubePendingVideoID = nil
        youtubeHostingView?.isHidden = true
        if let player = youtubePlayer {
            Task { [weak player] in
                try? await player?.pause()
            }
        }
        #else
        youtubeWebView?.stopLoading()
        youtubeWebView?.removeFromSuperview()
        #endif
    }

    private func setYouTubeVideo(videoID: String) {
        guard !videoID.isEmpty else { return }
        guard youtubeLoadedVideoID != videoID else { return }
        youtubeLoadedVideoID = videoID

        #if canImport(YouTubePlayerKit)
        guard let player = youtubePlayer else { return }

        let currentID = player.source?.videoID
        if currentID == videoID {
            return
        }

        if case .ready = player.state {
            Task { [weak player] in
                guard let player else { return }
                try? await player.load(source: .video(id: videoID))
            }
        } else {
            youtubePendingVideoID = videoID
        }
        #else
        guard let webView = youtubeWebView else { return }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "controls", value: "1"),
            URLQueryItem(name: "fs", value: "0"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
        ]

        guard let url = components.url else { return }
        webView.load(URLRequest(url: url))
        #endif
    }

    func deactivateYouTubeOverlayIfTarget(card: Card) {
        if youtubeCardTarget === card {
            deactivateYouTubeOverlay()
        }
    }

    private func beginEditingSectionName(section: Section, frame: Frame) {
        guard let coord = coordinator else { return }

        // Ensure only one inline editor is active.
        if cardNameTextField != nil {
            commitAndEndCardNameEditing()
        }

        // Ensure we have an accurate label size for placement + the initial editor frame.
        section.ensureLabelTexture(device: coord.device)

        let field: UITextField = {
            if let existing = sectionNameTextField { return existing }
            let f = UITextField(frame: .zero)
            f.borderStyle = .none
            f.textAlignment = .left
            f.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            f.textColor = .black
            f.autocapitalizationType = .sentences
            f.autocorrectionType = .yes
            f.spellCheckingType = .yes
            f.keyboardType = .default
            f.returnKeyType = .done
            f.enablesReturnKeyAutomatically = false
            f.clearButtonMode = .whileEditing
            f.layer.cornerRadius = 8.0
            f.layer.masksToBounds = true
            f.delegate = self

            let padX: CGFloat = 10.0
            let leftPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
            let rightPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
            f.leftView = leftPad
            f.leftViewMode = .always
            f.rightView = rightPad
            f.rightViewMode = .always

            addSubview(f)
            sectionNameTextField = f
            return f
        }()

        let bg = UIColor(red: CGFloat(section.color.x),
                         green: CGFloat(section.color.y),
                         blue: CGFloat(section.color.z),
                         alpha: 1.0)
        field.backgroundColor = bg

        sectionNameEditingTarget = section
        sectionNameEditingFrame = frame
        field.text = section.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : section.name

        updateSectionNameEditorOverlay()
        field.isHidden = false
        bringSubviewToFront(field)
        field.becomeFirstResponder()
    }

    private func commitAndEndSectionNameEditing() {
        guard let field = sectionNameTextField else { return }
        guard let section = sectionNameEditingTarget else {
            field.resignFirstResponder()
            field.removeFromSuperview()
            sectionNameTextField = nil
            sectionNameEditingFrame = nil
            return
        }

        let trimmed = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        section.name = trimmed.isEmpty ? "Untitled" : trimmed

        // Force a label texture rebuild with the updated name.
        section.labelTexture = nil
        section.labelWorldSize = .zero
        if let coord = coordinator {
            section.ensureLabelTexture(device: coord.device)
            coord.refreshInternalLinkReferenceCache()
        }

        field.resignFirstResponder()
        field.removeFromSuperview()
        sectionNameTextField = nil
        sectionNameEditingTarget = nil
        sectionNameEditingFrame = nil
    }

    private func beginEditingCardName(card: Card, frame: Frame) {
        guard let coord = coordinator else { return }

        // Ensure only one inline editor is active.
        if sectionNameTextField != nil {
            commitAndEndSectionNameEditing()
        }

        card.ensureLabelTexture(device: coord.device)

        let field: UITextField = {
            if let existing = cardNameTextField { return existing }
            let f = UITextField(frame: .zero)
            f.borderStyle = .none
            f.textAlignment = .left
            f.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            f.autocapitalizationType = .sentences
            f.autocorrectionType = .yes
            f.spellCheckingType = .yes
            f.keyboardType = .default
            f.returnKeyType = .done
            f.enablesReturnKeyAutomatically = false
            f.clearButtonMode = .whileEditing
            f.layer.cornerRadius = 8.0
            f.layer.masksToBounds = true
            f.delegate = self

            let padX: CGFloat = 10.0
            let leftPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
            let rightPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
            f.leftView = leftPad
            f.leftViewMode = .always
            f.rightView = rightPad
            f.rightViewMode = .always

            addSubview(f)
            cardNameTextField = f
            return f
        }()

        let bg = UIColor(red: CGFloat(card.backgroundColor.x),
                         green: CGFloat(card.backgroundColor.y),
                         blue: CGFloat(card.backgroundColor.z),
                         alpha: 1.0)
        field.backgroundColor = bg

        let lum = 0.2126 * Double(card.backgroundColor.x) +
        0.7152 * Double(card.backgroundColor.y) +
        0.0722 * Double(card.backgroundColor.z)
        let textColor: UIColor = lum > 0.6 ? .black : .white
        field.textColor = textColor
        field.tintColor = textColor

        cardNameEditingTarget = card
        cardNameEditingFrame = frame
        field.text = card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : card.name

        updateCardNameEditorOverlay()
        field.isHidden = false
        bringSubviewToFront(field)
        field.becomeFirstResponder()
    }

    private func commitAndEndCardNameEditing() {
        guard let field = cardNameTextField else { return }
        guard let card = cardNameEditingTarget else {
            field.resignFirstResponder()
            field.removeFromSuperview()
            cardNameTextField = nil
            cardNameEditingFrame = nil
            return
        }

        let trimmed = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        card.name = trimmed.isEmpty ? "Untitled" : trimmed
        if let coord = coordinator {
            card.ensureLabelTexture(device: coord.device)
            coord.refreshInternalLinkReferenceCache()
        }

        field.resignFirstResponder()
        field.removeFromSuperview()
        cardNameTextField = nil
        cardNameEditingTarget = nil
        cardNameEditingFrame = nil
    }

    private func hideLinkSelectionOverlay() {
        linkHandleView?.isHidden = true
        if !isShowingRemoveHighlightMenu && !isShowingLassoSectionMenu {
            hideLinkMenu()
            lastLinkMenuAnchorRect = .null
        }
    }

	    private func showLinkMenuIfNeeded(anchorRect: CGRect) {
	        guard let coord = coordinator else { return }
	        guard coord.linkSelection != nil else { return }
	        guard !coord.isDraggingLinkHandle else { return }
	        guard !isPresentingLinkPrompt else { return }
	        guard !isPresentingInternalLinkPicker else { return }
	        guard !isShowingLassoSectionMenu else { return }
	        guard !isShowingSectionColorMenu else { return }

	        let menu = UIMenuController.shared
	        if isShowingRemoveHighlightMenu, !menu.isMenuVisible {
	            isShowingRemoveHighlightMenu = false
	            removeHighlightMenuKey = nil
	        }
	        guard !isShowingRemoveHighlightMenu else { return }
	        if isShowingSectionColorMenu, !menu.isMenuVisible {
	            isShowingSectionColorMenu = false
	            sectionColorMenuTarget = nil
	        }
	        if !anchorRect.isNull, !anchorRect.isInfinite {
	            // Avoid re-showing the menu every frame unless the anchor moved meaningfully.
	            let delta = abs(anchorRect.midX - lastLinkMenuAnchorRect.midX) + abs(anchorRect.midY - lastLinkMenuAnchorRect.midY)
	            if !lastLinkMenuAnchorRect.isNull, delta < 8.0, menu.isMenuVisible {
                return
            }
        }

        becomeFirstResponder()
        menu.menuItems = [
            UIMenuItem(title: "Add Link", action: #selector(addLinkMenuItem(_:))),
            UIMenuItem(title: "Link", action: #selector(addInternalLinkMenuItem(_:)))
        ]
        menu.showMenu(from: self, rect: anchorRect)
        lastLinkMenuAnchorRect = anchorRect
    }

    private func hideLinkMenu() {
        let menu = UIMenuController.shared
        if menu.isMenuVisible {
            menu.setMenuVisible(false, animated: true)
        }
    }

    // MARK: - Section Creation Menu (Lasso → Create Section)

	    func showLassoSectionMenuIfNeeded(anchorRect: CGRect) {
	        guard let coord = coordinator else { return }
	        guard let selection = coord.lassoSelection, selection.cardStrokes.isEmpty else { return }
	        guard !isShowingSectionColorMenu else { return }

	        let menu = UIMenuController.shared

	        if !anchorRect.isNull, !anchorRect.isInfinite {
            let delta = abs(anchorRect.midX - lastLassoMenuAnchorRect.midX) + abs(anchorRect.midY - lastLassoMenuAnchorRect.midY)
            if !lastLassoMenuAnchorRect.isNull, delta < 8.0, menu.isMenuVisible {
                return
            }
        }

        // Ensure link menus don't fight this.
        isShowingRemoveHighlightMenu = false
        removeHighlightMenuKey = nil
        lastLinkMenuAnchorRect = .null

	        isShowingLassoSectionMenu = true
	        becomeFirstResponder()
	        menu.menuItems = [
	            UIMenuItem(title: "Create Section", action: #selector(createSectionMenuItem(_:)))
	        ]
	        menu.showMenu(from: self, rect: anchorRect)
	        lastLassoMenuAnchorRect = anchorRect
	    }

    private func hideLassoSectionMenu() {
        isShowingLassoSectionMenu = false
        lastLassoMenuAnchorRect = .null
        hideLinkMenu()
    }

    private func showRemoveHighlightMenuIfNeeded(key: Coordinator.LinkHighlightKey, anchorRect: CGRect) {
        guard !isPresentingLinkPrompt else { return }
        guard !isPresentingInternalLinkPicker else { return }

        isShowingRemoveHighlightMenu = true
        removeHighlightMenuKey = key

        // Hide any existing link menu state so it doesn't fight this menu.
        lastLinkMenuAnchorRect = .null

        becomeFirstResponder()
        let menu = UIMenuController.shared
        menu.menuItems = [
            UIMenuItem(title: "Remove Highlight", action: #selector(removeHighlightMenuItem(_:)))
        ]
        menu.showMenu(from: self, rect: anchorRect)
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

	    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
	        if action == #selector(addLinkMenuItem(_:)) {
	            return coordinator?.linkSelection != nil && coordinator?.isDraggingLinkHandle == false
	        }
	        if action == #selector(addInternalLinkMenuItem(_:)) {
            return coordinator?.linkSelection != nil && coordinator?.isDraggingLinkHandle == false
        }
        if action == #selector(removeHighlightMenuItem(_:)) {
            return removeHighlightMenuKey != nil &&
                isPresentingLinkPrompt == false &&
                isPresentingInternalLinkPicker == false
        }
	        if action == #selector(createSectionMenuItem(_:)) {
	            guard let selection = coordinator?.lassoSelection else { return false }
	            return selection.cardStrokes.isEmpty
	        }
        if action == #selector(setSectionColor0MenuItem(_:)) ||
            action == #selector(setSectionColor1MenuItem(_:)) ||
            action == #selector(setSectionColor2MenuItem(_:)) ||
            action == #selector(setSectionColor3MenuItem(_:)) ||
            action == #selector(setSectionColor4MenuItem(_:)) ||
            action == #selector(setSectionColor5MenuItem(_:)) ||
            action == #selector(renameSectionMenuItem(_:)) ||
            action == #selector(deleteSectionMenuItem(_:)) {
            return isShowingSectionColorMenu && sectionColorMenuTarget != nil
        }
        return super.canPerformAction(action, withSender: sender)
	    }

    @objc private func addLinkMenuItem(_ sender: Any?) {
        presentAddLinkPrompt()
    }

    @objc private func addInternalLinkMenuItem(_ sender: Any?) {
        presentInternalLinkPicker()
    }

    @objc private func removeHighlightMenuItem(_ sender: Any?) {
        guard let key = removeHighlightMenuKey else { return }
        coordinator?.removeHighlightSection(key)
        removeHighlightMenuKey = nil
        isShowingRemoveHighlightMenu = false
        hideLinkMenu()
    }

		    @objc private func createSectionMenuItem(_ sender: Any?) {
		        guard let coord = coordinator else { return }
		        guard let selection = coord.lassoSelection, selection.cardStrokes.isEmpty else { return }

		        _ = selection
		        hideLassoSectionMenu()

		        let randomColor = Self.sectionColorPalette.randomElement()?.color ?? SIMD4<Float>(1.0, 0.90, 0.20, 1.0)
		        coord.createSectionFromLasso(name: "", color: randomColor)
		        ignoreTapsUntilTime = CACurrentMediaTime() + 0.25
		    }

    private func showSectionColorMenuIfNeeded(section: Section, anchorRect: CGRect) {
        guard !isPresentingLinkPrompt else { return }
        guard !isPresentingInternalLinkPicker else { return }

        sectionColorMenuTarget = section
        ignoreTapsUntilTime = CACurrentMediaTime() + 0.3

        let colors = Self.sectionColorPalette.map { choice in
            FloatingMenuViewController.ColorOption(
                color: UIColor(
                    red: CGFloat(choice.color.x),
                    green: CGFloat(choice.color.y),
                    blue: CGFloat(choice.color.z),
                    alpha: 1.0
                ),
                simdColor: choice.color
            )
        }

        let menuItems = [
            FloatingMenuViewController.MenuItem(title: "Delete", icon: "trash", isDestructive: true) { [weak self] in
                guard let self else { return }
                self.coordinator?.deleteSection(section)
                self.sectionColorMenuTarget = nil
            }
        ]

        let menu = FloatingMenuViewController(
            colors: colors,
            menuItems: menuItems,
            onColorSelected: { [weak self] _, simdColor in
                section.color = simdColor
                section.labelTexture = nil
                self?.ignoreTapsUntilTime = CACurrentMediaTime() + 0.2
            },
            initialPickerColor: UIColor(
                red: CGFloat(section.color.x),
                green: CGFloat(section.color.y),
                blue: CGFloat(section.color.z),
                alpha: 1.0
            ),
            onDismiss: { [weak self] in
                self?.hideSectionColorMenu()
            },
            sourceRect: anchorRect,
            sourceView: self
        )

        guard let vc = nearestViewController() else { return }
        vc.present(menu, animated: true)
    }

    private func showCardMenuIfNeeded(card: Card, frame: Frame, anchorRect: CGRect) {
        cardMenuTarget = card
        cardMenuTargetFrame = frame
        ignoreTapsUntilTime = CACurrentMediaTime() + 0.3
        guard let coord = coordinator else { return }

        // Previous card menu (small + sheet-based settings) kept for reference:
        //
        // let colors = Self.cardColorPalette.map { choice in ... }
        // let menuItems = [ Settings (sheet), Lock, Delete ]
        // let menu = FloatingMenuViewController(...)
        //
        // The new card long-press uses a popover-style floating settings menu instead.
        let menu = CardSettingsFloatingMenu(
            card: card,
            shadowsEnabled: coord.cardShadowEnabled,
            onToggleShadows: { [weak coord] enabled in
                coord?.cardShadowEnabled = enabled
            },
            onDelete: { [weak self] in
                guard let self else { return }
                self.coordinator?.deleteCard(card)
                self.cardMenuTarget = nil
                self.cardMenuTargetFrame = nil
            },
            sourceRect: anchorRect,
            sourceView: self
        )

        guard let vc = nearestViewController() else { return }
        vc.present(menu, animated: true)
    }

    private func hideSectionColorMenu() {
	        isShowingSectionColorMenu = false
	        sectionColorMenuTarget = nil
	        hideLinkMenu()
	    }
	
	    private func applySectionColor(_ color: SIMD4<Float>) {
	        guard let section = sectionColorMenuTarget else { return }
	        section.color = color
	        section.labelTexture = nil
	        isShowingSectionColorMenu = false
	        sectionColorMenuTarget = nil
	        hideLinkMenu()
	        ignoreTapsUntilTime = CACurrentMediaTime() + 0.2
	    }
	
    @objc private func setSectionColor0MenuItem(_ sender: Any?) { applySectionColor(Self.sectionColorPalette[0].color) }
    @objc private func setSectionColor1MenuItem(_ sender: Any?) { applySectionColor(Self.sectionColorPalette[1].color) }
    @objc private func setSectionColor2MenuItem(_ sender: Any?) { applySectionColor(Self.sectionColorPalette[2].color) }
    @objc private func setSectionColor3MenuItem(_ sender: Any?) { applySectionColor(Self.sectionColorPalette[3].color) }
    @objc private func setSectionColor4MenuItem(_ sender: Any?) { applySectionColor(Self.sectionColorPalette[4].color) }
    @objc private func setSectionColor5MenuItem(_ sender: Any?) { applySectionColor(Self.sectionColorPalette[5].color) }

    @objc private func renameSectionMenuItem(_ sender: Any?) {
        guard let section = sectionColorMenuTarget else { return }
        hideSectionColorMenu()
        presentSectionRenamePrompt(section: section)
    }

    @objc private func deleteSectionMenuItem(_ sender: Any?) {
        guard let section = sectionColorMenuTarget else { return }
        coordinator?.deleteSection(section)
        hideSectionColorMenu()
        ignoreTapsUntilTime = CACurrentMediaTime() + 0.2
    }

    private func presentSectionRenamePrompt(section: Section) {
        hideSectionColorMenu()
        ignoreTapsUntilTime = CACurrentMediaTime() + 0.3

        let alert = UIAlertController(title: "Rename Section", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = section.name
            field.placeholder = "Section name"
            field.autocapitalizationType = .sentences
            field.autocorrectionType = .yes
            field.returnKeyType = .done
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self else { return }
            let newName = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            section.name = newName.isEmpty ? "Untitled" : newName
            section.labelTexture = nil // Force label texture regeneration
            self.coordinator?.refreshInternalLinkReferenceCache()
            self.ignoreTapsUntilTime = CACurrentMediaTime() + 0.2
        })

        guard let vc = nearestViewController() else { return }
        vc.present(alert, animated: true) {
            alert.textFields?.first?.becomeFirstResponder()
        }
    }

    @objc private func handleLinkHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard let coord = coordinator else { return }

        let loc = gesture.location(in: self)

        switch gesture.state {
        case .began:
            stopMomentum()
            coord.isDraggingLinkHandle = true
            coord.beginLinkSelectionDrag(at: loc, viewSize: bounds.size)
            hideLinkMenu()
            // Prevent canvas pan from also recognizing while dragging a handle.
            panGesture.isEnabled = false
            panGesture.isEnabled = true

        case .changed:
            coord.extendLinkSelection(to: loc, viewSize: bounds.size)
            updateLinkSelectionOverlay()

        case .ended, .cancelled, .failed:
            coord.isDraggingLinkHandle = false
            coord.snapLinkSelectionHandleToBounds()
            updateLinkSelectionOverlay()

        default:
            break
        }
    }

    private func presentAddLinkPrompt() {
        guard let coord = coordinator else { return }
        guard coord.linkSelection != nil else { return }

        isPresentingLinkPrompt = true
        hideLinkMenu()
        let anchorRect = (!lastLinkMenuAnchorRect.isNull && !lastLinkMenuAnchorRect.isInfinite)
            ? lastLinkMenuAnchorRect
            : CGRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)
        lastLinkMenuAnchorRect = .null

        let initialText: String? = {
            if let url = UIPasteboard.general.url?.absoluteString {
                return url
            }
            if let str = UIPasteboard.general.string, !str.isEmpty {
                return str
            }
            return nil
        }()

        let menu = AddLinkFloatingMenuViewController(
            initialText: initialText,
            onAdd: { [weak self] normalized in
                guard let self else { return }
                guard let coord = self.coordinator else { return }
                coord.addLinkToSelection(normalized)
                coord.snapLinkSelectionHandleToBounds()
                self.ignoreTapsUntilTime = CACurrentMediaTime() + 0.35
                self.updateLinkSelectionOverlay()
            },
            onDismiss: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.isPresentingLinkPrompt = false
                }
            },
            sourceRect: anchorRect,
            sourceView: self
        )

        guard let vc = nearestViewController() else { return }
        vc.present(menu, animated: true)
    }

    private func presentInternalLinkPicker() {
        guard let coord = coordinator else { return }
        guard coord.linkSelection != nil else { return }

        isPresentingInternalLinkPicker = true
        hideLinkMenu()
        let anchorRect = (!lastLinkMenuAnchorRect.isNull && !lastLinkMenuAnchorRect.isInfinite)
            ? lastLinkMenuAnchorRect
            : CGRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)
        lastLinkMenuAnchorRect = .null

        let destinations = coord.linkDestinationsInCanvas()
        guard !destinations.isEmpty else {
            let alert = UIAlertController(title: "No Sections or Cards",
                                          message: "Create a section or card first.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.isPresentingInternalLinkPicker = false
                }
            }))
            nearestViewController()?.present(alert, animated: true)
            return
        }

        let menu = InternalLinkPickerFloatingMenuViewController(
            destinations: destinations,
            onSelect: { [weak self] destination in
                guard let self else { return }
                guard let coord = self.coordinator else { return }
                coord.addInternalLinkToSelection(destination)
                coord.snapLinkSelectionHandleToBounds()
                self.ignoreTapsUntilTime = CACurrentMediaTime() + 0.35
                self.updateLinkSelectionOverlay()
            },
            onDismiss: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.isPresentingInternalLinkPicker = false
                }
            },
            sourceRect: anchorRect,
            sourceView: self
        )

        guard let vc = nearestViewController() else { return }
        vc.present(menu, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController {
                return vc
            }
            responder = current.next
        }
        return nil
    }

    // MARK: - Gesture Handlers

    ///  MODAL INPUT: TAP (Finger Only - Select/Deselect Cards)
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
	        if CACurrentMediaTime() < ignoreTapsUntilTime {
	            return
	        }

	        let loc = gesture.location(in: self)
	        guard let coord = coordinator else { return }

	        if let field = cardNameTextField {
	            // Tap-away commits and dismisses the inline editor.
	            if field.frame.contains(loc) {
	                return
	            }
	            commitAndEndCardNameEditing()
	            return
	        }

	        if let field = sectionNameTextField {
	            // Tap-away commits and dismisses the inline editor.
	            if field.frame.contains(loc) {
	                return
	            }
	            commitAndEndSectionNameEditing()
	            return
	        }
	
	        if isShowingSectionColorMenu {
	            hideSectionColorMenu()
	            return
	        }

        if coord.handleLassoTap(screenPoint: loc, viewSize: bounds.size) {
            if coord.lassoSelection == nil {
                hideLassoSectionMenu()
            }
            return
        }

        if coord.linkSelection != nil {
            // 1) Tap on a linked selected stroke: open it.
            if coord.openLinkIfNeeded(at: loc, viewSize: bounds.size, restrictToSelection: true) {
                return
            }

            // 2) Tap inside selection: keep selection (no side effects).
            if coord.linkSelectionContains(screenPoint: loc, viewSize: bounds.size) {
                return
            }

            // 3) Tap away: clear link selection + UI.
            coord.clearLinkSelection()
            updateLinkSelectionOverlay()
            return
        }

        // Tap on any linked stroke (when no selection is active).
        if coord.openLinkIfNeeded(at: loc, viewSize: bounds.size, restrictToSelection: false) {
            return
        }

        // Tap on card name label: inline rename.
        if let hit = coord.hitTestCardLabelHierarchy(screenPoint: loc, viewSize: bounds.size) {
            beginEditingCardName(card: hit.card, frame: hit.frame)
            return
        }

        // Use the new hierarchical hit test to find cards at any depth
        if let result = coord.hitTestHierarchy(screenPoint: loc, viewSize: bounds.size, ignoringLocked: true) {
            if case .youtube = result.card.type {
                if result.card.isEditing {
                    toggleYouTubeOverlay(card: result.card, frame: result.frame)
                } else {
                    result.card.isEditing = true
                }
            } else {
                // Toggle Edit on the card (wherever it lives - parent, active, or child)
                result.card.isEditing.toggle()
            }
            return
        }

        // Tap on section name label: inline rename.
        if let hit = coord.hitTestSectionLabelHierarchy(screenPoint: loc, viewSize: bounds.size) {
            beginEditingSectionName(section: hit.section, frame: hit.frame)
            return
        }

        // If we tapped nothing, deselect all cards (requires recursive clear)
        var topFrame = coord.activeFrame
        while let parent = topFrame.parent {
            topFrame = parent
        }
        clearSelectionRecursive(frame: topFrame)
    }

    /// Helper to clear all card selections recursively across the entire hierarchy
    func clearSelectionRecursive(frame: Frame) {
        frame.cards.forEach { $0.isEditing = false }
        for child in frame.children.values {
            clearSelectionRecursive(frame: child)
        }
    }

    ///  MODAL INPUT: PAN (Finger Only - Drag Card or Pan Canvas)
    /// Now supports cross-depth dragging with proper coordinate conversion
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        let loc = gesture.location(in: self)
        guard let coord = coordinator else { return }

        // Track drag context (card + conversion scale)
        var dragContext: DragContext? {
            get { objc_getAssociatedObject(self, &AssociatedKeys.dragContext) as? DragContext }
            set { objc_setAssociatedObject(self, &AssociatedKeys.dragContext, newValue, .OBJC_ASSOCIATION_RETAIN) }
        }

        switch gesture.state {
        case .began:
            // Stop any ongoing momentum
            stopMomentum()

            lassoDragActive = false
            if coord.lassoContains(screenPoint: loc, viewSize: bounds.size) {
                lassoDragActive = true
                hideLassoSectionMenu()
                dragContext = nil
                // TODO: Capture lasso state for undo
                return
            }
            // Hit test hierarchy to find card AND its coordinate scale
            if let result = coord.hitTestHierarchy(screenPoint: loc, viewSize: bounds.size, ignoringLocked: true) {
                if result.card.isEditing, !result.card.isLocked {
                    // Get zoom level in the target frame
                    let zoomInFrame = coord.zoomScale / result.conversionScale

                    // Check if touch is on handle vs card body
                    // result.pointInFrame is already in the correct frame's coordinates
                    let isOnHandle = coord.isPointOnCardHandle(result.pointInFrame, card: result.card, zoom: zoomInFrame)

                    // Store Card + Scale Factor + Resize Mode
                    dragContext = DragContext(card: result.card, frame: result.frame, conversionScale: result.conversionScale, isResizing: isOnHandle)
                    return
                }
            }
            dragContext = nil // Pan Canvas

            // Initialize velocity tracking
            lastPanTime = CACurrentMediaTime()
            panVelocity = .zero

	        case .changed:
            let translation = gesture.translation(in: self)

            if lassoDragActive {
                let dxActive = Double(translation.x) / coord.zoomScale
                let dyActive = Double(translation.y) / coord.zoomScale

                let ang = Double(coord.rotationAngle)
                let c = cos(ang)
                let s = sin(ang)
                let dxRot = dxActive * c + dyActive * s
                let dyRot = -dxActive * s + dyActive * c

                coord.translateLassoSelection(by: SIMD2<Double>(dxRot, dyRot))
                gesture.setTranslation(.zero, in: self)
                return
            }

            if let context = dragContext {
                // 1. Convert Screen Delta -> Active World Delta
                let dxActive = Double(translation.x) / coord.zoomScale
                let dyActive = Double(translation.y) / coord.zoomScale

                // 2. Apply Camera Rotation
                let ang = Double(coord.rotationAngle)
                let c = cos(ang), s = sin(ang)
                let dxRot = dxActive * c + dyActive * s
                let dyRot = -dxActive * s + dyActive * c

                // 3. Convert Active Delta -> Target Frame Delta
                let frameDelta = SIMD2<Double>(dxRot * context.conversionScale, dyRot * context.conversionScale)

                if context.isResizing {
                    //  RESIZE CARD (Drag Handle)
                    // Goal: Bottom-right corner tracks finger exactly, top-left corner stays fixed
                    // Since the card is centered at origin, changing size by S moves each corner by S/2
                    // To make corner track finger 1:1, size changes by localDelta, origin by localDelta/2

                    let cardRot = Double(context.card.rotation)
                    let cardC = cos(cardRot), cardS = sin(cardRot)

                    // Convert frame delta to card-local delta
                    let localDx = frameDelta.x * cardC + frameDelta.y * cardS
                    let localDy = -frameDelta.x * cardS + frameDelta.y * cardC

                    let minCardSize: Double = 10.0

                    // Size changes by the desired corner movement
                    var newSizeX = max(context.card.size.x + localDx, minCardSize)
                    var newSizeY = max(context.card.size.y + localDy, minCardSize)

                    // Lock aspect ratio for YouTube embed cards.
                    if case .youtube(_, let aspectRatio) = context.card.type,
                       aspectRatio.isFinite, aspectRatio > 0 {
                        let proposedWidthFromDx = context.card.size.x + localDx
                        let proposedWidthFromDy = context.card.size.x + localDy * aspectRatio
                        let widthCandidate = abs(localDx) >= abs(localDy * aspectRatio)
                            ? proposedWidthFromDx
                            : proposedWidthFromDy

                        var lockedWidth = max(widthCandidate, minCardSize)
                        var lockedHeight = lockedWidth / aspectRatio
                        if lockedHeight < minCardSize {
                            lockedHeight = minCardSize
                            lockedWidth = lockedHeight * aspectRatio
                        }

                        newSizeX = lockedWidth
                        newSizeY = lockedHeight
                    }

                    // Calculate actual size change (accounting for minimum size clamping)
                    let deltaX = newSizeX - context.card.size.x
                    let deltaY = newSizeY - context.card.size.y

                    // Apply size change
                    context.card.size.x = newSizeX
                    context.card.size.y = newSizeY

                    // Origin shifts by half the size change to keep top-left fixed
                    let originDx = deltaX * 0.5
                    let originDy = deltaY * 0.5

                    // Convert origin shift to frame coordinates
                    let originShiftX = originDx * cardC - originDy * cardS
                    let originShiftY = originDx * cardS + originDy * cardC

                    context.card.origin.x += originShiftX
                    context.card.origin.y += originShiftY

                    // Update geometry
                    context.card.rebuildGeometry()
                } else {
                    //  DRAG CARD (Move)
                    // Parent: Scale < 1.0 (Move slower - parent coords are smaller)
                    // Child: Scale > 1.0 (Move faster - child coords are larger)
                    context.card.origin.x += frameDelta.x
                    context.card.origin.y += frameDelta.y
                }

                gesture.setTranslation(.zero, in: self)

            } else {
                //  PAN CANVAS
                // panOffset is in screen/pixel space, so we don't divide by zoom
                let dx = Double(translation.x)
                let dy = Double(translation.y)

                let ang = Double(coord.rotationAngle)
                let c = cos(ang), s = sin(ang)

                coord.panOffset.x += dx * c + dy * s
                coord.panOffset.y += -dx * s + dy * c

                // Track velocity for momentum
                // Since we reset translation each frame, translation IS the delta
                let currentTime = CACurrentMediaTime()
                let dt = currentTime - lastPanTime
                if dt > 0 {
                    // Calculate velocity in screen space (before rotation)
                    panVelocity.x = Double(translation.x) / dt
                    panVelocity.y = Double(translation.y) / dt
                }
                lastPanTime = currentTime

                gesture.setTranslation(.zero, in: self)

                // Keep coordinates bounded by swapping tiles when the camera center exits the frame.
                let centerScreen = CGPoint(x: bounds.size.width / 2.0, y: bounds.size.height / 2.0)
                let cameraCenterWorld = coord.calculateCameraCenterWorld(viewSize: bounds.size)
                _ = wrapFractalIfNeeded(coord: coord,
                                       anchorWorld: cameraCenterWorld,
                                       anchorScreen: centerScreen)
            }

        case .ended, .cancelled, .failed:
            // TODO: Record undo action for lasso move
            if lassoDragActive {
                coord.endLassoDrag()
            }

            // Record undo action for card move/resize
            if let context = dragContext {
                if context.isResizing {
                    // Only record if size or origin actually changed
                    if context.card.size != context.startSize || context.card.origin != context.startOrigin {
                        coord.pushUndoResizeCard(card: context.card,
                                                frame: context.frame,
                                                oldOrigin: context.startOrigin,
                                                oldSize: context.startSize)
                    }
                } else {
                    // Only record if origin actually changed
                    if context.card.origin != context.startOrigin {
                        coord.pushUndoMoveCard(card: context.card,
                                              frame: context.frame,
                                              oldOrigin: context.startOrigin)
                    }
                }

                // Normalize across same-depth frames (and recompute section membership).
                coord.normalizeCardAcrossFramesIfNeeded(card: context.card, from: context.frame, viewSize: bounds.size)
            }

            // Start momentum if panning canvas and velocity is significant
            if dragContext == nil && !lassoDragActive {
                let speed = sqrt(panVelocity.x * panVelocity.x + panVelocity.y * panVelocity.y)
                if speed > 50.0 { // Minimum velocity threshold (points per second)
                    startMomentum()
                }
            }

            lassoDragActive = false
            dragContext = nil

        default:
            break
        }
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let coord = coordinator else { return }
        let loc = gesture.location(in: self)
        let tc  = gesture.numberOfTouches

        switch gesture.state {
        case .began:
            // Stop any ongoing momentum
            stopMomentum()

            if coord.lassoContains(screenPoint: loc, viewSize: bounds.size) {
                lassoPinchActive = true
                coord.beginLassoTransformIfNeeded()
                // TODO: Capture state for undo on first transform operation
                gesture.scale = 1.0
                return
            }
            if let result = coord.hitTestHierarchy(screenPoint: loc, viewSize: bounds.size, ignoringLocked: true),
               result.card.isEditing,
               !result.card.isLocked {
                cardPinchActive = true
                cardPinchTarget = result.card
                gesture.scale = 1.0
                return
            }
            // Start of pinch: claim the anchor if nobody owns it yet.
            lastPinchTouchCount = tc
            if activeOwner == .none {
                lockAnchor(owner: .pinch, at: loc, coord: coord)
            }

        case .changed:
            if lassoPinchActive {
                coord.updateLassoTransformScale(delta: Double(gesture.scale))
                gesture.scale = 1.0
                return
            }
            if cardPinchActive, let card = cardPinchTarget {
                let scale = Double(gesture.scale)
                card.size = SIMD2<Double>(card.size.x * scale, card.size.y * scale)
                card.rebuildGeometry()
                gesture.scale = 1.0
                return
            }
            // If finger count changes, re-lock to new centroid WITHOUT moving content.
            if activeOwner == .pinch, tc != lastPinchTouchCount {
                relockAnchorAtCurrentCentroid(owner: .pinch,
                                              screenPt: loc,
                                              coord: coord)
                lastPinchTouchCount = tc
                // Avoid solving pan on this frame; we just re-synced the anchor.
                gesture.scale = 1.0
                return
            }

	            // Normal incremental zoom (always relative).
	            //
	            // On Mac (Catalyst / iOS app on Mac), trackpad pinch deltas are much more aggressive than iPad,
	            // so we dampen the gesture scale to slow zoom down.
	            let rawScale = max(Double(gesture.scale), 1e-6)
	            let appliedScale: Double
	            if isRunningOnMac {
	                let macZoomSensitivity = 0.25
	                appliedScale = pow(rawScale, macZoomSensitivity)
	            } else {
	                appliedScale = rawScale
	            }
	            coord.zoomScale *= appliedScale
	            gesture.scale = 1.0

            // 🔑 IMPORTANT: depth switches are driven by the *shared anchor*,
            // not by re-sampling world from the current centroid.
            if checkFractalTransitions(coord: coord,
                                       anchorWorld: anchorWorld,
                                       anchorScreen: anchorScreen) {
                // The transition functions already solved a perfect panOffset
                // to keep the anchor pinned. Do NOT overwrite it this frame.
                return
            }

            // No frame switch: solve panOffset to keep the anchor fixed.
            let targetScreen: CGPoint = (activeOwner == .pinch) ? loc : anchorScreen

            coord.panOffset = solvePanOffsetForAnchor_Double(
                anchorWorld: anchorWorld,
                desiredScreen: targetScreen,
                viewSize: bounds.size,
                zoomScale: coord.zoomScale,
                rotationAngle: coord.rotationAngle
            )

            if activeOwner == .pinch {
                anchorScreen = targetScreen
            }

            // Keep coordinates bounded by swapping tiles when the anchor drifts outside the frame.
            anchorWorld = wrapFractalIfNeeded(coord: coord,
                                             anchorWorld: anchorWorld,
                                             anchorScreen: anchorScreen)

        case .ended, .cancelled, .failed:
            if lassoPinchActive {
                lassoPinchActive = false
                if !lassoRotationActive {
                    coord.endLassoTransformIfNeeded()
                    // TODO: Record undo for lasso transform
                }
                return
            }
            if cardPinchActive {
                cardPinchActive = false
                cardPinchTarget = nil
                return
            }
            if activeOwner == .pinch {
                // If rotation is active, hand off the anchor smoothly.
                if rotationGesture.state == .changed || rotationGesture.state == .began {
                    let rloc = rotationGesture.location(in: self)
                    handoffAnchor(to: .rotation, screenPt: rloc, coord: coord)
                } else {
                    clearAnchorIfUnused()
                }
            }
            lastPinchTouchCount = 0

        default:
            break
        }
    }
    @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard let coord = coordinator else { return }
        let loc = gesture.location(in: self)
        let tc  = gesture.numberOfTouches

        switch gesture.state {
        case .began:
            // Stop any ongoing momentum
            stopMomentum()

            if coord.lassoContains(screenPoint: loc, viewSize: bounds.size) {
                lassoRotationActive = true
                coord.beginLassoTransformIfNeeded()
                // TODO: Capture state for undo on first transform operation
                gesture.rotation = 0.0
                return
            }
            if let result = coord.hitTestHierarchy(screenPoint: loc, viewSize: bounds.size, ignoringLocked: true),
               result.card.isEditing,
               !result.card.isLocked {
                cardRotationActive = true
                cardRotationTarget = result.card
                gesture.rotation = 0.0
                return
            }
            lastRotationTouchCount = tc
            if activeOwner == .none { lockAnchor(owner: .rotation, at: loc, coord: coord) }

        case .changed:
            if lassoRotationActive {
                coord.updateLassoTransformRotation(delta: Double(gesture.rotation))
                gesture.rotation = 0.0
                return
            }
            if cardRotationActive, let card = cardRotationTarget {
                card.rotation += Float(gesture.rotation)
                card.rebuildGeometry()
                gesture.rotation = 0.0
                return
            }
            // Re-lock when finger count changes to prevent jump.
            if activeOwner == .rotation, tc != lastRotationTouchCount {
                relockAnchorAtCurrentCentroid(owner: .rotation, screenPt: loc, coord: coord)
                lastRotationTouchCount = tc
                gesture.rotation = 0.0
                return
            }

            // Apply incremental rotation
            coord.rotationAngle += Float(gesture.rotation)
            gesture.rotation = 0.0

            //  Keep shared anchor pinned - use Double-precision solver
            let target = (activeOwner == .rotation) ? loc : anchorScreen
            coord.panOffset = solvePanOffsetForAnchor_Double(anchorWorld: anchorWorld,
                                                             desiredScreen: target,
                                                             viewSize: bounds.size,
                                                             zoomScale: coord.zoomScale,
                                                             rotationAngle: coord.rotationAngle)
            if activeOwner == .rotation { anchorScreen = target }

            // Keep coordinates bounded by swapping tiles when the anchor drifts outside the frame.
            anchorWorld = wrapFractalIfNeeded(coord: coord,
                                             anchorWorld: anchorWorld,
                                             anchorScreen: anchorScreen)

        case .ended, .cancelled, .failed:
            if lassoRotationActive {
                lassoRotationActive = false
                if !lassoPinchActive {
                    coord.endLassoTransformIfNeeded()
                    // TODO: Record undo for lasso transform
                }
                return
            }
            if cardRotationActive {
                cardRotationActive = false
                cardRotationTarget = nil
                return
            }
            if activeOwner == .rotation {
                if pinchGesture.state == .changed || pinchGesture.state == .began {
                    let ploc = pinchGesture.location(in: self)
                    handoffAnchor(to: .pinch, screenPt: ploc, coord: coord)
                } else {
                    clearAnchorIfUnused()
                }
            }
            lastRotationTouchCount = 0

        default: break
        }
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        // Two-finger long press - currently unused
        // Could be used for global actions (zoom reset, frame navigation, etc.)
    }

    /// Single-finger long press to open card settings
    @objc func handleCardLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let coord = coordinator else { return }

        if gesture.state == .began {
            let location = gesture.location(in: self)
            if let key = coord.hitTestHighlightSection(at: location, viewSize: bounds.size) {
                let anchor = CGRect(x: location.x - 2, y: location.y - 2, width: 4, height: 4)
                showRemoveHighlightMenuIfNeeded(key: key, anchorRect: anchor)
                return
            }

            // Stroke long-press takes precedence (link selection).
            if coord.beginLinkSelection(at: location, viewSize: bounds.size) {
                updateLinkSelectionOverlay()
                return
            }

            // Card long-press shows card menu.
            if let (card, frame, _, _) = coord.hitTestHierarchy(screenPoint: location, viewSize: bounds.size) {
                let anchor = CGRect(x: location.x - 2, y: location.y - 2, width: 4, height: 4)
                showCardMenuIfNeeded(card: card, frame: frame, anchorRect: anchor)
                return
            }

            // Section bounds long-press shows color menu.
            if let section = coord.hitTestSectionHierarchy(screenPoint: location, viewSize: bounds.size) {
                let anchor = CGRect(x: location.x - 2, y: location.y - 2, width: 4, height: 4)
                showSectionColorMenuIfNeeded(section: section, anchorRect: anchor)
                return
            }

            // Clear any previous remove-highlight menu state if we didn't hit a highlight box.
            removeHighlightMenuKey = nil
            isShowingRemoveHighlightMenu = false

            coord.handleLongPress(at: location)
            updateLinkSelectionOverlay()
        }
    }

    // MARK: - Pan Momentum

    func startMomentum() {
        // Stop any existing display link without resetting velocity
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = CADisplayLink(target: self, selector: #selector(updateMomentum))
        momentumDisplayLink?.add(to: .main, forMode: .common)
    }

    func stopMomentum() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        panVelocity = .zero
    }

    @objc func updateMomentum() {
        guard let coord = coordinator else {
            stopMomentum()
            return
        }

        // Get frame duration (typically 1/60 for 60fps)
        let dt = momentumDisplayLink?.duration ?? (1.0 / 60.0)

        // Apply friction to decelerate (higher = slides more)
        let friction = 0.96
        panVelocity.x *= friction
        panVelocity.y *= friction

        // Check if velocity is below threshold and stop
        let speed = sqrt(panVelocity.x * panVelocity.x + panVelocity.y * panVelocity.y)
        if speed < 0.5 {
            stopMomentum()
            return
        }

        // Apply velocity to pan offset
        let dx = panVelocity.x * dt
        let dy = panVelocity.y * dt

        let ang = Double(coord.rotationAngle)
        let c = cos(ang), s = sin(ang)

        coord.panOffset.x += dx * c + dy * s
        coord.panOffset.y += -dx * s + dy * c

        // Keep coordinates bounded by swapping tiles when the camera center exits the frame.
        let centerScreen = CGPoint(x: bounds.size.width / 2.0, y: bounds.size.height / 2.0)
        let cameraCenterWorld = coord.calculateCameraCenterWorld(viewSize: bounds.size)
        _ = wrapFractalIfNeeded(coord: coord,
                               anchorWorld: cameraCenterWorld,
                               anchorScreen: centerScreen)
    }




    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if !isRunningOnMac {
            guard event?.allTouches?.count == 1 else { return }
        }
        let location = touch.location(in: self)
        coordinator?.handleTouchBegan(at: location, touchType: touch.type)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if !isRunningOnMac {
            guard event?.allTouches?.count == 1 else { return }
        }
        let location = touch.location(in: self)

        //  GET PREDICTED TOUCHES
        // These are high-precision estimates of where the finger will be next frame.
        var predictedPoints: [CGPoint] = []

        if let predicted = event?.predictedTouches(for: touch) {
            for pTouch in predicted {
                predictedPoints.append(pTouch.location(in: self))
            }
        }

        // Pass both Real and Predicted to Coordinator
        coordinator?.handleTouchMoved(at: location,
                                    predicted: predictedPoints,
                                    touchType: touch.type)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if !isRunningOnMac {
            guard event?.allTouches?.count == 1 else { return }
        }
        let location = touch.location(in: self)
        coordinator?.handleTouchEnded(at: location, touchType: touch.type)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if !isRunningOnMac {
            guard event?.allTouches?.count == 1 else { return }
        }
        coordinator?.handleTouchCancelled(touchType: touch.type)
    }
}

// MARK: - Apple Pencil Interactions

extension TouchableMTKView: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        coordinator?.onPencilSqueeze?()
    }
}

// MARK: - Gesture Delegate (Ignore Inline Text Editing)

extension TouchableMTKView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let loc = touch.location(in: self)

        if let field = sectionNameTextField, field.frame.contains(loc) {
            return false
        }
        if let field = cardNameTextField, field.frame.contains(loc) {
            return false
        }
        #if canImport(YouTubePlayerKit)
        if let view = youtubeHostingView,
           !view.isHidden,
           view.frame.contains(loc) {
            return false
        }
        #else
        if let webView = youtubeWebView,
           webView.superview != nil,
           !webView.isHidden,
           webView.frame.contains(loc) {
            return false
        }
        #endif
        return true
    }
}

// MARK: - UITextField Delegate (Inline Section Rename)

extension TouchableMTKView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === sectionNameTextField {
            commitAndEndSectionNameEditing()
        } else if textField === cardNameTextField {
            commitAndEndCardNameEditing()
        }
        return false
    }
}

// MARK: - Section Options Sheet

private class SectionOptionsViewController: UIViewController {
    private let colors: [UIColor]
    private let onColorSelected: (Int) -> Void
    private let onRename: () -> Void
    private let onDelete: () -> Void

    init(colors: [UIColor], onColorSelected: @escaping (Int) -> Void, onRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.colors = colors
        self.onColorSelected = onColorSelected
        self.onRename = onRename
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Color buttons row
        let colorStack = UIStackView()
        colorStack.axis = .horizontal
        colorStack.spacing = 16
        colorStack.alignment = .center
        colorStack.distribution = .equalSpacing

        for (index, color) in colors.enumerated() {
            let button = UIButton(type: .system)
            button.backgroundColor = color
            button.layer.cornerRadius = 22
            button.tag = index
            button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
            colorStack.addArrangedSubview(button)
        }

        // Action buttons row
        let renameButton = UIButton(type: .system)
        renameButton.setTitle("Rename", for: .normal)
        renameButton.titleLabel?.font = .systemFont(ofSize: 17)
        renameButton.addTarget(self, action: #selector(renameTapped), for: .touchUpInside)

        let deleteButton = UIButton(type: .system)
        deleteButton.setTitle("Delete", for: .normal)
        deleteButton.setTitleColor(.systemRed, for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 17)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let actionStack = UIStackView(arrangedSubviews: [renameButton, deleteButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 40
        actionStack.alignment = .center

        // Main stack
        let mainStack = UIStackView(arrangedSubviews: [colorStack, actionStack])
        mainStack.axis = .vertical
        mainStack.spacing = 24
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32)
        ])
    }

    @objc private func colorTapped(_ sender: UIButton) {
        dismiss(animated: true) { [weak self] in
            self?.onColorSelected(sender.tag)
        }
    }

    @objc private func renameTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onRename()
        }
    }

    @objc private func deleteTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onDelete()
        }
    }
}
