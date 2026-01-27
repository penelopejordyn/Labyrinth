import Foundation
import UIKit
import Vision

enum HandwritingOCR {
    struct RenderConfig {
        var maxDimension: CGFloat = 1024
        var padding: CGFloat = 24
        var minStrokeWidthPx: CGFloat = 3
        var maxStrokeWidthPx: CGFloat = 12
        var backgroundColor: UIColor = .white
        var strokeColor: UIColor = .black
    }

    struct OCRConfig {
        var languages: [String] = ["en-US"]
        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var usesLanguageCorrection: Bool = true
    }

    static func normalizeTextForDeepWriting(_ text: String) -> String {
        // DeepWriting alphabet (70 chars): 0-9 a-z A-Z ' . , - ( ) /
        // Spaces are used for word boundaries and handled separately.
        // We also map a few common “smart” punctuation variants into this alphabet.
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'.,-()/ ")

        var out = String()
        out.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                out.append(" ")
                continue
            }

            // Common Unicode punctuation → DeepWriting-safe ASCII.
            switch scalar.value {
            case 0x2018, 0x2019, 0x02BC: // ‘ ’ ʼ
                out.append("'")
                continue
            case 0x2013, 0x2014: // – —
                out.append("-")
                continue
            default:
                break
            }

            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            }
        }

        // Collapse whitespace runs and trim.
        let parts = out.split(whereSeparator: { $0 == " " })
        return parts.joined(separator: " ")
    }

    static func renderBurstImage(strokes: [Stroke], config: RenderConfig = RenderConfig()) -> CGImage? {
        let strokePointRuns: [(stroke: Stroke, points: [CGPoint])] = strokes.compactMap { stroke in
            let pts = stroke.rawPoints
            guard pts.count >= 2 else { return nil }
            let ox = CGFloat(stroke.origin.x)
            let oy = CGFloat(stroke.origin.y)
            let points = pts.map { p in
                CGPoint(x: ox + CGFloat(p.x), y: oy + CGFloat(p.y))
            }
            return (stroke: stroke, points: points)
        }
        guard !strokePointRuns.isEmpty else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for run in strokePointRuns {
            for p in run.points {
                minX = min(minX, p.x)
                minY = min(minY, p.y)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
        }

        let contentW = max(1, maxX - minX)
        let contentH = max(1, maxY - minY)
        let maxDim = max(1, config.maxDimension)
        let pad = max(0, config.padding)

        let available = max(1, maxDim - 2 * pad)
        let scale = available / max(contentW, contentH)
        if !scale.isFinite || scale <= 0 { return nil }

        let imageSize = CGSize(
            width: ceil(contentW * scale + 2 * pad),
            height: ceil(contentH * scale + 2 * pad)
        )
        if imageSize.width <= 0 || imageSize.height <= 0 { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(config.backgroundColor.cgColor)
            cg.fill(CGRect(origin: .zero, size: imageSize))

            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(config.strokeColor.cgColor)

            for run in strokePointRuns {
                guard run.points.count >= 2 else { continue }

                let wWorld = CGFloat(run.stroke.worldWidth)
                let wPx = min(max(config.minStrokeWidthPx, wWorld * scale), config.maxStrokeWidthPx)
                cg.setLineWidth(wPx)

                cg.beginPath()
                let first = run.points[0]
                cg.move(
                    to: CGPoint(
                        x: (first.x - minX) * scale + pad,
                        y: (first.y - minY) * scale + pad
                    )
                )
                for p in run.points.dropFirst() {
                    cg.addLine(
                        to: CGPoint(
                            x: (p.x - minX) * scale + pad,
                            y: (p.y - minY) * scale + pad
                        )
                    )
                }
                cg.strokePath()
            }
        }

        return image.cgImage
    }

    static func recognizeText(strokes: [Stroke], render: RenderConfig = RenderConfig(), ocr: OCRConfig = OCRConfig()) -> String? {
        guard let image = renderBurstImage(strokes: strokes, config: render) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = ocr.recognitionLevel
        request.usesLanguageCorrection = ocr.usesLanguageCorrection
        request.recognitionLanguages = ocr.languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results, !results.isEmpty else { return nil }

        let ordered = results.sorted {
            // Vision bounding boxes are normalized with origin at bottom-left.
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        let strings: [String] = ordered.compactMap { $0.topCandidates(1).first?.string }.filter { !$0.isEmpty }
        guard !strings.isEmpty else { return nil }
        return strings.joined(separator: " ")
    }
}
