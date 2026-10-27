import Foundation
import simd

/// A part made of coaxial sections stacked along its axis: bolts, screws,
/// pins, standoffs, spacers, shafts. Built standing up with section 0 on the bed.
struct TurnedPart: Equatable, Sendable, Codable {
    struct Section: Equatable, Sendable, Identifiable, Codable {
        enum Shape: String, CaseIterable, Identifiable, Sendable, Codable {
            case round = "Round", hex = "Hex"
            var id: String { rawValue }
        }
        var id = UUID()
        var shape: Shape = .round
        /// Diameter for round sections, across-flats for hex.
        var size: Float
        var length: Float
        /// ISO metric thread, when the section is threaded.
        var thread: MetricThread?
        /// Chamfer on the top edge.
        var chamfer: Float = 0

        var name: String {
            if thread != nil { return "Thread" }
            return shape == .hex ? "Hex" : "Round"
        }
    }

    var sections: [Section]
    /// Gap between printed threads and their mating part, in mm on the diameter.
    var threadFit: ThreadFit = .standard

    enum ThreadFit: String, CaseIterable, Identifiable, Sendable, Codable {
        case tight = "Tight", standard = "Standard", loose = "Loose"
        var id: String { rawValue }
        var clearance: Float { switch self { case .tight: 0.1; case .standard: 0.2; case .loose: 0.35 } }
    }

    /// The smallest threaded section, if it is too fine to print reliably.
    var fineThreadWarning: String? {
        guard let t = sections.compactMap(\.thread).min(by: { $0.nominal < $1.nominal }), t.nominal < 5 else { return nil }
        return "\(t.name) threads are finer than most FDM printers can form. Print with a 0.2 mm nozzle and 0.08 mm layers, or use a real screw for sizes below M5."
    }

    var totalLength: Float { sections.reduce(0) { $0 + $1.length } }
    var maxRadius: Float {
        sections.map { $0.shape == .hex ? $0.size / sqrt(3) : $0.size / 2 }.max() ?? 0
    }

    /// Y range of a section.
    func span(of index: Int) -> (start: Float, end: Float) {
        let start = sections.prefix(index).reduce(0) { $0 + $1.length }
        return (start, start + sections[index].length)
    }

    init(sections: [Section], threadFit: ThreadFit = .standard) {
        self.sections = sections
        self.threadFit = threadFit
    }

    static let sampleBolt = TurnedPart(sections: [
        Section(shape: .hex, size: 10, length: 4, chamfer: 0.4),
        Section(shape: .round, size: 6, length: 30, thread: MetricThread.standard(6)),
    ])
}

/// ISO 261 coarse threads with ISO 4017 hex head sizes.
struct MetricThread: Equatable, Sendable, Hashable, Identifiable, Codable {
    let nominal: Float
    let pitch: Float
    let headAcrossFlats: Float
    let headHeight: Float
    var id: Float { nominal }
    /// ISO 4032 nut height, about 0.8 × the diameter.
    var nutHeight: Float { (nominal * 0.8 * 10).rounded() / 10 }
    var name: String { "M\(nominal.clean)×\(pitch.clean)" }

    static let coarse: [MetricThread] = [
        .init(nominal: 2, pitch: 0.4, headAcrossFlats: 4, headHeight: 1.4),
        .init(nominal: 2.5, pitch: 0.45, headAcrossFlats: 5, headHeight: 1.7),
        .init(nominal: 3, pitch: 0.5, headAcrossFlats: 5.5, headHeight: 2),
        .init(nominal: 4, pitch: 0.7, headAcrossFlats: 7, headHeight: 2.8),
        .init(nominal: 5, pitch: 0.8, headAcrossFlats: 8, headHeight: 3.5),
        .init(nominal: 6, pitch: 1.0, headAcrossFlats: 10, headHeight: 4),
        .init(nominal: 8, pitch: 1.25, headAcrossFlats: 13, headHeight: 5.3),
        .init(nominal: 10, pitch: 1.5, headAcrossFlats: 16, headHeight: 6.4),
        .init(nominal: 12, pitch: 1.75, headAcrossFlats: 18, headHeight: 7.5),
        .init(nominal: 14, pitch: 2.0, headAcrossFlats: 21, headHeight: 8.8),
        .init(nominal: 16, pitch: 2.0, headAcrossFlats: 24, headHeight: 10),
        .init(nominal: 20, pitch: 2.5, headAcrossFlats: 30, headHeight: 12.5),
    ]

