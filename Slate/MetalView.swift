import SwiftUI
import Metal
import MetalKit

// MARK: - Geometry / Tessellation

/// Convert a world (canvas pixel) point to NDC, applying pan/zoom.
func worldPixelToNDC(point w: CGPoint,
                     viewSize: CGSize,
                     panOffset: SIMD2<Float>,
                     zoomScale: Float) -> SIMD2<Float> {
    let cx = Float(viewSize.width)  * 0.5
    let cy = Float(viewSize.height) * 0.5

    let wx = Float(w.x), wy = Float(w.y)

    // Remove center (world -> centered)
    let centeredX = wx - cx
    let centeredY = wy - cy

    // Apply zoom (centered -> zoomed)
    let zx = centeredX * zoomScale
    let zy = centeredY * zoomScale

    // Apply pan (in pixels)
    let px = zx + panOffset.x
    let py = zy + panOffset.y

    // Back to screen pixels
    let sx = px + cx
    let sy = py + cy

    // Screen pixels -> NDC
    let ndcX = (sx / Float(viewSize.width)) * 2.0 - 1.0
    let ndcY = -((sy / Float(viewSize.height)) * 2.0 - 1.0)

    return SIMD2<Float>(ndcX, ndcY)
}

/// Create triangles for a stroke from world (canvas pixel) center points.
func tessellateStroke(centerPoints: [CGPoint],
                      width: CGFloat,
                      viewSize: CGSize,
                      panOffset: SIMD2<Float> = .zero,
                      zoomScale: Float = 1.0) -> [SIMD2<Float>] {
    var vertices: [SIMD2<Float>] = []

    guard centerPoints.count >= 2 else {
        if centerPoints.count == 1 {
            return createCircle(at: centerPoints[0],
                                radius: width / 2.0,
                                viewSize: viewSize,
                                panOffset: panOffset,
                                zoomScale: zoomScale)
        }
        return vertices
    }

    let halfWidth = Float(width / 2.0)

    // 1) START CAP
    let startCapVertices = createCircle(
        at: centerPoints[0],
        radius: width / 2.0,
        viewSize: viewSize,
        panOffset: panOffset,
        zoomScale: zoomScale
    )
    vertices.append(contentsOf: startCapVertices)

    // 2) SEGMENTS + JOINTS
    for i in 0..<(centerPoints.count - 1) {
        let current = centerPoints[i]
        let next = centerPoints[i + 1]

        let p1 = worldPixelToNDC(point: current, viewSize: viewSize, panOffset: panOffset, zoomScale: zoomScale)
        let p2 = worldPixelToNDC(point: next, viewSize: viewSize, panOffset: panOffset, zoomScale: zoomScale)

        let dir = p2 - p1
        let len = sqrt(dir.x * dir.x + dir.y * dir.y)
        guard len > 0 else { continue }
        let n = dir / len

        let perp = SIMD2<Float>(-n.y, n.x)

        let widthInNDC = (halfWidth / Float(viewSize.width)) * 2.0 * zoomScale

        let T1 = p1 + perp * widthInNDC
        let B1 = p1 - perp * widthInNDC
        let T2 = p2 + perp * widthInNDC
        let B2 = p2 - perp * widthInNDC

        vertices.append(T1); vertices.append(B1); vertices.append(T2)
        vertices.append(B1); vertices.append(B2); vertices.append(T2)

        if i < centerPoints.count - 2 {
            let jointVertices = createCircle(
                at: next,
                radius: width / 2.0,
                viewSize: viewSize,
                panOffset: panOffset,
                zoomScale: zoomScale,
                segments: 16
            )
            vertices.append(contentsOf: jointVertices)
        }
    }

    // 4) END CAP
    let endCapVertices = createCircle(
        at: centerPoints[centerPoints.count - 1],
        radius: width / 2.0,
        viewSize: viewSize,
        panOffset: panOffset,
        zoomScale: zoomScale
    )
    vertices.append(contentsOf: endCapVertices)

    return vertices
}

/// Triangle fan circle in NDC.
func createCircle(at point: CGPoint,
                  radius: CGFloat,
                  viewSize: CGSize,
                  panOffset: SIMD2<Float> = .zero,
                  zoomScale: Float = 1.0,
                  segments: Int = 30) -> [SIMD2<Float>] {
    var vertices: [SIMD2<Float>] = []

    let center = worldPixelToNDC(point: point, viewSize: viewSize, panOffset: panOffset, zoomScale: zoomScale)
    let radiusInNDC = (Float(radius) / Float(viewSize.width)) * 2.0 * zoomScale

    for i in 0..<segments {
        let a1 = Float(i) * (2.0 * .pi / Float(segments))
        let a2 = Float(i + 1) * (2.0 * .pi / Float(segments))

        let p1 = SIMD2<Float>(center.x + cos(a1) * radiusInNDC,
                              center.y + sin(a1) * radiusInNDC)
        let p2 = SIMD2<Float>(center.x + cos(a2) * radiusInNDC,
                              center.y + sin(a2) * radiusInNDC)

        vertices.append(center)
        vertices.append(p1)
        vertices.append(p2)
    }
    return vertices
}

