#pragma once

#include "core/object/class_db.h"
#include "core/templates/list.h"

@class GodotStoreKit2Proxy;

// StoreKit 2 for Godot - the Crystal Tempest fork. See README.md.
//
// Registered as the engine singleton "StoreKit2". Every asynchronous result
// arrives as a Dictionary event, queued on Godot's main thread and read with
// get_pending_event_count() / pop_pending_event() - the same model as the
// godot-ios-plugins GameCenter plugin.
class GodotStoreKit2 : public Object {
	GDCLASS(GodotStoreKit2, Object);

	static GodotStoreKit2 *instance;
	static void _bind_methods();

	GodotStoreKit2Proxy *proxy;
	List<Variant> pending_events;

public:
	bool can_make_payments();
	void start();
	void request_products(PackedStringArray p_product_ids);
	void purchase(String p_product_id);
	void finish_transaction(String p_transaction_id);
	void restore_purchases();
	void refresh_entitlements();
	String get_plugin_version();

	void push_pending_event(const Variant &p_event);
	int get_pending_event_count();
	Variant pop_pending_event();

	static GodotStoreKit2 *get_singleton();

	GodotStoreKit2();
	~GodotStoreKit2();
};
