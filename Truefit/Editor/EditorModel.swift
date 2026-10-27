import Foundation
import simd
import SwiftUI

/// Everything the cleanup and sizing tools change, applied to the raw scan.
struct ScanSettings: Equatable, Sendable {
    var keepLargest = true
    var smoothPasses = 3
    var flatten: Float = 0          // mm shaved off the bottom
    var offset: Float = 0           // mm grown (+) or shrunk (−) on every surface
    var orientation = matrix_identity_float4x4
    var scale = SIMD3<Float>(1, 1, 1)
    var mirror = false
    var unitsToMM: Float = 1
    /// Extra length (mm) inserted at a cut on each axis; negative removes length.
    var stretch = SIMD3<Float>.zero
    /// Where each axis is cut, as a fraction of the part's length on that axis.
    var stretchCut = SIMD3<Float>(0.5, 0.5, 0.5)
}

/// Runs the scan pipeline off the main thread and caches the slow steps.
actor ScanPipeline {
    private let source: Mesh
    private var cleanedFor: Bool?
    private var cleaned = Mesh.empty
    private var removed = 0
    private var adjacency = Mesh.Adjacency(offsets: [], neighbors: [])
    private var smoothedFor: Int?
    private var smoothed = Mesh.empty

    init(source: Mesh) { self.source = source }

    private func prepare(_ s: ScanSettings) {
        if cleanedFor != s.keepLargest {
            if s.keepLargest {
                let r = source.largestComponent()
                cleaned = r.mesh; removed = r.removedPieces
            } else {
                cleaned = source; removed = 0
            }
            adjacency = cleaned.adjacency()
            cleanedFor = s.keepLargest
            smoothedFor = nil
        }
        if smoothedFor != s.smoothPasses {
            smoothed = cleaned.smoothed(passes: s.smoothPasses, adjacency: adjacency)
            smoothedFor = s.smoothPasses
        }
    }

    func run(_ s: ScanSettings) -> (mesh: Mesh, removedPieces: Int) {
        prepare(s)
        let units = simd_float4x4(diagonal: SIMD4<Float>(s.unitsToMM, s.unitsToMM, s.unitsToMM, 1))
        var m = smoothed.transformed(s.orientation * units)

        if s.flatten > 0, let lowest = m.positions.map(\.y).min() {
            let floor = lowest + s.flatten
            m.positions = m.positions.map { $0.y < floor ? SIMD3<Float>($0.x, floor, $0.z) : $0 }
        }
        let sizeM = simd_float4x4(diagonal: SIMD4<Float>(s.scale.x * (s.mirror ? -1 : 1), s.scale.y, s.scale.z, 1))
        m = m.transformed(sizeM)
        for axis in 0..<3 where s.stretch[axis] != 0 {
            let values = m.positions.map { $0[axis] }
            guard let lo = values.min(), let hi = values.max() else { continue }
            let cut = lo + (hi - lo) * s.stretchCut[axis]
            let d = s.stretch[axis]
            for i in m.positions.indices {
                let v = m.positions[i][axis]
                guard v > cut else { continue }
                if d > 0 {
                    m.positions[i][axis] = v + d
                } else {
                    m.positions[i][axis] = v >= cut - d ? v + d : cut
                }
            }
        }
        if s.offset != 0 {
            let normals = m.vertexNormals()
            for i in m.positions.indices { m.positions[i] += normals[i] * s.offset }
        }
        return (m.droppedToBed(), removed)
    }

    func layFlat(currentUp: SIMD3<Float>, keepLargest: Bool) -> simd_float4x4 {
        var s = ScanSettings(); s.keepLargest = keepLargest
        if cleanedFor != keepLargest { prepare(s) }
        return cleaned.layFlatRotation(currentUp: currentUp)
    }
}

@MainActor
final class EditorModel: ObservableObject {
    enum Shown: String, CaseIterable, Identifiable { case scan = "Scan", solid = "Rebuilt"; var id: String { rawValue } }
    enum Tab: Int, CaseIterable, Identifiable {
        case clean, size, rebuild, export
        var id: Int { rawValue }
        var title: String { ["Clean", "Size", "Rebuild", "Export"][rawValue] }
    }
    enum Units: String, CaseIterable, Identifiable, Codable {
        case mm = "Millimeters", cm = "Centimeters", m = "Meters", inch = "Inches"
        var id: String { rawValue }
        var toMM: Float { switch self { case .mm: 1; case .cm: 10; case .m: 1000; case .inch: 25.4 } }
    }

    let name: String
    let isSample: Bool
    private let pipeline: ScanPipeline
    private var runTask: Task<Void, Never>?

