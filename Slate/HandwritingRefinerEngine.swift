// HandwritingRefinerEngine.swift
//
// Streaming wrapper around the CoreML handwriting refiner model.
//
// Note: Xcode may auto-generate a `HandwritingRefiner` type from
// `HandwritingRefiner.mlpackage`. This wrapper intentionally uses a different
// name to avoid build conflicts.

import CoreML
import Foundation
import simd

final class HandwritingRefinerEngine {
    enum RefinerError: Error {
        case modelNotFound(String)
        case invalidModelOutput(String)
        case invalidText(String)
    }

    struct Settings {
        /// Controls neatness. Higher usually means "snappier"/cleaner output.
        var bias: Float = 2.0

        /// Scale factor between your local canvas units and the model's normalized units.
        /// If refinement looks too jittery, increase this; if it barely moves, decrease it.
        var inputScale: Float = 2.0

        /// 0 = no refinement (raw), 1 = fully refined (model).
        var refinementStrength: Float = 0.85

        /// CoreML model expects text length <= 100.
        var maxTextLength: Int = 100

        /// Avoid using GPU to reduce contention with Metal rendering.
        var computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    }

    final class Session {
        private let model: MLModel
        private let settings: Settings

        // Text context (fixed for the session).
        private let inputText: MLMultiArray
        private let inputTextLen: MLMultiArray
        private let inputBias: MLMultiArray

        // Streaming inputs/state (updated every step).
        private let inputStroke: MLMultiArray
        private var stateH1: MLMultiArray
        private var stateC1: MLMultiArray
        private var stateH2: MLMultiArray
        private var stateC2: MLMultiArray
        private var stateH3: MLMultiArray
        private var stateC3: MLMultiArray
        private var stateKappa: MLMultiArray
        private var stateW: MLMultiArray

        // Stroke coordinate transform (screen <-> local).
        private var firstScreenPoint: CGPoint?
        private var zoomAtStrokeStart: Float = 1.0
        private var rotationAtStrokeStart: Float = 0.0

        // Local-space stroke points (relative to firstScreenPoint).
        private var lastRawLocalPoint: SIMD2<Float> = .zero
        private var lastRefinedLocalPoint: SIMD2<Float> = .zero
        private var predictedNextDeltaLocal: SIMD2<Float>?
        private var lastStepWasStrokeEnd: Bool = false

        fileprivate init(model: MLModel, text: MLMultiArray, textLen: MLMultiArray, settings: Settings) throws {
            self.model = model
            self.settings = settings

            self.inputText = text
            self.inputTextLen = textLen

            self.inputBias = try HandwritingRefinerEngine.makeMultiArray(shape: [1], dataType: .float32)
            self.inputBias[0] = NSNumber(value: settings.bias)

            self.inputStroke = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 3], dataType: .float32)