// MARK: - Coordinate Conversion Helpers

/// Screen pixels -> World pixels (inverse of worldToScreenPixels).
func screenToWorldPixels(_ p: CGPoint,
                         viewSize: CGSize,
                         panOffset: SIMD2<Float>,
                         zoomScale: Float) -> CGPoint {
    let cx = Float(viewSize.width) * 0.5
    let cy = Float(viewSize.height) * 0.5

    let sx = Float(p.x), sy = Float(p.y)

    let centeredX = sx - cx
    let centeredY = sy - cy

    let unpannedX = centeredX - panOffset.x
    let unpannedY = centeredY - panOffset.y

    let wx = unpannedX / zoomScale + cx
    let wy = unpannedY / zoomScale + cy

    return CGPoint(x: CGFloat(wx), y: CGFloat(wy))
}

/// World pixels -> Screen pixels (inverse of screenToWorldPixels).
func worldToScreenPixels(_ w: CGPoint,
                         viewSize: CGSize,
                         panOffset: SIMD2<Float>,
                         zoomScale: Float) -> CGPoint {
    let cx = Float(viewSize.width) * 0.5
    let cy = Float(viewSize.height) * 0.5

    let wx = Float(w.x), wy = Float(w.y)

    let centeredX = wx - cx
    let centeredY = wy - cy

    let zx = centeredX * zoomScale
    let zy = centeredY * zoomScale

    let px = zx + panOffset.x
    let py = zy + panOffset.y

    let sx = px + cx
    let sy = py + cy

    return CGPoint(x: CGFloat(sx), y: CGFloat(sy))
}

// MARK: - GPU Transform Struct

struct GPUTransform {
    var panOffset: SIMD2<Float>
    var zoomScale: Float
    var screenWidth: Float
    var screenHeight: Float
}

// MARK: - MetalView

struct MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let mtkView = TouchableMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 1.0, blue: 1.0, alpha: 1.0)
        mtkView.delegate = context.coordinator
        mtkView.isUserInteractionEnabled = true

        mtkView.coordinator = context.coordinator
        context.coordinator.metalView = mtkView

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - TouchableMTKView
    class TouchableMTKView: MTKView {
        weak var coordinator: Coordinator?

        var panGesture: UIPanGestureRecognizer!
        var pinchGesture: UIPinchGestureRecognizer!

        // Pinch anchor (persist between .began and subsequent states)
        var pinchAnchorScreen: CGPoint = .zero
        var pinchAnchorWorld: SIMD2<Float> = .zero
        var panOffsetAtPinchStart: SIMD2<Float> = .zero

        override init(frame: CGRect, device: MTLDevice?) {
            super.init(frame: frame, device: device)
            setupGestures()
        }
        required init(coder: NSCoder) {
            super.init(coder: coder)
            setupGestures()
        }

        func setupGestures() {
            panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            panGesture.minimumNumberOfTouches = 2
            panGesture.maximumNumberOfTouches = 2
            addGestureRecognizer(panGesture)

            pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchGesture)

            panGesture.delegate = self
            pinchGesture.delegate = self
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let coord = coordinator else { return }
            let location = gesture.location(in: self)

            switch gesture.state {
            case .began:
                // Save current pan offset
                panOffsetAtPinchStart = coord.panOffset
                
                // Store screen anchor and corresponding world point
                pinchAnchorScreen = location
                let w = screenToWorldPixels(location,
                                            viewSize: bounds.size,
                                            panOffset: coord.panOffset,
                                            zoomScale: coord.zoomScale)
                pinchAnchorWorld = SIMD2<Float>(Float(w.x), Float(w.y))

            case .changed, .ended:
                // Calculate pan delta since pinch started
                let currentPanDelta = SIMD2<Float>(
                    coord.panOffset.x - panOffsetAtPinchStart.x,
                    coord.panOffset.y - panOffsetAtPinchStart.y
                )
                
                // Temporarily remove the pan delta to calculate zoom correctly
                coord.panOffset = panOffsetAtPinchStart
                
                // Incremental zoom (clamped)
                let newZoom = coord.zoomScale * Float(gesture.scale)

                // Where would the same world point land now?
                let newScreen = worldToScreenPixels(
                    CGPoint(x: CGFloat(pinchAnchorWorld.x), y: CGFloat(pinchAnchorWorld.y)),
                    viewSize: bounds.size,
                    panOffset: coord.panOffset,
                    zoomScale: newZoom
                )

                // Pixel correction to keep anchor under fingers
                let dx = Float(pinchAnchorScreen.x - newScreen.x)
                let dy = Float(pinchAnchorScreen.y - newScreen.y)

                coord.panOffset.x += dx
                coord.panOffset.y += dy
                coord.zoomScale = newZoom
                
                // Re-apply the pan delta from simultaneous panning
                coord.panOffset.x += currentPanDelta.x
                coord.panOffset.y += currentPanDelta.y
                
                // Update the baseline for next iteration
                panOffsetAtPinchStart = SIMD2<Float>(
                    coord.panOffset.x - currentPanDelta.x,
                    coord.panOffset.y - currentPanDelta.y
                )

                gesture.scale = 1.0

            default:
                break
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: self)
            coordinator?.panOffset.x += Float(translation.x)
            coordinator?.panOffset.y += Float(translation.y)
            gesture.setTranslation(.zero, in: self)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1, let touch = touches.first else { return }
            let location = touch.location(in: self)
            coordinator?.handleTouchBegan(at: location)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1, let touch = touches.first else { return }
            let location = touch.location(in: self)
            coordinator?.handleTouchMoved(at: location)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1, let touch = touches.first else { return }
            let location = touch.location(in: self)
            coordinator?.handleTouchEnded(at: location)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1 else { return }
            coordinator?.handleTouchCancelled()
        }
    }
}

