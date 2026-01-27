import CoreML
import Foundation
import simd

final class HandwritingRefiner {
    struct DxDyNorm {
        let meanDx: Float
        let stdDx: Float
        let meanDy: Float
        let stdDy: Float
    }

    struct StrokeRun {
        let id: UUID
        let points: [SIMD2<Float>]
    }

    // From `refine_mvp/iam_json/rnn_stats.json` (IAM lineStrokes 2 corpus).
    private let norm = DxDyNorm(
        meanDx: 3.493_063_8,
        stdDx: 13.586_004,
        meanDy: 3.664_047_7,
        stdDy: 19.447_28
    )

    private static let maxLen = 512
    private static let featureX = "x"
    private static let featureMask = "mask"
    private static let featureOut = "y_xy"
    private static let modelName = "StrokeRefineStudent"

    // MVP safety: make refinement conservative so it doesn't destroy legibility.
    // 0 = no change, 1 = fully model output.
    private let blendStrength: Float = 0.45
    // Clamp per-step output magnitude relative to the original step.
    private let maxStepMultiplier: Float = 2.0

    private lazy var model: MLModel? = {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            return nil
        }
        return try? MLModel(contentsOf: url)
    }()

    func refineStrokeRuns(_ runs: [StrokeRun]) -> [UUID: [SIMD2<Float>]] {
        var outByID: [UUID: [SIMD2<Float>]] = [:]
        outByID.reserveCapacity(runs.count)
        for r in runs {
            outByID[r.id] = r.points
        }

        guard let model else { return outByID }

        struct StrokeRange {
            let id: UUID
            let tokenStart: Int
            let pointCount: Int
            let anchor: SIMD2<Float>
        }

        var ranges: [StrokeRange] = []
        ranges.reserveCapacity(runs.count)

	        var dxNorms: [Float] = []
	        var dyNorms: [Float] = []
	        var rawDx: [Float] = []
	        var rawDy: [Float] = []
	        var ps: [Float] = []
	        var isStrokeStart: [Bool] = []

	        dxNorms.reserveCapacity(runs.reduce(into: 0) { $0 += $1.points.count })
	        dyNorms.reserveCapacity(dxNorms.capacity)
	        rawDx.reserveCapacity(dxNorms.capacity)
	        rawDy.reserveCapacity(dxNorms.capacity)
	        ps.reserveCapacity(dxNorms.capacity)
	        isStrokeStart.reserveCapacity(dxNorms.capacity)

        let stdDx = max(1e-9, norm.stdDx)
        let stdDy = max(1e-9, norm.stdDy)

        // Phase 4 (plan): our model was trained on IAM deltas with a particular coordinate scale.
        // Real strokes can arrive in a different unit/sampling density (e.g. points vs pixels, different resampling),
        // which makes normalization OOD and produces squiggles. We estimate a per-burst scale factor to map input
        // deltas into the teacher/student training scale, then unscale outputs back into the original coordinate space.
        var rawDxSum: Double = 0.0
        var rawDySum: Double = 0.0
        var rawDxSumSq: Double = 0.0
        var rawDySumSq: Double = 0.0
        var rawCount: Int = 0

        for r in runs {
            let pts = r.points
            guard pts.count >= 2 else { continue }
            for i in 1..<pts.count {
                let prev = pts[i - 1]
                let cur = pts[i]
                let dx = cur.x - prev.x
                let dy = cur.y - prev.y

                rawDxSum += Double(dx)
                rawDySum += Double(dy)
                rawDxSumSq += Double(dx * dx)
                rawDySumSq += Double(dy * dy)
                rawCount += 1
            }
        }

        var inputScale: Float = 1.0
        if rawCount > 0 {
            let n = Double(rawCount)
            let rawRmsMag = sqrt(max(0.0, (rawDxSumSq + rawDySumSq) / n))
            let targetRmsMag = sqrt(
                Double(norm.stdDx * norm.stdDx + norm.meanDx * norm.meanDx)
                    + Double(norm.stdDy * norm.stdDy + norm.meanDy * norm.meanDy)
            )
            if rawRmsMag.isFinite, rawRmsMag > 1e-6, targetRmsMag.isFinite, targetRmsMag > 0 {
                inputScale = Float(targetRmsMag / rawRmsMag)
            }
        }
        if !inputScale.isFinite || inputScale <= 0 {
            inputScale = 1.0
        }
        inputScale = min(max(inputScale, 0.25), 8.0)
        let invInputScale: Float = 1.0 / max(inputScale, 1e-6)

#if DEBUG
        if rawCount > 0 {
            let n = Double(rawCount)
            let meanDx = rawDxSum / n
            let meanDy = rawDySum / n
            let varDx = max(0.0, (rawDxSumSq / n) - (meanDx * meanDx))
            let varDy = max(0.0, (rawDySumSq / n) - (meanDy * meanDy))
            let rawStdDx = sqrt(varDx)
            let rawStdDy = sqrt(varDy)
            let rawRmsMag = sqrt(max(0.0, (rawDxSumSq + rawDySumSq) / n))

            let targetRmsMag = sqrt(
                Double(norm.stdDx * norm.stdDx + norm.meanDx * norm.meanDx)
                    + Double(norm.stdDy * norm.stdDy + norm.meanDy * norm.meanDy)
            )
            let suggestedScale = rawRmsMag > 1e-9 ? (targetRmsMag / rawRmsMag) : 0.0

            print(
                String(
                    format: "[HandwritingRefiner] raw std (dx=%.3f dy=%.3f) rms=%.3f; target rms=%.3f; suggested scale=%.2f; applied scale=%.2f",
                    rawStdDx,
                    rawStdDy,
                    rawRmsMag,
                    targetRmsMag,
                    suggestedScale,
                    Double(inputScale)
                )
            )
        }
#endif

	        for r in runs {
	            let pts = r.points
	            guard pts.count >= 2 else { continue }

	            let tokenStart = dxNorms.count
	            ranges.append(StrokeRange(id: r.id, tokenStart: tokenStart, pointCount: pts.count, anchor: pts[0]))

	            for i in 0..<pts.count {
	                if i == 0 {
	                    // Stroke-start tokens are always [0,0,1] after normalization.
	                    dxNorms.append(0.0)
	                    dyNorms.append(0.0)
	                    rawDx.append(0.0)
	                    rawDy.append(0.0)
	                    ps.append(1.0)
	                    isStrokeStart.append(true)
	                    continue
	                }

	                let prev = pts[i - 1]
	                let cur = pts[i]
	                let dx = cur.x - prev.x
	                let dy = cur.y - prev.y

	                let dxScaled = dx * inputScale
	                let dyScaled = dy * inputScale

	                let ndx = (dxScaled - norm.meanDx) / stdDx
	                let ndy = (dyScaled - norm.meanDy) / stdDy
	                dxNorms.append(ndx.isFinite ? ndx : 0.0)
	                dyNorms.append(ndy.isFinite ? ndy : 0.0)
	                rawDx.append(dx.isFinite ? dx : 0.0)
	                rawDy.append(dy.isFinite ? dy : 0.0)
	                ps.append(0.0)
	                isStrokeStart.append(false)
	            }
	        }

        let totalTokens = dxNorms.count
        guard totalTokens > 0 else { return outByID }

	        var predictedDx: [Float] = Array(repeating: 0.0, count: totalTokens)
	        var predictedDy: [Float] = Array(repeating: 0.0, count: totalTokens)

        var start = 0
        while start < totalTokens {
            let end = min(totalTokens, start + Self.maxLen)
            let len = end - start

            let xShape: [NSNumber] = [1, Self.maxLen, 3].map { NSNumber(value: $0) }
            let mShape: [NSNumber] = [1, Self.maxLen].map { NSNumber(value: $0) }
            guard let xArr = try? MLMultiArray(shape: xShape, dataType: .float32),
                  let mArr = try? MLMultiArray(shape: mShape, dataType: .float32) else {
                return outByID
            }

            let xStrideT = xArr.strides[1].intValue
            let xStrideC = xArr.strides[2].intValue
            let mStrideT = mArr.strides[1].intValue

            for i in 0..<Self.maxLen {
                let isReal = i < len
                mArr[i * mStrideT] = NSNumber(value: isReal ? 1.0 : 0.0)

                if !isReal {
                    let base = i * xStrideT
                    xArr[base + (0 * xStrideC)] = 0
                    xArr[base + (1 * xStrideC)] = 0
                    xArr[base + (2 * xStrideC)] = 0
                    continue
                }

                let tokenIdx = start + i
                let base = i * xStrideT
                xArr[base + (0 * xStrideC)] = NSNumber(value: dxNorms[tokenIdx])
                xArr[base + (1 * xStrideC)] = NSNumber(value: dyNorms[tokenIdx])
                xArr[base + (2 * xStrideC)] = NSNumber(value: ps[tokenIdx])
            }

            let input = try? MLDictionaryFeatureProvider(dictionary: [
                Self.featureX: xArr,
                Self.featureMask: mArr
            ])
            guard let input else { return outByID }

            guard let out = try? model.prediction(from: input),
                  let y = out.featureValue(for: Self.featureOut)?.multiArrayValue else {
                return outByID
            }

            let yStrideT = y.strides[1].intValue
            let yStrideC = y.strides[2].intValue

	            for i in 0..<len {
	                let tokenIdx = start + i
	                if isStrokeStart[tokenIdx] {
	                    predictedDx[tokenIdx] = 0.0
	                    predictedDy[tokenIdx] = 0.0
	                    continue
	                }

                let base = i * yStrideT
                let dxOutNorm = y[base + (0 * yStrideC)].floatValue
                let dyOutNorm = y[base + (1 * yStrideC)].floatValue

                let safeDxOutNorm = dxOutNorm.isFinite ? dxOutNorm : 0.0
                let safeDyOutNorm = dyOutNorm.isFinite ? dyOutNorm : 0.0

	                let dxOutScaled = safeDxOutNorm * stdDx + norm.meanDx
	                let dyOutScaled = safeDyOutNorm * stdDy + norm.meanDy

	                let dxOut = dxOutScaled * invInputScale
	                let dyOut = dyOutScaled * invInputScale

	                predictedDx[tokenIdx] = dxOut.isFinite ? dxOut : 0.0
	                predictedDy[tokenIdx] = dyOut.isFinite ? dyOut : 0.0
	            }

            start += Self.maxLen
        }

	        let t = min(max(blendStrength, 0.0), 1.0)
	        let oneMinusT = 1.0 - t
	        let pointsByID: [UUID: [SIMD2<Float>]] = runs.reduce(into: [:]) { $0[$1.id] = $1.points }

	        var finalDx: [Float] = Array(repeating: 0.0, count: totalTokens)
	        var finalDy: [Float] = Array(repeating: 0.0, count: totalTokens)
	        for i in 0..<totalTokens {
	            if isStrokeStart[i] {
	                finalDx[i] = 0.0
	                finalDy[i] = 0.0
	                continue
	            }
	            var dx = rawDx[i] * oneMinusT + predictedDx[i] * t
	            var dy = rawDy[i] * oneMinusT + predictedDy[i] * t

	            let inDx = rawDx[i]
	            let inDy = rawDy[i]
	            let inMag = simd_length(SIMD2<Float>(inDx, inDy))
	            let outMag = simd_length(SIMD2<Float>(dx, dy))
	            let maxMag = max(1e-4, inMag * maxStepMultiplier)
	            if outMag.isFinite, outMag > maxMag {
	                let s = maxMag / max(outMag, 1e-6)
	                dx *= s
	                dy *= s
	            }
	            finalDx[i] = dx.isFinite ? dx : 0.0
	            finalDy[i] = dy.isFinite ? dy : 0.0
	        }

	        for r in ranges {
	            var outPoints: [SIMD2<Float>] = []
	            outPoints.reserveCapacity(r.pointCount)

	            var cur = r.anchor
	            outPoints.append(cur)
	            if r.pointCount >= 2 {
	                for i in 1..<r.pointCount {
	                    let tokenIdx = r.tokenStart + i
	                    cur.x += finalDx[tokenIdx]
	                    cur.y += finalDy[tokenIdx]
	                    outPoints.append(cur)
	                }
	            }

	            // Keep endpoints stable to prevent global drift that makes words wobble vertically.
	            if r.pointCount >= 2, let inPts = pointsByID[r.id], inPts.count == r.pointCount {
	                let inEnd = inPts[r.pointCount - 1]
	                let outEnd = outPoints[r.pointCount - 1]
	                let correction = SIMD2<Float>(inEnd.x - outEnd.x, inEnd.y - outEnd.y)
	                if correction.x.isFinite && correction.y.isFinite {
	                    let denom = Float(max(1, r.pointCount - 1))
	                    for i in 0..<r.pointCount {
	                        let u = Float(i) / denom
	                        outPoints[i] += correction * u
	                    }
	                }
	            }

	            outByID[r.id] = outPoints
	        }

        return outByID
    }

    func refineStrokePoints(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let id = UUID()
        return refineStrokeRuns([StrokeRun(id: id, points: points)])[id] ?? points
    }
}
