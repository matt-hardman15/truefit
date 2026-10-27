import Foundation
import simd

/// A dimension drawn on the model that can be tapped, typed into, or dragged.
struct DimensionAnnotation: Identifiable, Equatable {
    enum Key: Hashable {
        case scanWidth, scanDepth, scanHeight
        case diameter, width, depth, height, hole
        case sectionLength(UUID), sectionSize(UUID), totalLength
    }
    let key: Key
    var id: Key { key }
    /// Short label shown on the model, e.g. "Ø6" or "30".
    let prefix: String
    /// Longer name for the editor bar, e.g. "Thread length".
    let title: String
    let value: Float
    /// Ends of the dimension line, in model millimeters. Dragging moves `end`.
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let minValue: Float
}

extension EditorModel {
    enum ResizeMode: String, CaseIterable, Identifiable {
        case scale = "Scale whole part", stretch = "Stretch at a cut"
        var id: String { rawValue }
    }

    /// Dimensions for whatever is showing in the viewport.
    var annotations: [DimensionAnnotation] {
        shown == .solid ? solidAnnotations : scanAnnotations
    }

    private var gap: Float { max(2.5, simd_length(size) * 0.07) }

    private var scanAnnotations: [DimensionAnnotation] {
        let s = scan.bounds.size
        guard s.x > 0 else { return [] }
        let g = gap, x = s.x / 2, z = s.z / 2
        return [
            .init(key: .scanWidth, prefix: "W", title: "Width", value: s.x,
                  start: [-x, 0, z + g], end: [x, 0, z + g], minValue: 0.5),
            .init(key: .scanDepth, prefix: "D", title: "Depth", value: s.z,
                  start: [x + g, 0, z], end: [x + g, 0, -z], minValue: 0.5),
            .init(key: .scanHeight, prefix: "H", title: "Height", value: s.y,
                  start: [-x - g, 0, z], end: [-x - g, s.y, z], minValue: 0.5),
        ]
    }

    private var solidAnnotations: [DimensionAnnotation] {
        let p = solidParams, g = gap
        switch p.kind {
        case .round:
            let r = p.diameter / 2
            var a: [DimensionAnnotation] = [
                .init(key: .diameter, prefix: "Ø", title: "Diameter", value: p.diameter,
                      start: [-r, p.height + g, 0], end: [r, p.height + g, 0], minValue: 1),
                .init(key: .height, prefix: "H", title: "Height", value: p.height,
                      start: [r + g, 0, 0], end: [r + g, p.height, 0], minValue: 0.4),
            ]
            if p.hole != .none {
                let h = p.holeSize / 2
                a.append(.init(key: .hole, prefix: p.hole == .hex ? "AF" : "Ø", title: "Hole", value: p.holeSize,
                               start: [-h, p.height + g * 0.4, r * 0.3], end: [h, p.height + g * 0.4, r * 0.3], minValue: 0.5))
            }
            return a
        case .block:
            let x = p.width / 2, z = p.depth / 2
            var a: [DimensionAnnotation] = [
                .init(key: .width, prefix: "W", title: "Width", value: p.width,
                      start: [-x, 0, z + g], end: [x, 0, z + g], minValue: 1),
                .init(key: .depth, prefix: "D", title: "Depth", value: p.depth,
                      start: [x + g, 0, z], end: [x + g, 0, -z], minValue: 1),
                .init(key: .height, prefix: "H", title: "Height", value: p.height,
                      start: [-x - g, 0, z], end: [-x - g, p.height, z], minValue: 0.4),
            ]
            if p.hole != .none {
                let h = p.holeSize / 2
                a.append(.init(key: .hole, prefix: p.hole == .hex ? "AF" : "Ø", title: "Hole", value: p.holeSize,
                               start: [-h, p.height + g * 0.4, 0], end: [h, p.height + g * 0.4, 0], minValue: 0.5))
            }
            return a
        case .turned:
            let part = p.turned
            let R = part.maxRadius
            var a = [DimensionAnnotation]()
            for (i, s) in part.sections.enumerated() {
                let span = part.span(of: i)
                let x = R + g
                a.append(.init(key: .sectionLength(s.id), prefix: "", title: "\(s.name) length", value: s.length,
                               start: [x, span.start, 0], end: [x, span.end, 0], minValue: 0.3))
                let r = s.size / 2
                let y = (span.start + span.end) / 2
                let z = R + g * 0.6
                a.append(.init(key: .sectionSize(s.id), prefix: s.shape == .hex ? "AF" : (s.thread != nil ? "M" : "Ø"),
                               title: s.shape == .hex ? "Across flats" : (s.thread != nil ? "Thread diameter" : "Diameter"),
                               value: s.size, start: [-r, y, z], end: [r, y, z], minValue: 0.5))
            }
            let x = -(R + g)
            a.append(.init(key: .totalLength, prefix: "L", title: "Overall length", value: part.totalLength,
                           start: [x, 0, 0], end: [x, part.totalLength, 0], minValue: 1))
            return a
        }
    }

    func annotation(_ key: DimensionAnnotation.Key) -> DimensionAnnotation? {
        annotations.first { $0.key == key }
    }

    /// Changes one dimension. Scans scale or stretch depending on the resize
    /// mode; rebuilt shapes change just that feature.
    func setValue(_ value: Float, for key: DimensionAnnotation.Key) {
        let v = (value * 100).rounded() / 100
        let isScanKey = key == .scanWidth || key == .scanDepth || key == .scanHeight
        if !isScanKey && !canEditSolid {
            selectedDimension = nil
            proPrompt = .rebuild
            return
        }
        switch key {
        case .scanWidth: resizeScan(axis: 0, to: v)
        case .scanHeight: resizeScan(axis: 1, to: v)
        case .scanDepth: resizeScan(axis: 2, to: v)
        case .diameter: editSolid { $0.diameter = max(1, v) }
        case .width: editSolid { $0.width = max(1, v) }
        case .depth: editSolid { $0.depth = max(1, v) }
        case .height: editSolid { $0.height = max(0.4, v) }
        case .hole: editSolid { $0.holeSize = max(0.5, v) }
        case .sectionLength(let id):
            editSolid { p in
                if let i = p.turned.sections.firstIndex(where: { $0.id == id }) { p.turned.sections[i].length = max(0.3, v) }
            }
        case .sectionSize(let id):
            editSolid { p in
                guard let i = p.turned.sections.firstIndex(where: { $0.id == id }) else { return }
                p.turned.sections[i].size = max(0.5, v)
                if p.turned.sections[i].thread != nil, let std = MetricThread.nearest(to: v) {
                    p.turned.sections[i].thread = std
                }
            }
        case .totalLength:
            // Longer or shorter overall: change the longest section, the shank on a bolt.
            editSolid { p in
                guard let i = p.turned.sections.indices.max(by: { p.turned.sections[$0].length < p.turned.sections[$1].length }) else { return }
                let others = p.turned.totalLength - p.turned.sections[i].length
                p.turned.sections[i].length = max(0.3, v - others)
            }
        }
    }

    /// Scale mode resizes the whole scan; stretch mode cuts it at a plane and
    /// moves everything past the cut, so features on either side keep their size.
    func resizeScan(axis: Int, to value: Float) {
        switch resizeMode {
        case .scale:
            setDimension(axis, to: value)
        case .stretch:
            let current = scanSize[axis]
            let delta = value - current
            let floor = -(current - settings.stretch[axis]) * 0.9   // can't shrink past the part
            settings.stretch[axis] = max(floor, settings.stretch[axis] + delta)
            stretchAxis = axis
        }
    }
}
