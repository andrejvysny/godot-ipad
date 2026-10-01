// Non-iOS (macOS host) bridge: every call is an inert no-op so the extension
// can load in the editor and headless tests without ever producing input.

#include <TargetConditionals.h>

#if !TARGET_OS_IOS

#include "platform_bridge.h"

#include <QuartzCore/CABase.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>

namespace wpni {

namespace {

std::string sysctl_string(const char *p_name) {
  char buffer[256] = {};
  size_t size = sizeof(buffer) - 1;
  if (sysctlbyname(p_name, buffer, &size, nullptr, 0) != 0) {
    return std::string();
  }
  return std::string(buffer);
}

class HostPlatformBridge final : public PlatformBridge {
public:
  bool start() override { return false; }
  void stop() override {}
  bool is_active() override { return false; }
  std::vector<double> drain() override { return {}; }
  double native_now() override { return CACurrentMediaTime(); }
  ViewMetrics view_metrics() override { return ViewMetrics(); }

  Capabilities capabilities() override {
    Capabilities caps;
    caps.platform = "macos";
    return caps;
  }

  void cancel_all(int) override {}

  BridgeDiagnostics diagnostics() override {
    BridgeDiagnostics diag;
    diag.attach_status = "unsupported_platform";
    return diag;
  }

  PlatformInfo platform_info() override {
    PlatformInfo info;
    struct utsname name;
    if (uname(&name) == 0) {
      info.machine = name.machine;
    }
    info.system_name = "macOS";
    info.system_version = sysctl_string("kern.osproductversion");
    info.model = sysctl_string("hw.model");
    info.idiom = "desktop";
    return info;
  }
};

} // namespace

std::unique_ptr<PlatformBridge> create_platform_bridge() {
  return std::make_unique<HostPlatformBridge>();
}

} // namespace wpni

#endif // !TARGET_OS_IOS
