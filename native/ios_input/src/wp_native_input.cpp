#include "wp_native_input.h"

#include "touch_record_queue.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstring>

using namespace godot;

namespace {

String to_godot(const std::string &p_value) {
  return String::utf8(p_value.c_str());
}

} // namespace

WPNativeInput::WPNativeInput() : bridge_(wpni::create_platform_bridge()) {}

WPNativeInput::~WPNativeInput() { bridge_->stop(); }

bool WPNativeInput::start() { return bridge_->start(); }

void WPNativeInput::stop() { bridge_->stop(); }

bool WPNativeInput::is_active() const { return bridge_->is_active(); }

PackedFloat64Array WPNativeInput::drain() {
  const std::vector<double> records = bridge_->drain();
  PackedFloat64Array out;
  out.resize(static_cast<int64_t>(records.size()));
  if (!records.empty()) {
    std::memcpy(out.ptrw(), records.data(), records.size() * sizeof(double));
  }
  return out;
}

int64_t WPNativeInput::get_record_stride() const { return wpni::RECORD_STRIDE; }

// Seconds on the CACurrentMediaTime() clock (mach absolute time), the clock of
// UITouch.timestamp. It is unrelated to Godot's Time.get_ticks_usec(); never
// subtract one from the other.
double WPNativeInput::native_now() const { return bridge_->native_now(); }

Dictionary WPNativeInput::get_view_metrics() const {
  const wpni::ViewMetrics m = bridge_->view_metrics();
  Dictionary d;
  d["view_size_points"] = Vector2(m.width_points, m.height_points);
  d["content_scale"] = m.content_scale;
  d["safe_area"] = Rect2(m.safe_x, m.safe_y, m.safe_width, m.safe_height);
  d["metrics_generation"] = m.generation;
  return d;
}

Dictionary WPNativeInput::get_capabilities() const {
  const wpni::Capabilities c = bridge_->capabilities();
  Dictionary d;
  d["platform"] = to_godot(c.platform);
  d["supported"] = c.supported;
  d["source_identity"] = c.source_identity;
  d["pressure"] = c.pressure;
  d["tilt"] = c.tilt;
  d["coalesced"] = c.coalesced;
  d["native_cancel"] = c.native_cancel;
  d["native_timestamps"] = c.native_timestamps;
  return d;
}

void WPNativeInput::cancel_all(int64_t p_reason_code) {
  // A CANCEL must always carry a real reason; unknown codes are reported as
  // explicit.
  const bool known = p_reason_code >= wpni::CANCEL_NATIVE &&
                     p_reason_code <= wpni::CANCEL_VIEW_CHANGED;
  bridge_->cancel_all(known ? static_cast<int>(p_reason_code)
                            : wpni::CANCEL_EXPLICIT);
}

Dictionary WPNativeInput::get_diagnostics() const {
  const wpni::BridgeDiagnostics b = bridge_->diagnostics();
  Dictionary d;
  d["active_contacts"] = b.active_contacts;
  d["queued_records"] = b.queued_records;
  d["overflow_count"] = b.overflow_count;
  d["records_emitted"] = b.records_emitted;
  d["ignored_contacts"] = b.ignored_contacts;
  d["observer_attached"] = b.observer_attached;
  d["attach_status"] = to_godot(b.attach_status);
  d["observed_view_class"] = to_godot(b.observed_view_class);
  return d;
}

Dictionary WPNativeInput::get_platform_info() const {
  const wpni::PlatformInfo p = bridge_->platform_info();
  Dictionary d;
  d["machine"] = to_godot(p.machine);
  d["system_name"] = to_godot(p.system_name);
  d["system_version"] = to_godot(p.system_version);
  d["model"] = to_godot(p.model);
  d["idiom"] = to_godot(p.idiom);
  return d;
}

void WPNativeInput::_bind_methods() {
  ClassDB::bind_method(D_METHOD("start"), &WPNativeInput::start);
  ClassDB::bind_method(D_METHOD("stop"), &WPNativeInput::stop);
  ClassDB::bind_method(D_METHOD("is_active"), &WPNativeInput::is_active);
  ClassDB::bind_method(D_METHOD("drain"), &WPNativeInput::drain);
  ClassDB::bind_method(D_METHOD("get_record_stride"),
                       &WPNativeInput::get_record_stride);
  ClassDB::bind_method(D_METHOD("native_now"), &WPNativeInput::native_now);
  ClassDB::bind_method(D_METHOD("get_view_metrics"),
                       &WPNativeInput::get_view_metrics);
  ClassDB::bind_method(D_METHOD("get_capabilities"),
                       &WPNativeInput::get_capabilities);
  ClassDB::bind_method(D_METHOD("cancel_all", "reason_code"),
                       &WPNativeInput::cancel_all);
  ClassDB::bind_method(D_METHOD("get_diagnostics"),
                       &WPNativeInput::get_diagnostics);
  ClassDB::bind_method(D_METHOD("get_platform_info"),
                       &WPNativeInput::get_platform_info);
}
