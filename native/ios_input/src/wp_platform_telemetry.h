#pragma once

#include "platform_telemetry.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>

// Optional platform telemetry, separate from WPNativeInput: no singleton, no
// shared state with the input queue/observer. Instantiable from GDScript.
class WPPlatformTelemetry : public godot::RefCounted {
  GDCLASS(WPPlatformTelemetry, godot::RefCounted)

public:
  WPPlatformTelemetry();
  ~WPPlatformTelemetry();

  bool is_available() const;
  int64_t thermal_state() const;
  int64_t footprint_bytes() const;
  int64_t consume_memory_warnings();
  godot::String source() const;

protected:
  static void _bind_methods();

private:
  std::unique_ptr<wpni::PlatformTelemetry> impl_;
};
