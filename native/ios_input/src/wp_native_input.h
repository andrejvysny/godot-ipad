#pragma once

#include "platform_bridge.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <memory>

// Engine singleton "WPNativeInput". Registered abstract so scripts cannot
// create a second instance (a second observer would deliver every touch twice).
class WPNativeInput : public godot::Object {
  GDCLASS(WPNativeInput, godot::Object)

public:
  WPNativeInput();
  ~WPNativeInput();

  bool start();
  void stop();
  bool is_active() const;
  godot::PackedFloat64Array drain();
  int64_t get_record_stride() const;
  double native_now() const;
  godot::Dictionary get_view_metrics() const;
  godot::Dictionary get_capabilities() const;
  void cancel_all(int64_t p_reason_code);
  godot::Dictionary get_diagnostics() const;
  godot::Dictionary get_platform_info() const;

protected:
  static void _bind_methods();

private:
  std::unique_ptr<wpni::PlatformBridge> bridge_;
};
