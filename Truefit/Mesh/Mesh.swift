import Foundation
import simd

/// Indexed triangle mesh. Positions are in millimeters, Y up, unless noted.
struct Mesh: Sendable {
    var positions: [SIMD3<Float>]
    var indices: [UInt32]

    static let empty = Mesh(positions: [], indices: [])

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { indices.isEmpty }

    // MARK: Bounds

    struct Bounds: Sendable {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
        var size: SIMD3<Float> { max - min }
        var center: SIMD3<Float> { (min + max) * 0.5 }
    }

    var bounds: Bounds {
        guard var lo = positions.first else { return Bounds(min: .zero, max: .zero) }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return Bounds(min: lo, max: hi)
    }

    // MARK: Welding

    /// Merges vertices closer than `tolerance` and drops degenerate triangles.
    static func welded(positions: [SIMD3<Float>], indices: [UInt32]?, tolerance: Float) -> Mesh {
        let tol = max(tolerance, 1e-9)
        var map = [SIMD3<Int32>: UInt32]()
        map.reserveCapacity(positions.count)
        var out = [SIMD3<Float>]()
        out.reserveCapacity(positions.count)
        var remap = [UInt32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let q = SIMD3<Int32>(Int32((p.x / tol).rounded()), Int32((p.y / tol).rounded()), Int32((p.z / tol).rounded()))
            if let existing = map[q] {
                remap[i] = existing
            } else {
                let n = UInt32(out.count)
                map[q] = n
                out.append(p)
                remap[i] = n
            }
        }
        let source = indices ?? (0..<UInt32(positions.count)).map { $0 }
        var idx = [UInt32]()
        idx.reserveCapacity(source.count)
        var t = 0
        while t + 2 < source.count {
            let a = remap[Int(source[t])], b = remap[Int(source[t + 1])], c = remap[Int(source[t + 2])]
            if a != b && b != c && a != c { idx.append(contentsOf: [a, b, c]) }
            t += 3
        }
        return Mesh(positions: out, indices: idx)
    }

    // MARK: Cleanup

