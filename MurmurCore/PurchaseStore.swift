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
//  Phase 1 (StoreKit 2): products fetched via `Product.products(for:)`
//  on init; ownership tracked via `Transaction.currentEntitlements`
//  (initial state) and a long-running listener on `Transaction.updates`
//  (purchases / restores / refunds). Unverified transactions are
//  refused — we only grant entitlements off cryptographically verified
//  transactions per Apple's sample-code pattern.
//
//  Surface is `public` so the paid framework targets (MurmurAnnotation,
//  MurmurSilver, MurmurInference — pulling MurmurCore as an SPM dep)
//  can call `PurchaseStore.shared.owns(...)` from their own bundles.
//

import Foundation
import Observation
import StoreKit

/// Process-wide entitlement state. `@MainActor` because the UI
/// surfaces that consume it (ProducersPanel, future locked-feature
/// gates) all run on the main actor.
@MainActor
@Observable
public final class PurchaseStore {

    /// Shared instance the app uses at runtime. Tests should construct
    /// a fresh `PurchaseStore()` to keep parallel runs isolated.
    public static let shared = PurchaseStore()

    /// App Store Connect product identifiers. Raw values match what
    /// will be registered in App Store Connect when Phase 1 of the
    /// IAP roadmap submits — `com.kevinlong.murmur.<feature>`.
    public enum ProductID: String, CaseIterable, Sendable {
        case annotationAuthoring = "com.kevinlong.murmur.annotationauthoring"
        case silverMetrics       = "com.kevinlong.murmur.silvermetrics"
        case vtDetection         = "com.kevinlong.murmur.vtdetection"
    }

    /// Errors surfaced from `purchase(_:)`. UI converts these into
    /// localized strings; nothing should escape to the user as a raw
    /// StoreKit error.
    public enum PurchaseError: Error, Sendable {
        /// Apple returned a transaction we couldn't cryptographically
        /// verify. Treat as if no purchase happened — never grant.
        case unverifiedTransaction
        /// `Product.products(for:)` hasn't returned this product yet,
        /// or App Store Connect doesn't know about it. Surface as a
        /// "try again" affordance.
        case productNotLoaded
        /// Underlying StoreKit error from the purchase flow.
        case storeKit(any Error)
    }

    /// Loaded products keyed by `ProductID`. Empty until
    /// `loadProducts()` resolves; stays empty if App Store Connect
    /// hasn't registered the IDs yet.
    public private(set) var products: [ProductID: Product] = [:]

    /// Set of products the user currently owns. Updated whenever a
    /// StoreKit transaction resolves (purchase, restore, refund).
    public private(set) var ownedProductIDs: Set<ProductID> = []

    public init() {
        // Listen for transactions forever. Must be started before any
        // purchase begins so we don't miss the resolution of in-flight
        // transactions (e.g. interrupted purchases that resolve on the
        // next app launch). `[weak self]` so the orphaned Task becomes
        // a no-op when test-constructed instances deallocate — we
        // can't cancel a MainActor-isolated stored task from a
        // nonisolated deinit under Swift 6, and the singleton never
        // deallocates anyway.
        Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(transactionResult: update)
            }
        }
        // Fetch products + current entitlements asynchronously after
        // init. Both are fire-and-forget; UI binds to `products` and
        // `ownedProductIDs` and re-renders when they populate.
        Task { await self.loadProducts() }
        Task { await self.refreshCurrentEntitlements() }
    }

    /// True when the user currently owns the IAP for `id`.
    public func owns(_ id: ProductID) -> Bool {
        ownedProductIDs.contains(id)
    }

    // MARK: - Purchase + Restore

    /// Initiate a purchase for `id`. Returns true on a completed
    /// verified purchase, false on user-cancel or pending result.
    /// Throws on unverified transactions or StoreKit errors.
    @discardableResult
    public func purchase(_ id: ProductID) async throws -> Bool {
        guard let product = products[id] else {
            throw PurchaseError.productNotLoaded
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                applyEntitlement(
                    productIDString: transaction.productID,
                    revocationDate: transaction.revocationDate
                )
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch let error as PurchaseError {
            throw error
        } catch {
            throw PurchaseError.storeKit(error)
        }
    }

    /// Restore previous purchases. Required surface per Apple Review
    /// Guideline 3.1.1. `AppStore.sync()` forces Apple to re-issue
    /// current entitlements; resulting transactions arrive via
    /// `Transaction.updates` and we also re-walk
    /// `currentEntitlements` for completeness.
    public func restore() async {
        try? await AppStore.sync()
        await refreshCurrentEntitlements()
    }

    // MARK: - Loading

    private func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ProductID.allCases.map(\.rawValue))
            var byID: [ProductID: Product] = [:]
            for product in fetched {
                if let id = ProductID(rawValue: product.id) {
                    byID[id] = product
                }
            }
            self.products = byID
        } catch {
            // Non-fatal: the products surface stays empty until the
            // next successful load. Purchase attempts throw
            // `productNotLoaded` so the caller can surface a retry.
        }
    }

    private func refreshCurrentEntitlements() async {
        var owned: Set<ProductID> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.revocationDate == nil,
               let id = ProductID(rawValue: transaction.productID) {
                owned.insert(id)
            }
        }
        self.ownedProductIDs = owned
    }

    // MARK: - Transaction processing

    private func process(transactionResult: VerificationResult<Transaction>) async {
        do {
            let transaction = try checkVerified(transactionResult)
            await transaction.finish()
            applyEntitlement(
                productIDString: transaction.productID,
                revocationDate: transaction.revocationDate
            )
        } catch {
            // Unverified transactions are silently ignored — never
            // grant an entitlement off a transaction we can't prove
            // came from Apple.
        }
    }

    private func applyEntitlement(productIDString: String, revocationDate: Date?) {
        guard let id = ProductID(rawValue: productIDString) else { return }
        if revocationDate == nil {
            ownedProductIDs.insert(id)
        } else {
            ownedProductIDs.remove(id)
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseError.unverifiedTransaction
        case .verified(let value):
            return value
        }
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
    public nonisolated static func requiredProduct(forProducerID producerID: String) -> ProductID? {
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
    public func canRun(producerID: String) -> Bool {
        guard let required = Self.requiredProduct(forProducerID: producerID) else {
            return true
        }
        return owns(required)
    }

    // MARK: - Test / debug seam

    #if DEBUG
    /// Test-only setter: directly populate the owned-products set.
    /// Bypasses StoreKit entirely so unit tests can exercise
    /// downstream gating logic without provisioning real
    /// transactions. The production code path NEVER calls this.
    public func _setOwnedForTesting(_ ids: Set<ProductID>) {
        ownedProductIDs = ids
    }
    #endif
}
