//
//  SettingsView.swift
//  Murmur
//
//  Application-wide preferences, surfaced via the standard macOS Settings
//  window (App menu → Settings…, ⌘,). One TabView per preference category
//  so the same scaffolding extends cleanly when future preferences land.
//

import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            InteractionSettingsTab()
                .tabItem { Label("Interaction", systemImage: "hand.draw") }
            PurchasesSettingsTab()
                .tabItem { Label("Purchases", systemImage: "creditcard") }
        }
        // X55 §2: size for the TALLEST state — the unowned Purchases tab, where
        // Buy buttons make the rows taller than the Owned badge and the closing
        // captions must stay fully visible. Sized at 320 it clipped the last
        // caption line mid-sentence, and the only person who ever sees that
        // screen is a first-time buyer reading how Restore works.
        .frame(width: 460, height: 440)
    }
}

/// In-app purchase state + the Apple-mandated Restore Purchases
/// surface. Lists the three research-extension IAPs with their
/// current ownership status; the Restore button re-syncs Apple's
/// view of the user's entitlements via `AppStore.sync()`.
private struct PurchasesSettingsTab: View {
    @State private var store = PurchaseStore.shared
    @State private var isRestoring = false
    /// The product whose purchase is currently in flight, if any — drives the
    /// per-row spinner and disables the other buy buttons meanwhile.
    @State private var purchasing: PurchaseStore.ProductID?
    /// Last purchase failure, surfaced in the section footer.
    @State private var purchaseError: String?

    var body: some View {
        Form {
            Section {
                // X55 §4: order by tier (ECG Metrics first), not alphabetically.
                ForEach(PurchaseStore.merchandisingOrder, id: \.self) { id in
                    HStack {
                        Text(displayName(for: id))
                        Spacer()
                        productControl(for: id)
                    }
                }
            } header: {
                Text("Research extensions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let purchaseError {
                        Text(purchaseError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("purchase-error")
                    }
                    Text("Purchases are tied to your Apple ID and restore automatically on new devices.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                Button {
                    Task {
                        isRestoring = true
                        await store.restore()
                        isRestoring = false
                    }
                } label: {
                    if isRestoring {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Restoring…")
                        }
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(isRestoring)
            } footer: {
                Text("Re-sync your purchases from the App Store. Use this on a new device or after reinstalling.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            #if DEBUG
            // Developer-only local unlock. The real Buy surface above needs a
            // StoreKit configuration to return products; this toggle lets a
            // plain debug build (no StoreKit config loaded) exercise paid
            // features without a purchase. Compiled out of Release entirely.
            Section {
                ForEach(PurchaseStore.ProductID.allCases, id: \.self) { id in
                    Toggle(displayName(for: id), isOn: Binding(
                        get: { store.owns(id) },
                        set: { grant in
                            let updated = grant
                                ? store.ownedProductIDs.union([id])
                                : store.ownedProductIDs.subtracting([id])
                            store._setOwnedForTesting(updated)
                        }
                    ))
                }
            } header: {
                Text("Developer — grant entitlements (DEBUG)")
            } footer: {
                Text("Debug builds only. Flips local ownership so paid features can be exercised without a StoreKit purchase. Grant \"VT/VF Detection (RUO)\", open a recording, then use the \"Scan for VT/VF candidates\" toolbar button.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            #endif
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Trailing control for a product row: Owned badge, an in-flight spinner,
    /// a Buy button with the StoreKit price, or an Unavailable state when the
    /// product didn't load. A row never renders inert with no explanation
    /// (App Review Guideline 3.1.1) — "not purchasable right now" always says
    /// why.
    @ViewBuilder
    private func productControl(for id: PurchaseStore.ProductID) -> some View {
        let state = PurchaseStore.rowState(
            owns: store.owns(id),
            purchasing: purchasing == id,
            price: store.displayPrice(for: id),
            loadState: store.productsLoadState
        )
        switch state {
        case .owned:
            Label("Owned", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("purchase-owned-\(id.rawValue)")
        case .purchasing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Purchasing…")
            }
            .accessibilityIdentifier("purchase-pending-\(id.rawValue)")
        case .buy(let price):
            Button("Buy \(price)") { buy(id) }
                .buttonStyle(.borderedProminent)
                .disabled(purchasing != nil)
                .accessibilityIdentifier("purchase-buy-\(id.rawValue)")
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("purchase-checking-\(id.rawValue)")
        case .unreachable:
            // X55 §3: a TRANSIENT failure — the store returned nothing. Say the
            // honest thing and offer a retry rather than a dead-end word.
            HStack(spacing: 6) {
                Text("Couldn't reach the App Store")
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await store.reloadProducts() } }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("purchase-retry-\(id.rawValue)")
            }
            .accessibilityIdentifier("purchase-unreachable-\(id.rawValue)")
        case .notOfferedHere:
            // X55 §3: loaded successfully, but this storefront doesn't carry it —
            // nothing the user can do, so no retry. Distinct from unreachable.
            Text("Not available in your region")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("purchase-unavailable-\(id.rawValue)")
        }
    }

    private func buy(_ id: PurchaseStore.ProductID) {
        purchaseError = nil
        purchasing = id
        Task {
            defer { purchasing = nil }
            do {
                _ = try await store.purchase(id)
            } catch {
                purchaseError = "\(displayName(for: id)): \(purchaseFailureMessage(error))"
            }
        }
    }

    private func purchaseFailureMessage(_ error: Error) -> String {
        switch error {
        case PurchaseStore.PurchaseError.productNotLoaded:
            return "product isn't available from the App Store right now."
        case PurchaseStore.PurchaseError.unverifiedTransaction:
            return "the purchase couldn't be verified and was not applied."
        case PurchaseStore.PurchaseError.storeKit(let underlying):
            return underlying.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    private func displayName(for id: PurchaseStore.ProductID) -> String {
        switch id {
        case .annotationAuthoring: return "Annotation Authoring"
        case .ecgMetrics:          return "ECG Metrics"
        case .vtDetection:         return "VT/VF Detection (RUO)"
        }
    }
}

/// Pointer / gesture preferences. Currently just haptic feedback — more
/// settings (cursor style, scroll inertia, etc.) can live here too.
private struct InteractionSettingsTab: View {
    @AppStorage(HapticPreferences.modeKey)
    private var hapticMode: HapticMode = HapticPreferences.defaultMode

    var body: some View {
        Form {
            Section {
                Picker("Haptic feedback while panning", selection: $hapticMode) {
                    ForEach(HapticMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(hapticMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Trackpad")
            } footer: {
                Text("Force Touch trackpad required. Magic Mouse and external pointers won't tick.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
