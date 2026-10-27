import Foundation
import simd

/// How to fill in the parts of a scan the camera never saw.
struct CompletionSettings: Equatable, Sendable, Codable {
    enum Symmetry: String, CaseIterable, Identifiable, Sendable, Codable {
        case none = "None", mirror = "Mirror", revolve = "Revolve"
        var id: String { rawValue }
    }
    enum Detail: String, CaseIterable, Identifiable, Sendable, Codable {
        case draft = "Fast", standard = "Standard", fine = "Fine"
        var id: String { rawValue }
        /// Voxels along the longest side.
        var resolution: Float { switch self { case .draft: 90; case .standard: 140; case .fine: 200 } }
    }

    var symmetry: Symmetry = .none
    /// 0 = left–right (X), 1 = top–bottom (Y), 2 = front–back (Z).
    var mirrorAxis = 0
    /// Plane position as a fraction of the part's size, measured from its center.
    var mirrorOffset: Float = 0
    /// Holes up to about twice this size are bridged, in mm.
    var fillGaps: Float = 1.0
    /// Seal the side that was resting on the table.
    var closeBottom = true
    var detail: Detail = .standard
    /// Evens out waviness about this wide (mm) on the completed result.
    var smoothShape: Float = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompletionSettings()
        symmetry = try c.decodeIfPresent(Symmetry.self, forKey: .symmetry) ?? d.symmetry
        mirrorAxis = try c.decodeIfPresent(Int.self, forKey: .mirrorAxis) ?? d.mirrorAxis
        mirrorOffset = try c.decodeIfPresent(Float.self, forKey: .mirrorOffset) ?? d.mirrorOffset
        fillGaps = try c.decodeIfPresent(Float.self, forKey: .fillGaps) ?? d.fillGaps
        closeBottom = try c.decodeIfPresent(Bool.self, forKey: .closeBottom) ?? d.closeBottom
        detail = try c.decodeIfPresent(Detail.self, forKey: .detail) ?? d.detail
        smoothShape = try c.decodeIfPresent(Float.self, forKey: .smoothShape) ?? d.smoothShape
    }
}

enum Completion {

    // MARK: Entry point

    /// Returns a closed, printable version of `scan` with missing areas filled.
    static func complete(_ scan: Mesh, _ s: CompletionSettings) -> Mesh {
        guard !scan.isEmpty else { return .empty }
        if s.symmetry == .revolve, let lathe = revolve(scan) {
            return lathe.mesh
        }
        var source = scan
        if s.symmetry == .mirror {
            source = mirroredUnion(scan, axis: s.mirrorAxis, plane: mirrorPlane(scan, s))
        }
        return voxelFill(source, settings: s)
    }

    static func mirrorPlane(_ scan: Mesh, _ s: CompletionSettings) -> Float {
        let b = scan.bounds
        return b.center[s.mirrorAxis] + s.mirrorOffset * b.size[s.mirrorAxis]
    }

    /// The scan plus its mirror image (with flipped winding so it still faces out).
    static func mirroredUnion(_ m: Mesh, axis: Int, plane: Float) -> Mesh {
        var pos = m.positions
        let n = UInt32(pos.count)
        pos += m.positions.map { p in var q = p; q[axis] = 2 * plane - p[axis]; return q }
        var idx = m.indices
        idx.reserveCapacity(m.indices.count * 2)
        var t = 0
        while t < m.indices.count {
            idx += [m.indices[t] + n, m.indices[t + 2] + n, m.indices[t + 1] + n]
            t += 3
        }
        return Mesh(positions: pos, indices: idx)
    }

    // MARK: Voxel fill

