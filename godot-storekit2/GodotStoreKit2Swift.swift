import Foundation
import StoreKit

// StoreKit 2 for Godot - the Crystal Tempest fork.
//
// StoreKit 2 is Swift-only, so this proxy does the StoreKit work and hands
// every result to the Godot class (godot-storekit2.mm) as a dictionary event
// through `emit`. The Godot side moves each event onto the main queue - the
// thread Godot's main loop runs on - and queues it for polling.
//
// What the fork exists for:
//  - Nothing here ever finishes a transaction on its own. The game records a
//    purchase first and only then calls finishTransaction, so a transaction
//    the app dies holding stays unfinished and is delivered again by start().
//  - Every delivered transaction carries its id and dates, so the game can
//    count a purchase exactly once.
//  - restorePurchases() replays what the account owns, after AppStore.sync().
//
// Only VerificationResult.verified transactions are delivered as
// "transaction". An unverified one is reported as "transaction_unverified"
// for the logs, and is never finished.
@objcMembers
public final class GodotStoreKit2Proxy: NSObject, @unchecked Sendable {
	private let emitEvent: @Sendable (NSDictionary) -> Void

	// Guards the state below. Only taken inside locked(), which is
	// synchronous, so it is never held across an await.
	private let lock = NSLock()
	private var products: [String: Product] = [:]
	// Verified transactions delivered to the game, by id, so that
	// finishTransaction has the object StoreKit needs.
	private var held: [UInt64: Transaction] = [:]
	private var updates: Task<Void, Never>? = nil

	public init(emit: @escaping @Sendable (NSDictionary) -> Void) {
		emitEvent = emit
		super.init()
	}

	deinit {
		updates?.cancel()
	}

	public func canMakePayments() -> Bool {
		return AppStore.canMakePayments
	}

	// Starts listening to Transaction.updates (Ask to Buy approvals, purchases
	// made on another device, refunds), then delivers every unfinished
	// transaction and the current entitlements. Apple wants the listener
	// running from launch. A second call does nothing.
	public func start() {
		let alreadyStarted: Bool = locked {
			if updates != nil {
				return true
			}
			updates = Task(priority: .background) { [weak self] in
				for await result in Transaction.updates {
					guard let self else {
						return
					}
					self.deliver(result, source: "update")
					await self.emitEntitlements()
				}
			}
			return false
		}
		if alreadyStarted {
			return
		}
		Task {
			for await result in Transaction.unfinished {
				deliver(result, source: "unfinished")
			}
			await emitEntitlements()
		}
	}

	public func requestProducts(_ productIds: [String]) {
		Task {
			do {
				let found = try await Product.products(for: productIds)
				locked {
					for product in found {
						products[product.id] = product
					}
				}
				let foundIds = Set(found.map { $0.id })
				emit([
					"type": "products",
					"result": "ok",
					"products": found.map { productInfo($0) },
					"invalid_ids": productIds.filter { !foundIds.contains($0) },
				])
			} catch {
				emit(["type": "products", "result": "error", "error": error.localizedDescription])
			}
		}
	}

	// Shows the App Store's purchase sheet. A verified purchase is delivered
	// as a "transaction" event BEFORE its "purchase" event.
	public func purchase(productId: String) {
		Task {
			do {
				guard let product = try await loadProduct(productId) else {
					emitPurchase(productId, "failed", error: "Product not found: \(productId)")
					return
				}
				let result = try await product.purchase()
				switch result {
				case .success(let verification):
					switch verification {
					case .verified(let transaction):
						deliver(verification, source: "purchase")
						emitPurchase(productId, "purchased", transactionId: String(transaction.id))
					case .unverified(let transaction, let verificationError):
						emitUnverified(transaction, source: "purchase", error: verificationError)
						emitPurchase(productId, "failed", transactionId: String(transaction.id),
								error: "The purchase could not be verified.")
					}
				case .pending:
					emitPurchase(productId, "pending")
				case .userCancelled:
					emitPurchase(productId, "cancelled")
				@unknown default:
					emitPurchase(productId, "failed", error: "Unknown purchase result.")
				}
			} catch StoreKitError.userCancelled {
				emitPurchase(productId, "cancelled")
			} catch {
				emitPurchase(productId, "failed", error: error.localizedDescription)
			}
		}
	}

	// Tells StoreKit the transaction is recorded. Only the game calls this,
	// and only once it has recorded the purchase.
	public func finishTransaction(transactionId: String) {
		Task {
			guard let id = UInt64(transactionId) else {
				emitFinish(transactionId, error: "Not a StoreKit transaction id.")
				return
			}
			var transaction: Transaction? = locked { held[id] }
			if transaction == nil {
				// Not delivered during this run - look among StoreKit's own
				// unfinished transactions.
				for await result in Transaction.unfinished {
					if case .verified(let candidate) = result, candidate.id == id {
						transaction = candidate
						break
					}
				}
			}
			guard let transaction else {
				emitFinish(transactionId, error: "No unfinished transaction with that id.")
				return
			}
			await transaction.finish()
			locked {
				held[id] = nil
			}
			emitFinish(transactionId, productId: transaction.productID)
		}
	}

