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
        .frame(width: 460, height: 320)
    }
}

/// In-app purchase state + the Apple-mandated Restore Purchases
/// surface. Lists the three research-extension IAPs with their
/// current ownership status; the Restore button re-syncs Apple's
/// view of the user's entitlements via `AppStore.sync()`.
private struct PurchasesSettingsTab: View {
    @State private var store = PurchaseStore.shared
    @State private var isRestoring = false

    var body: some View {
        Form {
            Section {
                ForEach(PurchaseStore.ProductID.allCases, id: \.self) { id in
                    HStack {
                        Text(displayName(for: id))
                        Spacer()
                        if store.owns(id) {
                            Label("Owned", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text("Not purchased")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Research extensions")
            } footer: {
                Text("Purchases are tied to your Apple ID and restore automatically on new devices.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        }
        .formStyle(.grouped)
        .padding()
    }

    private func displayName(for id: PurchaseStore.ProductID) -> String {
        switch id {
        case .annotationAuthoring: return "Annotation Authoring"
        case .silverMetrics:       return "Silver Layer Metrics"
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
