import SwiftUI
import UniformTypeIdentifiers

/// A scan the person opened or captured, kept in the app's Documents folder.
struct SavedScan: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum Library {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list() -> [SavedScan] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { MeshIO.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map { SavedScan(url: $0, date: (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }

    /// Copies a file into the library under a unique name and returns the copy.
    static func add(_ source: URL, name: String? = nil) throws -> URL {
        let ext = source.pathExtension.lowercased()
        let base = name ?? source.deletingPathExtension().lastPathComponent
        var dest = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }
}

struct EditorRoute: Hashable {
    let id = UUID()
    let model: EditorModel
    static func == (a: EditorRoute, b: EditorRoute) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct HomeView: View {
    @EnvironmentObject private var store: Store
    @State private var scans: [SavedScan] = []
    @State private var route: EditorRoute?
    @State private var showTips = false
    @State private var showCapture = false
    @State private var showImporter = false
    @State private var showPaywall = false
    @State private var showSettings = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var loading: String?
    @State private var error: String?

    private static let importTypes: [UTType] = [.usdz, .usd, .threeDContent]
        + ["stl", "obj", "ply"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    hero
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Button { showImporter = true } label: {
                        Label("Open a scan file", systemImage: "folder")
                    }
                    Button { openSample() } label: {
                        Label("Try a sample scan: knob", systemImage: "cube.transparent")
                    }
                    Button { openBoltSample() } label: {
                        Label("Try a sample scan: half-hidden bolt", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    Text("Works with USDZ, STL, OBJ and PLY files from apps like Polycam, Scaniverse or Reality Composer.")
                }
                if !scans.isEmpty {
                    Section("Your scans") {
                        ForEach(scans) { scan in
                            Button { open(scan.url, name: scan.name) } label: {
                                HStack {
                                    Image(systemName: "cube").foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(scan.name).foregroundStyle(.primary)
                                        Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(scan.url.pathExtension.uppercased())
                                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                try? FileManager.default.removeItem(at: scans[i].url)
                                try? FileManager.default.removeItem(at: ProjectFile.url(for: scans[i].url))
                            }
                            scans = Library.list()
                        }
                    }
                }
            }
            .navigationTitle("Truefit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isPro {
                        Label("Pro", systemImage: "checkmark.seal.fill").labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                    } else {
                        Button("Get Pro") { showPaywall = true }.font(.subheadline.weight(.semibold))
                    }
                }
            }
            .navigationDestination(item: $route) { r in EditorView(model: r.model) }
            .overlay {
                if let loading {
                    ProgressView(loading)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert("Couldn't open that scan", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes) { result in
                if case .success(let url) = result { importFile(url) }
            }
            .sheet(isPresented: $showTips) { ScanTipsView { showCapture = true } }
            .sheet(isPresented: $showPaywall) { PaywallView(feature: nil) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { if !$0 { hasOnboarded = true } })) {
                OnboardingView(onTrySample: {
                    hasOnboarded = true
                    openBoltSample()
                }, onFinish: { hasOnboarded = true })
            }
            .fullScreenCover(isPresented: $showCapture) {
                CaptureView { url in
                    showCapture = false
                    let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())
                    if let saved = try? Library.add(url, name: "Scan \(stamp)".replacingOccurrences(of: ":", with: ".")) {
                        open(saved, name: saved.deletingPathExtension().lastPathComponent)
                    } else {
                        open(url, name: "New scan")
                    }
                }
            }
            .onAppear { scans = Library.list() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan it. Size it. Print it.")
                .font(.system(.title, design: .rounded, weight: .bold))
            Text("Capture an object with your iPhone, clean it up, set exact dimensions, and save a print-ready STL.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                showTips = true
            } label: {
                Label {
                    Text("Scan an object")
                } icon: {
                    Image(systemName: "camera.viewfinder")
                }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!CaptureModel.isSupported)
            if !CaptureModel.isSupported {
                Text("Scanning needs an iPhone with LiDAR (iPhone 12 Pro or later Pro model). You can still open scan files and try the sample.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Opening

    private func openSample() {
        let model = EditorModel(source: SolidBuilder.sampleScan(), name: "Sample knob", isSample: true)
        route = EditorRoute(model: model)
    }

    private func openBoltSample() {
        let model = EditorModel(source: SolidBuilder.sampleBoltScan(), name: "Sample bolt", isSample: true)
        route = EditorRoute(model: model)
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let saved = try Library.add(url)
            scans = Library.list()
            open(saved, name: saved.deletingPathExtension().lastPathComponent)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ url: URL, name: String) {
        loading = "Loading \(name)…"
        let zUp = url.pathExtension.lowercased() == "stl"
        Task {
            do {
                let mesh = try await Task.detached(priority: .userInitiated) { try MeshIO.load(url: url) }.value
                loading = nil
                route = EditorRoute(model: EditorModel(source: mesh, name: name, zUp: zUp,
                                                       projectURL: ProjectFile.url(for: url)))
                scans = Library.list()
            } catch {
                loading = nil
                self.error = error.localizedDescription
            }
        }
    }
}
