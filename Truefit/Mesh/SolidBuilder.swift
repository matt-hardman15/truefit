import Foundation
import simd

/// The editable shape that replaces a scan. All sizes in millimeters.
struct SolidParams: Equatable, Sendable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Sendable, Codable {
        case round = "Round", block = "Block", turned = "Bolt / pin"
        var id: String { rawValue }
    }
    enum Hole: String, CaseIterable, Identifiable, Sendable, Codable {
        case none = "No hole", round = "Round", dShaft = "D-shaft", hex = "Hex nut"
        var id: String { rawValue }
    }

    var kind: Kind = .round
    var diameter: Float = 30
    var width: Float = 30
    var depth: Float = 30
    var height: Float = 16
    var cornerRadius: Float = 2
    var chamfer: Float = 0.6
    var hole: Hole = .none
    var holeSize: Float = 6   // diameter, or across-flats for hex
    var turned = TurnedPart.sampleBolt

    var outerMin: Float { kind == .round ? diameter : min(width, depth) }
}

enum SolidBuilder {
    static func build(_ p: SolidParams) -> Mesh {
        if p.kind == .turned { return p.turned.mesh() }
        let h = max(0.4, p.height)
        let chamfer = max(0, min(p.chamfer, h / 2 - 0.1, p.outerMin / 4))
        let outer: Prism.Loop
        switch p.kind {
        case .round:
            let r = p.diameter / 2
            outer = Prism.loop(count: 192, reach: r * 1.5) { simd_length($0) - r }
        case .block, .turned:
            let w = p.width / 2, d = p.depth / 2
            let c = max(0, min(p.cornerRadius, min(w, d) - 0.05))
            outer = Prism.loop(count: 192, reach: (w + d) * 1.5) { Prism.roundedRect($0, w, d, c) }
        }
        var hole: Prism.Loop?
        if p.hole != .none, p.holeSize > 0, p.holeSize < p.outerMin - 2 * chamfer - 0.8 {
            hole = holeLoop(p.hole, size: p.holeSize)
        }
        return Prism.extrude(outer: outer, hole: hole, height: h, chamfer: chamfer)
    }

    static func holeLoop(_ hole: SolidParams.Hole, size: Float) -> Prism.Loop? {
        let r = size / 2
        switch hole {
        case .none:
            return nil
        case .round:
            return Prism.loop(count: 96, reach: r * 2) { simd_length($0) - r }
        case .hex:
            // across flats = size; 96 samples put a vertex on every corner
            return Prism.loop(count: 96, reach: size) { p in
                let a = atan2(p.y, p.x)
                let sector = Float.pi / 3
                var off = a.truncatingRemainder(dividingBy: sector)
                if off < 0 { off += sector }
                return simd_length(p) * cos(off - sector / 2) - r
            }
        case .dShaft:
            // flat side at 75% of the diameter, the common motor-shaft profile
            return Prism.loop(count: 96, reach: r * 2) { p in max(simd_length(p) - r, p.y - r * 0.5) }
        }
    }

    /// A procedurally made "phone scan" of a knurled knob, for trying the app
    /// without scanning: slightly oversized, noisy, tilted, with stray pieces,
    /// in meters like a real capture.
    static func sampleScan() -> Mesh {
        let ribs: Float = 30
        let outline = Prism.loop(count: 360, reach: 25) { p in
            let a = atan2(p.y, p.x)
            return simd_length(p) - (15.2 + 0.45 * pow(max(0, cos(a * ribs)), 3))
        }
        var knob = Prism.extrude(outer: outline, hole: holeLoop(.dShaft, size: 6), height: 17, chamfer: 1)
        knob = subdivideLongEdges(knob, maxEdge: 1.2)

        var positions = knob.positions
        var indices = knob.indices
        func addBlob(center: SIMD3<Float>, radius: Float) {
            let m = sphere(radius: radius)
            let base = UInt32(positions.count)
            positions += m.positions.map { $0 + center }
            indices += m.indices.map { $0 + base }
        }
        addBlob(center: SIMD3<Float>(21, 6, 4), radius: 1.6)
        addBlob(center: SIMD3<Float>(-19, -2, -6), radius: 2.2)

        positions = positions.map { p in
            let n = 0.16 * sin(p.x * 3.1 + p.z * 1.7) * cos(p.y * 2.9 - p.z * 2.3)
                + 0.1 * sin(p.x * 7.3 + p.y * 6.1 + p.z * 5.2)
            return SIMD3<Float>(p.x * 1.012 + n, p.y + n * 0.8, p.z * 1.012 - n)
        }
        let tilt = simd_float4x4(simd_quatf(angle: 0.16, axis: simd_normalize(SIMD3<Float>(1, 0.3, 0.2))))
        let meters = simd_float4x4(diagonal: SIMD4<Float>(0.001, 0.001, 0.001, 1))
        return Mesh(positions: positions, indices: indices).transformed(meters * tilt)
    }