    /// Rasterizes the surface, plugs holes using an estimate of which points are
    /// enclosed (generalized winding number), closes small gaps morphologically,
    /// and extracts a smooth watertight surface.
    static func voxelFill(_ m: Mesh, settings s: CompletionSettings) -> Mesh {
        let b = m.bounds
        let extent = max(b.size.x, b.size.y, b.size.z)
        guard extent > 0 else { return .empty }
        let voxel = max(0.2, extent / s.detail.resolution)
        let k = max(1, Int((s.fillGaps / voxel).rounded()))
        let pad = k + 3 + Int((s.smoothShape / voxel).rounded(.up))
        let lo = b.min - SIMD3<Float>(repeating: Float(pad) * voxel)
        let nx = Int(((b.size.x) / voxel).rounded(.up)) + 2 * pad + 1
        let ny = Int(((b.size.y) / voxel).rounded(.up)) + 2 * pad + 1
        let nz = Int(((b.size.z) / voxel).rounded(.up)) + 2 * pad + 1
        var grid = Grid(nx: nx, ny: ny, nz: nz)

        // 1. Surface voxels.
        var wall = [UInt8](repeating: 0, count: grid.count)
        rasterize(m, into: &wall, grid: grid, lo: lo, voxel: voxel)

        // 2. Enclosure estimate on a coarse grid.
        let baseY = b.min.y
        let inside = windingMask(m, grid: grid, lo: lo, voxel: voxel, extent: extent,
                                 reflectBelow: s.closeBottom ? baseY : nil)

        // 3. Thicken the walls to bridge small gaps.
        var blocked = wall
        for _ in 0..<k { dilate(&blocked, grid) }
        for i in 0..<grid.count where inside[i] != 0 { blocked[i] = 1 }
        let baseRow = max(0, min(ny - 2, Int(((baseY - lo.y) / voxel).rounded())))
        if s.closeBottom {
            for z in 0..<nz { for y in 0...baseRow { for x in 0..<nx { blocked[grid.index(x, y, z)] = 1 } } }
        }

        // 4. Everything the outside can't reach is solid.
        var solid = floodInterior(blocked, grid, openBottom: !s.closeBottom)
        if s.closeBottom {
            // Below the base, keep only what sits under the part's footprint.
            for y in stride(from: baseRow, through: 0, by: -1) {
                for z in 0..<nz { for x in 0..<nx { solid[grid.index(x, y, z)] = solid[grid.index(x, y + 1, z)] } }
            }
            for y in 0..<baseRow { for z in 0..<nz { for x in 0..<nx { solid[grid.index(x, y, z)] = 0 } } }
        }

        // 5. Undo the thickening.
        for _ in 0..<k { erode(&solid, grid) }
        if s.closeBottom {
            let top = min(ny - 1, baseRow + k + 1)
            for y in baseRow..<top {
                for z in 0..<nz { for x in 0..<nx where solid[grid.index(x, top, z)] != 0 { solid[grid.index(x, y, z)] = 1 } }
            }
            for y in 0..<baseRow { for z in 0..<nz { for x in 0..<nx { solid[grid.index(x, y, z)] = 0 } } }
        }

        // 6. Smooth surface. Each 3-tap blur pass adds about (2/3)·voxel² of variance,
        //    so the shape smoothing radius sets the number of extra passes.
        var field = solid.map { Float($0) }
        let sigma = s.smoothShape / 2
        let extra = sigma > 0 ? min(150, Int((1.5 * (sigma / voxel) * (sigma / voxel)).rounded())) : 0
        for _ in 0..<(2 + extra) { blur(&field, grid) }
        grid.lo = lo; grid.voxel = voxel
        var out = surfaceNets(field, grid)
        guard !out.isEmpty else { return .empty }
        if signedVolume(out) < 0 { out = flipped(out) }
        out = out.smoothed(passes: 2, adjacency: out.adjacency())
        return out.droppedToBed()
    }

    // MARK: Grid helpers

