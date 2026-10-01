#include "wp_platform_telemetry.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

WPPlatformTelemetry::WPPlatformTelemetry()
    : impl_(wpni::create_platform_telemetry()) {}

WPPlatformTelemetry::~WPPlatformTelemetry() = default;

bool WPPlatformTelemetry::is_available() const { return impl_ != nullptr; }

int64_t WPPlatformTelemetry::thermal_state() const {
  return impl_ ? impl_->thermal_state() : -1;
}

int64_t WPPlatformTelemetry::footprint_bytes() const {
  return impl_ ? impl_->footprint_bytes() : -1;
}

int64_t WPPlatformTelemetry::consume_memory_warnings() {
  return impl_ ? impl_->consume_memory_warnings() : 0;
}

String WPPlatformTelemetry::source() const {
  return impl_ ? String(impl_->source()) : String("unavailable");
}

void WPPlatformTelemetry::_bind_methods() {
  ClassDB::bind_method(D_METHOD("is_available"),
                       &WPPlatformTelemetry::is_available);
  ClassDB::bind_method(D_METHOD("thermal_state"),
                       &WPPlatformTelemetry::thermal_state);
  ClassDB::bind_method(D_METHOD("footprint_bytes"),
                       &WPPlatformTelemetry::footprint_bytes);
  ClassDB::bind_method(D_METHOD("consume_memory_warnings"),
                       &WPPlatformTelemetry::consume_memory_warnings);
  ClassDB::bind_method(D_METHOD("source"), &WPPlatformTelemetry::source);
}