	// The player's Restore Purchases: AppStore.sync(), then replay through
	// "transaction" events exactly
	//  - the non-consumables the account owns (currentEntitlements), and
	//  - every unfinished transaction,
	// then the entitlements, then the "restore" event. A finished consumable
	// is never replayed: consumables are skipped in currentEntitlements, and
	// only reach the game from Transaction.unfinished.
	public func restorePurchases() {
		Task {
			var result = "ok"
			var syncError: String? = nil
			do {
				try await AppStore.sync()
			} catch StoreKitError.userCancelled {
				result = "cancelled"
			} catch {
				result = "error"
				syncError = error.localizedDescription
			}

			// Replayed whether or not the sync worked: what this device already
			// knows is still true, and the game counts each transaction once.
			var replayed = Set<UInt64>()
			for await entitlement in Transaction.currentEntitlements {
				if case .verified(let transaction) = entitlement,
						transaction.productType != .consumable,
						transaction.revocationDate == nil,
						replayed.insert(transaction.id).inserted {
					deliver(entitlement, source: "restore")
				}
			}
			for await unfinished in Transaction.unfinished {
				if case .verified(let transaction) = unfinished,
						replayed.insert(transaction.id).inserted {
					deliver(unfinished, source: "restore")
				}
			}
			await emitEntitlements()

			var event: [String: Any] = ["type": "restore", "result": result]
			if let syncError {
				event["error"] = syncError
			}
			emit(event)
		}
	}

	public func refreshEntitlements() {
		Task {
			await emitEntitlements()
		}
	}

	// MARK: - Events

	private func deliver(_ result: VerificationResult<Transaction>, source: String) {
		switch result {
		case .verified(let transaction):
			locked {
				held[transaction.id] = transaction
			}
			emit(transactionEvent(transaction, source: source))
		case .unverified(let transaction, let error):
			emitUnverified(transaction, source: source, error: error)
		}
	}

	// The non-consumable, unrevoked, unexpired products the account owns.
	private func emitEntitlements() async {
		var owned = Set<String>()
		for await result in Transaction.currentEntitlements {
			guard case .verified(let transaction) = result,
					transaction.productType != .consumable,
					transaction.revocationDate == nil else {
				continue
			}
			if let expiry = transaction.expirationDate, expiry < Date() {
				continue
			}
			owned.insert(transaction.productID)
		}
		emit(["type": "entitlements", "result": "ok", "product_ids": owned.sorted()])
	}

	private func transactionEvent(_ transaction: Transaction, source: String) -> [String: Any] {
		var event: [String: Any] = [
			"type": transaction.revocationDate == nil ? "transaction" : "transaction_revoked",
			"source": source,
			"transaction_id": String(transaction.id),
			"original_transaction_id": String(transaction.originalID),
			"product_id": transaction.productID,
			"product_type": productTypeName(transaction.productType),
			"purchase_date_ms": milliseconds(transaction.purchaseDate),
			"quantity": transaction.purchasedQuantity,
			"family_shared": transaction.ownershipType == .familyShared,
		]
		if let revocationDate = transaction.revocationDate {
			event["revocation_date_ms"] = milliseconds(revocationDate)
		}
		if #available(iOS 16.0, *) {
			event["environment"] = transaction.environment.rawValue
		}
		return event
	}

	private func emitUnverified(_ transaction: Transaction, source: String,
			error: VerificationResult<Transaction>.VerificationError) {
		emit([
			"type": "transaction_unverified",
			"source": source,
			"transaction_id": String(transaction.id),
			"product_id": transaction.productID,
			"error": error.localizedDescription,
		])
	}

	private func emitPurchase(_ productId: String, _ result: String,
			transactionId: String? = nil, error: String? = nil) {
		var event: [String: Any] = ["type": "purchase", "result": result, "product_id": productId]
		if let transactionId {
			event["transaction_id"] = transactionId
		}
		if let error {
			event["error"] = error
		}
		emit(event)
	}

	private func emitFinish(_ transactionId: String, productId: String? = nil, error: String? = nil) {
		var event: [String: Any] = [
			"type": "finish",
			"result": error == nil ? "ok" : "error",
			"transaction_id": transactionId,
		]
		if let productId {
			event["product_id"] = productId
		}
		if let error {
			event["error"] = error
		}
		emit(event)
	}

	private func emit(_ event: [String: Any]) {
		emitEvent(event as NSDictionary)
	}

	// MARK: - Helpers

	private func locked<T>(_ body: () -> T) -> T {
		lock.lock()
		defer {
			lock.unlock()
		}
		return body()
	}

	private func loadProduct(_ productId: String) async throws -> Product? {
		if let cached = locked({ products[productId] }) {
			return cached
		}
		guard let product = try await Product.products(for: [productId]).first else {
			return nil
		}
		locked {
			products[productId] = product
		}
		return product
	}

	private func productInfo(_ product: Product) -> [String: Any] {
		return [
			"product_id": product.id,
			"display_name": product.displayName,
			"description": product.description,
			"display_price": product.displayPrice,
			"price": NSDecimalNumber(decimal: product.price).doubleValue,
			"currency_code": product.priceFormatStyle.currencyCode,
			"product_type": productTypeName(product.type),
		]
	}

	private func productTypeName(_ type: Product.ProductType) -> String {
		switch type {
		case .consumable:
			return "consumable"
		case .nonConsumable:
			return "non_consumable"
		case .autoRenewable:
			return "auto_renewable"
		case .nonRenewable:
			return "non_renewing"
		default:
			return type.rawValue
		}
	}

	private func milliseconds(_ date: Date) -> Int64 {
		return Int64((date.timeIntervalSince1970 * 1000).rounded())
	}
}