    struct Grid {
        let nx: Int, ny: Int, nz: Int
        var lo = SIMD3<Float>.zero
        var voxel: Float = 1
        init(nx: Int, ny: Int, nz: Int) { self.nx = nx; self.ny = ny; self.nz = nz }
        var count: Int { nx * ny * nz }
        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }
    }

    static func rasterize(_ m: Mesh, into wall: inout [UInt8], grid g: Grid, lo: SIMD3<Float>, voxel: Float) {
        let step = voxel * 0.5
        func mark(_ p: SIMD3<Float>) {
            let q = (p - lo) / voxel
            let x = Int(q.x.rounded()), y = Int(q.y.rounded()), z = Int(q.z.rounded())
            guard x >= 0, y >= 0, z >= 0, x < g.nx, y < g.ny, z < g.nz else { return }
            wall[g.index(x, y, z)] = 1
        }
        var t = 0
        while t < m.indices.count {
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            let n = min(64, max(1, Int((longest / step).rounded(.up))))
            for i in 0...n {
                for j in 0...(n - i) {
                    let u = Float(i) / Float(n), v = Float(j) / Float(n)
                    mark(a + (b - a) * u + (c - a) * v)
                }
            }
            t += 3
        }
    }

    static func dilate(_ a: inout [UInt8], _ g: Grid) {
        let src = a
        for z in 0..<g.nz {
            for y in 0..<g.ny {
                for x in 0..<g.nx {
                    let i = g.index(x, y, z)
                    if src[i] != 0 { continue }
                    if (x > 0 && src[i - 1] != 0) || (x < g.nx - 1 && src[i + 1] != 0)
                        || (y > 0 && src[i - g.nx] != 0) || (y < g.ny - 1 && src[i + g.nx] != 0)
                        || (z > 0 && src[i - g.nx * g.ny] != 0) || (z < g.nz - 1 && src[i + g.nx * g.ny] != 0) {
                        a[i] = 1
                    }
                }
            }
        }
    }

    static func erode(_ a: inout [UInt8], _ g: Grid) {
        let src = a
        for z in 0..<g.nz {
            for y in 0..<g.ny {
                for x in 0..<g.nx {
                    let i = g.index(x, y, z)
                    if src[i] == 0 { continue }
                    if x == 0 || y == 0 || z == 0 || x == g.nx - 1 || y == g.ny - 1 || z == g.nz - 1
                        || src[i - 1] == 0 || src[i + 1] == 0 || src[i - g.nx] == 0 || src[i + g.nx] == 0
                        || src[i - g.nx * g.ny] == 0 || src[i + g.nx * g.ny] == 0 {
                        a[i] = 0
                    }
                }
            }
        }
    }

    /// Flood-fills the outside from the grid boundary; returns 1 for everything it can't reach.
    static func floodInterior(_ blocked: [UInt8], _ g: Grid, openBottom: Bool) -> [UInt8] {
        var outside = [UInt8](repeating: 0, count: g.count)
        var queue = [Int32]()
        queue.reserveCapacity(g.count / 4)
        func seed(_ x: Int, _ y: Int, _ z: Int) {
            let i = g.index(x, y, z)
            if blocked[i] == 0 && outside[i] == 0 { outside[i] = 1; queue.append(Int32(i)) }
        }
        for z in 0..<g.nz { for y in 0..<g.ny { seed(0, y, z); seed(g.nx - 1, y, z) } }
        for z in 0..<g.nz { for x in 0..<g.nx { seed(x, g.ny - 1, z); if openBottom { seed(x, 0, z) } } }
        for y in 0..<g.ny { for x in 0..<g.nx { seed(x, y, 0); seed(x, y, g.nz - 1) } }
        var head = 0
        let sx = 1, sy = g.nx, sz = g.nx * g.ny
        while head < queue.count {
            let i = Int(queue[head]); head += 1
            let x = i % g.nx, y = (i / g.nx) % g.ny, z = i / sz
            func visit(_ j: Int) {
                if blocked[j] == 0 && outside[j] == 0 { outside[j] = 1; queue.append(Int32(j)) }
            }
            if x > 0 { visit(i - sx) }
            if x < g.nx - 1 { visit(i + sx) }
            if y > 0 { visit(i - sy) }
            if y < g.ny - 1 { visit(i + sy) }
            if z > 0 { visit(i - sz) }
            if z < g.nz - 1 { visit(i + sz) }
        }
        return outside.map { $0 == 0 ? 1 : 0 }
    }

    /// Three-tap box blur along each axis; zero padding keeps the surface closed at the border.
    static func blur(_ f: inout [Float], _ g: Grid) {
        let sy = g.nx, sz = g.nx * g.ny
        var src = f
        for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            let i = g.index(x, y, z)
            f[i] = (src[i] + (x > 0 ? src[i - 1] : 0) + (x < g.nx - 1 ? src[i + 1] : 0)) / 3
        } } }
        src = f
        for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            let i = g.index(x, y, z)
            f[i] = (src[i] + (y > 0 ? src[i - sy] : 0) + (y < g.ny - 1 ? src[i + sy] : 0)) / 3
        } } }
        src = f
        for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            let i = g.index(x, y, z)
            f[i] = (src[i] + (z > 0 ? src[i - sz] : 0) + (z < g.nz - 1 ? src[i + sz] : 0)) / 3
        } } }
    }

    // MARK: Winding number

    /// Estimates which voxels the surface encloses, even through holes, using a
    /// dipole approximation of the generalized winding number on a coarse grid.
    /// With `reflectBelow`, the scan is mirrored under the table so an open base reads as closed.
    static func windingMask(_ m: Mesh, grid g: Grid, lo: SIMD3<Float>, voxel: Float, extent: Float,
                            reflectBelow: Float?) -> [UInt8] {
        let coarse = max(voxel * 3, extent / 40)
        let clusterSize = coarse * 1.5
        // Cluster triangle area vectors.
        var cells = [SIMD3<Int32>: Int]()
        var area = [SIMD3<Float>](), center = [SIMD3<Float>](), weight = [Float]()
        var t = 0
        while t < m.indices.count {
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            let av = simd_cross(b - a, c - a) * 0.5
            let w = simd_length(av)
            let cen = (a + b + c) / 3
            let key = SIMD3<Int32>(Int32((cen.x / clusterSize).rounded(.down)), Int32((cen.y / clusterSize).rounded(.down)), Int32((cen.z / clusterSize).rounded(.down)))
            if let j = cells[key] {
                area[j] += av; center[j] += cen * w; weight[j] += w
            } else {
                cells[key] = area.count
                area.append(av); center.append(cen * w); weight.append(w)
            }
            t += 3
        }
        for j in center.indices { center[j] /= max(weight[j], 1e-9) }
        if let base = reflectBelow {
            let n = area.count
            for j in 0..<n {
                var c = center[j]; c.y = 2 * base - c.y
                center.append(c)
                area.append(SIMD3(area[j].x, -area[j].y, area[j].z))
            }
        }

        // Evaluate on the coarse grid.
        let cx = Int((Float(g.nx) * voxel / coarse).rounded(.up)) + 2
        let cy = Int((Float(g.ny) * voxel / coarse).rounded(.up)) + 2
        let cz = Int((Float(g.nz) * voxel / coarse).rounded(.up)) + 2
        var w = [Float](repeating: 0, count: cx * cy * cz)
        let minR = coarse * 0.5
        let clusterCount = area.count
        area.withUnsafeBufferPointer { A in
            center.withUnsafeBufferPointer { C in
                w.withUnsafeMutableBufferPointer { W in
                    let wp = W.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: cz) { z in
                        for y in 0..<cy {
                            for x in 0..<cx {
                                let p = lo + SIMD3<Float>(Float(x), Float(y), Float(z)) * coarse
                                var sum: Float = 0
                                for j in 0..<clusterCount {
                                    let d = C[j] - p
                                    let r = max(simd_length(d), minR)
                                    sum += simd_dot(d, A[j]) / (r * r * r)
                                }
                                wp[(z * cy + y) * cx + x] = sum / (4 * .pi)
                            }
                        }
                    }
                }
            }
        }
        // Scans can be wound either way; use whichever sign dominates.
        if let mn = w.min(), let mx = w.max(), abs(mn) > abs(mx) { w = w.map { -$0 } }

        // Sample onto the fine grid.
        var mask = [UInt8](repeating: 0, count: g.count)
        let ratio = voxel / coarse
        for z in 0..<g.nz {
            let fz = Float(z) * ratio, z0 = min(Int(fz), cz - 2), tz = fz - Float(z0)
            for y in 0..<g.ny {
                let fy = Float(y) * ratio, y0 = min(Int(fy), cy - 2), ty = fy - Float(y0)
                for x in 0..<g.nx {
                    let fx = Float(x) * ratio, x0 = min(Int(fx), cx - 2), tx = fx - Float(x0)
                    func at(_ i: Int, _ j: Int, _ k: Int) -> Float { w[((z0 + k) * cy + (y0 + j)) * cx + (x0 + i)] }
                    let c00 = at(0, 0, 0) * (1 - tx) + at(1, 0, 0) * tx
                    let c10 = at(0, 1, 0) * (1 - tx) + at(1, 1, 0) * tx
                    let c01 = at(0, 0, 1) * (1 - tx) + at(1, 0, 1) * tx
                    let c11 = at(0, 1, 1) * (1 - tx) + at(1, 1, 1) * tx
                    let v = (c00 * (1 - ty) + c10 * ty) * (1 - tz) + (c01 * (1 - ty) + c11 * ty) * tz
                    if v > 0.45 { mask[g.index(x, y, z)] = 1 }
                }
            }
        }
        return mask
    }

    // MARK: Surface nets

    /// Extracts the 0.5 iso-surface: one vertex per boundary cell, one quad per crossing edge.
    static func surfaceNets(_ f: [Float], _ g: Grid) -> Mesh {
        let iso: Float = 0.5
        let cnx = g.nx - 1, cny = g.ny - 1, cnz = g.nz - 1
        var vid = [Int32](repeating: -1, count: cnx * cny * cnz)
        var positions = [SIMD3<Float>]()
        let cx: [Float] = [0, 1, 0, 1, 0, 1, 0, 1]
        let cy: [Float] = [0, 0, 1, 1, 0, 0, 1, 1]
        let cz: [Float] = [0, 0, 0, 0, 1, 1, 1, 1]
        let ea = [0, 2, 4, 6, 0, 1, 4, 5, 0, 1, 2, 3]
        let eb = [1, 3, 5, 7, 2, 3, 6, 7, 4, 5, 6, 7]
        let sy = g.nx, sz = g.nx * g.ny
        let offsets = [0, 1, sy, sy + 1, sz, sz + 1, sz + sy, sz + sy + 1]
        var v = [Float](repeating: 0, count: 8)
        for z in 0..<cnz {
            for y in 0..<cny {
                for x in 0..<cnx {
                    let base = g.index(x, y, z)
                    var inCount = 0
                    for k in 0..<8 {
                        v[k] = f[base + offsets[k]]
                        if v[k] > iso { inCount += 1 }
                    }
                    guard inCount > 0 && inCount < 8 else { continue }
                    var acc = SIMD3<Float>.zero, n: Float = 0
                    for e in 0..<12 {
                        let a = ea[e], b = eb[e]
                        guard (v[a] > iso) != (v[b] > iso) else { continue }
                        let t = (iso - v[a]) / (v[b] - v[a])
                        acc += SIMD3(cx[a] + (cx[b] - cx[a]) * t, cy[a] + (cy[b] - cy[a]) * t, cz[a] + (cz[b] - cz[a]) * t)
                        n += 1
                    }
                    vid[(z * cny + y) * cnx + x] = Int32(positions.count)
                    positions.append(g.lo + (SIMD3<Float>(Float(x), Float(y), Float(z)) + acc / n) * g.voxel)
                }
            }
        }
        func cell(_ x: Int, _ y: Int, _ z: Int) -> Int32 { vid[(z * cny + y) * cnx + x] }

        var indices = [UInt32]()
        let axisStride = [1, sy, sz]
        // For each axis, edges between node p and p + axis; (u, v) are the other two axes, ascending.
        for ax in 0..<3 {
            let rightHanded = ax != 1
            let st = axisStride[ax]
            for z in 0..<g.nz {
                for y in 0..<g.ny {
                    for x in 0..<g.nx {
                        if (ax == 0 && x >= g.nx - 1) || (ax == 1 && y >= g.ny - 1) || (ax == 2 && z >= g.nz - 1) { continue }
                        let i = g.index(x, y, z)
                        let a = f[i] > iso
                        guard a != (f[i + st] > iso) else { continue }
                        let p = [x, y, z]
                        let (u, w) = ax == 0 ? (1, 2) : (ax == 1 ? (0, 2) : (0, 1))
                        let dims = [g.nx, g.ny, g.nz]
                        guard p[u] >= 1, p[u] <= dims[u] - 2, p[w] >= 1, p[w] <= dims[w] - 2 else { continue }
                        func c(_ du: Int, _ dw: Int) -> Int32 {
                            var r = p; r[u] -= du; r[w] -= dw
                            return cell(r[0], r[1], r[2])
                        }
                        var quad = [c(1, 1), c(0, 1), c(0, 0), c(1, 0)]
                        if quad.contains(-1) { continue }
                        if a != !rightHanded { quad.reverse() }
                        indices += [UInt32(quad[0]), UInt32(quad[1]), UInt32(quad[2]),
                                    UInt32(quad[0]), UInt32(quad[2]), UInt32(quad[3])]
                    }
                }
            }
        }
        return Mesh(positions: positions, indices: indices)
    }

    static func signedVolume(_ m: Mesh) -> Float {
        var vol: Float = 0
        var t = 0
        while t < m.indices.count {
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            vol += simd_dot(a, simd_cross(b, c)) / 6
            t += 3
        }
        return vol
    }

    static func flipped(_ m: Mesh) -> Mesh {
        var idx = m.indices
        var t = 0
        while t < idx.count { idx.swapAt(t + 1, t + 2); t += 3 }
        return Mesh(positions: m.positions, indices: idx)
    }

    // MARK: Mirror plane detection

    struct MirrorGuess: Sendable { var axis: Int; var offset: Float; var error: Float }

    /// Finds the plane (along X, Z or Y) that best maps the scan onto itself.
    /// `error` is the typical mismatch as a fraction of the part's size; under ~0.03 is a good fit.
    static func detectMirror(_ m: Mesh) -> MirrorGuess? {
        let pts = m.positions
        guard pts.count > 100 else { return nil }
        let b = m.bounds
        let extent = max(b.size.x, b.size.y, b.size.z)
        let cellSize = max(extent / 60, 0.1)
        var hash = [SIMD3<Int32>: [Int32]]()
        let stride = max(1, pts.count / 60000)
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cellSize).rounded(.down)), Int32((p.y / cellSize).rounded(.down)), Int32((p.z / cellSize).rounded(.down)))
        }
        for i in Swift.stride(from: 0, to: pts.count, by: stride) { hash[key(pts[i]), default: []].append(Int32(i)) }
        let sampleStride = max(1, pts.count / 1500)
        let sample = Swift.stride(from: 0, to: pts.count, by: sampleStride).map { pts[$0] }
        func nearest(_ p: SIMD3<Float>) -> Float {
            let k = key(p)
            var best = Float.infinity
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                guard let list = hash[k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                for j in list { best = min(best, simd_distance_squared(p, pts[Int(j)])) }
            } } }
            return best.isFinite ? best.squareRoot() : cellSize * 2
        }
        func cost(axis: Int, plane: Float) -> Float {
            var d = sample.map { p -> Float in var q = p; q[axis] = 2 * plane - p[axis]; return nearest(q) }
            d.sort()
            return d[Int(Float(d.count - 1) * 0.6)]
        }
        var best: MirrorGuess?
        for axis in [0, 2, 1] {
            let size = b.size[axis]
            guard size > 0 else { continue }
            for step in -25...25 {
                let frac = Float(step) / 100
                let c = cost(axis: axis, plane: b.center[axis] + frac * size)
                // Prefer left–right and front–back planes over top–bottom.
                let penalized = axis == 1 ? c * 1.5 : c
                if best == nil || penalized < best!.error * extent {
                    best = MirrorGuess(axis: axis, offset: frac, error: penalized / extent)
                }
            }
        }
        return best
    }

    // MARK: Revolve

    /// Builds a solid of revolution from the visible profile around the scan's best axis.
    static func revolve(_ m: Mesh) -> (mesh: Mesh, confidence: Float)? {
        guard let det = TurnedPart.detectAnyAxis(in: m) else { return nil }
        let pts = m.positions.map { p -> SIMD3<Float> in
            let r = det.scanToPart * SIMD4<Float>(p, 1)
            return SIMD3(r.x, r.y, r.z)
        }
        guard let ymin = pts.map(\.y).min(), let ymax = pts.map(\.y).max(), ymax > ymin else { return nil }
        let length = ymax - ymin
        let nb = max(16, min(240, Int(length / 0.4)))
        let bw = length / Float(nb)
        var bins = [[Float]](repeating: [], count: nb)
        for p in pts {
            let i = min(nb - 1, max(0, Int((p.y - ymin) / bw)))
            bins[i].append((p.x * p.x + p.z * p.z).squareRoot())
        }
        var radius = bins.map { b -> Float in
            guard b.count >= 4 else { return .nan }
            let s = b.sorted()
            return s[Int(Float(s.count - 1) * 0.9)]
        }
        let known = radius.indices.filter { !radius[$0].isNaN }
        guard !known.isEmpty else { return nil }
        for i in radius.indices where radius[i].isNaN {
            radius[i] = radius[known.min { abs($0 - i) < abs($1 - i) }!]
        }
        radius = radius.indices.map { i in
            let w = radius[max(0, i - 1)...min(nb - 1, i + 1)].sorted()
            return w[w.count / 2]
        }
        // Lathe.
        let seg = 96
        var positions = [SIMD3<Float>]()
        var indices = [UInt32]()
        let rows = nb + 1
        for i in 0..<rows {
            let y = Float(i) * bw
            let rr = max(0.05, i == 0 ? radius[0] : (i == nb ? radius[nb - 1] : (radius[i - 1] + radius[i]) / 2))
            for k in 0..<seg {
                let a = Float(k) / Float(seg) * 2 * .pi
                positions.append(SIMD3(rr * cos(a), y, rr * sin(a)))
            }
        }
        for i in 0..<(rows - 1) {
            for k in 0..<seg {
                let a = UInt32(i * seg + k), b = UInt32((i + 1) * seg + k)
                let c = UInt32(i * seg + (k + 1) % seg), d = UInt32((i + 1) * seg + (k + 1) % seg)
                indices += [a, b, c, c, b, d]
            }
        }
        let bottom = UInt32(positions.count); positions.append(SIMD3(0, 0, 0))
        let top = UInt32(positions.count); positions.append(SIMD3(0, length, 0))
        let last = (rows - 1) * seg
        for k in 0..<seg {
            indices += [bottom, UInt32(k), UInt32((k + 1) % seg)]
            indices += [top, UInt32(last + (k + 1) % seg), UInt32(last + k)]
        }
        var mesh = Mesh(positions: positions, indices: indices)
        if signedVolume(mesh) < 0 { mesh = flipped(mesh) }
        return (mesh.droppedToBed(), det.confidence)
    }
}
