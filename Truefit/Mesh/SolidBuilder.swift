import Foundation
import SceneKit
import UIKit
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
        let path: UIBezierPath
        switch p.kind {
        case .round:
            let r = CGFloat(p.diameter / 2)
            path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        case .block, .turned:
            let w = CGFloat(p.width), d = CGFloat(p.depth)
            let c = CGFloat(max(0, min(p.cornerRadius, min(p.width, p.depth) / 2 - 0.05)))
            path = UIBezierPath(roundedRect: CGRect(x: -w / 2, y: -d / 2, width: w, height: d), cornerRadius: c)
        }
        if p.hole != .none, p.holeSize > 0, p.holeSize < p.outerMin - 2 * chamfer - 0.8 {
            path.append(holePath(p.hole, size: CGFloat(p.holeSize)))
            path.usesEvenOddFillRule = true
        }
        path.flatness = 0.02

        let shape = SCNShape(path: path, extrusionDepth: CGFloat(h))
        shape.chamferRadius = CGFloat(chamfer)
        shape.chamferMode = .both
        // Flatten so the generated geometry is fully built before we read it.
        let node = SCNNode(geometry: shape).flattenedClone()
        guard let geo = node.geometry else { return .empty }
        let raw = MeshIO.mesh(from: geo)

        // SCNShape extrudes along Z around the origin; stand it up on Y.
        let standUp = simd_float4x4(rows: [
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(0, 0, 0, 1),
        ])
        return raw.transformed(standUp).droppedToBed()
    }

    static func holePath(_ hole: SolidParams.Hole, size: CGFloat) -> UIBezierPath {
        let r = size / 2
        switch hole {
        case .none:
            return UIBezierPath()
        case .round:
            return UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: size, height: size))
        case .hex:
            let path = UIBezierPath()
            let R = size / sqrt(3)
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                let pt = CGPoint(x: R * cos(a), y: R * sin(a))
                if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.close()
            return path
        case .dShaft:
            // flat side at 75% of the diameter, the common motor-shaft profile
            let path = UIBezierPath()
            let a0 = asin(0.5)               // flat sits r/2 from the center
            let sweep = CGFloat.pi + 2 * a0  // the long way round, below the flat
            for k in 0...64 {
                let a = a0 - sweep * CGFloat(k) / 64
                let pt = CGPoint(x: r * cos(a), y: r * sin(a))
                if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.close()
            return path
        }
    }

    /// A procedurally made "phone scan" of a knurled knob, for trying the app
    /// without scanning: slightly oversized, noisy, tilted, with stray pieces,
    /// in meters like a real capture.
    static func sampleScan() -> Mesh {
        let ribs = 30
        let outline = UIBezierPath()
        for k in 0...360 {
            let a = CGFloat(k) / 360 * 2 * .pi
            let r = 15.2 + 0.45 * pow(max(0, cos(a * CGFloat(ribs))), 3)
            let pt = CGPoint(x: r * cos(a), y: r * sin(a))
            if k == 0 { outline.move(to: pt) } else { outline.addLine(to: pt) }
        }
        outline.close()
        outline.append(holePath(.dShaft, size: 6))
        outline.usesEvenOddFillRule = true
        let shape = SCNShape(path: outline, extrusionDepth: 17)
        shape.chamferRadius = 1
        let geo = SCNNode(geometry: shape).flattenedClone().geometry ?? shape
        var knob = MeshIO.mesh(from: geo)
        knob = subdivideLongEdges(knob, maxEdge: 1.2)

        var positions = knob.positions
        var indices = knob.indices
        func addBlob(center: SIMD3<Float>, radius: Float) {
            let s = SCNSphere(radius: CGFloat(radius)); s.segmentCount = 16
            let m = MeshIO.mesh(from: SCNNode(geometry: s).flattenedClone().geometry ?? s)
            let base = UInt32(positions.count)
            positions += m.positions.map { $0 + center }
            indices += m.indices.map { $0 + base }
        }
        addBlob(center: SIMD3<Float>(21, 6, 4), radius: 1.6)
        addBlob(center: SIMD3<Float>(-19, -12, -6), radius: 2.2)

        positions = positions.map { p in
            let n = 0.16 * sin(p.x * 3.1 + p.z * 1.7) * cos(p.y * 2.9 - p.z * 2.3)
                + 0.1 * sin(p.x * 7.3 + p.y * 6.1 + p.z * 5.2)
            return SIMD3<Float>(p.x * 1.012 + n, p.y * 1.012 - n, p.z + n * 0.8)
        }
        let tilt = simd_float4x4(simd_quatf(angle: 0.16, axis: simd_normalize(SIMD3<Float>(1, 0.3, 0.2))))
        // stand it on Y (SCNShape extrudes along Z), tilt, convert to meters
        let standUp = simd_float4x4(rows: [
            SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, -1, 0, 0), SIMD4<Float>(0, 0, 0, 1),
        ])
        let meters = simd_float4x4(diagonal: SIMD4<Float>(0.001, 0.001, 0.001, 1))
        return Mesh(positions: positions, indices: indices).transformed(meters * tilt * standUp)
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