    /// Keeps only the connected piece with the most triangles.
    func largestComponent() -> (mesh: Mesh, removedPieces: Int) {
        let n = positions.count
        guard n > 0 else { return (self, 0) }
        var parent = [Int32](0..<Int32(n))
        func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x {
                parent[Int(x)] = parent[Int(parent[Int(x)])]
                x = parent[Int(x)]
            }
            return x
        }
        func unite(_ a: UInt32, _ b: UInt32) {
            let ra = find(Int32(a)), rb = find(Int32(b))
            if ra != rb { parent[Int(ra)] = rb }
        }
        var t = 0
        while t < indices.count {
            unite(indices[t], indices[t + 1])
            unite(indices[t + 1], indices[t + 2])
            t += 3
        }
        var counts = [Int32: Int]()
        t = 0
        while t < indices.count {
            counts[find(Int32(indices[t])), default: 0] += 1
            t += 3
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return (self, 0) }
        var remap = [Int32](repeating: -1, count: n)
        var newPos = [SIMD3<Float>]()
        var newIdx = [UInt32]()
        t = 0
        while t < indices.count {
            if find(Int32(indices[t])) == best {
                for k in 0..<3 {
                    let v = Int(indices[t + k])
                    if remap[v] < 0 {
                        remap[v] = Int32(newPos.count)
                        newPos.append(positions[v])
                    }
                    newIdx.append(UInt32(remap[v]))
                }
            }
            t += 3
        }
        return (Mesh(positions: newPos, indices: newIdx), counts.count - 1)
    }

    /// Compressed neighbor lists for smoothing.
    struct Adjacency: Sendable {
        var offsets: [Int32]
        var neighbors: [UInt32]
    }

    func adjacency() -> Adjacency {
        let n = positions.count
        var degree = [Int32](repeating: 0, count: n + 1)
        for v in indices { degree[Int(v)] += 2 }
        var offsets = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { offsets[i + 1] = offsets[i] + degree[i] }
        var fill = Array(offsets[0..<n])
        var nb = [UInt32](repeating: 0, count: Int(offsets[n]))
        var t = 0
        while t < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            nb[Int(fill[a])] = UInt32(b); nb[Int(fill[a]) + 1] = UInt32(c); fill[a] += 2
            nb[Int(fill[b])] = UInt32(a); nb[Int(fill[b]) + 1] = UInt32(c); fill[b] += 2
            nb[Int(fill[c])] = UInt32(a); nb[Int(fill[c]) + 1] = UInt32(b); fill[c] += 2
            t += 3
        }
        return Adjacency(offsets: offsets, neighbors: nb)
    }

    /// Taubin smoothing: removes noise without shrinking the part.
    func smoothed(passes: Int, adjacency adj: Adjacency) -> Mesh {
        guard passes > 0 else { return self }
        var p = positions
        var q = positions
        let n = p.count
        for _ in 0..<passes {
            for factor: Float in [0.5, -0.53] {
                for v in 0..<n {
                    let s = Int(adj.offsets[v]), e = Int(adj.offsets[v + 1])
                    guard e > s else { q[v] = p[v]; continue }
                    var sum = SIMD3<Float>.zero
                    for j in s..<e { sum += p[Int(adj.neighbors[j])] }
                    let avg = sum / Float(e - s)
                    q[v] = p[v] + factor * (avg - p[v])
                }
                swap(&p, &q)
            }
        }
        return Mesh(positions: p, indices: indices)
    }

    func vertexNormals() -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var t = 0
        while t < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            t += 3
        }
        return normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0) }
    }

    func transformed(_ m: simd_float4x4) -> Mesh {
        let pts = positions.map { p -> SIMD3<Float> in
            let r = m * SIMD4<Float>(p, 1)
            return SIMD3<Float>(r.x, r.y, r.z)
        }
        var idx = indices
        if simd_determinant(m) < 0 {
            var t = 0
            while t < idx.count { idx.swapAt(t + 1, t + 2); t += 3 }
        }
        return Mesh(positions: pts, indices: idx)
    }

    /// Moves the part so it is centered on X/Z and sits on Y = 0.
    func droppedToBed() -> Mesh {
        let b = bounds
        let shift = SIMD3<Float>(-b.center.x, -b.min.y, -b.center.z)
        return Mesh(positions: positions.map { $0 + shift }, indices: indices)
    }

    // MARK: Measurements

    struct Stats: Sendable {
        var volume: Float      // mm³
        var surfaceArea: Float // mm²
        var isWatertight: Bool
        var triangles: Int

        /// PLA grams with ~2 walls (0.9 mm shell) and 15% infill.
        var estimatedGrams: Float {
            let shell = min(volume, surfaceArea * 0.9)
            return (shell + (volume - shell) * 0.15) / 1000 * 1.24
        }
    }

    func stats() -> Stats {
        var vol: Float = 0, area: Float = 0
        var edges = [UInt64: Int32]()
        edges.reserveCapacity(indices.count)
        var t = 0
        while t < indices.count {
            let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
            vol += simd_dot(a, simd_cross(b, c)) / 6
            area += simd_length(simd_cross(b - a, c - a)) / 2
            for k in 0..<3 {
                let u = UInt64(indices[t + k]), w = UInt64(indices[t + (k + 1) % 3])
                edges[u < w ? (u << 32) | w : (w << 32) | u, default: 0] += 1
            }
            t += 3
        }
        // Closed when every edge is shared by an even number of triangles (no open borders).
        let tight = !edges.isEmpty && edges.values.allSatisfy { $0 % 2 == 0 }
        return Stats(volume: abs(vol), surfaceArea: area, isWatertight: tight, triangles: triangleCount)
    }

    // MARK: Orientation

    /// Rotation that lays the part on its widest side: thinnest axis up,
    /// longest axis left to right. Keeps "up" on the side of `currentUp`.
    func layFlatRotation(currentUp: SIMD3<Float>) -> simd_float4x4 {
        guard !positions.isEmpty else { return matrix_identity_float4x4 }
        func dbl(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
        var mean = SIMD3<Double>.zero
        for p in positions { mean += dbl(p) }
        mean /= Double(positions.count)
        var c = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in positions {
            let d = dbl(p) - mean
            for i in 0..<3 { for j in 0..<3 { c[i][j] += d[i] * d[j] } }
        }
        let (vals, vecs) = Mesh.jacobiEigen(c)
        let order = [0, 1, 2].sorted { vals[$0] > vals[$1] }
        func column(_ k: Int) -> SIMD3<Float> { SIMD3<Float>(Float(vecs[0][k]), Float(vecs[1][k]), Float(vecs[2][k])) }
        var x = column(order[0])
        var up = column(order[2])
        if simd_dot(up, currentUp) < 0 { up = -up }
        let z = simd_normalize(simd_cross(x, up))
        x = simd_normalize(simd_cross(up, z))
        // rows are the new axes, so this maps x→X, up→Y, z→Z
        let r = simd_float3x3(rows: [x, up, z])
        return simd_float4x4(
            SIMD4<Float>(r.columns.0, 0),
            SIMD4<Float>(r.columns.1, 0),
            SIMD4<Float>(r.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }

    static func jacobiEigen(_ m: [[Double]]) -> ([Double], [[Double]]) {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var p = 0, q = 1, big = 0.0
            for i in 0..<3 { for j in (i + 1)..<3 where abs(a[i][j]) > big { big = abs(a[i][j]); p = i; q = j } }
            if big < 1e-12 { break }
            let th = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p])
            let c = cos(th), s = sin(th)
            for k in 0..<3 { let x = a[k][p], y = a[k][q]; a[k][p] = c * x - s * y; a[k][q] = s * x + c * y }
            for k in 0..<3 { let x = a[p][k], y = a[q][k]; a[p][k] = c * x - s * y; a[q][k] = s * x + c * y }
            for k in 0..<3 { let x = v[k][p], y = v[k][q]; v[k][p] = c * x - s * y; v[k][q] = s * x + c * y }
        }
        return ([a[0][0], a[1][1], a[2][2]], v)
    }

    // MARK: Shape detection

    struct ShapeFit: Sendable {
        var isRound: Bool
        var diameter: Float
        var width: Float
        var depth: Float
        var height: Float
        var edgeDeviation: Float
        var holeDiameter: Float?
    }

    /// Looks at the middle band of a bed-centered part and decides whether
    /// it is round or a block, and whether it has a center hole.
    func fitShape() -> ShapeFit {
        let size = bounds.size
        let h = size.y
        let bins = 72
        var outer = [Float](repeating: 0, count: bins)
        var inner = [Float](repeating: .infinity, count: bins)
        for p in positions where p.y >= 0.25 * h && p.y <= 0.75 * h {
            let r = (p.x * p.x + p.z * p.z).squareRoot()
            let ang = atan2(p.z, p.x) + .pi
            let b = min(bins - 1, Int(ang / (2 * .pi) * Float(bins)))
            outer[b] = max(outer[b], r)
            inner[b] = min(inner[b], r)
        }
        func median(_ a: [Float]) -> Float {
            let s = a.filter { $0.isFinite }.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        let r = median(outer)
        let dev = (outer.reduce(0) { $0 + ($1 - r) * ($1 - r) } / Float(bins)).squareRoot()
        let ri = median(inner)
        let round = r > 0 && dev / r < 0.06
        let hole: Float? = (ri > 0.12 * r && ri < 0.8 * r) ? 2 * ri : nil
        return ShapeFit(isRound: round, diameter: 2 * r, width: size.x, depth: size.z,
                        height: h, edgeDeviation: dev, holeDiameter: hole)
    }

    // MARK: STL

    /// Binary STL in millimeters with Z up (the convention slicers expect).
    func stlData() -> Data {
        let n = triangleCount
        var data = Data(count: 84 + n * 50)
        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            let header = Array("Truefit export, millimeters, Z up".utf8)
            for (i, b) in header.enumerated() { base.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
            base.storeBytes(of: UInt32(n).littleEndian, toByteOffset: 80, as: UInt32.self)
            var o = 84
            func zUp(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(p.x, -p.z, p.y) }
            func put(_ v: SIMD3<Float>) {
                for f in [v.x, v.y, v.z] {
                    base.storeBytes(of: f.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                    o += 4
                }
            }
            for t in 0..<n {
                let a = zUp(positions[Int(indices[3 * t])])
                let b = zUp(positions[Int(indices[3 * t + 1])])
                let c = zUp(positions[Int(indices[3 * t + 2])])
                let cr = simd_cross(b - a, c - a)
                let len = simd_length(cr)
                put(len > 0 ? cr / len : .zero)
                put(a); put(b); put(c)
                o += 2
            }
        }
        return data
    }
}
