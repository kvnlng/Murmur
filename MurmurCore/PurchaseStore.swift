//
//  PurchaseStore.swift
//  MurmurCore
//
//  Entitlement state for the single all-inclusive in-app purchase that
//  gates the paid extension frameworks (annotation authoring, ECG
//  metrics, arrhythmia candidate detection) — they unlock together.
//  The free viewer + the synthetic test producer never need to consult
//  this store — `canRun(producerID:)` returns true for free producers
//  by design. (Single-IAP pivot 2026-08-01; the former per-module
//  product IDs are retired — nothing shipped under them.)
//
//  Phase 1 (StoreKit 2): products fetched via `Product.products(for:)`
//  on init; ownership tracked via `Transaction.currentEntitlements`
//  (initial state) and a long-running listener on `Transaction.updates`
//  (purchases / restores / refunds). Unverified transactions are
//  refused — we only grant entitlements off cryptographically verified
//  transactions per Apple's sample-code pattern.
//
//  Surface is `public` so the paid framework targets (MurmurAnnotation,
//  MurmurMetrics, MurmurInference — pulling MurmurCore as an SPM dep)
//  can call `PurchaseStore.shared.owns(...)` from their own bundles.
//

import Foundation
import Observation
import OSLog
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

    /// Diagnostic log for the StoreKit round-trip.
    ///
    /// Exists because a shipped build that can't sell anything is otherwise
    /// mute: `Product.products(for:)` returning an empty array and returning
    /// the product look identical from outside, the UI deliberately refuses to
    /// guess a cause, and a TestFlight tester has no debugger. Every message
    /// here is `.notice` or `.error` — the two levels the unified log persists
    /// to disk by default — so the answer survives until someone runs:
    ///
    ///     log show --last 1h --predicate 'subsystem == "com.kevinlong.murmur"'
    ///
    /// Product identifiers are interpolated `.public` on purpose. Logger
    /// redacts string interpolations by default, which would render every
    /// line as `<private>` and defeat the point. These are compile-time
    /// constants from `ProductID` — no user or purchase data is logged, and
    /// nothing here touches a transaction's contents.
    private static let log = Logger(
        subsystem: "com.kevinlong.murmur",
        category: "purchases"
    )

    /// App Store Connect product identifiers. One all-inclusive product
    /// now (single-IAP pivot): it unlocks every paid feature together.
    /// The former per-module IDs (`…annotationauthoring` / `…metrics` /
    /// `…vtdetection`) are retired — nothing shipped under them, so no
    /// purchaser migration is owed. Kept as an enum (not a bare constant)
    /// so the generic ownership / row-state / gating API is unchanged.
    public enum ProductID: String, CaseIterable, Sendable {
        case studio = "com.kevinlong.murmur.studio"
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

    /// Outcome of the most recent product load — lets the purchase UI tell a
    /// TRANSIENT failure (offer a retry) apart from a product the App Store
    /// isn't offering (a reload won't help — nothing the user can do). X55 §3 /
    /// K19: two non-resolving conditions, not one dead-end "Unavailable".
    public enum ProductsLoadState: Sendable, Equatable {
        case idle, loading, loaded, failed
    }
    public private(set) var productsLoadState: ProductsLoadState = .idle

    /// Presentation order for the purchase surface. One product now, so this is
    /// a single entry; kept as an array so `SettingsView` iterates uniformly.
    /// (The former by-tier ordering of X55 §4 is moot under the single IAP.)
    public static let merchandisingOrder: [ProductID] = [.studio]

    public init() {
        #if DEBUG
        // Free-viewer XCUI hermeticity: `--ui-test-no-entitlements` makes this
        // process ignore any ambient StoreKit-test transactions persisted on
        // the dev machine, so the "no IAP owned" assertions don't depend on
        // local Manage-Transactions state. Start no listener and skip the
        // entitlement walk — ownedProductIDs stays empty for the process.
        if UITestSupport.forceNoEntitlements { return }
        // X52 §5: grant Studio for the QTc-lane wire-up test and skip the
        // entitlement walk, so a StoreKit-test machine (which has no studio
        // transaction) can't clobber the grant on the async refresh.
        if UITestSupport.injectQTcLaneValue != nil {
            ownedProductIDs = [.studio]
            return
        }
        // X76: same pattern for the LF/HF-lane wire-up test.
        if UITestSupport.injectLFHFLane {
            ownedProductIDs = [.studio]
            return
        }
        // X76: real-compute counterpart — grant without injecting anything,
        // so a staged record exercises the actual paid computations.
        if UITestSupport.grantStudio {
            ownedProductIDs = [.studio]
            return
        }
        #endif
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

    /// True when the user owns the single all-inclusive Murmur Studio purchase —
    /// the one entitlement every paid feature checks. There is no per-module
    /// ownership under the single-IAP model; feature call sites read this.
    public var hasStudio: Bool { ownedProductIDs.contains(.studio) }

    /// User-facing name for `id`. Prefers StoreKit's own `displayName`, which
    /// comes from App Store Connect and is localized by Apple, and falls back
    /// to a built-in constant when the product hasn't loaded — offline, not yet
    /// configured, or the App Store isn't offering it. That last case is not
    /// hypothetical, so the fallback is a shipping surface, not a nicety.
    ///
    /// The fallback is the product's DISPLAY name, never its App Store Connect
    /// *reference* name. Settings used to hard-code "Murmur Studio
    /// (all-inclusive)" — the reference name, which exists for ASC bookkeeping
    /// and should never reach a user. It also disagreed with the buy screen, so
    /// one purchase appeared under two names.
    public func displayName(for id: ProductID) -> String {
        products[id]?.displayName ?? Self.fallbackDisplayName(for: id)
    }

    /// Name shown before StoreKit resolves the product. `nonisolated` so tests
    /// and non-main-actor callers can reach it without a hop.
    public nonisolated static func fallbackDisplayName(for id: ProductID) -> String {
        switch id {
        case .studio: return "Murmur Studio"
        }
    }

    /// Localised price string for `id` (e.g. "$9.99"), or nil when the
    /// product hasn't loaded from the App Store yet (offline, not configured
    /// in App Store Connect, or still fetching). Keeps StoreKit's `Product`
    /// type out of the view layer — the Buy UI reads prices through this.
    public func displayPrice(for id: ProductID) -> String? {
        products[id]?.displayPrice
    }

    // MARK: - Purchase + Restore

    /// Initiate a purchase for `id`. Returns true on a completed
    /// verified purchase, false on user-cancel or pending result.
    /// Throws on unverified transactions or StoreKit errors.
    @discardableResult
    public func purchase(_ id: ProductID) async throws -> Bool {
        guard let product = products[id] else {
            Self.log.error("Purchase refused — \(id.rawValue, privacy: .public) never loaded from the App Store")
            throw PurchaseError.productNotLoaded
        }
        Self.log.notice("Purchase starting — \(id.rawValue, privacy: .public)")
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
                Self.log.notice("Purchase SUCCEEDED — \(id.rawValue, privacy: .public)")
                return true
            case .userCancelled:
                Self.log.notice("Purchase cancelled by user — \(id.rawValue, privacy: .public)")
                return false
            case .pending:
                // Ask-to-Buy / SCA. Resolves later via `Transaction.updates`.
                Self.log.notice("Purchase pending approval — \(id.rawValue, privacy: .public)")
                return false
            @unknown default:
                Self.log.error("Purchase returned an unknown result — \(id.rawValue, privacy: .public)")
                return false
            }
        } catch let error as PurchaseError {
            throw error
        } catch {
            Self.log.error("Purchase FAILED — \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            throw PurchaseError.storeKit(error)
        }
    }

    /// Restore previous purchases. Required surface per Apple Review
    /// Guideline 3.1.1. `AppStore.sync()` forces Apple to re-issue
    /// current entitlements; resulting transactions arrive via
    /// `Transaction.updates` and we also re-walk
    /// `currentEntitlements` for completeness.
    public func restore() async {
        Self.log.notice("Restore requested — calling AppStore.sync()")
        do {
            try await AppStore.sync()
        } catch {
            // Still fall through to the entitlement walk: a failed sync does
            // not mean we can't see already-issued entitlements.
            Self.log.error("AppStore.sync() failed — \(String(describing: error), privacy: .public)")
        }
        await refreshCurrentEntitlements()
    }

    // MARK: - Loading

    /// Re-run the product load — the retry action behind a transient-failure
    /// row (X55 §3). Public so the purchase UI can offer "Try again".
    public func reloadProducts() async {
        await loadProducts()
    }

    private func loadProducts() async {
        productsLoadState = .loading
        let requested = ProductID.allCases.map(\.rawValue)
        Self.log.notice("Product load starting — requesting \(requested.joined(separator: ", "), privacy: .public)")
        do {
            let fetched = try await Product.products(for: requested)
            var byID: [ProductID: Product] = [:]
            for product in fetched {
                if let id = ProductID(rawValue: product.id) {
                    byID[id] = product
                }
            }
            self.products = byID
            // Loaded successfully. A product absent from `byID` isn't
            // purchasable, but StoreKit doesn't say why — region restriction,
            // Missing Metadata, an inactive Paid Apps agreement, or an
            // unknown/mismatched ID all look identical here. Don't infer a
            // cause; the row copy stays neutral. Distinct from a transient .failed.
            self.productsLoadState = .loaded

            let returned = fetched.map(\.id).sorted()
            let missing = requested.filter { !returned.contains($0) }
            if missing.isEmpty {
                Self.log.notice("Product load OK — App Store returned \(returned.joined(separator: ", "), privacy: .public)")
            } else {
                // The interesting case, and the one this logger exists for. The
                // call SUCCEEDED — this is not a network problem — the App
                // Store simply did not offer these identifiers. Log it as an
                // error so it lands in the persisted store, and record what did
                // come back: an empty list and a partial list point at
                // different causes.
                Self.log.error(
                    """
                    Product load returned WITHOUT \(missing.joined(separator: ", "), privacy: .public) \
                    — the call succeeded, so this is an App Store Connect condition, not connectivity. \
                    App Store returned: \(returned.isEmpty ? "(nothing)" : returned.joined(separator: ", "), privacy: .public). \
                    Check, in order: Paid Applications Agreement active; the identifier exists under this app; \
                    product state is not Missing Metadata.
                    """
                )
            }
        } catch {
            // Transient (network / outage): the products surface stays empty and
            // the UI offers a retry rather than a dead-end "Unavailable".
            self.productsLoadState = .failed
            Self.log.error("Product load FAILED (transient) — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Purchase-row presentation (pure, testable)

    /// What a product's row should show, decided from ownership, an in-flight
    /// purchase, the resolved price, and the load state. Pure so the two
    /// non-resolving conditions (X55 §3) are unit-testable without StoreKit.
    public enum RowState: Sendable, Equatable {
        case owned
        case purchasing
        case buy(price: String)
        case checking              // load in flight — no verdict yet
        case unreachable           // transient failure — offer a retry
        case unavailable           // loaded, but the App Store isn't offering it (cause unknowable here)
    }

    public static func rowState(
        owns: Bool,
        purchasing: Bool,
        price: String?,
        loadState: ProductsLoadState
    ) -> RowState {
        if owns { return .owned }
        if purchasing { return .purchasing }
        if let price { return .buy(price: price) }
        switch loadState {
        case .loaded:          return .unavailable
        case .failed:          return .unreachable
        case .idle, .loading:  return .checking
        }
    }

    private func refreshCurrentEntitlements() async {
        var owned: Set<ProductID> = []
        var unverifiedCount = 0
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                unverifiedCount += 1
                continue
            }
            if transaction.revocationDate == nil,
               let id = ProductID(rawValue: transaction.productID) {
                owned.insert(id)
            }
        }
        self.ownedProductIDs = owned
        let names = owned.map(\.rawValue).sorted()
        Self.log.notice("Entitlement walk — owns \(names.isEmpty ? "(nothing)" : names.joined(separator: ", "), privacy: .public)")
        if unverifiedCount > 0 {
            // Refusing these is correct, but refusing them silently means a
            // user who genuinely bought the product looks identical to one who
            // never did. Say so.
            Self.log.error("Entitlement walk skipped \(unverifiedCount, privacy: .public) unverified transaction(s) — never granted")
        }
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
            // Unverified transactions are ignored — never grant an
            // entitlement off a transaction we can't prove came from Apple.
            // Logged rather than swallowed: this is the one path where a
            // legitimate purchase can vanish without the user seeing anything.
            Self.log.error("Ignored an unverified transaction from Transaction.updates — entitlement NOT granted")
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
        // One purchase unlocks every paid producer (single-IAP pivot).
        case "murmur.annotation", "murmur.metrics", "murmur.vtdetect":
            return .studio
        default:
            return nil   // free / baseline producer
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
