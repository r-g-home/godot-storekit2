# Godot StoreKit 2 (Crystal Tempest fork)

A fork of [godot-sdk-integrations/godot-storekit2](https://github.com/godot-sdk-integrations/godot-storekit2)
for Godot **4.7.2**, rewritten for a game that credits consumable purchases
itself. The API is not compatible with upstream.

What the fork changes:

- **It never finishes a transaction on its own.** The game records a purchase
  first and only then calls `finish_transaction`. A transaction the app dies
  holding stays unfinished and is delivered again by `start()`. (Upstream
  finished every purchase as soon as the sheet closed.)
- **Every transaction carries its id and dates**, so a purchase can be counted
  exactly once.
- **Restore replays what the account owns** after `AppStore.sync()`, and never
  a finished consumable.
- **Results are polled events**, as in the godot-ios-plugins GameCenter plugin,
  instead of signals.

Only `VerificationResult.verified` transactions are delivered. iOS 15 or later.

## Installation

Build (below), then copy `bin/godot-storekit2/` into the project's
`ios/plugins/` folder and enable `godot-storekit2` in the iOS export preset.

## Usage

The engine singleton is `StoreKit2`, present only in iOS builds:

```gdscript
if Engine.has_singleton("StoreKit2"):
	var store = Engine.get_singleton("StoreKit2")
	store.start()

func _process(_delta):
	while store.get_pending_event_count() > 0:
		var event: Dictionary = store.pop_pending_event()
		match event.type:
			"transaction":
				record(event)                                 # credit it first...
				store.finish_transaction(event.transaction_id) # ...then finish it
```

## Methods

`can_make_payments() -> bool` - `AppStore.canMakePayments`: false when the
device does not allow purchases (Screen Time restrictions).

`start()` - Starts listening to `Transaction.updates` (Ask to Buy approvals,
purchases made elsewhere, refunds), then delivers every unfinished transaction
and the current entitlements. Call once at launch. A second call does nothing.

`request_products(product_ids: PackedStringArray)` - Loads products. Answers
with a `products` event.

`purchase(product_id: String)` - Shows the App Store purchase sheet. A verified
purchase produces a `transaction` event and then a `purchase` event.

`finish_transaction(transaction_id: String)` - Calls `Transaction.finish()`.
Call it only after the purchase is recorded. Answers with a `finish` event.

`restore_purchases()` - `AppStore.sync()`, then `transaction` events (with
`source` `restore`) for the non-consumables the account owns and for every
unfinished transaction, then an `entitlements` event, then a `restore` event.
The sync asks the player to sign in, so call it only from a button. Replaying
happens even when the sync fails.

`refresh_entitlements()` - Re-reads the entitlements. Answers with an
`entitlements` event.

`get_plugin_version() -> String` - The fork's git revision this plugin was
built from; `+` marks a build from a dirty tree.

`get_pending_event_count() -> int`, `pop_pending_event() -> Dictionary` - The
event queue. `pop_pending_event()` returns `null` when it is empty.

## Events

Every event has a `type`. Dates are milliseconds since the Unix epoch (UTC).
Transaction ids are strings.

| `type` | Fields |
|---|---|
| `transaction` | `source` (`purchase`, `update`, `unfinished`, `restore`), `transaction_id`, `original_transaction_id`, `product_id`, `product_type`, `purchase_date_ms`, `quantity`, `family_shared`, `environment` (iOS 16+: `Production`, `Sandbox`, `Xcode`) |
| `transaction_revoked` | As `transaction`, plus `revocation_date_ms`. A refund or revocation. |
| `transaction_unverified` | `source`, `transaction_id`, `product_id`, `error`. For logs only: never credit it. |
| `purchase` | `product_id`, `result` (`purchased`, `pending`, `cancelled`, `failed`), `transaction_id` (when there is one), `error` (for `failed`) |
| `products` | `result` `ok`: `products` (each `product_id`, `display_name`, `description`, `display_price`, `price`, `currency_code`, `product_type`) and `invalid_ids`; `result` `error`: `error` |
| `entitlements` | `result` `ok`, `product_ids`: the non-consumable (and unexpired subscription) products the account owns |
| `finish` | `transaction_id`, `result` (`ok`, `error`), `product_id` (for `ok`), `error` |
| `restore` | `result` (`ok`, `cancelled`, `error`), `error` |

`product_type` is `consumable`, `non_consumable`, `auto_renewable` or
`non_renewing`.

Transactions can repeat: the same unfinished transaction arrives from `start()`
on every launch, and again from a restore. Count purchases by `transaction_id`.

## Building

Requires Xcode. The `godot` submodule is pinned to `4.7.2-stable`; its
generated headers (`*.gen.h`) must exist, which `scripts/generate_headers.sh`
creates by starting an engine build.

```
./scripts/make_release.sh
```

The output is `bin/godot-storekit2/`: the `.gdip` plus debug and release
xcframeworks.