// MARK: - Coordinator

class Coordinator: NSObject, MTKViewDelegate {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!

    var currentTouchPoints: [CGPoint] = []
    var allStrokes: [Stroke] = []

    weak var metalView: MTKView?

    var panOffset: SIMD2<Float> = .zero
    var zoomScale: Float = 1.0

    override init() {
        super.init()
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        makePipeLine()
        makeVertexBuffer()
    }

    func draw(in view: MTKView) {
        let startTime = Date()

        var allVertices: [SIMD2<Float>] = []

        // Use cached vertices (tessellated at identity)
        for stroke in allStrokes {
            allVertices.append(contentsOf: stroke.vertices)
        }

        // Current stroke - ALSO tessellate at identity!
        if currentTouchPoints.count >= 2 {
            let currentVertices = tessellateStroke(
                centerPoints: currentTouchPoints,
                width: 10.0,
                viewSize: view.bounds.size,
                panOffset: .zero,      // ← Identity, not current!
                zoomScale: 1.0
            )
            allVertices.append(contentsOf: currentVertices)
        }

        let tessellationTime = Date().timeIntervalSince(startTime)
        if tessellationTime > 0.016 {
            print("⚠️ Tessellation taking \(tessellationTime * 1000)ms - too slow!")
        }

        // Transform buffer with current pan/zoom
        var transform = GPUTransform(
            panOffset: panOffset,
            zoomScale: zoomScale,
            screenWidth: Float(view.bounds.width),
            screenHeight: Float(view.bounds.height)
        )
        let transformBuffer = device.makeBuffer(
            bytes: &transform,
            length: MemoryLayout<GPUTransform>.stride,
            options: .storageModeShared
        )

        if allVertices.isEmpty {
            let commandBuffer = commandQueue.makeCommandBuffer()!
            guard let rpd = view.currentRenderPassDescriptor else { return }
            let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setRenderPipelineState(pipelineState)
            enc.setCullMode(.none)

            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(transformBuffer, offset: 0, index: 1)

            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
            commandBuffer.present(view.currentDrawable!)
            commandBuffer.commit()
            return
        }

        updateVertexBuffer(with: allVertices)
        let commandBuffer = commandQueue.makeCommandBuffer()!
        guard let rpd = view.currentRenderPassDescriptor else { return }
        let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipelineState)
        enc.setCullMode(.none)

        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(transformBuffer, offset: 0, index: 1)

        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: allVertices.count)
        enc.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func makePipeLine() {
        let library = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = library.makeFunction(name: "vertex_main")
        desc.fragmentFunction = library.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
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

    // MARK: - Touch Handling

    func handleTouchBegan(at point: CGPoint) {
        guard let view = metalView else { return }
        let worldPoint = screenToWorldPixels(point,
                                             viewSize: view.bounds.size,
                                             panOffset: panOffset,
                                             zoomScale: zoomScale)
        currentTouchPoints = [worldPoint]
    }

    func handleTouchMoved(at point: CGPoint) {
        guard let view = metalView else { return }
        let worldPoint = screenToWorldPixels(point,
                                             viewSize: view.bounds.size,
                                             panOffset: panOffset,
                                             zoomScale: zoomScale)
        currentTouchPoints.append(worldPoint)
    }

    func handleTouchEnded(at point: CGPoint) {
        guard let view = metalView else { return }
        let worldPoint = screenToWorldPixels(point,
                                             viewSize: view.bounds.size,
                                             panOffset: panOffset,
                                             zoomScale: zoomScale)
        currentTouchPoints.append(worldPoint)

        guard currentTouchPoints.count >= 4 else {
            currentTouchPoints = []
            return
        }

        let smoothPoints = catmullRomPoints(points: currentTouchPoints,
                                            closed: false,
                                            alpha: 0.5,
                                            segmentsPerCurve: 20)

        let stroke = Stroke(centerPoints: smoothPoints,
                            width: 10.0,
                            color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0),
                            viewSize: view.bounds.size)

        allStrokes.append(stroke)
        currentTouchPoints = []
    }

    func handleTouchCancelled() {
        currentTouchPoints = []
    }
}

// MARK: - Gesture Delegate

extension MetalView.TouchableMTKView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
