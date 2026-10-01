#include "register_types.h"

#include "wp_native_input.h"
#include "wp_platform_telemetry.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

namespace {

const char *const SINGLETON_NAME = "WPNativeInput";
WPNativeInput *singleton = nullptr;

} // namespace

void initialize_wp_native_input(ModuleInitializationLevel p_level) {
  if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
    return;
  }
  GDREGISTER_ABSTRACT_CLASS(WPNativeInput);
  GDREGISTER_CLASS(WPPlatformTelemetry);
  singleton = memnew(WPNativeInput);
  Engine::get_singleton()->register_singleton(SINGLETON_NAME, singleton);
}

void uninitialize_wp_native_input(ModuleInitializationLevel p_level) {
  if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE || singleton == nullptr) {
    return;
  }
  Engine::get_singleton()->unregister_singleton(SINGLETON_NAME);
  memdelete(singleton);
  singleton = nullptr;
}

extern "C" {

// Entry symbol named in app/addons/wp_native_input/wp_native_input.gdextension.
// On iOS the export links the static xcframework and registers this symbol by
// name.
GDExtensionBool GDE_EXPORT
wp_native_input_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                     GDExtensionClassLibraryPtr p_library,
                     GDExtensionInitialization *r_initialization) {
  GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library,
                                          r_initialization);
  init_obj.register_initializer(initialize_wp_native_input);
  init_obj.register_terminator(uninitialize_wp_native_input);
  init_obj.set_minimum_library_initialization_level(
      MODULE_INITIALIZATION_LEVEL_SCENE);
  return init_obj.init();
}

} // extern "C"
