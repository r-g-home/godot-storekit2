#include "godot-storekit2.h"

#import "godot_storekit2-Swift.h"

// Written by scripts/make_release.sh from the fork's git revision.
#if __has_include("plugin_version.gen.h")
#include "plugin_version.gen.h"
#endif
#ifndef STOREKIT2_PLUGIN_VERSION
#define STOREKIT2_PLUGIN_VERSION "unknown"
#endif

GodotStoreKit2 *GodotStoreKit2::instance = nullptr;

static NSString *sk2_nsstring(const String &p_string) {
	return [NSString stringWithUTF8String:p_string.utf8().get_data()];
}

// The proxy's events hold strings, numbers, booleans, arrays and dictionaries.
// Numbers keep their kind: a Swift Bool arrives as a CFBoolean, an Int64 as an
// integer NSNumber, a Double as a floating one.
static Variant sk2_variant(id p_value) {
	if (p_value == nil || p_value == [NSNull null]) {
		return Variant();
	}
	if ([p_value isKindOfClass:[NSString class]]) {
		const char *utf8 = [(NSString *)p_value UTF8String];
		return String::utf8(utf8 != nullptr ? utf8 : "");
	}
	if ([p_value isKindOfClass:[NSNumber class]]) {
		NSNumber *number = (NSNumber *)p_value;
		if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
			return (bool)number.boolValue;
		}
		if (CFNumberIsFloatType((__bridge CFNumberRef)number)) {
			return number.doubleValue;
		}
		return (int64_t)number.longLongValue;
	}
	if ([p_value isKindOfClass:[NSArray class]]) {
		Array array;
		for (id item in (NSArray *)p_value) {
			array.push_back(sk2_variant(item));
		}
		return array;
	}
	if ([p_value isKindOfClass:[NSDictionary class]]) {
		NSDictionary *source = (NSDictionary *)p_value;
		Dictionary dictionary;
		for (id key in source) {
			dictionary[sk2_variant(key)] = sk2_variant(source[key]);
		}
		return dictionary;
	}
	return Variant();
}

void GodotStoreKit2::_bind_methods() {
	ClassDB::bind_method(D_METHOD("can_make_payments"), &GodotStoreKit2::can_make_payments);
	ClassDB::bind_method(D_METHOD("start"), &GodotStoreKit2::start);
	ClassDB::bind_method(D_METHOD("request_products", "product_ids"), &GodotStoreKit2::request_products);
	ClassDB::bind_method(D_METHOD("purchase", "product_id"), &GodotStoreKit2::purchase);
	ClassDB::bind_method(D_METHOD("finish_transaction", "transaction_id"), &GodotStoreKit2::finish_transaction);
	ClassDB::bind_method(D_METHOD("restore_purchases"), &GodotStoreKit2::restore_purchases);
	ClassDB::bind_method(D_METHOD("refresh_entitlements"), &GodotStoreKit2::refresh_entitlements);
	ClassDB::bind_method(D_METHOD("get_plugin_version"), &GodotStoreKit2::get_plugin_version);

	ClassDB::bind_method(D_METHOD("get_pending_event_count"), &GodotStoreKit2::get_pending_event_count);
	ClassDB::bind_method(D_METHOD("pop_pending_event"), &GodotStoreKit2::pop_pending_event);
}

bool GodotStoreKit2::can_make_payments() {
	return [proxy canMakePayments];
}

void GodotStoreKit2::start() {
	[proxy start];
}

void GodotStoreKit2::request_products(PackedStringArray p_product_ids) {
	NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:p_product_ids.size()];
	for (int i = 0; i < p_product_ids.size(); i++) {
		[ids addObject:sk2_nsstring(p_product_ids[i])];
	}
	[proxy requestProducts:ids];
}

void GodotStoreKit2::purchase(String p_product_id) {
	[proxy purchaseWithProductId:sk2_nsstring(p_product_id)];
}

void GodotStoreKit2::finish_transaction(String p_transaction_id) {
	[proxy finishTransactionWithTransactionId:sk2_nsstring(p_transaction_id)];
}

void GodotStoreKit2::restore_purchases() {
	[proxy restorePurchases];
}

void GodotStoreKit2::refresh_entitlements() {
	[proxy refreshEntitlements];
}

String GodotStoreKit2::get_plugin_version() {
	return String(STOREKIT2_PLUGIN_VERSION);
}

void GodotStoreKit2::push_pending_event(const Variant &p_event) {
	pending_events.push_back(p_event);
}

int GodotStoreKit2::get_pending_event_count() {
	return pending_events.size();
}

Variant GodotStoreKit2::pop_pending_event() {
	if (pending_events.is_empty()) {
		return Variant();
	}
	Variant front = pending_events.front()->get();
	pending_events.pop_front();
	return front;
}

GodotStoreKit2 *GodotStoreKit2::get_singleton() {
	return instance;
}

GodotStoreKit2::GodotStoreKit2() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;

	proxy = [[GodotStoreKit2Proxy alloc] initWithEmit:^(NSDictionary *p_event) {
		// StoreKit answers on its own threads; Godot reads the queue on the
		// main one, so every event is handed over there.
		dispatch_async(dispatch_get_main_queue(), ^{
			GodotStoreKit2 *store = GodotStoreKit2::get_singleton();
			if (store != nullptr) {
				store->push_pending_event(sk2_variant(p_event));
			}
		});
	}];
}

GodotStoreKit2::~GodotStoreKit2() {
	proxy = nil;
	if (instance == this) {
		instance = nullptr;
	}
}
