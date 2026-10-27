import Foundation
import ModelIO
import SceneKit
import simd

enum MeshIOError: LocalizedError {
    case noSurface
    var errorDescription: String? {
        "This file has no surface mesh. Export it from your scanner app as a mesh (USDZ, STL or OBJ), not a point cloud."
    }
}

enum MeshIO {
    static let supportedExtensions = ["usdz", "usd", "stl", "obj", "ply"]

    /// Loads every mesh in the file, applying each object's placement.
    /// Coordinates come back in the file's own units and axes.
    static func load(url: URL) throws -> Mesh {
        let asset = MDLAsset(url: url)
        var positions = [SIMD3<Float>]()
        var indices = [UInt32]()

        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        for mesh in meshes {
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let base = UInt32(positions.count)
            let count = mesh.vertexCount
            let ptr = attr.dataStart
            for i in 0..<count {
                let p = ptr.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                positions.append(SIMD3<Float>(w.x, w.y, w.z))
            }
            guard let submeshes = mesh.submeshes as? [MDLSubmesh] else { continue }
            for sub in submeshes where sub.geometryType == .triangles {
                let buf = sub.indexBuffer.map()
                let raw = buf.bytes
                for k in 0..<sub.indexCount {
                    let v: UInt32
                    switch sub.indexType {
                    case .uInt8: v = UInt32(raw.load(fromByteOffset: k, as: UInt8.self))
                    case .uInt16: v = UInt32(raw.load(fromByteOffset: k * 2, as: UInt16.self))
                    default: v = raw.load(fromByteOffset: k * 4, as: UInt32.self)
                    }
                    indices.append(base + v)
                }
            }
        }
        guard !indices.isEmpty else { throw MeshIOError.noSurface }
        let b = Mesh(positions: positions, indices: indices).bounds
        return Mesh.welded(positions: positions, indices: indices, tolerance: simd_length(b.size) * 1e-6)
    }

    /// Reads triangles out of any SceneKit geometry (used for SCNShape solids).
    static func mesh(from geometry: SCNGeometry) -> Mesh {
        guard let src = geometry.sources(for: .vertex).first else { return .empty }
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(src.vectorCount)
        src.data.withUnsafeBytes { raw in
            for i in 0..<src.vectorCount {
                let o = src.dataOffset + i * src.dataStride
                if src.bytesPerComponent == 8 {
                    positions.append(SIMD3<Float>(
                        Float(raw.loadUnaligned(fromByteOffset: o, as: Double.self)),
                        Float(raw.loadUnaligned(fromByteOffset: o + 8, as: Double.self)),
                        Float(raw.loadUnaligned(fromByteOffset: o + 16, as: Double.self))))
                } else {
                    positions.append(SIMD3<Float>(
                        raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                        raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                        raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                }
            }
        }
        var indices = [UInt32]()
        for el in geometry.elements where el.primitiveType == .triangles {
            el.data.withUnsafeBytes { raw in
                let n = el.primitiveCount * 3
                for k in 0..<n {
                    switch el.bytesPerIndex {
                    case 1: indices.append(UInt32(raw.load(fromByteOffset: k, as: UInt8.self)))
                    case 2: indices.append(UInt32(raw.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self)))
                    default: indices.append(raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self))
                    }
                }
            }
        }
        return Mesh.welded(positions: positions, indices: indices, tolerance: 1e-4)
    }

    /// SceneKit geometry for display, with smooth normals.
    static func geometry(for mesh: Mesh) -> SCNGeometry {
        let verts = mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) }
        let normals = mesh.vertexNormals().map { SCNVector3($0.x, $0.y, $0.z) }
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals)], elements: [element])
    }

    /// Writes an STL into a temporary folder for sharing.
    static func exportSTL(_ mesh: Mesh, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).stl")
        try mesh.stlData().write(to: url, options: .atomic)
        return url
    }
}
