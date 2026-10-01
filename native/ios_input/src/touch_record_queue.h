#pragma once

// Contact tracking and the bounded record queue behind WPNativeInput. Pure C++
// (no UIKit, no godot-cpp) so the contact/overflow policy compiles and can be
// exercised on any host. Record layout: native/ios_input/README.md "Record
// layout".

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace wpni {

enum Source : int {
  SOURCE_UNKNOWN = 0,
  SOURCE_PENCIL = 1,
  SOURCE_FINGER = 2,
};

enum Phase : int {
  PHASE_BEGIN = 0,
  PHASE_MOVE = 1,
  PHASE_END = 2,
  PHASE_CANCEL = 3,
};

enum CancelReason : int {
  CANCEL_NONE = 0,
  CANCEL_NATIVE = 1,          // UIKit touchesCancelled
  CANCEL_APP_DEACTIVATED = 2, // app resign active / scene will deactivate
  CANCEL_QUEUE_OVERFLOW = 3,
  CANCEL_EXPLICIT = 4, // cancel_all() from the app
  CANCEL_VIEW_CHANGED =
      5, // view metrics changed, observer reset/detached with live contacts
};

enum Flag : uint32_t {
  FLAG_COALESCED =
      1u << 0, // intermediate sample from coalescedTouchesForTouch:
  FLAG_PREDICTED =
      1u << 1, // reserved; the bridge never emits predicted samples
  FLAG_FORCE_ESTIMATED = 1u << 2,
};

// Offsets of the float64 fields inside one record.
enum Field : int {
  F_SOURCE = 0,
  F_POINTER_ID,
  F_PHASE,
  F_TIMESTAMP,
  F_X,
  F_Y,
  F_PRESSURE_VALID,
  F_PRESSURE,
  F_TILT_VALID,
  F_TILT_X,
  F_TILT_Y,
  F_FLAGS,
  F_SEQUENCE,
  F_CANCEL_REASON,
  F_MAJOR_RADIUS, // points; NaN when unknown
  RECORD_STRIDE,  // 15
};

struct TouchSample {
  double timestamp =
      0.0; // seconds, UITouch.timestamp clock (== CACurrentMediaTime clock)
  double x = 0.0; // points in the observed view
  double y = 0.0;
  bool pressure_valid = false;
  double pressure = 0.0; // [0, 1]
  bool tilt_valid = false;
  double tilt_x = 0.0;
  double tilt_y = 0.0;
  uint32_t flags = 0;
  bool radius_valid = false;
  double major_radius = 0.0; // UITouch.majorRadius, points
};

struct QueueStats {
  int64_t active_contacts = 0;
  int64_t ignored_contacts = 0;
  int64_t queued_records = 0;
  int64_t overflow_count = 0;
  int64_t records_emitted = 0;
};

// Invariant: every contact whose BEGIN reached the consumer receives exactly
// one terminal record (END or CANCEL). Contacts cancelled by the bridge become
// "ignored": they emit nothing further and are only forgotten when UIKit
// ends/cancels them (or the observer resets). An overflow ignores every contact
// tracked at that instant, including a touch whose began triggered it (that
// touch emits no records at all).
class TouchRecordQueue {
public:
  using TouchKey = const void *; // UITouch identity; never dereferenced

  static constexpr size_t CAPACITY_RECORDS = 4096;
  static constexpr size_t CANCEL_HEADROOM_RECORDS = 64;

  void touch_began(TouchKey p_key, int p_source, const TouchSample &p_sample);
  void touch_moved(TouchKey p_key, const TouchSample &p_sample);
  void touch_ended(TouchKey p_key, const TouchSample &p_sample);
  void touch_cancelled(TouchKey p_key, const TouchSample &p_sample);

  // CANCEL every live contact with p_reason and ignore it until UIKit ends it.
  void cancel_active(int p_reason, double p_now);
  // cancel_active(), then drop all tracking: UIKit will deliver nothing more
  // for these touches.
  void forget_all(int p_reason, double p_now);

  std::vector<double> drain();
  QueueStats stats() const;

private:
  struct Contact {
    TouchKey key = nullptr;
    int64_t pointer_id = 0;
    int source = SOURCE_UNKNOWN;
    bool ignored = false;
    double last_x = 0.0;
    double last_y = 0.0;
  };

  Contact *find_locked(TouchKey p_key);
  void remove_locked(TouchKey p_key);
  size_t queued_locked() const;
  bool reserve_locked(bool p_is_cancel, double p_now);
  void overflow_locked(double p_now);
  void cancel_active_locked(int p_reason, double p_now);
  void append_locked(const Contact &p_contact, int p_phase,
                     const TouchSample &p_sample, int p_reason);
  void append_cancel_locked(const Contact &p_contact, int p_reason,
                            double p_now);

  mutable std::mutex mutex_;
  std::vector<Contact>
      contacts_; // few live contacts; insertion order == pointer_id order
  std::vector<double> records_;
  int64_t next_pointer_id_ = 1;
  int64_t next_sequence_ = 1;
  int64_t overflow_count_ = 0;
  int64_t records_emitted_ = 0;
};

} // namespace wpni
