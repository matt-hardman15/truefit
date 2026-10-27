import SwiftUI
import SceneKit
import simd

/// 3D viewport: the scan, the rebuilt solid, a bounding box, the A1 bed grid,
/// and tap-to-measure.
struct MeshSceneView: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.pointOfView = context.coordinator.cameraNode
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        context.coordinator.attachOverlay(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.sync(scheme: scheme)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: EditorModel
        let scene = SCNScene()
        let cameraNode = SCNNode()
        weak var view: SCNView?

        private let scanNode = SCNNode()
        private let solidNode = SCNNode()
        private let boxNode = SCNNode()
        private let gridNode = SCNNode()
        private let measureNode = SCNNode()
        private let dimNode = SCNNode()
        private let nutNode = SCNNode()
        private var nutVersion = -1
        private var lastNutPreview: Bool?
        private let cutNode = SCNNode()
        private var lastAnnotations: [DimensionAnnotation] = []
        private var lastSelected: DimensionAnnotation.Key?
        private var lastCut: SIMD4<Float> = .zero
        private var dimensionsVisible = false

        // UIKit layer over the 3D view: tappable dimension labels and a drag handle.
        private let overlay = PassthroughView()
        private var labels: [DimensionAnnotation.Key: UIButton] = [:]
        private let handle = UIView()
        private var displayLink: CADisplayLink?
        private var drag: (key: DimensionAnnotation.Key, startValue: Float, dir: CGPoint, pxPerMM: CGFloat, lastWhole: Int)?
        private let haptics = UISelectionFeedbackGenerator()
        private var scanVersion = -1, solidVersion = -1, resetToken = -1
        private var scheme: ColorScheme?
        private var lastBox: SIMD3<Float> = .zero
        private var lastMeasure: [SIMD3<Float>] = []
        private var lastShown: EditorModel.Shown?
        private var lastOverlay: Bool?

        private let scanMaterial = SCNMaterial()
        private let ghostMaterial = SCNMaterial()
        private let solidMaterial = SCNMaterial()

        init(model: EditorModel) {
            self.model = model
            super.init()
            let camera = SCNCamera()
            camera.fieldOfView = 35
            camera.zNear = 0.5
            camera.zFar = 5000
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900
            key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
            let fill = SCNNode(); fill.light = SCNLight(); fill.light!.type = .ambient; fill.light!.intensity = 420
            let rim = SCNNode(); rim.light = SCNLight(); rim.light!.type = .directional; rim.light!.intensity = 350
            rim.eulerAngles = SCNVector3(-0.3, -2.4, 0)
            [key, fill, rim, scanNode, solidNode, nutNode, boxNode, gridNode, measureNode, dimNode, cutNode].forEach { scene.rootNode.addChildNode($0) }

            for m in [scanMaterial, ghostMaterial, solidMaterial] {
                m.lightingModel = .physicallyBased
                m.isDoubleSided = false
            }
            scanMaterial.roughness.contents = 0.85
            ghostMaterial.roughness.contents = 0.9
            ghostMaterial.transparency = 0.22
            ghostMaterial.writesToDepthBuffer = false
            solidMaterial.roughness.contents = 0.45
            solidMaterial.metalness.contents = 0.05
        }

        func sync(scheme: ColorScheme) {
            if self.scheme != scheme {
                self.scheme = scheme
                applyColors()
            }
            if model.scanVersion != scanVersion {
                scanVersion = model.scanVersion
                scanNode.geometry = MeshIO.geometry(for: model.scan)
                lastShown = nil
            }
            if model.solidVersion != solidVersion {
                solidVersion = model.solidVersion
                solidNode.geometry = MeshIO.geometry(for: model.solid)
                solidNode.geometry?.firstMaterial = solidMaterial
                lastShown = nil
            }
            if model.nutVersion != nutVersion {
                nutVersion = model.nutVersion
                nutNode.geometry = MeshIO.geometry(for: model.nut)
                nutNode.geometry?.firstMaterial = solidMaterial
            }
            if lastShown != model.shown || lastOverlay != model.showOverlay || lastNutPreview != model.previewingNut {
                lastShown = model.shown; lastOverlay = model.showOverlay; lastNutPreview = model.previewingNut
                let nutOnly = model.previewingNut
                nutNode.isHidden = !nutOnly
                let solid = model.shown == .solid
                solidNode.isHidden = !solid || nutOnly
                scanNode.isHidden = (solid && !model.showOverlay) || nutOnly
                scanNode.geometry?.firstMaterial = solid ? ghostMaterial : scanMaterial
                scanNode.renderingOrder = solid ? 10 : 0
            }
            let s = model.size
            if s != lastBox { lastBox = s; boxNode.geometry = boxLines(s) }
            if model.measurePoints != lastMeasure { lastMeasure = model.measurePoints; drawMeasure() }
            if model.cameraResetToken != resetToken { resetToken = model.cameraResetToken; frame() }

            let turnedOverlay = model.shown == .solid && model.solidParams.kind == .turned
            scanNode.simdTransform = turnedOverlay ? model.overlayTransform : matrix_identity_float4x4

            let showDims = model.showDimensions && !model.isMeasuring && (model.tab == .size || model.tab == .rebuild)
            let anns = showDims ? model.annotations : []
            if anns != lastAnnotations || model.selectedDimension != lastSelected || showDims != dimensionsVisible {
                lastAnnotations = anns
                lastSelected = model.selectedDimension
                dimensionsVisible = showDims
                drawDimensions()
            }
            syncCutPlane()
        }

        // MARK: Dimensions

        func attachOverlay(to view: SCNView) {
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(overlay)
            handle.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
            handle.layer.cornerRadius = 15
            handle.layer.borderWidth = 3
            handle.layer.borderColor = UIColor.white.cgColor
            handle.layer.shadowOpacity = 0.25
            handle.layer.shadowRadius = 3
            handle.layer.shadowOffset = .zero
            handle.isHidden = true
            handle.accessibilityLabel = "Drag to change the selected dimension"
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
            overlay.addSubview(handle)
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        private func drawDimensions() {
            dimNode.childNodes.forEach { $0.removeFromParentNode() }
            let keys = Set(lastAnnotations.map(\.key))
            for (k, b) in labels where !keys.contains(k) { b.removeFromSuperview(); labels[k] = nil }
            let dim = resolved("DimColor"), accent = resolved("AccentColor")
            let tick = max(0.8, simd_length(model.size) * 0.018)
            for a in lastAnnotations {
                let selected = a.key == model.selectedDimension
                let dir = simd_normalize(a.end - a.start)
                let side: SIMD3<Float> = abs(dir.y) > 0.7 ? [1, 0, 0] : [0, 1, 0]
                var segs = [(a.start, a.end)]
                segs.append((a.start - side * tick, a.start + side * tick))
                segs.append((a.end - side * tick, a.end + side * tick))
                let n = SCNNode(geometry: lines(segs, color: selected ? accent : dim))
                n.geometry?.firstMaterial?.readsFromDepthBuffer = false
                n.renderingOrder = 30
                dimNode.addChildNode(n)

                let b = labels[a.key] ?? makeLabel(for: a.key)
                labels[a.key] = b
                var config = b.configuration ?? .filled()
                config.title = a.prefix + a.value.clean
                config.baseBackgroundColor = selected ? accent : dim
                config.baseForegroundColor = selected ? .white : UIColor(white: 0.08, alpha: 1)
                b.configuration = config
                b.accessibilityLabel = "\(a.title) \(String(format: "%.1f", a.value)) millimeters"
            }
            let sel = lastAnnotations.first { $0.key == model.selectedDimension }
            handle.isHidden = sel == nil
            handle.backgroundColor = accent
            tick()
        }

        private func makeLabel(for key: DimensionAnnotation.Key) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                return out
            }
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.model.selectedDimension = self.model.selectedDimension == key ? nil : key
            })
            overlay.addSubview(b)
            overlay.bringSubviewToFront(handle)
            return b
        }

        private func screen(_ p: SIMD3<Float>) -> CGPoint? {
            guard let view else { return nil }
            let q = view.projectPoint(SCNVector3(p.x, p.y, p.z))
            guard q.z > 0, q.z < 1 else { return nil }
            return CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
        }

        @objc private func tick() {
            guard dimensionsVisible else {
                labels.values.forEach { $0.isHidden = true }
                handle.isHidden = true
                return
            }
            for a in lastAnnotations {
                guard let b = labels[a.key] else { continue }
                if let p = screen((a.start + a.end) * 0.5) {
                    b.isHidden = false
                    b.sizeToFit()
                    b.center = p
                } else {
                    b.isHidden = true
                }
            }
            if let sel = lastAnnotations.first(where: { $0.key == model.selectedDimension }), let p = screen(sel.end) {
                handle.isHidden = false
                if drag == nil { handle.center = p }
            } else {
                handle.isHidden = true
            }
        }

        @objc private func dragged(_ g: UIPanGestureRecognizer) {
            guard let key = model.selectedDimension, let a = model.annotation(key) else { return }
            switch g.state {
            case .began:
                guard let s0 = screen(a.start), let s1 = screen(a.end) else { return }
                let dx = s1.x - s0.x, dy = s1.y - s0.y
                let len = max(1, (dx * dx + dy * dy).squareRoot())
                drag = (key, a.value, CGPoint(x: dx / len, y: dy / len), len / CGFloat(max(a.value, 0.1)), Int(a.value))
                haptics.prepare()
            case .changed:
                guard let d = drag else { return }
                let t = g.translation(in: overlay)
                let along = t.x * d.dir.x + t.y * d.dir.y
                let raw = d.startValue + Float(along / d.pxPerMM)
                let value = max(a.minValue, (raw * 10).rounded() / 10)
                model.setValue(value, for: key)
                let whole = Int(value)
                if whole != d.lastWhole { haptics.selectionChanged(); drag?.lastWhole = whole }
                if let p = screen(model.annotation(key)?.end ?? a.end) { handle.center = p }
            default:
                drag = nil
            }
        }

        private func syncCutPlane() {
            let show = model.resizeMode == .stretch && model.tab == .size && model.shown == .scan && !model.scan.isEmpty
            let axis = model.stretchAxis
            let key = SIMD4<Float>(show ? 1 : 0, Float(axis), model.settings.stretchCut[axis], model.settings.stretch[axis] + simd_length(model.scanSize))
            guard key != lastCut else { return }
            lastCut = key
            cutNode.childNodes.forEach { $0.removeFromParentNode() }
            guard show else { return }
            let b = model.scan.bounds, size = b.size
            let d = model.settings.stretch[axis]
            let at = b.min[axis] + (size[axis] - max(d, 0) - min(d, 0)) * model.settings.stretchCut[axis]
            let pad: Float = 1.15
            let plane: SCNPlane
            let node = SCNNode()
            switch axis {
            case 0:
                plane = SCNPlane(width: CGFloat(size.z * pad), height: CGFloat(size.y * pad))
                node.simdEulerAngles = [0, .pi / 2, 0]
                node.simdPosition = [at, b.center.y, b.center.z]
            case 1:
                plane = SCNPlane(width: CGFloat(size.x * pad), height: CGFloat(size.z * pad))
                node.simdEulerAngles = [-.pi / 2, 0, 0]
                node.simdPosition = [b.center.x, at, b.center.z]
            default:
                plane = SCNPlane(width: CGFloat(size.x * pad), height: CGFloat(size.y * pad))
                node.simdPosition = [b.center.x, b.center.y, at]
            }
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = resolved("AccentColor").withAlphaComponent(0.28)
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            plane.firstMaterial = m
            node.geometry = plane
            node.renderingOrder = 25
            cutNode.addChildNode(node)
        }

        private func applyColors() {
            scanMaterial.diffuse.contents = resolved("ScanColor")
            ghostMaterial.diffuse.contents = resolved("ScanColor")
            solidMaterial.diffuse.contents = resolved("SolidColor")
            gridNode.geometry = gridLines()
            boxNode.geometry = boxLines(lastBox)
            drawMeasure()
            drawDimensions()
            lastCut = .zero
        }

        private func resolved(_ name: String) -> UIColor {
            let c = UIColor(named: name) ?? .systemOrange
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
            return c.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        }

        private func lineMaterial(_ color: UIColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            return m
        }

        private func lines(_ segments: [(SIMD3<Float>, SIMD3<Float>)], color: UIColor) -> SCNGeometry {
            var verts = [SCNVector3]()
            var idx = [UInt32]()
            for (a, b) in segments {
                idx += [UInt32(verts.count), UInt32(verts.count + 1)]
                verts += [SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, b.y, b.z)]
            }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                                elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            g.firstMaterial = lineMaterial(color)
            return g
        }

        private func gridLines() -> SCNGeometry {
            let half = EditorModel.bed / 2
            var segs = [(SIMD3<Float>, SIMD3<Float>)]()
            var x = -half
            while x <= half + 0.01 {
                segs.append((SIMD3(x, -0.02, -half), SIMD3(x, -0.02, half)))
                segs.append((SIMD3(-half, -0.02, x), SIMD3(half, -0.02, x)))
                x += 8
            }
            return lines(segs, color: resolved("GridColor"))
        }

        private func boxLines(_ s: SIMD3<Float>) -> SCNGeometry {
            let x = s.x / 2, z = s.z / 2, y = s.y
            let c = [SIMD3<Float>(-x, 0, -z), SIMD3(x, 0, -z), SIMD3(x, 0, z), SIMD3(-x, 0, z)]
            let top = c.map { SIMD3<Float>($0.x, y, $0.z) }
            var segs = [(SIMD3<Float>, SIMD3<Float>)]()
            for i in 0..<4 {
                segs.append((c[i], c[(i + 1) % 4]))
                segs.append((top[i], top[(i + 1) % 4]))
                segs.append((c[i], top[i]))
            }
            return lines(segs, color: resolved("DimColor"))
        }

        private func drawMeasure() {
            measureNode.childNodes.forEach { $0.removeFromParentNode() }
            let pts = model.measurePoints
            guard !pts.isEmpty else { return }
            let r = CGFloat(max(0.35, simd_length(model.scanSize) / 140))
            let color = resolved("DimColor")
            for p in pts {
                let s = SCNSphere(radius: r)
                s.firstMaterial = lineMaterial(color)
                let n = SCNNode(geometry: s)
                n.simdPosition = p
                n.renderingOrder = 20
                measureNode.addChildNode(n)
            }
            if pts.count == 2 {
                let n = SCNNode(geometry: lines([(pts[0], pts[1])], color: color))
                n.renderingOrder = 20
                n.geometry?.firstMaterial?.readsFromDepthBuffer = false
                measureNode.addChildNode(n)
            }
        }

        /// Frames the part from a three-quarter view.
        func frame() {
            let s = model.size
            let radius = max(8, simd_length(s) / 2)
            let fov = Float(35) * .pi / 180
            let d = radius / sin(fov / 2) * 1.2
            let target = SIMD3<Float>(0, s.y / 2, 0)
            cameraNode.simdPosition = target + SIMD3<Float>(0.62, 0.55, 0.6) * (d / 1.03)
            cameraNode.simdLook(at: target)
            cameraNode.camera?.zNear = Double(d / 100)
            cameraNode.camera?.zFar = Double(d * 40)
            if let view {
                view.pointOfView = cameraNode
                view.defaultCameraController.target = SCNVector3(target.x, target.y, target.z)
            }
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard model.isMeasuring, let view else { return }
            let hits = view.hitTest(g.location(in: view), options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .rootNode: scanNode,
            ])
            guard let hit = hits.first else { return }
            let p = hit.worldCoordinates
            model.addMeasurePoint(SIMD3<Float>(p.x, p.y, p.z))
        }
    }
}

/// Lets touches fall through to the 3D view except on its own subviews.
final class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.frame.insetBy(dx: -8, dy: -8).contains(point) }
    }
}