    @Published var settings: ScanSettings {
        didSet {
            guard settings != oldValue else { return }
            recordHistory(Snapshot(settings: oldValue, solid: solidParams, solidEdited: solidEdited))
            reprocess()
            scheduleSave()
        }
    }
    @Published var units: Units { didSet { settings.unitsToMM = units.toMM; settings.scale = .one } }
    @Published var keepProportions = true
    @Published var tab: Tab = .clean
    @Published var shown: Shown = .scan
    @Published var showOverlay = true

    @Published private(set) var scan = Mesh.empty
    @Published private(set) var scanVersion = 0
    @Published private(set) var removedPieces = 0
    @Published private(set) var isProcessing = false

    @Published var solidParams = SolidParams() {
        didSet {
            guard solidParams != oldValue else { return }
            recordHistory(Snapshot(settings: settings, solid: oldValue, solidEdited: solidEdited))
            rebuildSolid()
            scheduleSave()
        }
    }
    @Published private(set) var solid = Mesh.empty
    @Published private(set) var solidVersion = 0
    @Published private(set) var fit: Mesh.ShapeFit?
    private var solidEdited = false

    @Published var isMeasuring = false
    @Published private(set) var measurePoints: [SIMD3<Float>] = []
    @Published private(set) var lastCalibration: String?

    @Published var cameraResetToken = 0

    // Direct dimension editing
    @Published var showDimensions = true
    @Published var selectedDimension: DimensionAnnotation.Key?
    @Published var resizeMode: ResizeMode = .scale
    @Published var stretchAxis = 1
    /// For a rebuilt bolt or pin: places the scan in the part's frame so the overlay lines up.
    @Published private(set) var overlayTransform = matrix_identity_float4x4
    @Published private(set) var turnedConfidence: Float?
    /// Set by the view from the subscription state; editing a rebuilt shape needs Pro.
    var canEditSolid = true
    /// Asks the view to show the paywall.
    @Published var proPrompt: ProFeature?

    enum ExportTarget: String, CaseIterable, Identifiable {
        case scan = "Cleaned scan", solid = "Rebuilt shape", nut = "Matching nut"
        var id: String { rawValue }
    }
    @Published var exportTarget: ExportTarget = .scan
    @Published private(set) var nut = Mesh.empty
    @Published private(set) var nutVersion = 0
    var previewingNut: Bool { tab == .export && exportTarget == .nut && !nut.isEmpty }
    var hasThread: Bool { solidParams.kind == .turned && solidParams.turned.mainThread != nil }

    // Undo / redo
    struct Snapshot: Equatable {
        var settings: ScanSettings
        var solid: SolidParams
        var solidEdited: Bool
    }
    @Published private(set) var undoStack: [Snapshot] = []
    @Published private(set) var redoStack: [Snapshot] = []
    private var lastHistoryTime = Date.distantPast
    private var historyPaused = 0

    // Saving
    let projectURL: URL?
    private var saveTask: Task<Void, Never>?

