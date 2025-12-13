//
//  PurchaseManager.swift
//  LyrPlay
//
//  Created by Claude Code on 12/11/25.
//  StoreKit 2 integration for Icon Pack IAP
//

import Foundation
import StoreKit
import OSLog

/// Manages in-app purchases using StoreKit 2
/// Handles Icon Pack ($2.99) and future LyrPlay Pro features
@MainActor
class PurchaseManager: ObservableObject {

    // MARK: - Singleton

    static let shared = PurchaseManager()

    // MARK: - Product IDs

    enum ProductID: String, CaseIterable {
        case iconPack = "com.lyrplay.icons"
        // Future products:
        // case carplayPro = "com.lyrplay.carplay"
        // case widgetsPro = "com.lyrplay.widgets"
        // case lyrplayPro = "com.lyrplay.pro"
    }

    // MARK: - Published State

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isPurchasing = false
    @Published private(set) var purchaseError: Error?

    // MARK: - Properties

    private let logger = OSLog(subsystem: "com.lmsstream", category: "PurchaseManager")
    private var updateListenerTask: Task<Void, Error>?

    // MARK: - Initialization

    private init() {
        // Start listening for transaction updates
        updateListenerTask = listenForTransactions()

        Task {
            await loadProducts()
            await updatePurchasedProducts()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Product Loading

    /// Load products from App Store Connect
    func loadProducts() async {
        do {
            let productIDs = ProductID.allCases.map { $0.rawValue }
            let storeProducts = try await Product.products(for: productIDs)

            self.products = storeProducts.sorted { $0.price < $1.price }

            #if DEBUG
            if storeProducts.isEmpty {
                os_log(.debug, log: logger, "ℹ️ No products loaded (expected without StoreKit config)")
            } else {
                os_log(.info, log: logger, "📦 Loaded %d products from App Store", storeProducts.count)
            }
            #else
            os_log(.info, log: logger, "📦 Loaded %d products from App Store", storeProducts.count)
            #endif

        } catch {
            #if DEBUG
            os_log(.debug, log: logger, "ℹ️ Product loading skipped (expected in debug without StoreKit config)")
            #else
            os_log(.error, log: logger, "❌ Failed to load products: %{public}s", error.localizedDescription)
            self.purchaseError = error
            #endif
        }
    }

    // MARK: - Purchase Flow

    /// Purchase a product
    /// - Parameter productID: The product to purchase
    /// - Returns: True if purchase succeeded, false otherwise
    @discardableResult
    func purchase(_ productID: ProductID) async -> Bool {
        #if DEBUG
        // In debug builds, if already unlocked via simulatePurchase, just return success
        if purchasedProductIDs.contains(productID.rawValue) {
            os_log(.debug, log: logger, "🧪 DEBUG: Already unlocked via simulatePurchase - skipping purchase")
            return true
        }
        #endif

        guard let product = products.first(where: { $0.id == productID.rawValue }) else {
            #if DEBUG
            os_log(.debug, log: logger, "ℹ️ Product not found (expected in debug without StoreKit config): %{public}s", productID.rawValue)
            #else
            os_log(.error, log: logger, "❌ Product not found: %{public}s", productID.rawValue)
            #endif
            return false
        }

        isPurchasing = true
        purchaseError = nil

        defer {
            isPurchasing = false
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                // Verify the transaction
                let transaction = try checkVerified(verification)

                // Update purchased products
                await updatePurchasedProducts()

                // Finish the transaction
                await transaction.finish()

                os_log(.info, log: logger, "✅ Purchase successful: %{public}s", productID.rawValue)
                return true

            case .userCancelled:
                os_log(.info, log: logger, "ℹ️ User cancelled purchase")
                return false

            case .pending:
                os_log(.info, log: logger, "⏳ Purchase pending approval")
                return false

            @unknown default:
                os_log(.error, log: logger, "❌ Unknown purchase result")
                return false
            }

        } catch {
            os_log(.error, log: logger, "❌ Purchase failed: %{public}s", error.localizedDescription)
            purchaseError = error
            return false
        }
    }

    // MARK: - Restore Purchases

    /// Restore previously purchased products
    func restorePurchases() async {
        os_log(.info, log: logger, "🔄 Restoring purchases...")

        do {
            try await AppStore.sync()
            await updatePurchasedProducts()

            os_log(.info, log: logger, "✅ Restore complete - %d products owned", purchasedProductIDs.count)

        } catch {
            os_log(.error, log: logger, "❌ Restore failed: %{public}s", error.localizedDescription)
            purchaseError = error
        }
    }

    // MARK: - Transaction Monitoring

    /// Listen for transaction updates in the background
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    await self.updatePurchasedProducts()

                    await transaction.finish()

                } catch {
                    os_log(.error, log: self.logger, "❌ Transaction verification failed: %{public}s", error.localizedDescription)
                }
            }
        }
    }

    /// Update the list of purchased products
    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                // Add to purchased set
                purchased.insert(transaction.productID)

            } catch {
                os_log(.error, log: logger, "❌ Failed to verify entitlement: %{public}s", error.localizedDescription)
            }
        }

        #if DEBUG
        // In debug mode, preserve simulated purchases
        let debugPurchases = self.purchasedProductIDs
        if !debugPurchases.isEmpty {
            os_log(.debug, log: logger, "🧪 DEBUG: Preserving simulated purchases: %{public}s", debugPurchases.joined(separator: ", "))
            purchased.formUnion(debugPurchases)
        }
        #endif

        self.purchasedProductIDs = purchased

        os_log(.debug, log: logger, "📊 Updated purchases: %{public}s", purchased.joined(separator: ", "))
    }

    // MARK: - Transaction Verification

    /// Verify a transaction to ensure it's legitimate
    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Feature Access Helpers

    /// Check if user has purchased Icon Pack (or Pro bundle)
    var hasIconPack: Bool {
        let hasPurchase = purchasedProductIDs.contains(ProductID.iconPack.rawValue)
        #if DEBUG
        os_log(.debug, log: logger, "🔍 hasIconPack check: %{public}@ (purchasedIDs: %{public}s)",
               hasPurchase ? "YES" : "NO",
               purchasedProductIDs.joined(separator: ", "))
        #endif
        return hasPurchase
        // Future: || purchasedProductIDs.contains(ProductID.lyrplayPro.rawValue)
    }

    /// Get the Icon Pack product for display
    var iconPackProduct: Product? {
        products.first { $0.id == ProductID.iconPack.rawValue }
    }

    /// Get formatted price for Icon Pack
    var iconPackPrice: String {
        iconPackProduct?.displayPrice ?? "$2.99"
    }
}

// MARK: - Debug Helpers

#if DEBUG || TESTFLIGHT
extension PurchaseManager {
    /// Simulate purchase for testing UI (does not actually purchase)
    func simulatePurchase(_ productID: ProductID) {
        purchasedProductIDs.insert(productID.rawValue)
        os_log(.debug, log: logger, "🧪 DEBUG: Simulated purchase of %{public}s", productID.rawValue)
        os_log(.debug, log: logger, "🧪 DEBUG: purchasedProductIDs now contains: %{public}s",
               purchasedProductIDs.joined(separator: ", "))
    }

    /// Reset all purchases for testing
    func resetPurchases() {
        purchasedProductIDs.removeAll()
        os_log(.debug, log: logger, "🧪 DEBUG: Reset all purchases")
    }
}
#endif
