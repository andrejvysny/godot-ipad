// Apple (iOS + macOS host) telemetry. Public API only: NSProcessInfo
// thermalState, task_info(TASK_VM_INFO), and on iOS
// UIApplicationDidReceiveMemoryWarningNotification via NSNotificationCenter.
// No state is shared with platform_bridge_*.{mm,cpp}.

#include <TargetConditionals.h>

#include "platform_telemetry.h"

#include <atomic>
#include <memory>

#import <Foundation/Foundation.h>
#include <mach/mach.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

namespace wpni {

namespace {

int map_thermal(NSProcessInfoThermalState p_state) {
  switch (p_state) {
  case NSProcessInfoThermalStateNominal:
    return 0;
  case NSProcessInfoThermalStateFair:
    return 1;
  case NSProcessInfoThermalStateSerious:
    return 2;
  case NSProcessInfoThermalStateCritical:
    return 3;
  default:
    return -1; // a future state is reported as unavailable, never guessed
  }
}

class AppleTelemetry final : public PlatformTelemetry {
public:
  ~AppleTelemetry() override {
#if TARGET_OS_IOS
    // Lifetime: observer_ is the opaque token returned by
    // addObserverForName:; ARC owns it (strong member) and the center keeps its
    // own reference until removed here. Removing it in the destructor stops
    // further block calls; the block only holds a shared_ptr to the counter, so
    // a block already in flight cannot touch freed memory.
    if (observer_ != nil) {
      [[NSNotificationCenter defaultCenter] removeObserver:observer_];
      observer_ = nil;
    }
#endif
  }

  int thermal_state() override {
    return map_thermal([NSProcessInfo processInfo].thermalState);
  }

  int64_t footprint_bytes() override {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t result =
        task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&info), &count);
    if (result != KERN_SUCCESS || count < TASK_VM_INFO_REV1_COUNT) {
      return -1;
    }
    return static_cast<int64_t>(info.phys_footprint);
  }

  int64_t consume_memory_warnings() override {
#if TARGET_OS_IOS
    // Registered on first use, so warnings before the first call are not
    // counted.
    if (observer_ == nil) {
      std::shared_ptr<std::atomic<int64_t>> counter = warnings_;
      observer_ = [[NSNotificationCenter defaultCenter]
          addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *) {
                    counter->fetch_add(1, std::memory_order_relaxed);
                  }];
    }
    return warnings_->exchange(0, std::memory_order_relaxed);
#else
    return 0;
#endif
  }

  const char *source() const override {
#if TARGET_OS_IOS
    return "ios_native";
#else
    return "macos_native";
#endif
  }

private:
  std::shared_ptr<std::atomic<int64_t>> warnings_ =
      std::make_shared<std::atomic<int64_t>>(0);
#if TARGET_OS_IOS
  id observer_ = nil;
#endif
};

} // namespace

std::unique_ptr<PlatformTelemetry> create_platform_telemetry() {
  return std::make_unique<AppleTelemetry>();
}

} // namespace wpni
