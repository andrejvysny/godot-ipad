#pragma once

// Platform telemetry in plain C++ types (thermal state, process footprint,
// memory-warning count). Independent of PlatformBridge and TouchRecordQueue: it
// shares no state, thread or notification observer with the input path.
// Defined once for iOS and macOS in platform_telemetry_apple.mm.

#include <cstdint>
#include <memory>

namespace wpni {

class PlatformTelemetry {
public:
  virtual ~PlatformTelemetry() = default;
  // 0 nominal, 1 fair, 2 serious, 3 critical; -1 when unavailable.
  virtual int thermal_state() = 0;
  // task_info TASK_VM_INFO phys_footprint; -1 on failure.
  virtual int64_t footprint_bytes() = 0;
  // Memory-warning notifications since the previous call.
  virtual int64_t consume_memory_warnings() = 0;
  // "ios_native" or "macos_native".
  virtual const char *source() const = 0;
};

std::unique_ptr<PlatformTelemetry> create_platform_telemetry();

} // namespace wpni
