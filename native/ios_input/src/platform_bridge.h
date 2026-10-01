#pragma once

// Platform side of WPNativeInput in plain C++ types, so UIKit
// (platform_bridge_ios.mm) and godot-cpp (wp_native_input.cpp) never share a
// translation unit.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wpni {

struct ViewMetrics {
  double width_points = 0.0;
  double height_points = 0.0;
  double content_scale = 0.0;
  double safe_x = 0.0; // safe area in view points
  double safe_y = 0.0;
  double safe_width = 0.0;
  double safe_height = 0.0;
  int64_t generation = 0;
};

struct Capabilities {
  std::string platform;
  bool supported = false;
  bool source_identity = false;
  bool pressure = false;
  bool tilt = false;
  bool coalesced = false;
  bool native_cancel = false;
  bool native_timestamps = false;
};

struct BridgeDiagnostics {
  int64_t active_contacts = 0;
  int64_t queued_records = 0;
  int64_t overflow_count = 0;
  int64_t records_emitted = 0;
  int64_t ignored_contacts = 0;
  bool observer_attached = false;
  std::string
      attach_status; // why start() failed, or the current attachment state
  std::string observed_view_class;
};

struct PlatformInfo {
  std::string machine;
  std::string system_name;
  std::string system_version;
  std::string model;
  std::string idiom;
};

class PlatformBridge {
public:
  virtual ~PlatformBridge() = default;
  virtual bool start() = 0;
  virtual void stop() = 0;
  virtual bool is_active() = 0;
  virtual std::vector<double> drain() = 0;
  // Seconds on the CACurrentMediaTime() clock, which UITouch.timestamp also
  // uses.
  virtual double native_now() = 0;
  virtual ViewMetrics view_metrics() = 0;
  virtual Capabilities capabilities() = 0;
  virtual void cancel_all(int p_reason) = 0;
  virtual BridgeDiagnostics diagnostics() = 0;
  virtual PlatformInfo platform_info() = 0;
};

// Defined once per platform: platform_bridge_ios.mm (TARGET_OS_IOS) or
// platform_bridge_host.cpp.
std::unique_ptr<PlatformBridge> create_platform_bridge();

} // namespace wpni