    static func sphere(radius: Float, rings: Int = 12, segments: Int = 18) -> Mesh {
        var pos = [SIMD3<Float>](), idx = [UInt32]()
        pos.append([0, radius, 0])
        for i in 1..<rings {
            let th = Float(i) / Float(rings) * .pi
            for j in 0..<segments {
                let ph = Float(j) / Float(segments) * 2 * .pi
                pos.append(SIMD3(radius * sin(th) * cos(ph), radius * cos(th), radius * sin(th) * sin(ph)))
            }
        }
        pos.append([0, -radius, 0])
        let bottom = UInt32(pos.count - 1)
        func v(_ ring: Int, _ seg: Int) -> UInt32 { UInt32(1 + (ring - 1) * segments + (seg % segments)) }
        for j in 0..<segments { idx += [0, v(1, j + 1), v(1, j)] }
        for i in 1..<(rings - 1) {
            for j in 0..<segments {
                idx += [v(i, j), v(i, j + 1), v(i + 1, j), v(i, j + 1), v(i + 1, j + 1), v(i + 1, j)]
            }
        }
        for j in 0..<segments { idx += [bottom, v(rings - 1, j), v(rings - 1, j + 1)] }
        let m = Mesh(positions: pos, indices: idx)
        return Completion.signedVolume(m) < 0 ? Completion.flipped(m) : m
    }

    /// A "phone scan" of an M6×30 bolt lying on its side: the side touching the
    /// table is missing, the way a real single-lap capture comes out. Shows off
    /// rebuilding a full part from its symmetry.
    static func sampleBoltScan() -> Mesh {
        var m = subdivideLongEdges(TurnedPart.sampleBolt.mesh(), maxEdge: 0.7, rounds: 6)
        m = m.transformed(simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 0, 1))))
        let b = m.bounds
        let hidden = b.min.y + 0.22 * b.size.y
        var remap = [Int32](repeating: -1, count: m.positions.count)
        var pos = [SIMD3<Float>](), idx = [UInt32]()
        var t = 0
        while t < m.indices.count {
            let tri = [Int(m.indices[t]), Int(m.indices[t + 1]), Int(m.indices[t + 2])]
            if tri.contains(where: { m.positions[$0].y > hidden }) {
                for v in tri {
                    if remap[v] < 0 { remap[v] = Int32(pos.count); pos.append(m.positions[v]) }
                    idx.append(UInt32(remap[v]))
                }
            }
            t += 3
        }
        pos = pos.map { p in
            let n = 0.05 * sin(p.x * 4.1 + p.z * 2.3) * cos(p.y * 3.7) + 0.04 * sin(p.x * 9.1 + p.y * 7.7 + p.z * 6.3)
            return p + SIMD3<Float>(n, n * 0.8, -n)
        }
        let turn = simd_float4x4(simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0)))
        let meters = simd_float4x4(diagonal: SIMD4<Float>(0.001, 0.001, 0.001, 1))
        return Mesh(positions: pos, indices: idx).transformed(meters * turn)
    }

    /// Splits edges longer than `maxEdge` so the sample has scan-like vertex
    /// density. Decisions are per edge, so neighbors always agree and the
    /// surface stays closed.
    static func subdivideLongEdges(_ mesh: Mesh, maxEdge: Float, rounds: Int = 5) -> Mesh {
        var m = mesh
        for _ in 0..<rounds {
            var pos = m.positions
            var idx = [UInt32]()
            idx.reserveCapacity(m.indices.count * 2)
            var mid = [UInt64: UInt32]()
            var changed = false
            func split(_ a: UInt32, _ b: UInt32) -> UInt32? {
                guard simd_distance(m.positions[Int(a)], m.positions[Int(b)]) > maxEdge else { return nil }
                let key = a < b ? (UInt64(a) << 32) | UInt64(b) : (UInt64(b) << 32) | UInt64(a)
                if let v = mid[key] { return v }
                pos.append((m.positions[Int(a)] + m.positions[Int(b)]) * 0.5)
                let v = UInt32(pos.count - 1)
                mid[key] = v
                return v
            }
            var t = 0
            while t < m.indices.count {
                var v = [m.indices[t], m.indices[t + 1], m.indices[t + 2]]
                var s: [UInt32?] = [split(v[0], v[1]), split(v[1], v[2]), split(v[2], v[0])]
                let count = s.compactMap { $0 }.count
                // rotate so the pattern starts at edge 0
                var turns = 0
                while turns < 3 {
                    let ok: Bool
                    switch count {
                    case 1: ok = s[0] != nil
                    case 2: ok = s[0] != nil && s[1] != nil
                    default: ok = true
                    }
                    if ok { break }
                    v = [v[1], v[2], v[0]]
                    s = [s[1], s[2], s[0]]
                    turns += 1
                }
                let (a, b, c) = (v[0], v[1], v[2])
                switch count {
                case 0:
                    idx += [a, b, c]
                case 1:
                    let ab = s[0]!
                    idx += [a, ab, c, ab, b, c]
                case 2:
                    let ab = s[0]!, bc = s[1]!
                    idx += [ab, b, bc, a, ab, bc, a, bc, c]
                default:
                    let ab = s[0]!, bc = s[1]!, ca = s[2]!
                    idx += [a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca]
                }
                if count > 0 { changed = true }
                t += 3
            }
            m = Mesh(positions: pos, indices: idx)
            if !changed { break }
        }
        return m
    }
}