    init(source: Mesh, name: String, isSample: Bool = false, zUp: Bool = false, projectURL: URL? = nil) {
        self.name = name
        self.isSample = isSample
        self.projectURL = isSample ? nil : projectURL
        self.pipeline = ScanPipeline(source: source)
        let ext = source.bounds.size.max()
        let detected: Units = ext < 2 ? .m : .mm   // scanner apps usually export meters
        self.units = detected
        var s = ScanSettings()
        s.unitsToMM = detected.toMM
        if zUp { s.orientation = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))) }
        self.settings = s
        if let url = projectURL, let saved = ProjectFile.load(from: url) {
            self.units = saved.units
            self.settings = saved.settings
            self.solidParams = saved.solid
            self.solidEdited = saved.solidEdited
            rebuildSolid()
        }
        reprocess(refit: true)
    }

    // MARK: History

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Saves the state from before a change. Changes within 0.6 s of each other
    /// (a slider or handle drag) collapse into one step.
    private func recordHistory(_ before: Snapshot) {
        guard historyPaused == 0 else { return }
        let now = Date()
        defer { lastHistoryTime = now }
        if now.timeIntervalSince(lastHistoryTime) < 0.6, !undoStack.isEmpty { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private var current: Snapshot { Snapshot(settings: settings, solid: solidParams, solidEdited: solidEdited) }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(current)
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(current)
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        historyPaused += 1
        defer { historyPaused -= 1; lastHistoryTime = .distantPast }
        selectedDimension = nil
        settings = s.settings
        solidParams = s.solid
        solidEdited = s.solidEdited
    }

    // MARK: Saving

    private func scheduleSave() {
        guard projectURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let url = projectURL else { return }
        saveTask?.cancel()
        ProjectFile(settings: settings, units: units, solid: solidParams, solidEdited: solidEdited).save(to: url)
    }

    var size: SIMD3<Float> {
        if previewingNut { return nut.bounds.size }
        return (shown == .solid ? solid : scan).bounds.size
    }
    var scanSize: SIMD3<Float> { scan.bounds.size }
    static let bed: Float = 256
    func fitsBed(_ s: SIMD3<Float>) -> Bool { s.x <= Self.bed && s.y <= Self.bed && s.z <= Self.bed }

    // MARK: Pipeline

    func reprocess(refit: Bool = false) {
        runTask?.cancel()
        let s = settings
        isProcessing = true
        runTask = Task { [pipeline] in
            let result = await pipeline.run(s)
            guard !Task.isCancelled else { return }
            self.scan = result.mesh
            self.removedPieces = result.removedPieces
            self.scanVersion += 1
            self.isProcessing = false
            if self.tab == .rebuild || self.tab == .export { self.detectIfNeeded() }
            if refit { self.cameraResetToken += 1 }
        }
    }

    // MARK: Clean

    func layFlat() {
        let o = settings.orientation
        let r = simd_float3x3(SIMD3(o.columns.0.x, o.columns.0.y, o.columns.0.z),
                              SIMD3(o.columns.1.x, o.columns.1.y, o.columns.1.z),
                              SIMD3(o.columns.2.x, o.columns.2.y, o.columns.2.z))
        let currentUp = r.transpose * SIMD3<Float>(0, 1, 0)
        let keep = settings.keepLargest
        Task { [pipeline] in
            let rot = await pipeline.layFlat(currentUp: currentUp, keepLargest: keep)
            self.settings.orientation = rot
            self.cameraResetToken += 1
        }
    }

    func rotate(axis: SIMD3<Float>, degrees: Float) {
        let q = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: axis))
        settings.orientation = q * settings.orientation
        cameraResetToken += 1
    }

    // MARK: Size

    func setDimension(_ axis: Int, to value: Float) {
        let current = scanSize[axis]
        guard value > 0, current > 0 else { return }
        let k = value / current
        if keepProportions { settings.scale *= k } else { settings.scale[axis] *= k }
    }

    func resetSize() {
        settings.scale = .one
        settings.offset = 0
        settings.mirror = false
        settings.stretch = .zero
        lastCalibration = nil
    }

    func startMeasuring() {
        shown = .scan
        measurePoints = []
        isMeasuring = true
    }

    func cancelMeasuring() {
        isMeasuring = false
        measurePoints = []
    }

    func addMeasurePoint(_ p: SIMD3<Float>) {
        guard isMeasuring else { return }
        measurePoints.append(p)
        if measurePoints.count == 2 { isMeasuring = false }
    }

    var measuredDistance: Float? {
        measurePoints.count == 2 ? simd_distance(measurePoints[0], measurePoints[1]) : nil
    }

    func calibrate(realDistance: Float) {
        guard let d = measuredDistance, d > 0, realDistance > 0 else { return }
        let k = realDistance / d
        settings.scale *= k
        lastCalibration = String(format: "Rescaled by %+.2f%% to match your %.2f mm measurement.", (k - 1) * 100, realDistance)
        measurePoints = []
    }

    // MARK: Rebuild

    func detectShape(userAsked: Bool = false) {
        guard !scan.isEmpty else { return }
        if !userAsked { historyPaused += 1 }
        defer { if !userAsked { historyPaused -= 1 } }
        let f = scan.fitShape()
        fit = f
        var p = solidParams
        if let t = TurnedPart.detect(in: scan), t.lengthToWidth > 1.3, t.confidence > 0.35, t.part.sections.count <= 8 {
            p.kind = .turned
            let fit = p.turned.threadFit
            p.turned = t.part
            p.turned.threadFit = fit
            overlayTransform = t.scanToPart
            turnedConfidence = t.confidence
            solidParams = p
            if userAsked { solidEdited = false }
            return
        }
        turnedConfidence = nil
        overlayTransform = matrix_identity_float4x4
        p.kind = f.isRound ? .round : .block
        p.diameter = rounded(f.diameter)
        p.width = rounded(f.width)
        p.depth = rounded(f.depth)
        p.height = rounded(f.height)
        if let hole = f.holeDiameter {
            if p.hole == .none { p.hole = .round }
            p.holeSize = rounded(hole)
        } else {
            p.hole = .none
        }
        solidParams = p
        if userAsked { solidEdited = false }
    }

    /// Re-fits the rebuilt shape to the scan unless the person has edited it.
    func detectIfNeeded() {
        if !solidEdited { detectShape() }
    }

    func editSolid(_ change: (inout SolidParams) -> Void) {
        solidEdited = true
        change(&solidParams)
    }

    // MARK: Bolt / pin sections

    func addSection() {
        editSolid { p in
            let last = p.turned.sections.last
            p.turned.sections.append(.init(shape: .round, size: max(1, (last?.size ?? 6) * 0.8), length: 5))
        }
    }

    func removeSection(_ id: UUID) {
        editSolid { p in
            guard p.turned.sections.count > 1 else { return }
            p.turned.sections.removeAll { $0.id == id }
        }
    }

    func snapToStandard() { editSolid { $0.turned.snapToStandard() } }

    private func rebuildSolid() {
        solid = SolidBuilder.build(solidParams)
        solidVersion += 1
        nut = solidParams.kind == .turned ? solidParams.turned.matchingNut() : .empty
        nutVersion += 1
        if nut.isEmpty && exportTarget == .nut { exportTarget = .solid }
    }

    private func rounded(_ v: Float) -> Float { (v * 10).rounded() / 10 }

    var fitSummary: String {
        if solidParams.kind == .turned, turnedConfidence != nil {
            let part = solidParams.turned
            let parts = part.sections.map { s -> String in
                let size = s.thread?.name ?? (s.shape == .hex ? "hex \(s.size.clean) AF" : "Ø\(s.size.clean)")
                return "\(size) × \(String(format: "%.1f", s.length))"
            }
            return "Looks like a bolt or pin, \(String(format: "%.1f", part.totalLength)) mm long: " + parts.joined(separator: ", ")
                + ". The hidden side is filled in from its symmetry."
        }
        guard let f = fit else { return "Measures the scan and suggests a matching shape." }
        let hole = f.holeDiameter.map { String(format: " Found a center hole about Ø%.1f mm.", $0) } ?? ""
        if f.isRound {
            return String(format: "Looks round: Ø%.1f mm, %.1f mm tall, varying ±%.2f mm around the edge.", f.diameter, f.height, f.edgeDeviation) + hole
        }
        return String(format: "Looks like a block: %.1f × %.1f × %.1f mm.", f.width, f.depth, f.height) + hole
    }

    // MARK: Export

    func mesh(for shown: Shown) -> Mesh { shown == .solid ? solid : scan }

    func mesh(for target: ExportTarget) -> Mesh {
        switch target {
        case .scan: return scan
        case .solid: return solid
        case .nut: return nut
        }
    }

    var defaultFileName: String {
        let base = name.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
        let cleaned = base.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-_ ")).inverted).joined()
        let dashed = cleaned.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        return dashed.isEmpty ? "part" : dashed
    }
}


