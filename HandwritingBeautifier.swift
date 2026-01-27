import CoreML
import Foundation
import simd

final class HandwritingBeautifier {
    private static let modelName = "StrokeBeautifyStudent"
    private static let featureCharID = "char_id"
    private static let featureBOW = "bow"
    private static let featureDH = "dh"
    private static let featureDC = "dc"
    private static let featureOutY = "y"
    private static let featureOutDH = "dh_out"
    private static let featureOutDC = "dc_out"

    static let maxTextLen = 96
    static let maxOutLen = 512
    private static let rnnLayers = 2
    private static let rnnHidden = 256

    // NOTE: These must match the `std` used during training (the same file passed to
    // `train_charstep.py --dw-stats-npz ...`). We multiply back here to get teacher-scale dx/dy.
    // For reference, the 10k charstep set had:
    //   std_dx=0.00455514, std_dy=0.00472899  (see `/tmp/dw_stats_distill_charsteps_out_10k.npz`)
    private static let deepWritingStdDx: Float = 0.00455514
    private static let deepWritingStdDy: Float = 0.00472899

    private static let eocThreshold: Float = 0.05
    private static let cursiveThreshold: Float = 0.005

    // DeepWriting uses sklearn's LabelEncoder over its alphabet, which produces a lexicographically
    // sorted class order. The per-step `char_id` we saved from the teacher sampling loop uses that.
    //
    // This string is the exact sorted order (excluding the blank class). We use:
    //   0 = blank, 1..69 = chars below.
    private static let charToID: [Character: Int] = {
        let sortedChars = "'(),-./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        var out: [Character: Int] = [:]
        out.reserveCapacity(sortedChars.count)
        for (i, ch) in sortedChars.enumerated() {
            out[ch] = i + 1
        }
        return out
    }()

    private lazy var model: MLModel? = {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            return nil
        }
        return try? MLModel(contentsOf: url)
    }()

    func generateStrokes(ocrText: String) -> [[SIMD2<Float>]] {
        guard let model else {
            NSLog("[HandwritingBeautifier] Missing model '%@.mlmodelc' in bundle", Self.modelName)
            return []
        }

        let text = HandwritingOCR.normalizeTextForDeepWriting(ocrText)
        guard !text.isEmpty else { return [] }

        // Char-step CoreML model inputs.
        let scalarShape: [NSNumber] = [1].map { NSNumber(value: $0) }
        let stateShape: [NSNumber] = [Self.rnnLayers, Self.rnnHidden].map { NSNumber(value: $0) }
        guard let charArr = try? MLMultiArray(shape: scalarShape, dataType: .int32),
              let bowArr = try? MLMultiArray(shape: scalarShape, dataType: .float32),
              var dh = try? MLMultiArray(shape: stateShape, dataType: .float32),
              var dc = try? MLMultiArray(shape: stateShape, dataType: .float32) else {
            return []
        }
        for i in 0..<dh.count { dh[i] = 0.0 }
        for i in 0..<dc.count { dc[i] = 0.0 }

        var strokes: [[SIMD2<Float>]] = []
        strokes.reserveCapacity(32)
        var cur: [SIMD2<Float>] = []
        cur.reserveCapacity(64)

        var x: Float = 0
        var yPos: Float = 0
        var globalStep: Int = 0
        var prevEOCStep: Int = 0
        let cursiveStyle: Bool = Self.cursiveThreshold > 0.5

        func step(charID: Int, bow: Float, save: Bool = true) -> Float {
            globalStep += 1
            charArr[0] = NSNumber(value: charID)
            bowArr[0] = NSNumber(value: bow)

            guard let input = try? MLDictionaryFeatureProvider(dictionary: [
                Self.featureCharID: charArr,
                Self.featureBOW: bowArr,
                Self.featureDH: dh,
                Self.featureDC: dc
            ]) else {
                return 0
            }
            guard let out = try? model.prediction(from: input),
                  let y = out.featureValue(for: Self.featureOutY)?.multiArrayValue,
                  let dhOut = out.featureValue(for: Self.featureOutDH)?.multiArrayValue,
                  let dcOut = out.featureValue(for: Self.featureOutDC)?.multiArrayValue else {
                return 0
            }
            dh = dhOut
            dc = dcOut

            // y: [1,4]
            let rowStride = y.strides[0].intValue
            let colStride = y.strides[1].intValue
            let base = 0 * rowStride

            let dxScaled = y[base + (0 * colStride)].floatValue
            let dyScaled = y[base + (1 * colStride)].floatValue
            let penLogit = y[base + (2 * colStride)].floatValue
            let eocLogit = y[base + (3 * colStride)].floatValue

            let dx = dxScaled * Self.deepWritingStdDx
            let dy = dyScaled * Self.deepWritingStdDy

            let penEnd = sigmoid(penLogit) > 0.5
            let eocProb = sigmoid(eocLogit)

            if save || penEnd {
                x += dx
                yPos += dy
                cur.append(SIMD2<Float>(x, yPos))
                if penEnd {
                    if cur.count >= 2 {
                        strokes.append(cur)
                    }
                    cur = []
                    cur.reserveCapacity(64)
                }
            }
            return eocProb
        }

        let words = text.split(separator: " ")
        for wordSubstr in words {
            let word = String(wordSubstr)
            if word.isEmpty { continue }

            // Start-of-word: blank + BOW=1.
            _ = step(charID: 0, bow: 1.0, save: true)

            let chars = word.compactMap { Self.charToID[$0] != nil ? $0 : nil }
            if chars.isEmpty { continue }

            var charIdx: Int = 0
            while globalStep < Self.maxOutLen {
                guard charIdx < chars.count else { break }
                let ch = chars[charIdx]
                guard let id = Self.charToID[ch] else {
                    charIdx += 1
                    continue
                }

                let eoc = step(charID: id, bow: 0.0)
                if eoc > Self.eocThreshold, (globalStep - prevEOCStep) > 4 {
                    prevEOCStep = globalStep
                    charIdx += 1
                    let lastStep = charIdx >= chars.count

                    if lastStep || !cursiveStyle {
                        if globalStep < Self.maxOutLen {
                            _ = step(charID: 0, bow: 0.0, save: lastStep)
                        }
                    }
                    if lastStep { break }
                }
            }
        }

        if cur.count >= 2 {
            strokes.append(cur)
        }
        return strokes
    }

    private func sigmoid(_ x: Float) -> Float {
        if x >= 0 {
            let z = exp(-x)
            return 1 / (1 + z)
        } else {
            let z = exp(x)
            return z / (1 + z)
        }
    }
}
