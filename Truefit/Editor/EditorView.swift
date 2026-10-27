import SwiftUI
import simd

struct EditorView: View {
    @StateObject var model: EditorModel
    @EnvironmentObject private var store: Store
    @State private var paywall: ProFeature?
    @FocusState private var focused: Bool
    @State private var hiddenGuides: Set<Int> = []
    @State private var forcedGuide: Int?

    init(model: EditorModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                viewport
                    .frame(maxHeight: .infinity)
                StepTabs(selection: $model.tab)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if showGuide {
                            StepGuideCard(guide: StepGuide.guide(for: model.tab)) {
                                GuideMemory.markSeen(model.tab)
                                hiddenGuides.insert(model.tab.rawValue)
                                forcedGuide = nil
                            }
                            .transition(.opacity)
                        }
                        panel
                    }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(height: geo.size.height * 0.47)
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation { forcedGuide = model.tab.rawValue; hiddenGuides.remove(model.tab.rawValue) }
                } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("What does this step do?")
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .accessibilityLabel("Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .accessibilityLabel("Redo")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !store.isPro {
                    Button("Pro") { paywall = .rebuild }
                        .font(.subheadline.weight(.semibold))
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .sheet(item: $paywall) { PaywallView(feature: $0) }
        .animation(.snappy, value: model.selectedDimension)
        .onChange(of: model.shown) { _, shown in
            model.selectedDimension = nil
            if shown == .solid { model.scheduleCompletion() }
        }
        .onAppear { model.canEditSolid = store.isPro }
        .onDisappear { model.saveNow() }
        .onChange(of: store.isPro) { _, pro in model.canEditSolid = pro }
        .onChange(of: model.proPrompt) { _, f in if let f { paywall = f; model.proPrompt = nil } }
        .onChange(of: model.tab) { _, tab in
            switch tab {
            case .rebuild: model.shown = .solid; model.scheduleCompletion()
            case .clean, .size: model.shown = .scan
            case .export: model.scheduleCompletion()
            }
            if tab != .size { model.cancelMeasuring() }
            model.selectedDimension = nil
        }
    }

    private var showGuide: Bool {
        let t = model.tab.rawValue
        if forcedGuide == t { return true }
        if hiddenGuides.contains(t) { return false }
        return model.isSample || !GuideMemory.seen(model.tab)
    }

    // MARK: Viewport

    private var viewport: some View {
        ZStack {
            Color(.secondarySystemBackground)
            MeshSceneView(model: model)
            VStack {
                HStack(alignment: .top) {
                    DimChip(size: model.size)
                    Spacer()
                    BedChip(fits: model.fitsBed(model.size))
                }
                if model.isMeasuring {
                    Text(model.measurePoints.isEmpty ? "Tap the first point on the model" : "Now tap the second point")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.78), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                Spacer()
                if let key = model.selectedDimension, let a = model.annotation(key) {
                    DimensionEditorBar(annotation: a, focused: $focused,
                                       hint: model.shown == .scan ? model.resizeMode.rawValue : nil,
                                       onChange: { model.setValue($0, for: key) },
                                       onDone: { model.selectedDimension = nil })
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack {
                    Picker("Model shown", selection: $model.shown) {
                        ForEach(EditorModel.Shown.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    Spacer()
                    if model.tab == .size || model.tab == .rebuild {
                        Button { model.showDimensions.toggle(); if !model.showDimensions { model.selectedDimension = nil } } label: {
                            Image(systemName: model.showDimensions ? "ruler.fill" : "ruler")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(model.showDimensions ? "Hide dimensions" : "Show dimensions")
                    }
                    Button { model.cameraResetToken += 1 } label: {
                        Label("Reset view", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            if model.isProcessing || (model.isCompleting && model.shown == .solid) {
                VStack { Spacer(); ProgressView().padding(.bottom, 56) }
            }
        }
        .clipped()
    }

    @ViewBuilder private var panel: some View {
        switch model.tab {
        case .clean: CleanPanel(model: model)
        case .size: SizePanel(model: model, focused: $focused, paywall: $paywall)
        case .rebuild: RebuildPanel(model: model, focused: $focused, paywall: $paywall)
        case .export: ExportPanel(model: model, focused: $focused, paywall: $paywall)
        }
    }
}

// MARK: - Chrome

struct StepTabs: View {
    @Binding var selection: EditorModel.Tab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorModel.Tab.allCases) { tab in
                Button { withAnimation(.snappy) { selection = tab } } label: {
                    VStack(spacing: 2) {
                        Text(String(format: "%02d", tab.rawValue + 1))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selection == tab ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selection == tab ? Color.accentColor : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .top) { Divider() }
    }
}

struct DimChip: View {
    let size: SIMD3<Float>
    var body: some View {
        HStack(spacing: 10) {
            dim("W", size.x); dim("D", size.z); dim("H", size.y)
            Text("mm").foregroundStyle(.secondary)
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    private func dim(_ label: String, _ v: Float) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Color("DimColor"))
            Text(String(format: "%.1f", v))
        }
    }
}

struct BedChip: View {
    let fits: Bool
    var body: some View {
        Label(fits ? "Fits A1 bed" : "Too big for A1", systemImage: "circle.fill")
            .labelStyle(DotLabel(color: fits ? .green : .orange))
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    struct DotLabel: LabelStyle {
        let color: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.font(.system(size: 7)).foregroundStyle(color)
                configuration.title
            }
        }
    }
}

// MARK: - Reusable controls

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct ValueSlider: View {
    let title: String
    let caption: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let display: (Float) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text(display(value)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct MMField: View {
    let title: String
    @Binding var value: Float
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .font(.body.monospacedDigit())
                    .focused(focused)
                Text("mm").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator), lineWidth: 0.5))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProLock: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Card {
            Label("Truefit Pro", systemImage: "lock.fill").font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Button("See Pro plans", action: action).buttonStyle(.borderedProminent)
        }
    }
}

extension Binding where Value == Int {
    var asFloat: Binding<Float> {
        Binding<Float>(get: { Float(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) })
    }
}


/// Floating bar for the dimension selected on the model: type a value,
/// nudge it, or drag the handle on the model.
struct DimensionEditorBar: View {
    let annotation: DimensionAnnotation
    var focused: FocusState<Bool>.Binding
    let hint: String?
    let onChange: (Float) -> Void
    let onDone: () -> Void
    @State private var text: Float = 0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(annotation.title).font(.subheadline.weight(.semibold))
                Text(hint ?? "Drag the handle or type a value").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { onChange(max(annotation.minValue, annotation.value - 0.5)) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decrease by half a millimeter")
            HStack(spacing: 2) {
                TextField("Value", value: $text, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 64)
                    .focused(focused)
                    .onSubmit { onChange(text) }
                Text("mm").font(.caption).foregroundStyle(.secondary)
            }
            Button { onChange(annotation.value + 0.5) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Increase by half a millimeter")
            Button("Done", action: { if text != annotation.value { onChange(text) }; onDone() })
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { text = rounded(annotation.value) }
        .onChange(of: annotation.value) { _, v in text = rounded(v) }
        .onChange(of: focused.wrappedValue) { _, isFocused in
            if !isFocused, text != rounded(annotation.value) { onChange(text) }
        }
    }

    private func rounded(_ v: Float) -> Float { (v * 100).rounded() / 100 }
}
