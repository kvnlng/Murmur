//
//  PurchaseStore.swift
//  MurmurCore
//
//  Entitlement state for the three planned in-app purchases that gate
//  the paid extension frameworks (Annotation Authoring, Silver Layer
//  Metrics, VT Detection). The free viewer + the synthetic test
//  producer never need to consult this store — `canRun(producerID:)`
//  returns true for free producers by design.
//
//  Scope today (Phase 0): the surface + the producer-to-product
//  mapping. The actual StoreKit 2 wiring (Product.products(for:),
//  Transaction.updates, AppStore.sync()) lands in Phase 1 alongside
//  the App Store Connect product registrations. Until then,
//  `ownedProductIDs` stays empty in RELEASE and tests pin the mapping.
//
//  Public-API audit deferred along with the rest of MurmurCore's
//  internal types — see FindingProducer.swift TODO. Once the paid
//  framework targets land, this becomes `public` so they can call
//  `PurchaseStore.shared.owns(...)` from their own bundles.
//

import Foundation
import Observation

/// Process-wide entitlement state. `@MainActor` because the UI
/// surfaces that consume it (ProducersPanel, future locked-feature
/// gates) all run on the main actor.
@MainActor
@Observable
final class PurchaseStore {

    /// Shared instance the app uses at runtime. Tests should construct
    /// a fresh `PurchaseStore()` to keep parallel runs isolated.
    static let shared = PurchaseStore()

    /// App Store Connect product identifiers. Raw values match what
    /// will be registered in App Store Connect when Phase 1 of the
    /// IAP roadmap submits — `com.kevinlong.murmur.<feature>`.
    enum ProductID: String, CaseIterable, Sendable {
        case annotationAuthoring = "com.kevinlong.murmur.annotationauthoring"
        case silverMetrics       = "com.kevinlong.murmur.silvermetrics"
        case vtDetection         = "com.kevinlong.murmur.vtdetection"
    }

    /// Set of products the user currently owns. Updated when StoreKit
    /// transactions resolve. Today this stays empty (Phase 0 stub);
    /// Phase 1 wires Transaction.currentEntitlements + Transaction.updates
    /// into the setter.
    private(set) var ownedProductIDs: Set<ProductID> = []

    init() {}

    /// True when the user currently owns the IAP for `id`.
    func owns(_ id: ProductID) -> Bool {
        ownedProductIDs.contains(id)
    }

    // MARK: - Producer gating

    /// Maps a `FindingProducer.id` to the IAP that gates it. Returns
    /// nil for free producers (the synthetic baseline, any future
    /// free producers). Centralising the mapping here lets the paid
    /// frameworks register their producers without each having to
    /// know its own product identifier.
    ///
    /// `nonisolated` because the mapping is a pure static lookup with
    /// no main-actor-isolated state, so callers (including background
    /// tasks and tests) can use it without a hop.
    nonisolated static func requiredProduct(forProducerID producerID: String) -> ProductID? {
        switch producerID {
        case "murmur.annotation":  return .annotationAuthoring
        case "murmur.silver":      return .silverMetrics
        case "murmur.vtdetect":    return .vtDetection
        default:                   return nil   // free / baseline producer
        }
    }

    /// True when this producer can be run — either it's free (no
    /// product required) or the user owns the gating IAP. UI surfaces
    /// that list producers (the Producers panel today, future surfaces
    /// later) filter through this so locked producers don't appear
    /// until the corresponding IAP is purchased.
    func canRun(producerID: String) -> Bool {
        guard let required = Self.requiredProduct(forProducerID: producerID) else {
            return true
        }
        return owns(required)
    }

    // MARK: - Test / debug seam

    #if DEBUG
    /// Test-only setter: directly populate the owned-products set.
    /// Phase 1 will replace this with the real Transaction.updates
    /// listener; today it lets unit tests exercise `canRun` against
    /// arbitrary entitlement states.
    func _setOwnedForTesting(_ ids: Set<ProductID>) {
        ownedProductIDs = ids
    }
    #endif
}
