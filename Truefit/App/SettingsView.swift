import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @State private var guidesMessage: String?
    @State private var showManage = false
    @State private var showPaywall = false
    @State private var restoring = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    proStatus
                    if store.isPro && !store.isTestBuild {
                        Button("Manage subscription") { showManage = true }
                    } else if !store.isPro {
                        Button("See Pro plans") { showPaywall = true }
                    }
                    Button {
                        Task {
                            restoring = true
                            await store.restore()
                            restoring = false
                            restoreMessage = store.isPro ? "Truefit Pro is active." : "No active Truefit Pro subscription was found for this Apple ID."
                        }
                    } label: {
                        HStack {
                            Text("Restore purchases")
                            if restoring { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(restoring)
                } header: {
                    Text("Truefit Pro")
                } footer: {
                    Text("Subscriptions are billed through your Apple ID. You can change or cancel anytime in Manage subscription, or in iPhone Settings → your name → Subscriptions.")
                }

                Section("Help") {
                    NavigationLink("How Truefit works") { HelpView() }
                    Button("Show the welcome tour again") { hasOnboarded = false; dismiss() }
                    Button("Show step guides again") {
                        GuideMemory.resetAll()
                        guidesMessage = "The step guides will show again the next time you open each step."
                    }
                    if let guidesMessage {
                        Text(guidesMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    Link("Privacy policy", destination: Links.privacy)
                    Link("Terms of use", destination: Links.terms)
                    Link("Report a problem or request a refund", destination: Links.refunds)
                    Link("Contact support", destination: Links.support)
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $showManage)
            .sheet(isPresented: $showPaywall) { PaywallView(feature: nil) }
            .alert("Restore purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(restoreMessage ?? "") }
        }
    }

    @ViewBuilder private var proStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: store.isPro ? "checkmark.seal.fill" : "seal")
                .font(.title2)
                .foregroundStyle(store.isPro ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.isPro ? "Pro is active" : "Free plan").font(.headline)
                Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusDetail: String {
        if store.isTestBuild { return "Test build: every Pro feature is unlocked." }
        if store.isPro {
            let plan = store.activePlanName ?? "Subscription"
            if let date = store.renewalDate {
                return "\(plan) · renews \(date.formatted(date: .abbreviated, time: .omitted))"
            }
            return plan
        }
        return "\(store.freeExportsLeft) of \(Store.freeExports) free exports left"
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("The four steps") {
                ForEach(StepGuide.all) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(g.title, systemImage: g.icon).font(.headline)
                        Text(g.summary).font(.subheadline)
                        ForEach(g.points, id: \.self) { p in
                            Text("• " + p).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Scanning") {
                faq("What scans best?", "Matte objects with some surface pattern, in bright even light, on a textured surface like newspaper. Do three slow laps: low, middle and from above.")
                faq("Why is my scan lumpy?", "Truefit builds the model from photos, so it needs surface detail to lock onto. Plain black, shiny or see-through parts come out wavy. Dust them with dry shampoo, foot powder or scanning spray, or add strips of masking tape. Smooth shape in step 3 evens out what's left.")
                faq("Should I flip the object?", "Only if it has visible texture. Plain parts line up poorly after a flip; leave them in place and let Close the bottom seal the underside.")
                faq("The size is 10× or 1000× off", "Change Scan units in step 1. Apps export in meters, millimeters or inches, and Truefit guesses from the size.")
            }
            Section("Printing") {
                faq("How accurate is a phone scan?", "Usually within a millimeter or two. For parts that must fit, measure one feature with calipers and use Calibrate in step 2.")
                faq("Printed threads won't screw in", "Choose a looser Thread fit in the Exact shape section, or print slower with finer layers. Threads under M5 rarely print well.")
                faq("Which file should I export?", "Completed is the filled-in, printable solid. Scan is the cleaned scan exactly as captured. Exact shape and Nut appear when you use those tools.")
            }
        }
        .navigationTitle("How Truefit works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func faq(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q).font(.subheadline.weight(.semibold))
            Text(a).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
