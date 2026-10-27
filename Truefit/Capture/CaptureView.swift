import SwiftUI
import RealityKit

/// Full-screen guided scan. Calls `onFinished` with the reconstructed USDZ.
struct CaptureView: View {
    let onFinished: (URL) -> Void
    @StateObject private var model = CaptureModel()
    @Environment(\.dismiss) private var dismiss

    init(onFinished: @escaping (URL) -> Void) { self.onFinished = onFinished }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .capturing:
                capturing
            case .reconstructing(let fraction):
                ReconstructionProgress(fraction: fraction)
            case .finished(let url):
                ProgressView("Opening your scan…")
                    .tint(.white).foregroundStyle(.white)
                    .task { onFinished(url) }
            case .failed(let message):
                failure(message)
            }
        }
        .onAppear { model.start() }
        .statusBarHidden()
    }

    @ViewBuilder private var capturing: some View {
        if let session = model.session {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
        }
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { model.cancel(); dismiss() }
                    .buttonStyle(.bordered).tint(.white)
                Spacer()
            }
            .padding()
            Spacer()
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(model.stepTitle).font(.headline)
                    if !model.stepDetail.isEmpty {
                        Text(model.stepDetail).font(.subheadline).multilineTextAlignment(.center).opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    if model.isDetecting {
                        Button("Reset box") { model.resetBox() }
                            .buttonStyle(.bordered).tint(.white)
                    }
                    if model.canContinue {
                        Button(model.isDetecting ? "Start capturing" : "Continue") { model.continueTapped() }
                            .buttonStyle(.borderedProminent)
                    }
                    if model.canFinish {
                        Menu {
                            Button { model.flipTapped() } label: {
                                Label("Flip it over and scan the bottom", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button { model.anotherLapTapped() } label: {
                                Label("Another lap, same position", systemImage: "arrow.clockwise.circle")
                            }
                        } label: {
                            Label("Next lap", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered).tint(.white)
                        Button("Finish scan") { model.finishTapped() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                if model.canFinish {
                    Text(model.lap < 3
                         ? "Next: another lap from higher up. Only flip parts with visible texture; plain dark parts merge better left in place, and step 3 fills the bottom."
                         : "Finish when you've covered low, middle and high angles.")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.45))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            Button("Close") { model.cancel(); dismiss() }.buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

struct ReconstructionProgress: View {
    let fraction: Double
    var body: some View {
        VStack(spacing: 18) {
            Text("Building your model").font(.title2.weight(.semibold))
            ProgressView(value: fraction)
                .tint(.white)
                .frame(maxWidth: 260)
            Text("\(Int(fraction * 100))% · Keep the app open. This takes a few minutes on the phone.")
                .font(.footnote).multilineTextAlignment(.center).opacity(0.8)
                .frame(maxWidth: 280)
        }
        .foregroundStyle(.white)
    }
}

/// Short checklist shown before the camera opens.
struct ScanTipsView: View {
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tip("light.max", "Even light", "Bright, diffuse light with no harsh shadows or glare.")
                    tip("newspaper", "Textured surface", "Set it on something with a pattern, like newspaper, with room to walk around.")
                    tip("figure.walk.circle", "Three laps", "Circle slowly at a low angle, then middle, then from above.")
                    tip("ruler", "Measure one thing", "Caliper one feature now so you can calibrate the scan later.")
                } footer: {
                    Text("Truefit builds the model from photos, so it needs surface detail to lock onto. Plain black, shiny or see-through parts come out lumpy. Dust them with dry shampoo, foot powder or 3D scanning spray, or add a few strips of masking tape.")
                }
            }
            .navigationTitle("Before you scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss(); onStart()
                } label: {
                    Text("Open camera").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }

    private func tip(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }
}