    static func standard(_ nominal: Float) -> MetricThread? { coarse.first { $0.nominal == nominal } }

    /// Closest standard size, if the measured diameter is within 0.7 mm of it.
    static func nearest(to diameter: Float) -> MetricThread? {
        guard let best = coarse.min(by: { abs($0.nominal - diameter) < abs($1.nominal - diameter) }),
              abs(best.nominal - diameter) < 0.7 else { return nil }
        return best
    }
}

extension Float {
    /// "6" instead of "6.0", "1.25" stays "1.25".
    var clean: String {
        let s = String(format: "%.2f", self)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

// MARK: - Mesh

extension TurnedPart {
    static let segments = 72   // divisible by 6 so hex corners land on vertices

    func mesh() -> Mesh {
        let n = Self.segments
        let angles = (0..<n).map { Float($0) * 2 * .pi / Float(n) }
        var rows: [(y: Float, r: [Float])] = []
        var y: Float = 0
        for s in sections where s.length > 0 && s.size > 0 {
            let y0 = y, y1 = y + s.length
            let base: [Float] = angles.map { s.shape == .hex ? Self.hexRadius(acrossFlats: s.size, angle: $0) : s.size / 2 }
            if let t = s.thread {
                let shrink = threadFit.clearance / 2        // leave half the fit gap on the bolt
                let major = s.size / 2 - shrink
                let minor = major - 0.5413 * t.pitch          // ISO basic profile depth
                let steps = max(4, Int(((y1 - y0) / (t.pitch / 10)).rounded(.up)))
                for i in 0...steps {
                    let yy = y0 + (y1 - y0) * Float(i) / Float(steps)
                    let taper = min(1, max(0, (y1 - yy) / t.pitch))  // lead-in at the tip
                    let r = angles.map { a -> Float in
                        let phase = (yy - y0) / t.pitch - a / (2 * .pi)
                        let f = phase - phase.rounded(.down)
                        let profile: Float
                        switch f {
                        case ..<0.125: profile = 1
                        case ..<0.4375: profile = 1 - (f - 0.125) / 0.3125
                        case ..<0.6875: profile = 0
                        default: profile = (f - 0.6875) / 0.3125
                        }
                        return min(minor + (major - minor) * profile, minor + (major - minor) * taper)
                    }
                    rows.append((yy, r))
                }
            } else {
                rows.append((y0, base))
                let c = min(s.chamfer, s.length * 0.45, (base.min() ?? 0) * 0.9)
                if c > 0 {
                    rows.append((y1 - c, base))
                    rows.append((y1, base.map { max(0.01, $0 - c) }))
                } else {
                    rows.append((y1, base))
                }
            }
            y = y1
        }
        guard rows.count >= 2 else { return .empty }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(rows.count * n + 2)
        for row in rows {
            for k in 0..<n {
                positions.append(SIMD3(row.r[k] * cos(angles[k]), row.y, row.r[k] * sin(angles[k])))
            }
        }
        var indices = [UInt32]()
        indices.reserveCapacity(rows.count * n * 6 + n * 6)
        for i in 0..<(rows.count - 1) {
            for k in 0..<n {
                let a = UInt32(i * n + k), b = UInt32((i + 1) * n + k)
                let c = UInt32(i * n + (k + 1) % n), d = UInt32((i + 1) * n + (k + 1) % n)
                indices += [a, b, c, c, b, d]
            }
        }
        let bottom = UInt32(positions.count)
        positions.append(SIMD3(0, rows[0].y, 0))
        let top = UInt32(positions.count)
        positions.append(SIMD3(0, rows[rows.count - 1].y, 0))
        let last = (rows.count - 1) * n
        for k in 0..<n {
            indices += [bottom, UInt32(k), UInt32((k + 1) % n)]
            indices += [top, UInt32(last + (k + 1) % n), UInt32(last + k)]
        }
        return Mesh(positions: positions, indices: indices)
    }

    /// Radius of an ISO external thread surface at a height and angle.
    static func threadRadius(major: Float, pitch: Float, y: Float, angle: Float) -> Float {
        let minor = major - 0.5413 * pitch
        let phase = y / pitch - angle / (2 * .pi)
        let f = phase - phase.rounded(.down)
        let profile: Float
        switch f {
        case ..<0.125: profile = 1
        case ..<0.4375: profile = 1 - (f - 0.125) / 0.3125
        case ..<0.6875: profile = 0
        default: profile = (f - 0.6875) / 0.3125
        }
        return minor + (major - minor) * profile
    }

    /// The bolt's thread, if any, for making a matching nut.
    var mainThread: MetricThread? { sections.compactMap(\.thread).max { $0.nominal < $1.nominal } }

    /// A standard hex nut that screws onto this part's thread, with the other
    /// half of the fit gap on its internal thread.
    func matchingNut() -> Mesh {
        guard let t = mainThread else { return .empty }
        let n = Self.segments
        let angles = (0..<n).map { Float($0) * 2 * .pi / Float(n) }
        let height = t.nutHeight
        let steps = max(4, Int((height / (t.pitch / 10)).rounded(.up)))
        let ys = (0...steps).map { height * Float($0) / Float(steps) }
        let grow = threadFit.clearance / 2
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(ys.count * n * 2)
        for y in ys {
            for (k, a) in angles.enumerated() {
                let r = Self.hexRadius(acrossFlats: t.headAcrossFlats, angle: a)
                positions.append(SIMD3(r * cos(angles[k]), y, r * sin(angles[k])))
            }
        }
        let innerStart = positions.count
        for y in ys {
            for a in angles {
                let r = Self.threadRadius(major: t.nominal / 2, pitch: t.pitch, y: y, angle: a) + grow
                positions.append(SIMD3(r * cos(a), y, r * sin(a)))
            }
        }
        var indices = [UInt32]()
        let rows = ys.count
        for i in 0..<(rows - 1) {
            for k in 0..<n {
                let a = UInt32(i * n + k), b = UInt32((i + 1) * n + k)
                let c = UInt32(i * n + (k + 1) % n), d = UInt32((i + 1) * n + (k + 1) % n)
                indices += [a, b, c, c, b, d]                       // outside faces out
                let o = UInt32(innerStart)
                indices += [o + a, o + c, o + b, o + c, o + d, o + b] // thread faces in
            }
        }
        let lo = UInt32(0), li = UInt32(innerStart)
        let to = UInt32((rows - 1) * n), ti = UInt32(innerStart + (rows - 1) * n)
        for k in 0..<n {
            let k0 = UInt32(k), k1 = UInt32((k + 1) % n)
            indices += [lo + k0, lo + k1, li + k0, lo + k1, li + k1, li + k0]   // bottom faces down
            indices += [to + k0, ti + k0, to + k1, to + k1, ti + k0, ti + k1]   // top faces up
        }
        return Mesh(positions: positions, indices: indices)
    }

    static func hexRadius(acrossFlats af: Float, angle: Float) -> Float {
        let sector = Float.pi / 3
        let a = angle.truncatingRemainder(dividingBy: sector) - sector / 2
        return (af / 2) / cos(a)
    }

    /// Sets the thread, shank and head to ISO sizes for the nearest metric bolt.
    mutating func snapToStandard() {
        guard let ti = sections.firstIndex(where: { $0.thread != nil }) ?? sections.indices.min(by: { sections[$0].size < sections[$1].size }),
              let std = MetricThread.nearest(to: sections[ti].size) ?? sections[ti].thread else { return }
        sections[ti].thread = std
        sections[ti].size = std.nominal
        if let hi = sections.indices.filter({ $0 != ti && sections[$0].shape == .hex }).max(by: { sections[$0].size < sections[$1].size }) {
            sections[hi].size = std.headAcrossFlats
            sections[hi].length = std.headHeight
        }
    }
}

// MARK: - Detection from a scan

extension TurnedPart {
    struct Detection: Sendable {
        var part: TurnedPart
        /// Maps scan coordinates into the part's frame (axis along Y, head at Y = 0).
        var scanToPart: simd_float4x4
        /// 0 (poor) to 1 (clean) — how well the scan matches a body of revolution.
        var confidence: Float
        var lengthToWidth: Float
    }

    /// Finds the part's axis even when one side was hidden (lying on a table),
    /// reads the radius profile along it, and splits it into sections.
    static func detect(in scan: Mesh) -> Detection? {
        let pts = scan.positions
        guard pts.count > 200 else { return nil }

        // 1. Start from the longest principal axis.
        var center = pts.reduce(SIMD3<Float>.zero, +) / Float(pts.count)
        var axis = principalAxis(of: pts, around: center)

        // 2. Refine: fit circles to slices, then fit a line through their centers.
        //    Circle fits work on partial arcs, so a hidden underside doesn't bias the axis.
        for _ in 0..<3 {
            let f = Frame(axis: axis)
            let (tmin, binW, nb, bins) = slice(pts, center: center, frame: f)
            var cs = [SIMD3<Float>](), ws = [Float]()
            for b in 0..<nb where bins[b].count >= 10 {
                let uv = bins[b].map { i -> SIMD2<Float> in
                    let d = pts[i] - center
                    return SIMD2(simd_dot(d, f.u), simd_dot(d, f.w))
                }
                guard let c = fitCircle(uv) else { continue }
                let t = tmin + (Float(b) + 0.5) * binW
                cs.append(center + f.a * t + f.u * c.center.x + f.w * c.center.y)
                ws.append(Float(bins[b].count))
            }
            guard cs.count >= 4 else { break }
            let med = SIMD3<Float>(median(cs.map(\.x)), median(cs.map(\.y)), median(cs.map(\.z)))
            let dev = cs.map { simd_length(simd_cross($0 - med, f.a)) }
            let cut = percentile(dev, 0.7) + 1e-5
            var sumW: Float = 0, mean = SIMD3<Float>.zero
            for (i, c) in cs.enumerated() where dev[i] <= cut { mean += c * ws[i]; sumW += ws[i] }
            guard sumW > 0 else { break }
            mean /= sumW
            var cov = [[Double]](repeating: [0, 0, 0], count: 3)
            for (i, c) in cs.enumerated() where dev[i] <= cut {
                let d = c - mean
                for r in 0..<3 { for q in 0..<3 { cov[r][q] += Double(ws[i] * d[r] * d[q]) } }
            }
            let (vals, vecs) = Mesh.jacobiEigen(cov)
            let k = (0..<3).max { vals[$0] < vals[$1] }!
            var na = SIMD3<Float>(Float(vecs[0][k]), Float(vecs[1][k]), Float(vecs[2][k]))
            if simd_dot(na, axis) < 0 { na = -na }
            center = mean
            axis = simd_normalize(na)
        }

        // 3. Radius profile along the axis.
        let f = Frame(axis: axis)
        let (tmin, binW, nb, bins) = slice(pts, center: center, frame: f)
        var rho = [Float](repeating: 0, count: pts.count)
        var phi = [Float](repeating: 0, count: pts.count)
        var tOf = [Float](repeating: 0, count: pts.count)
        for (i, p) in pts.enumerated() {
            let d = p - center
            let u = simd_dot(d, f.u), w = simd_dot(d, f.w)
            rho[i] = (u * u + w * w).squareRoot()
            phi[i] = atan2(w, u)
            tOf[i] = simd_dot(d, f.a)
        }
        var profile = [Float](repeating: .nan, count: nb)
        for b in 0..<nb where bins[b].count >= 6 { profile[b] = percentile(bins[b].map { rho[$0] }, 0.85) }
        let filled = profile.indices.filter { !profile[$0].isNaN }
        guard !filled.isEmpty else { return nil }
        for b in 0..<nb where profile[b].isNaN {
            profile[b] = profile[filled.min { abs($0 - b) < abs($1 - b) }!]
        }
        let k = max(1, Int((1.25 / binW).rounded()))   // ~2.5 mm window flattens thread ripple
        let smooth = (0..<nb).map { median(Array(profile[max(0, $0 - k)...min(nb - 1, $0 + k)])) }

        // 4. Split where the radius steps.
        func threshold(_ r: Float) -> Float { max(0.5, 0.12 * r) }
        var groups: [[Int]] = [[0]]
        for i in 1..<nb {
            let cur = median(groups[groups.count - 1].map { smooth[$0] })
            let next = smooth[min(nb - 1, i + 1)]
            if abs(smooth[i] - cur) > threshold(cur) && abs(next - cur) > threshold(cur) {
                groups.append([i])
            } else {
                groups[groups.count - 1].append(i)
            }
        }
        var merged = true
        while merged && groups.count > 1 {
            merged = false
            for (i, g) in groups.enumerated() where Float(g.count) * binW < 1.0 {
                let m = median(g.map { smooth[$0] })
                let j: Int
                if i == 0 { j = 1 } else if i == groups.count - 1 { j = i - 1 } else {
                    let l = abs(median(groups[i - 1].map { smooth[$0] }) - m)
                    let r = abs(median(groups[i + 1].map { smooth[$0] }) - m)
                    j = l < r ? i - 1 : i + 1
                }
                groups[j] = (groups[j] + g).sorted()
                groups.remove(at: i)
                merged = true
                break
            }
        }

        // 5. Size each section and tell round, hex and threaded apart.
        var sections = [Section]()
        var circleResiduals = [Float]()
        var hexPhase: Float = 0
        for g in groups {
            let lo = tmin + Float(g.first!) * binW, hi = tmin + Float(g.last! + 1) * binW
            let len = hi - lo
            let r85 = median(g.map { smooth[$0] })
            var sel = pts.indices.filter { tOf[$0] > lo + 0.2 * len && tOf[$0] < hi - 0.2 * len && rho[$0] > 0.8 * r85 }
            if sel.count < 12 { sel = pts.indices.filter { tOf[$0] >= lo && tOf[$0] < hi } }
            let rr = sel.map { rho[$0] }, pp = sel.map { phi[$0] }
            guard !rr.isEmpty else { continue }
            var radius = median(rr)
            let ripple = percentile(rr, 0.9) - percentile(rr, 0.1)
            var threaded = ripple > max(0.4, 0.06 * radius)
            if threaded { radius = percentile(rr, 0.92) }
            let circ = rr.reduce(0) { $0 + abs($1 - radius) } / Float(rr.count)

            var best: (res: Float, phase: Float, half: Float) = (.infinity, 0, radius)
            for step in stride(from: Float(0), to: 60, by: 2) {
                let p0 = step * .pi / 180
                let cosA = pp.map { cos(sectorOffset($0 - p0)) }
                let half = median(zip(rr, cosA).map { $0 * $1 })
                let res = zip(rr, cosA).reduce(Float(0)) { $0 + abs($1.0 - half / $1.1) } / Float(rr.count)
                if res < best.res { best = (res, p0, half) }
            }
            let isHex = rr.count >= 30 && best.res < 0.42 * circ
            if isHex { threaded = false; hexPhase = best.phase }

            var s = Section(shape: isHex ? .hex : .round, size: isHex ? 2 * best.half : 2 * radius, length: len)
            if threaded, let std = MetricThread.nearest(to: s.size) { s.thread = std }
            sections.append(s)
            circleResiduals.append(isHex ? best.res / max(radius, 0.1) : circ / max(radius, 0.1))
        }
        guard !sections.isEmpty else { return nil }

        // 6. Put the widest end on the bed (bolt head down).
        var headAtMin = true
        if let first = sections.first, let last = sections.last, last.size > first.size {
            sections.reverse(); headAtMin = false
        }

        let part = TurnedPart(sections: sections)
        let tmax = tmin + Float(nb) * binW
        let ay = headAtMin ? f.a : -f.a
        let origin = center + f.a * (headAtMin ? tmin : tmax)
        // part frame: X = u rotated by the hex phase, Y = axis, Z completes
        let ux = simd_normalize(f.u * cos(hexPhase) + f.w * sin(hexPhase))
        let uz = simd_normalize(simd_cross(ux, ay))
        let partToScan = simd_float4x4(SIMD4(ux, 0), SIMD4(ay, 0), SIMD4(uz, 0), SIMD4(origin, 1))
        let meanResidual = circleResiduals.reduce(0, +) / Float(circleResiduals.count)
        let lengthToWidth = (tmax - tmin) / max(0.1, 2 * part.maxRadius)
        return Detection(part: part, scanToPart: partToScan.inverse,
                         confidence: max(0, min(1, 1 - meanResidual * 6)),
                         lengthToWidth: lengthToWidth)
    }

    // MARK: helpers

    private struct Frame {
        let a: SIMD3<Float>, u: SIMD3<Float>, w: SIMD3<Float>
        init(axis: SIMD3<Float>) {
            a = simd_normalize(axis)
            let tmp: SIMD3<Float> = abs(a.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
            u = simd_normalize(simd_cross(a, tmp))
            w = simd_cross(a, u)
        }
    }

    private static func slice(_ pts: [SIMD3<Float>], center: SIMD3<Float>, frame f: Frame)
        -> (tmin: Float, binWidth: Float, count: Int, bins: [[Int]]) {
        let ts = pts.map { simd_dot($0 - center, f.a) }
        let tmin = ts.min() ?? 0, tmax = ts.max() ?? 1
        let length = max(0.1, tmax - tmin)
        let nb = max(20, min(200, Int(length / 0.4)))
        let w = length / Float(nb)
        var bins = [[Int]](repeating: [], count: nb)
        for (i, t) in ts.enumerated() { bins[min(nb - 1, Int((t - tmin) / w))].append(i) }
        return (tmin, w, nb, bins)
    }

    private static func principalAxis(of pts: [SIMD3<Float>], around c: SIMD3<Float>) -> SIMD3<Float> {
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        let stride = max(1, pts.count / 20000)
        for i in Swift.stride(from: 0, to: pts.count, by: stride) {
            let d = pts[i] - c
            for r in 0..<3 { for q in 0..<3 { cov[r][q] += Double(d[r] * d[q]) } }
        }
        let (vals, vecs) = Mesh.jacobiEigen(cov)
        let k = (0..<3).max { vals[$0] < vals[$1] }!
        return simd_normalize(SIMD3<Float>(Float(vecs[0][k]), Float(vecs[1][k]), Float(vecs[2][k])))
    }

    /// Kåsa least-squares circle fit; works on partial arcs.
    private static func fitCircle(_ p: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float)? {
        var m = simd_double3x3(0), b = SIMD3<Double>.zero
        for q in p {
            let x = Double(q.x), y = Double(q.y)
            let row = SIMD3<Double>(x, y, 1)
            m += simd_double3x3(rows: [row * x, row * y, row])
            b += row * (x * x + y * y)
        }
        guard abs(m.determinant) > 1e-12 else { return nil }
        let s = m.inverse * b
        let cx = s.x / 2, cy = s.y / 2
        let r2 = s.z + cx * cx + cy * cy
        guard r2 > 0 else { return nil }
        return (SIMD2(Float(cx), Float(cy)), Float(r2.squareRoot()))
    }

    private static func sectorOffset(_ angle: Float) -> Float {
        let sector = Float.pi / 3
        var a = angle.truncatingRemainder(dividingBy: sector)
        if a < 0 { a += sector }
        return a - sector / 2
    }

    private static func median(_ a: [Float]) -> Float { percentile(a, 0.5) }

    private static func percentile(_ a: [Float], _ q: Float) -> Float {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, max(0, Int(Float(s.count - 1) * q)))]
    }
}
