import Foundation
import simd

struct LinkedStrokeKey: Hashable {
    let strokeID: UUID
    let frameID: ObjectIdentifier
    let cardID: ObjectIdentifier?
}

struct LinkedStrokeRef {
    enum Container {
        case canvas(frame: Frame)
        case card(card: Card, frame: Frame)
    }

    let key: LinkedStrokeKey
    let container: Container
    let stroke: Stroke
    let depthID: UInt32
}

struct StrokeLinkSelection {
    var strokes: [LinkedStrokeRef]
    var keys: Set<LinkedStrokeKey>
    var handleActiveWorld: SIMD2<Double>

    init(strokes: [LinkedStrokeRef] = [],
         handleActiveWorld: SIMD2<Double> = .zero) {
        self.strokes = strokes
        self.keys = Set(strokes.map(\.key))
        self.handleActiveWorld = handleActiveWorld
    }

    mutating func insert(_ ref: LinkedStrokeRef) {
        guard keys.insert(ref.key).inserted else { return }
        strokes.append(ref)
    }

    mutating func remove(_ key: LinkedStrokeKey) {
        guard keys.remove(key) != nil else { return }
        if let idx = strokes.firstIndex(where: { $0.key == key }) {
            strokes.remove(at: idx)
        }
    }
}
