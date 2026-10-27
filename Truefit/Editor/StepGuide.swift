import SwiftUI

/// What each editor step does, shown as a dismissible card at the top of the
/// step (always on samples, once per step otherwise) and in Help.
struct StepGuide: Identifiable {
    let tab: EditorModel.Tab
    let title: String
    let icon: String
    let summary: String
    let points: [String]
    var id: Int { tab.rawValue }

    static let all: [StepGuide] = [
        .init(tab: .clean, title: "1 · Clean", icon: "sparkles",
              summary: "Tidy the raw scan and stand it the right way up.",
              points: ["Lay flat puts the widest side on the bed.",
                       "Remove stray pieces drops bits of table caught in the scan.",
                       "Smooth surface removes fine speckle."]),
        .init(tab: .size, title: "2 · Size", icon: "ruler",
              summary: "Make it the exact size you need.",
              points: ["Tap any dimension on the model, then type a value or drag its handle.",
                       "Stretch at a cut adds length in one spot without fattening the rest.",
                       "Calibrate: tap two points and enter your caliper reading."]),
        .init(tab: .rebuild, title: "3 · Complete", icon: "cube.transparent",
              summary: "Fill in the sides the camera never saw, so the part prints as one solid piece.",
              points: ["Mirror copies the visible side across a plane. Revolve spins a round profile.",
                       "Close the bottom seals the side that sat on the table.",
                       "Smooth shape evens out lumps. Exact shape swaps in a clean part or a threaded bolt."]),
        .init(tab: .export, title: "4 · Export", icon: "square.and.arrow.up",
              summary: "Save a print-ready STL in millimeters.",
              points: ["Completed is the filled-in solid, usually what you want to print.",
                       "Check it fits your bed and see the filament estimate.",
                       "Share to Files, AirDrop or Bambu Handy."]),
    ]

    static func guide(for tab: EditorModel.Tab) -> StepGuide { all[tab.rawValue] }
}

struct StepGuideCard: View {
    let guide: StepGuide
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(guide.title, systemImage: guide.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Got it", action: onDismiss)
                    .font(.subheadline.weight(.semibold))
            }
            Text(guide.summary).font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(guide.points, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(p).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

/// Remembers which step guides have been dismissed.
enum GuideMemory {
    static func key(_ tab: EditorModel.Tab) -> String { "guideSeen.\(tab.rawValue)" }

    static func seen(_ tab: EditorModel.Tab) -> Bool {
        UserDefaults.standard.bool(forKey: key(tab))
    }

    static func markSeen(_ tab: EditorModel.Tab) {
        UserDefaults.standard.set(true, forKey: key(tab))
    }

    static func resetAll() {
        for t in EditorModel.Tab.allCases { UserDefaults.standard.removeObject(forKey: key(t)) }
    }
}

// MARK: - Welcome tour

struct OnboardingView: View {
    let onTrySample: () -> Void
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("camera.viewfinder", "Scan it",
         "Circle an object with your iPhone and Truefit builds a 3D model from the photos. You can also open scans from Polycam, Scaniverse and other apps."),
        ("ruler", "Size it",
         "Tap any dimension on the model to type an exact value or drag it. Calibrate against a caliper reading so the part fits the first time."),
        ("cube.transparent", "Complete it",
         "Fill in the sides the camera couldn't see by mirroring, revolving or patching, so the part prints as one solid piece."),
        ("printer", "Print it",
         "Export a watertight STL in millimeters for Bambu Studio or any slicer, with a filament estimate and a bed-fit check."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: pages[i].icon)
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(height: 90)
                        Text(pages[i].title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(pages[i].text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                if page < pages.count - 1 {
                    Button { withAnimation { page += 1 } } label: {
                        Text("Next").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Skip", action: onFinish)
                } else {
                    Button(action: onTrySample) {
                        Text("Try the sample bolt").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Start scanning", action: onFinish)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
