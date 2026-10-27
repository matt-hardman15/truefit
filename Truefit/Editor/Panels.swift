import SwiftUI
import simd

// MARK: - 01 Clean

struct CleanPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Orientation")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    orient("Lay flat", "square.3.layers.3d.down.forward") { model.layFlat() }
                    orient("Flip over", "arrow.up.and.down.righttriangle.up.righttriangle.down") { model.rotate(axis: [1, 0, 0], degrees: 180) }
                    orient("Tilt 90°", "rotate.3d") { model.rotate(axis: [1, 0, 0], degrees: 90) }
                    orient("Turn 90°", "arrow.clockwise") { model.rotate(axis: [0, 1, 0], degrees: 90) }
                }
            }

            Toggle(isOn: $model.settings.keepLargest) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove stray pieces").font(.body.weight(.medium))
                    Text(strayCaption).font(.footnote).foregroundStyle(.secondary)
                }
            }

            ValueSlider(title: "Smooth surface",
                        caption: "Removes fine speckle. For bigger bumps, use Smooth shape in step 3.",
                        value: $model.settings.smoothPasses.asFloat, range: 0...15, step: 1) {
                $0 == 0 ? "Off" : "\(Int($0)) \(Int($0) == 1 ? "pass" : "passes")"
            }

            ValueSlider(title: "Flatten base",
                        caption: "Shaves the bottom flat so it sits on the bed.",
                        value: $model.settings.flatten, range: 0...5, step: 0.1) {
                String(format: "%.1f mm", $0)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Scan units")
                Picker("Scan units", selection: $model.units) {
                    ForEach(EditorModel.Units.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Text("Detected from the scan's size. Change it if the part comes out 10× too big or small.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var strayCaption: String {
        guard model.settings.keepLargest else { return "Drops bits of table and background caught in the scan." }
        switch model.removedPieces {
        case 0: return "No loose pieces found."
        case 1: return "Removed 1 loose piece from the scan."
        default: return "Removed \(model.removedPieces) loose pieces from the scan."
        }
    }

    private func orient(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - 02 Size

struct SizePanel: View {
    @ObservedObject var model: EditorModel
    var focused: FocusState<Bool>.Binding
    @Binding var paywall: ProFeature?
    @EnvironmentObject private var store: Store
    @State private var realDistance: Float = 0

    init(model: EditorModel, focused: FocusState<Bool>.Binding, paywall: Binding<ProFeature?>) {
        self.model = model; self.focused = focused; self._paywall = paywall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Exact size")
                Picker("When you change a size", selection: $model.resizeMode) {
                    ForEach(EditorModel.ResizeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 8) {
                    MMField(title: "Width", value: dim(0), focused: focused)
                    MMField(title: "Depth", value: dim(2), focused: focused)
                    MMField(title: "Height", value: dim(1), focused: focused)
                }
                if model.resizeMode == .scale {
                    Toggle("Keep proportions", isOn: $model.keepProportions).font(.subheadline)
                    Text("Tip: tap a dimension on the model to select it, then drag its handle.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    stretchControls
                }
            }

            Card {
                HStack {
                    Text("Calibrate with a measurement").font(.headline)
                    Spacer()
                    if model.isMeasuring || model.measuredDistance != nil {
                        Button("Cancel") { model.cancelMeasuring() }
                    } else {
                        Button { model.startMeasuring() } label: { Label("Measure", systemImage: "ruler") }
                            .buttonStyle(.bordered)
                    }
                }
                if let d = model.measuredDistance {
                    Text("The scan measures **\(String(format: "%.2f", d)) mm** between those points. What does your caliper read?")
                        .font(.subheadline)
                    HStack(alignment: .bottom, spacing: 8) {
                        MMField(title: "Real distance", value: $realDistance, focused: focused)
                        Button("Apply") {
                            guard store.isPro else { paywall = .calibrate; return }
                            model.calibrate(realDistance: realDistance)
                            realDistance = 0
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(realDistance <= 0)
                    }
                } else {
                    Text(model.lastCalibration ?? "Phone scans drift by a millimeter or two. Tap two points you've measured with calipers, enter the real distance, and the whole part rescales to match.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            ValueSlider(title: "Fit tolerance",
                        caption: "Grows or shrinks every surface. Use a negative value for a part that slides into something.",
                        value: $model.settings.offset, range: -1...1, step: 0.05) {
                String(format: "%+.2f mm", $0)
            }

            Toggle(isOn: $model.settings.mirror) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirror left to right").font(.body.weight(.medium))
                    Text("Makes the opposite-hand version of a part.").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Button("Reset size") { model.resetSize() }
                .buttonStyle(.bordered)
        }
    }

    private func dim(_ axis: Int) -> Binding<Float> {
        Binding(get: { (model.scanSize[axis] * 100).rounded() / 100 },
                set: { model.resizeScan(axis: axis, to: $0) })
    }

    @ViewBuilder private var stretchControls: some View {
        Text("Cuts the part at the blue plane and adds or removes length there, so features on either side keep their size. Use it to make a bolt longer without fattening the head.")
            .font(.footnote).foregroundStyle(.secondary)
        Picker("Stretch along", selection: $model.stretchAxis) {
            Text("Width").tag(0); Text("Height").tag(1); Text("Depth").tag(2)
        }
        .pickerStyle(.segmented)
        ValueSlider(title: "Cut position",
                    caption: "Slide the cut to a plain stretch of the part, away from features you want to keep.",
                    value: cutBinding, range: 0.05...0.95, step: 0.01) {
            "\(Int(($0 * 100).rounded()))%"
        }
        HStack {
            let d = model.settings.stretch[model.stretchAxis]
            Text(d == 0 ? "No stretch yet" : String(format: "%@ %.1f mm at the cut", d > 0 ? "Added" : "Removed", abs(d)))
                .font(.subheadline.monospacedDigit())
            Spacer()
            Button("Clear stretch") { model.settings.stretch = .zero }
                .disabled(model.settings.stretch == .zero)
        }
    }

    private var cutBinding: Binding<Float> {
        Binding(get: { model.settings.stretchCut[model.stretchAxis] },
                set: { model.settings.stretchCut[model.stretchAxis] = $0 })
    }
}

// MARK: - 03 Rebuild

struct RebuildPanel: View {
    @ObservedObject var model: EditorModel
    var focused: FocusState<Bool>.Binding
    @Binding var paywall: ProFeature?
    @EnvironmentObject private var store: Store

    init(model: EditorModel, focused: FocusState<Bool>.Binding, paywall: Binding<ProFeature?>) {
        self.model = model; self.focused = focused; self._paywall = paywall
    }

    @State private var showExact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Fill in what the scan missed. The result is a closed solid, ready to print.")
                .font(.subheadline).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Symmetry")
                Picker("Symmetry", selection: Binding(get: { model.completion.symmetry },
                                                      set: { model.chooseSymmetry($0) })) {
                    ForEach(CompletionSettings.Symmetry.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(symmetryExplanation).font(.footnote).foregroundStyle(.secondary)

                if model.completion.symmetry == .mirror {
                    Picker("Mirror across", selection: $model.completion.mirrorAxis) {
                        Text("Left–right").tag(0)
                        Text("Front–back").tag(2)
                        Text("Top–bottom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    ValueSlider(title: "Plane position",
                                caption: "The orange plane in the view. Line it up with the part's center line.",
                                value: $model.completion.mirrorOffset, range: -0.5...0.5, step: 0.005) {
                        String(format: "%+.1f mm", $0 * model.scanSize[model.completion.mirrorAxis])
                    }
                    Button("Find the plane again") { model.chooseSymmetry(.mirror) }
                        .font(.subheadline)
                }
                if let hint = model.symmetryHint {
                    Label(hint, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.completion.symmetry != .revolve {
                ValueSlider(title: "Fill gaps",
                            caption: "Bridges cracks and small holes up to about this size. Bigger openings are patched with a smooth surface.",
                            value: $model.completion.fillGaps, range: 0.5...5, step: 0.5) {
                    String(format: "%.1f mm", $0)
                }
                ValueSlider(title: "Smooth shape",
                            caption: "Evens out waviness and lumps about this wide. Higher values also round off sharp edges.",
                            value: $model.completion.smoothShape, range: 0...8, step: 0.5) {
                    $0 == 0 ? "Off" : String(format: "%.1f mm", $0)
                }
                Toggle(isOn: $model.completion.closeBottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Close the bottom").font(.body.weight(.medium))
                        Text("Seals the side that was resting on the table with a flat base.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Detail")
                    Picker("Detail", selection: $model.completion.detail) {
                        ForEach(CompletionSettings.Detail.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Finer detail keeps small features but takes longer to compute.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if model.isCompleting {
                    ProgressView().controlSize(.small)
                    Text("Completing…").font(.footnote).foregroundStyle(.secondary)
                } else if !model.completed.isEmpty && !model.useExactShape {
                    let s = model.completed.bounds.size
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(String(format: "Completed: %.1f × %.1f × %.1f mm", s.x, s.z, s.y))
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            Toggle("Show scan overlay", isOn: $model.showOverlay)

            Divider()

            DisclosureGroup(isExpanded: $showExact) {
                exactShape.padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exact shape").font(.headline)
                    Text("Replace the scan with a clean round part, block, or bolt with threads.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { if model.useExactShape { showExact = true } }
    }

    private var symmetryExplanation: String {
        switch model.completion.symmetry {
        case .none: return "Keeps the scan's own shape and patches holes smoothly."
        case .mirror: return "Copies the visible side across a plane to fill the hidden side. Best for parts that match side to side."
        case .revolve: return "Spins the visible profile around the part's center axis. Best for round parts like knobs, caps and spacers."
        }
    }

    @ViewBuilder private var exactShape: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Use an exact shape", isOn: Binding(
                get: { model.useExactShape },
                set: { on in
                    if on && !store.isPro { paywall = .rebuild; return }
                    model.useExactShape = on
                }))
            .font(.body.weight(.medium))

            if model.useExactShape {
                Card {
                    HStack {
                        Text("Detect shape").font(.headline)
                        Spacer()
                        Button("Detect from scan") { model.detectShape(userAsked: true) }.buttonStyle(.bordered)
                    }
                    Text(model.fitSummary).font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Shape")
                    Picker("Shape", selection: param(\.kind)) {
                        ForEach(SolidParams.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.solidParams.kind == .turned {
                        TurnedEditor(model: model, focused: focused)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                            if model.solidParams.kind == .round {
                                MMField(title: "Diameter", value: param(\.diameter), focused: focused)
                            } else {
                                MMField(title: "Width", value: param(\.width), focused: focused)
                                MMField(title: "Depth", value: param(\.depth), focused: focused)
                            }
                            MMField(title: "Height", value: param(\.height), focused: focused)
                            if model.solidParams.kind == .block {
                                MMField(title: "Corners", value: param(\.cornerRadius), focused: focused)
                            }
                            MMField(title: "Chamfer", value: param(\.chamfer), focused: focused)
                        }
                    }
                }

                if model.solidParams.kind != .turned {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Center hole")
                        HStack(alignment: .bottom, spacing: 8) {
                            Picker("Hole", selection: param(\.hole)) {
                                ForEach(SolidParams.Hole.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if model.solidParams.hole != .none {
                                MMField(title: model.solidParams.hole == .hex ? "Across flats" : "Diameter",
                                        value: param(\.holeSize), focused: focused)
                                    .frame(width: 130)
                            }
                        }
                    }
                }
            } else if !store.isPro {
                Text("Exact shapes are part of Truefit Pro.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func param<T>(_ key: WritableKeyPath<SolidParams, T>) -> Binding<T> {
        Binding(get: { model.solidParams[keyPath: key] },
                set: { v in model.editSolid { $0[keyPath: key] = v } })
    }
}

// MARK: - 04 Export

struct ExportPanel: View {
    @ObservedObject var model: EditorModel
    var focused: FocusState<Bool>.Binding
    @Binding var paywall: ProFeature?
    @EnvironmentObject private var store: Store
    private var which: EditorModel.ExportTarget { model.exportTarget }
    @State private var stats: Mesh.Stats?
    @State private var fileName = ""
    @State private var shareURL: ShareItem?
    @State private var error: String?

    init(model: EditorModel, focused: FocusState<Bool>.Binding, paywall: Binding<ProFeature?>) {
        self.model = model; self.focused = focused; self._paywall = paywall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Export", selection: $model.exportTarget) {
                ForEach(model.exportTargets) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if which == .nut, let t = model.solidParams.turned.mainThread {
                Text("\(t.name) hex nut, \(t.headAcrossFlats.clean) mm across flats and \(t.nutHeight.clean) mm tall, with a \(model.solidParams.turned.threadFit.rawValue.lowercased()) fit to your bolt. Print it flat.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            let mesh = model.mesh(for: which)
            let size = mesh.bounds.size
            Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    stat("Size (W × D × H)", String(format: "%.1f × %.1f × %.1f", size.x, size.z, size.y))
                    stat("A1 bed", model.fitsBed(size) ? "Fits" : "Too big", tint: model.fitsBed(size) ? .green : .orange)
                }
                GridRow {
                    stat("Solid volume", stats.map { String(format: "%.1f cm³", $0.volume / 1000) } ?? "…")
                    stat("Filament (est.)", stats.map { String(format: "≈ %.0f g PLA", $0.estimatedGrams) } ?? "…")
                }
                GridRow {
                    stat("Triangles", stats.map { $0.triangles.formatted() } ?? "…")
                    stat("Watertight", stats.map { $0.isWatertight ? "Yes" : "Has gaps" } ?? "…",
                         tint: stats.map { $0.isWatertight ? Color.green : .orange })
                }
            }
            .background(Color(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("File name").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack {
                    TextField("File name", text: $fileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused(focused)
                    Text(".stl").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            Button(action: export) {
                Label("Save STL", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(mesh.isEmpty)

            if which == .completed && model.isCompleting {
                Label("Completing the scan…", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            }
            Text(footnote).font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .onAppear {
            if model.exportTarget != .nut { model.exportTarget = model.useExactShape ? .solid : .completed }
            if fileName.isEmpty { fileName = model.defaultFileName }
        }
        .onChange(of: model.exportTarget) { _, t in
            let base = model.defaultFileName
            fileName = t == .nut ? base + "-nut" : base
        }
        .task(id: "\(which.rawValue)-\(model.scanVersion)-\(model.solidVersion)-\(model.nutVersion)-\(model.resultVersion)") {
            stats = nil
            let mesh = model.mesh(for: which)
            stats = await Task.detached(priority: .userInitiated) { mesh.stats() }.value
        }
        .sheet(item: $shareURL) { ShareSheet(items: [$0.url]) }
    }

    private var footnote: String {
        let base = "Saved in millimeters with Z up, ready for Bambu Studio or any slicer. Filament assumes PLA with 2 walls and 15% infill."
        if store.isPro { return base }
        return base + " \(store.freeExportsLeft) of \(Store.freeExports) free exports left."
    }

    private func export() {
        guard store.canExport else { paywall = .export; return }
        let name = fileName.trimmingCharacters(in: .whitespaces).isEmpty ? model.defaultFileName : fileName
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        do {
            let url = try MeshIO.exportSTL(model.mesh(for: which), name: safe)
            store.recordExport()
            shareURL = ShareItem(url: url)
            error = nil
        } catch {
            self.error = "Couldn't write the file: \(error.localizedDescription)"
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit()).foregroundStyle(tint ?? .primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}


// MARK: - Bolt / pin sections

struct TurnedEditor: View {
    @ObservedObject var model: EditorModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sections, from the bed up").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Snap to ISO bolt") { model.snapToStandard() }
                    .font(.footnote.weight(.semibold))
            }
            ForEach(Array(model.solidParams.turned.sections.enumerated()), id: \.element.id) { index, section in
                SectionRow(model: model, index: index, section: section, focused: focused)
            }
            Button { model.addSection() } label: { Label("Add section", systemImage: "plus") }
                .buttonStyle(.bordered)
            if model.solidParams.turned.mainThread != nil {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Thread fit")
                    Picker("Thread fit", selection: Binding(
                        get: { model.solidParams.turned.threadFit },
                        set: { v in model.editSolid { $0.turned.threadFit = v } })) {
                        ForEach(TurnedPart.ThreadFit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Printed threads need a gap to turn. Standard (\(TurnedPart.ThreadFit.standard.clearance.clean) mm) suits most printers; go looser if parts bind.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let warning = model.solidParams.turned.fineThreadWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        model.exportTarget = .nut
                        model.tab = .export
                    } label: {
                        Label("Make a matching nut", systemImage: "hexagon")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Overall length \(model.solidParams.turned.totalLength.clean) mm. Tap any dimension on the model to change it, or drag its handle. Threads print best standing up, head on the bed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct SectionRow: View {
    @ObservedObject var model: EditorModel
    let index: Int
    let section: TurnedPart.Section
    var focused: FocusState<Bool>.Binding

    var body: some View {
        Card {
            HStack {
                Picker("Shape", selection: bind(\.shape)) {
                    ForEach(TurnedPart.Section.Shape.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
                Spacer()
                Menu {
                    Button("No thread") { update { $0.thread = nil } }
                    ForEach(MetricThread.coarse) { t in
                        Button(t.name) { update { $0.thread = t; $0.size = t.nominal; $0.shape = .round } }
                    }
                } label: {
                    Label(section.thread?.name ?? "No thread", systemImage: "screwdriver")
                        .font(.subheadline)
                }
                if model.solidParams.turned.sections.count > 1 {
                    Button(role: .destructive) { model.removeSection(section.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove section")
                }
            }
            HStack(spacing: 8) {
                MMField(title: section.shape == .hex ? "Across flats" : "Diameter", value: bind(\.size), focused: focused)
                MMField(title: "Length", value: bind(\.length), focused: focused)
                if section.thread == nil {
                    MMField(title: "Top chamfer", value: bind(\.chamfer), focused: focused)
                }
            }
        }
    }

    private func update(_ change: @escaping (inout TurnedPart.Section) -> Void) {
        model.editSolid { p in
            if let i = p.turned.sections.firstIndex(where: { $0.id == section.id }) { change(&p.turned.sections[i]) }
        }
    }

    private func bind<T>(_ key: WritableKeyPath<TurnedPart.Section, T>) -> Binding<T> {
        Binding(get: { section[keyPath: key] },
                set: { v in update { $0[keyPath: key] = v } })
    }
}