/// Builds closed prisms (extruded outlines) directly, so every part is a
/// watertight mesh we control. Outlines are star-shaped around the origin and
/// sampled at evenly spaced angles; X/Z is the bed plane and Y is up.
enum Prism {
    struct Loop {
        var points: [SIMD2<Float>]
        var normals: [SIMD2<Float>]
    }

    /// Samples a shape given by its signed distance function along rays from the center.
    static func loop(count: Int, reach: Float, sdf: (SIMD2<Float>) -> Float) -> Loop {
        var pts = [SIMD2<Float>](), nrm = [SIMD2<Float>]()
        for k in 0..<count {
            let a = -Float.pi + 2 * .pi * Float(k) / Float(count)
            let d = SIMD2<Float>(cos(a), sin(a))
            var lo: Float = 0, hi = reach
            for _ in 0..<40 {
                let m = (lo + hi) / 2
                if sdf(d * m) < 0 { lo = m } else { hi = m }
            }
            let p = d * lo
            let e: Float = 1e-3
            var g = SIMD2<Float>(sdf(p + [e, 0]) - sdf(p - [e, 0]), sdf(p + [0, e]) - sdf(p - [0, e]))
            let len = simd_length(g)
            g = len > 0 ? g / len : d
            pts.append(p); nrm.append(g)
        }
        return Loop(points: pts, normals: nrm)
    }

    static func roundedRect(_ p: SIMD2<Float>, _ w: Float, _ d: Float, _ r: Float) -> Float {
        let q = abs(p) - SIMD2<Float>(w - r, d - r)
        return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - r
    }

    static func extrude(outer: Loop, hole: Loop?, height h: Float, chamfer c: Float) -> Mesh {
        var V = [SIMD3<Float>](), F = [UInt32]()
        let n = outer.points.count
        func addLoop(_ pts: [SIMD2<Float>], _ y: Float) -> Int {
            let s = V.count
            for p in pts { V.append(SIMD3(p.x, y, p.y)) }
            return s
        }
        let inset = zip(outer.points, outer.normals).map { $0 - $1 * c }
        let rows: [(Float, [SIMD2<Float>])] = c > 0
            ? [(0, inset), (c, outer.points), (h - c, outer.points), (h, inset)]
            : [(0, outer.points), (h, outer.points)]
        let starts = rows.map { addLoop($0.1, $0.0) }
        func quads(_ s0: Int, _ s1: Int, _ count: Int, reversed: Bool) {
            for i in 0..<count {
                let a = UInt32(s0 + i), b = UInt32(s1 + i)
                let cc = UInt32(s0 + (i + 1) % count), d = UInt32(s1 + (i + 1) % count)
                F += reversed ? [a, b, cc, cc, b, d] : [a, cc, b, cc, d, b]
            }
        }
        for r in 0..<(rows.count - 1) { quads(starts[r], starts[r + 1], n, reversed: false) }
        func tri(_ t: (Int, Int, Int), top: Bool) {
            F += top ? [UInt32(t.0), UInt32(t.2), UInt32(t.1)] : [UInt32(t.0), UInt32(t.1), UInt32(t.2)]
        }
        func cap(outerStart so: Int, innerStart si: Int?, innerCount m: Int, y: Float, top: Bool) {
            guard let si else {
                let center = V.count
                V.append(SIMD3(0, y, 0))
                for i in 0..<n { tri((so + i, center, so + (i + 1) % n), top: top) }
                return
            }
            var i = 0, j = 0
            while i < n || j < m {
                let ao = -Float.pi + 2 * .pi * Float(i + 1) / Float(n)
                let ai = -Float.pi + 2 * .pi * Float(j + 1) / Float(m)
                if j == m || (i < n && ao <= ai) {
                    tri((so + i, si + j % m, so + (i + 1) % n), top: top); i += 1
                } else {
                    tri((so + i % n, si + j, si + (j + 1) % m), top: top); j += 1
                }
            }
        }
        if let hole {
            let m = hole.points.count
            let hb = addLoop(hole.points, 0), ht = addLoop(hole.points, h)
            quads(hb, ht, m, reversed: true)
            cap(outerStart: starts[0], innerStart: hb, innerCount: m, y: 0, top: false)
            cap(outerStart: starts[starts.count - 1], innerStart: ht, innerCount: m, y: h, top: true)
        } else {
            cap(outerStart: starts[0], innerStart: nil, innerCount: 0, y: 0, top: false)
            cap(outerStart: starts[starts.count - 1], innerStart: nil, innerCount: 0, y: h, top: true)
        }
        let mesh = Mesh(positions: V, indices: F)
        return Completion.signedVolume(mesh) < 0 ? Completion.flipped(mesh) : mesh
    }
}