            // Initialize recurrent state to zeros.
            self.stateH1 = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 400], dataType: .float32)
            self.stateC1 = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 400], dataType: .float32)
            self.stateH2 = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 400], dataType: .float32)
            self.stateC2 = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 400], dataType: .float32)
            self.stateH3 = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 400], dataType: .float32)
            self.stateC3 = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 400], dataType: .float32)
            self.stateKappa = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 10], dataType: .float32)
            self.stateW = try HandwritingRefinerEngine.makeMultiArray(shape: [1, 73], dataType: .float32)

            self.resetModelState()
        }

        func resetModelState() {
            HandwritingRefinerEngine.zero(self.inputStroke)
            HandwritingRefinerEngine.zero(self.stateH1)
            HandwritingRefinerEngine.zero(self.stateC1)
            HandwritingRefinerEngine.zero(self.stateH2)
            HandwritingRefinerEngine.zero(self.stateC2)
            HandwritingRefinerEngine.zero(self.stateH3)
            HandwritingRefinerEngine.zero(self.stateC3)
            HandwritingRefinerEngine.zero(self.stateKappa)
            HandwritingRefinerEngine.zero(self.stateW)

            self.firstScreenPoint = nil
            self.lastRawLocalPoint = .zero
            self.lastRefinedLocalPoint = .zero
            self.predictedNextDeltaLocal = nil
            self.lastStepWasStrokeEnd = false
        }

        func beginStroke(firstScreenPoint: CGPoint, zoom: Double, rotationAngle: Float) throws {
            self.firstScreenPoint = firstScreenPoint
            self.zoomAtStrokeStart = Float(max(zoom, 1e-6))
            self.rotationAtStrokeStart = rotationAngle
            self.lastRawLocalPoint = .zero
            self.lastRefinedLocalPoint = .zero
            self.predictedNextDeltaLocal = nil
            self.lastStepWasStrokeEnd = false

            // Prime the model with the start token x0 = [0, 0, 1].
            // (Training uses y0 as the first "real" delta.)
            try self.step(rawDeltaLocal: .zero, eos: 1.0)
            // The start token isn't a real stroke end for our refinement logic.
            self.lastStepWasStrokeEnd = false
        }

        /// Feed a new raw screen point and get the refined screen point.
        /// - Important: Call `beginStroke(...)` before calling this.
        func addPoint(_ screenPoint: CGPoint, isFinal: Bool) throws -> CGPoint {
            guard let first = firstScreenPoint else { return screenPoint }

            let rawLocal = screenToLocal(screenPoint, firstScreenPoint: first)
            let rawDeltaLocal = rawLocal - lastRawLocalPoint

            // Preserve layout between pen-up strokes: do not refine the "jump" to the next stroke start.
            if lastStepWasStrokeEnd {
                lastRawLocalPoint = rawLocal
                lastRefinedLocalPoint = rawLocal
                predictedNextDeltaLocal = nil

                try step(rawDeltaLocal: rawDeltaLocal, eos: isFinal ? 1.0 : 0.0)
                lastStepWasStrokeEnd = isFinal
                return localToScreen(rawLocal, firstScreenPoint: first)
            }

            let predictedDelta = predictedNextDeltaLocal ?? rawDeltaLocal
            let t = max(0.0, min(settings.refinementStrength, 1.0))
            let refinedDeltaLocal = rawDeltaLocal * (1.0 - t) + predictedDelta * t
            let refinedLocal = lastRefinedLocalPoint + refinedDeltaLocal

            lastRawLocalPoint = rawLocal
            lastRefinedLocalPoint = refinedLocal

            // Update model state + predict the next delta (aligned with the *next* incoming point).
            try step(rawDeltaLocal: rawDeltaLocal, eos: isFinal ? 1.0 : 0.0)
            lastStepWasStrokeEnd = isFinal

            return localToScreen(refinedLocal, firstScreenPoint: first)
        }

        // MARK: - CoreML step

        private func step(rawDeltaLocal: SIMD2<Float>, eos: Float) throws {
            let scale = max(settings.inputScale, 1e-6)

            // Model input is normalized offsets; model's Y axis is flipped vs iOS screen coords.
            let dx = rawDeltaLocal.x / scale
            let dy = -rawDeltaLocal.y / scale

            inputStroke[0] = NSNumber(value: dx)
            inputStroke[1] = NSNumber(value: dy)
            inputStroke[2] = NSNumber(value: eos)

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_stroke": MLFeatureValue(multiArray: inputStroke),
                "input_text": MLFeatureValue(multiArray: inputText),
                "input_text_len": MLFeatureValue(multiArray: inputTextLen),
                "input_bias": MLFeatureValue(multiArray: inputBias),
                "state_h1": MLFeatureValue(multiArray: stateH1),
                "state_c1": MLFeatureValue(multiArray: stateC1),
                "state_h2": MLFeatureValue(multiArray: stateH2),
                "state_c2": MLFeatureValue(multiArray: stateC2),
                "state_h3": MLFeatureValue(multiArray: stateH3),
                "state_c3": MLFeatureValue(multiArray: stateC3),
                "state_kappa": MLFeatureValue(multiArray: stateKappa),
                "state_w": MLFeatureValue(multiArray: stateW),
            ])

            let out = try model.prediction(from: provider)

            guard let gmm = out.featureValue(for: "gmm_params")?.multiArrayValue else {
                throw RefinerError.invalidModelOutput("Missing output: gmm_params")
            }

            // Update recurrent state for the next step.
            guard
                let nextH1 = out.featureValue(for: "next_h1")?.multiArrayValue,
                let nextC1 = out.featureValue(for: "next_c1")?.multiArrayValue,
                let nextH2 = out.featureValue(for: "next_h2")?.multiArrayValue,
                let nextC2 = out.featureValue(for: "next_c2")?.multiArrayValue,
                let nextH3 = out.featureValue(for: "next_h3")?.multiArrayValue,
                let nextC3 = out.featureValue(for: "next_c3")?.multiArrayValue,
                let nextKappa = out.featureValue(for: "next_kappa")?.multiArrayValue,
                let nextW = out.featureValue(for: "next_w")?.multiArrayValue
            else {
                throw RefinerError.invalidModelOutput("Missing one or more next-state outputs")
            }

            stateH1 = nextH1
            stateC1 = nextC1
            stateH2 = nextH2
            stateC2 = nextC2
            stateH3 = nextH3
            stateC3 = nextC3
            stateKappa = nextKappa
            stateW = nextW

            predictedNextDeltaLocal = decodePredictedDeltaLocal(from: gmm, inputScale: scale)
        }

        private func decodePredictedDeltaLocal(from gmmParams: MLMultiArray, inputScale: Float) -> SIMD2<Float> {
            // gmm_params layout from training:
            //   pis:    20
            //   sigmas: 40
            //   rhos:   20
            //   mus:    40 (mu1[20], mu2[20])
            //   e:      1
            //
            // We take the *mixture mean* (E[mu]) to avoid "component hopping" jitter.
            //
            // Note: The exported model returns *raw* logits for `pis` and `sigmas`. The training
            // code applies `bias` before softmax / exp; we mirror the `pis` biasing here so the
            // "neatness" slider still has an effect in deterministic mode.
            let floatPtr = gmmParams.dataPointer.assumingMemoryBound(to: Float.self)

            let bias = settings.bias
            let logitScale = 1.0 + bias

            var maxLogit = floatPtr[0] * logitScale
            for i in 1..<20 {
                maxLogit = max(maxLogit, floatPtr[i] * logitScale)
            }

            var weights = [Float](repeating: 0, count: 20)
            var sumExp: Float = 0
            for i in 0..<20 {
                let scaled = floatPtr[i] * logitScale
                let e = exp(scaled - maxLogit)
                weights[i] = e
                sumExp += e
            }

            if sumExp > 0 {
                for i in 0..<20 { weights[i] /= sumExp }
            }

            // Prune extremely low-probability components to avoid far-away modes pulling the mean.
            var sumPruned: Float = 0
            for i in 0..<20 {
                if weights[i] < 0.001 { weights[i] = 0 }
                sumPruned += weights[i]
            }
            if sumPruned > 0 {
                for i in 0..<20 { weights[i] /= sumPruned }
            }

            var muX: Float = 0
            var muY: Float = 0
            for i in 0..<20 {
                let w = weights[i]
                if w == 0 { continue }
                muX += w * floatPtr[80 + i]
                muY += w * floatPtr[100 + i]
            }

            // Convert back to local coords (+ flip Y back to screen/down space).
            return SIMD2<Float>(muX * inputScale, -muY * inputScale)
        }

        // MARK: - Coordinate transforms

        private func screenToLocal(_ p: CGPoint, firstScreenPoint: CGPoint) -> SIMD2<Float> {
            let dx = Float(p.x - firstScreenPoint.x)
            let dy = Float(p.y - firstScreenPoint.y)

            let angle = rotationAtStrokeStart
            let c = cos(angle)
            let s = sin(angle)

            // Inverse rotation (screen -> local), matching Stroke.swift / live rendering.
            let unrotatedX = dx * c + dy * s
            let unrotatedY = -dx * s + dy * c

            let zoom = zoomAtStrokeStart
            return SIMD2<Float>(unrotatedX / zoom, unrotatedY / zoom)
        }

        private func localToScreen(_ p: SIMD2<Float>, firstScreenPoint: CGPoint) -> CGPoint {
            let angle = rotationAtStrokeStart
            let c = cos(angle)
            let s = sin(angle)
            let zoom = zoomAtStrokeStart

            // Forward rotation (local -> screen).
            let dx = (p.x * c - p.y * s) * zoom
            let dy = (p.x * s + p.y * c) * zoom
            return CGPoint(x: firstScreenPoint.x + CGFloat(dx), y: firstScreenPoint.y + CGFloat(dy))
        }
    }

    private let model: MLModel
    private let baseSettings: Settings

    init(modelName: String = "HandwritingRefiner", settings: Settings = Settings()) throws {
        self.baseSettings = settings

        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw RefinerError.modelNotFound("Missing \(modelName).mlmodelc in app bundle")
        }

        let cfg = MLModelConfiguration()
        cfg.computeUnits = settings.computeUnits
        self.model = try MLModel(contentsOf: url, configuration: cfg)
    }

    func makeSession(text: String, settings: Settings? = nil) throws -> Session {
        let s = settings ?? baseSettings
        let (inputText, inputTextLen) = try Self.encodeText(text, maxLength: s.maxTextLength)
        return try Session(model: model, text: inputText, textLen: inputTextLen, settings: s)
    }

    // MARK: - Text encoding

    private static let vocabSize: Int = 73

    // Must match `drawing.alphabet` in handwriting-synthesis/drawing.py.
    private static let alphabetScalarValues: [UInt32] = [
        0, 32, 33, 34, 35, 39, 40, 41, 44, 45, 46,
        48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
        58, 59, 63,
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
        82, 83, 84, 85, 86, 87, 89,
        97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
        111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122,
    ]

    private static let alphabetIndex: [UInt32: Int] = {
        var dict: [UInt32: Int] = [:]
        dict.reserveCapacity(alphabetScalarValues.count)
        for (i, v) in alphabetScalarValues.enumerated() {
            dict[v] = i
        }
        return dict
    }()

    private static func encodeText(_ text: String, maxLength: Int) throws -> (MLMultiArray, MLMultiArray) {
        let maxLen = max(1, min(maxLength, 100))

        // Unknown characters map to space.
        let spaceIdx = alphabetIndex[UInt32(32)] ?? 1

        var indices: [Int] = []
        indices.reserveCapacity(min(text.count + 1, maxLen))

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 10 || v == 13 { // newlines -> space
                indices.append(spaceIdx)
                continue
            }
            indices.append(alphabetIndex[v] ?? spaceIdx)
            if indices.count >= maxLen - 1 { break }
        }
        indices.append(0) // terminator

        if indices.isEmpty { indices = [0] }
        if indices.count > maxLen {
            indices = Array(indices.prefix(maxLen))
            indices[maxLen - 1] = 0
        }

        let len = max(1, indices.count)
        let inputText = try makeMultiArray(shape: [1, len, vocabSize], dataType: .float32)
        zero(inputText)

        let ptr = inputText.dataPointer.assumingMemoryBound(to: Float.self)
        for t in 0..<len {
            let idx = indices[t]
            if idx >= 0 && idx < vocabSize {
                ptr[t * vocabSize + idx] = 1.0
            }
        }

        let inputLen = try makeMultiArray(shape: [1], dataType: .int32)
        inputLen[0] = NSNumber(value: Int32(len))

        return (inputText, inputLen)
    }

    // MARK: - MLMultiArray helpers

    private static func makeMultiArray(shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
    }

    private static func zero(_ a: MLMultiArray) {
        let count = a.count
        switch a.dataType {
        case .float32:
            let ptr = a.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<count { ptr[i] = 0 }
        case .int32:
            let ptr = a.dataPointer.assumingMemoryBound(to: Int32.self)
            for i in 0..<count { ptr[i] = 0 }
        default:
            // Fall back to NSNumber assignment (slower, but avoids crashing on unexpected types).
            for i in 0..<count { a[i] = 0 }
        }
    }
}