// MARK: - Saved edits

/// Everything needed to reopen a scan with its edits. Saved as JSON next to the scan.
struct ProjectFile: Codable {
    var version = 1
    var settings: ScanSettings
    var units: EditorModel.Units
    var solid: SolidParams
    var solidEdited: Bool

    init(settings: ScanSettings, units: EditorModel.Units, solid: SolidParams, solidEdited: Bool) {
        self.settings = settings; self.units = units; self.solid = solid; self.solidEdited = solidEdited
    }

    static func url(for scan: URL) -> URL {
        scan.deletingLastPathComponent().appendingPathComponent(scan.lastPathComponent + ".truefit.json")
    }

    static func load(from url: URL) -> ProjectFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectFile.self, from: data)
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension ScanSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case keepLargest, smoothPasses, flatten, offset, orientation, scale, mirror, unitsToMM, stretch, stretchCut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        keepLargest = try c.decodeIfPresent(Bool.self, forKey: .keepLargest) ?? keepLargest
        smoothPasses = try c.decodeIfPresent(Int.self, forKey: .smoothPasses) ?? smoothPasses
        flatten = try c.decodeIfPresent(Float.self, forKey: .flatten) ?? flatten
        offset = try c.decodeIfPresent(Float.self, forKey: .offset) ?? offset
        if let m = try c.decodeIfPresent([Float].self, forKey: .orientation), m.count == 16 {
            orientation = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                        SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
        }
        scale = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .scale) ?? scale
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? mirror
        unitsToMM = try c.decodeIfPresent(Float.self, forKey: .unitsToMM) ?? unitsToMM
        stretch = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .stretch) ?? stretch
        stretchCut = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .stretchCut) ?? stretchCut
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keepLargest, forKey: .keepLargest)
        try c.encode(smoothPasses, forKey: .smoothPasses)
        try c.encode(flatten, forKey: .flatten)
        try c.encode(offset, forKey: .offset)
        let o = orientation
        try c.encode([o.columns.0, o.columns.1, o.columns.2, o.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }, forKey: .orientation)
        try c.encode(scale, forKey: .scale)
        try c.encode(mirror, forKey: .mirror)
        try c.encode(unitsToMM, forKey: .unitsToMM)
        try c.encode(stretch, forKey: .stretch)
        try c.encode(stretchCut, forKey: .stretchCut)
    }
}
