// Frame.swift defines the Frame data model for the 5x5 fractal grid system.
//
// A "Frame" is a bounded local universe. Unlike the previous telescoping
// linked-list architecture, each Frame now contains a sparse 5x5 grid of
// children, enabling infinite panning (via cousins/uncles) and stable zooming
// (via constant scale transitions).

import Foundation

/// A Frame represents a bounded coordinate system (a "Local Universe").
///
/// **The Philosophy:**
/// Instead of one infinite coordinate system that breaks at 10^15, we use
/// a linked list of finite coordinate systems. When zoom exceeds a threshold,
/// we create a new Frame inside the current one and reset the zoom to 1.0.
///
/// **The Analogy:**
/// Like the movie "Men in Black" - the galaxy is inside a marble, which is
/// inside a bag, which is inside a locker. Each level is a separate Frame.
class Frame: Identifiable {
    let id: UUID

    /// Strokes that belong to this specific "depth" or layer of reality
    var strokes: [Stroke] = []

    /// Cards that belong to this Frame (Images, PDFs, Sketches)
    var cards: [Card] = []

    /// The "Universe" containing this frame (nil for root frame)
    weak var parent: Frame?

    /// Which 5x5 slot this frame occupies inside its parent (nil for topmost root).
    var indexInParent: GridIndex?

    /// Sparse instantiation: only allocate children that are actually visited.
    /// Keyed by 5x5 grid index (0...4, 0...4).
    var children: [GridIndex: Frame] = [:]

    /// Cached depth relative to a reference root frame
    /// Positive = child of root (drilled in), Negative = parent of root (telescoped out), 0 = is root
    /// This is set once when the frame is created and never changes
    var depthFromRoot: Int = 0

    /// Initialize a new Frame
    /// - Parameters:
    ///   - parent: The containing universe (nil for root)
    ///   - depth: The depth relative to root (calculated by caller)
    init(id: UUID = UUID(), parent: Frame? = nil, indexInParent: GridIndex? = nil, depth: Int = 0) {
        self.id = id
        self.parent = parent
        self.indexInParent = indexInParent
        self.depthFromRoot = depth
    }
}

// MARK: - 5x5 Fractal Graph Helpers
extension Frame {
    func child(at index: GridIndex) -> Frame {
        let key = index.clamped()
        if let existing = children[key] {
            return existing
        }

        let created = Frame(parent: self, indexInParent: key, depth: depthFromRoot + 1)
        children[key] = created
        return created
    }

    func childIfExists(at index: GridIndex) -> Frame? {
        children[index.clamped()]
    }

    /// If this frame has no parent, create a new super-root above it and place this frame at (2,2).
    @discardableResult
    func ensureSuperRoot() -> Frame {
        if let parent {
            return parent
        }

        let newParent = Frame(depth: depthFromRoot - 1)
        let center = GridIndex.center
        self.parent = newParent
        self.indexInParent = center
        newParent.children[center] = self
        return newParent
    }

    /// Same-depth neighbor resolution using "Up, Over, Down" recursion.
    ///
    /// Important: because `parent` is `weak`, callers must retain any newly-created super-root.
    /// Pass a closure that stores the returned root (e.g. `Coordinator.rootFrame = newRoot`).
    func neighbor(_ direction: GridDirection, retainNewRoot: (Frame) -> Void) -> Frame {
        guard let parent, let indexInParent else {
            let superRoot = ensureSuperRoot()
            retainNewRoot(superRoot)
            return neighbor(direction, retainNewRoot: retainNewRoot)
        }

        let d = direction.delta
        let next = GridIndex(col: indexInParent.col + d.dx, row: indexInParent.row + d.dy)

        if next.isValid {
            return parent.child(at: next)
        }

        let uncle = parent.neighbor(direction, retainNewRoot: retainNewRoot)
        return uncle.child(at: next.wrapped())
    }

    /// Non-instantiating same-depth neighbor lookup.
    /// Returns nil when the neighbor has not been created yet.
    func neighborIfExists(_ direction: GridDirection) -> Frame? {
        guard let parent, let indexInParent else {
            return nil
        }

        let d = direction.delta
        let next = GridIndex(col: indexInParent.col + d.dx, row: indexInParent.row + d.dy)

        if next.isValid {
            return parent.childIfExists(at: next)
        }

        guard let uncle = parent.neighborIfExists(direction) else { return nil }
        return uncle.childIfExists(at: next.wrapped())
    }
}

// MARK: - Serialization (v2 Fractal)
extension Frame {
    func toDTOv2() -> FrameDTOv2 {
        let sortedKeys = children.keys.sorted { lhs, rhs in
            if lhs.row != rhs.row { return lhs.row < rhs.row }
            return lhs.col < rhs.col
        }

        let childDTOs = sortedKeys.compactMap { index -> ChildFrameDTOv2? in
            guard let child = children[index] else { return nil }
            return ChildFrameDTOv2(index: GridIndexDTO(index), frame: child.toDTOv2())
        }

        return FrameDTOv2(
            id: id,
            depthFromRoot: depthFromRoot,
            indexInParent: indexInParent.map { GridIndexDTO($0) },
            strokes: strokes.map { $0.toDTO() },
            cards: cards.map { $0.toDTO() },
            children: childDTOs
        )
    }
}

/*
// MARK: - Legacy Telescoping Frame Model (Reference Only)
//
// class Frame: Identifiable {
//     let id: UUID
//     var strokes: [Stroke] = []
//     var cards: [Card] = []
//     var parent: Frame?
//     var originInParent: SIMD2<Double>
//     var scaleRelativeToParent: Double
//     var children: [Frame] = []
//     var depthFromRoot: Int = 0
//
//     init(id: UUID = UUID(), parent: Frame? = nil, origin: SIMD2<Double> = .zero, scale: Double = 1.0, depth: Int = 0) {
//         self.id = id
//         self.parent = parent
//         self.originInParent = origin
//         self.scaleRelativeToParent = scale
//         self.depthFromRoot = depth
//     }
// }
*/
