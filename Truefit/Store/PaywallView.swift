import SwiftUI
import StoreKit

struct PaywallView: View {
    let feature: ProFeature?
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    init(feature: ProFeature?) { self.feature = feature }

    var body: some View {
        SubscriptionStoreView(productIDs: Store.productIDs) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "ruler")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Truefit Pro")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                if let feature {
                    Text(feature.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    benefit("cube.transparent", "Rebuild scans as clean shapes", "Exact diameters, heights, holes and chamfers you can edit.")
                    benefit("ruler", "Caliper calibration", "Tap two points, enter the real distance, and the whole part rescales.")
                    benefit("square.and.arrow.up", "Unlimited STL exports", "Print-ready files in millimeters for any slicer.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: Links.terms, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Links.privacy, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(_)) = result {
                await store.refresh()
                dismiss()
            }
        }
        .onChange(of: store.isPro) { _, pro in if pro { dismiss() } }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

enum Links {
    // Replace with your hosted pages before submitting (see README).
    static let privacy = URL(string: "https://YOUR-GITHUB-USERNAME.github.io/truefit/privacy.html")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
