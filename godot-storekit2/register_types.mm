#include "register_types.h"

#include "godot-storekit2.h"

#include "core/config/engine.h"

static GodotStoreKit2 *storekit2 = nullptr;

void register_godot_storekit2_types() {
	storekit2 = memnew(GodotStoreKit2);
	Engine::get_singleton()->add_singleton(Engine::Singleton("StoreKit2", storekit2));
}

void unregister_godot_storekit2_types() {
	if (storekit2) {
		memdelete(storekit2);
		storekit2 = nullptr;
	}
}
