import Foundation
import StoreKit

/// Truefit Pro subscription state, using StoreKit 2.
@MainActor
final class Store: ObservableObject {
    /// Must match the product IDs created in App Store Connect
    /// (and in Truefit.storekit for local testing).
    static let monthlyID = "truefit.pro.monthly"
    static let yearlyID = "truefit.pro.yearly"
    static let productIDs = [monthlyID, yearlyID]

    /// Free users get this many STL exports before Pro is needed.
    static let freeExports = 3

    @Published private(set) var isPro = false
    @Published private(set) var exportsUsed: Int

    private var updatesTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        exportsUsed = defaults.integer(forKey: "exportsUsed")
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    var freeExportsLeft: Int { max(0, Self.freeExports - exportsUsed) }
    var canExport: Bool { isPro || freeExportsLeft > 0 }

    func recordExport() {
        guard !isPro else { return }
        exportsUsed += 1
        defaults.set(exportsUsed, forKey: "exportsUsed")
    }

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil {
                active = true
            }
        }
        #if SIDELOAD
        isPro = true   // test builds installed outside the App Store have Pro unlocked
        #else
        isPro = active
        #endif
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}

/// Features that need Pro.
enum ProFeature: String, Identifiable {
    case rebuild, calibrate, export
    var id: String { rawValue }

    var reason: String {
        switch self {
        case .rebuild: return "Rebuilding a scan as an exact, editable shape is part of Truefit Pro."
        case .calibrate: return "Calibrating a scan against your caliper measurement is part of Truefit Pro."
        case .export: return "You've used your \(Store.freeExports) free exports. Truefit Pro includes unlimited exports."
        }
    }
}
