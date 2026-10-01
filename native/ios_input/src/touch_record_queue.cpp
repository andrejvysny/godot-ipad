#include "touch_record_queue.h"

#include <algorithm>
#include <unordered_set>

namespace wpni {

TouchRecordQueue::Contact *TouchRecordQueue::find_locked(TouchKey p_key) {
  for (Contact &contact : contacts_) {
    if (contact.key == p_key) {
      return &contact;
    }
  }
  return nullptr;
}

void TouchRecordQueue::remove_locked(TouchKey p_key) {
  contacts_.erase(
      std::remove_if(contacts_.begin(), contacts_.end(),
                     [p_key](const Contact &c) { return c.key == p_key; }),
      contacts_.end());
}

size_t TouchRecordQueue::queued_locked() const {
  return records_.size() / RECORD_STRIDE;
}

// Returns false when the queue was full and overflowed: every contact tracked
// at that moment is now cancelled/ignored, so the caller must not append its
// record.
bool TouchRecordQueue::reserve_locked(bool p_is_cancel, double p_now) {
  const size_t limit =
      CAPACITY_RECORDS + (p_is_cancel ? CANCEL_HEADROOM_RECORDS : 0);
  if (queued_locked() < limit) {
    return true;
  }
  overflow_locked(p_now);
  return false;
}

// Queued records have not reached the consumer yet. Dropping them is only safe
// if every contact the consumer already knows (BEGIN drained) still gets
// exactly one terminal record: queued CANCELs are kept verbatim, queued ENDs
// and live contacts become CANCEL(overflow) because their strokes lost samples.
// Contacts whose BEGIN was still queued vanish whole.
void TouchRecordQueue::overflow_locked(double p_now) {
  std::unordered_set<int64_t> undelivered_begins;
  std::vector<double> kept_cancels;
  std::vector<Contact> ended_contacts;
  // Single pass is enough: a contact's BEGIN always precedes its terminal
  // record in the queue.
  for (size_t i = 0; i < records_.size(); i += RECORD_STRIDE) {
    const double *r = &records_[i];
    const int64_t id = static_cast<int64_t>(r[F_POINTER_ID]);
    if (r[F_PHASE] == PHASE_BEGIN) {
      undelivered_begins.insert(id);
    } else if (undelivered_begins.count(id) != 0) {
      continue;
    } else if (r[F_PHASE] == PHASE_CANCEL) {
      kept_cancels.insert(kept_cancels.end(), r, r + RECORD_STRIDE);
    } else if (r[F_PHASE] == PHASE_END) {
      Contact ended;
      ended.pointer_id = id;
      ended.source = static_cast<int>(r[F_SOURCE]);
      ended.last_x = r[F_X];
      ended.last_y = r[F_Y];
      ended_contacts.push_back(ended);
    }
  }
  // Kept CANCELs carry older sequence numbers, so they must precede the new
  // ones.
  records_.swap(kept_cancels);
  overflow_count_ += 1;
  // Appends below bypass the capacity check: at most one per discarded record
  // or live contact.
  for (const Contact &ended : ended_contacts) {
    append_cancel_locked(ended, CANCEL_QUEUE_OVERFLOW, p_now);
  }
  for (Contact &contact : contacts_) {
    if (!contact.ignored && undelivered_begins.count(contact.pointer_id) == 0) {
      append_cancel_locked(contact, CANCEL_QUEUE_OVERFLOW, p_now);
    }
    contact.ignored = true;
  }
}

void TouchRecordQueue::append_locked(const Contact &p_contact, int p_phase,
                                     const TouchSample &p_sample,
                                     int p_reason) {
  double r[RECORD_STRIDE] = {};
  r[F_SOURCE] = p_contact.source;
  r[F_POINTER_ID] = static_cast<double>(p_contact.pointer_id);
  r[F_PHASE] = p_phase;
  r[F_TIMESTAMP] = p_sample.timestamp;
  r[F_X] = p_sample.x;
  r[F_Y] = p_sample.y;
  r[F_PRESSURE_VALID] = p_sample.pressure_valid ? 1.0 : 0.0;
  r[F_PRESSURE] = p_sample.pressure_valid ? p_sample.pressure : 0.0;
  r[F_TILT_VALID] = p_sample.tilt_valid ? 1.0 : 0.0;
  r[F_TILT_X] = p_sample.tilt_valid ? p_sample.tilt_x : 0.0;
  r[F_TILT_Y] = p_sample.tilt_valid ? p_sample.tilt_y : 0.0;
  r[F_FLAGS] = static_cast<double>(p_sample.flags);
  r[F_SEQUENCE] = static_cast<double>(next_sequence_++);
  r[F_CANCEL_REASON] = p_phase == PHASE_CANCEL ? p_reason : CANCEL_NONE;
  records_.insert(records_.end(), r, r + RECORD_STRIDE);
  records_emitted_ += 1;
}

void TouchRecordQueue::append_cancel_locked(const Contact &p_contact,
                                            int p_reason, double p_now) {
  TouchSample sample;
  sample.timestamp = p_now;
  sample.x = p_contact.last_x;
  sample.y = p_contact.last_y;
  append_locked(p_contact, PHASE_CANCEL, sample, p_reason);
}

void TouchRecordQueue::cancel_active_locked(int p_reason, double p_now) {
  // Index loop: an overflow inside reserve_locked() flips `ignored` on later
  // contacts.
  for (size_t i = 0; i < contacts_.size(); ++i) {
    if (contacts_[i].ignored) {
      continue;
    }
    if (reserve_locked(true, p_now)) {
      append_cancel_locked(contacts_[i], p_reason, p_now);
    }
    contacts_[i].ignored = true;
  }
}

void TouchRecordQueue::touch_began(TouchKey p_key, int p_source,
                                   const TouchSample &p_sample) {
  std::lock_guard<std::mutex> lock(mutex_);
  const int64_t overflows_before = overflow_count_;
  if (Contact *stale = find_locked(p_key)) {
    // A key seen again at began means its end was never delivered; close the
    // old contact.
    if (!stale->ignored && reserve_locked(true, p_sample.timestamp)) {
      append_cancel_locked(*stale, CANCEL_VIEW_CHANGED, p_sample.timestamp);
    }
    remove_locked(p_key);
  }
  reserve_locked(false, p_sample.timestamp);
  Contact contact;
  contact.key = p_key;
  contact.pointer_id = next_pointer_id_++;
  contact.source = p_source;
  contact.last_x = p_sample.x;
  contact.last_y = p_sample.y;
  // A touch landing on an overflow is ignored until it lifts, like every
  // contact down at that instant. Starting it fresh would hand the consumer a
  // BEGIN that its overflow reaction (cancel_all) immediately cancels again.
  contact.ignored = overflow_count_ != overflows_before;
  contacts_.push_back(contact);
  if (!contact.ignored) {
    append_locked(contact, PHASE_BEGIN, p_sample, CANCEL_NONE);
  }
}

void TouchRecordQueue::touch_moved(TouchKey p_key,
                                   const TouchSample &p_sample) {
  std::lock_guard<std::mutex> lock(mutex_);
  Contact *contact = find_locked(p_key);
  if (contact == nullptr || contact->ignored ||
      !reserve_locked(false, p_sample.timestamp)) {
    return;
  }
  contact->last_x = p_sample.x;
  contact->last_y = p_sample.y;
  append_locked(*contact, PHASE_MOVE, p_sample, CANCEL_NONE);
}

void TouchRecordQueue::touch_ended(TouchKey p_key,
                                   const TouchSample &p_sample) {
  std::lock_guard<std::mutex> lock(mutex_);
  Contact *contact = find_locked(p_key);
  if (contact == nullptr) {
    return;
  }
  // A full queue turns this END into the overflow CANCEL: the stroke lost
  // samples.
  if (!contact->ignored && reserve_locked(false, p_sample.timestamp)) {
    append_locked(*contact, PHASE_END, p_sample, CANCEL_NONE);
  }
  remove_locked(p_key);
}

void TouchRecordQueue::touch_cancelled(TouchKey p_key,
                                       const TouchSample &p_sample) {
  std::lock_guard<std::mutex> lock(mutex_);
  Contact *contact = find_locked(p_key);
  if (contact == nullptr) {
    return;
  }
  if (!contact->ignored && reserve_locked(true, p_sample.timestamp)) {
    append_locked(*contact, PHASE_CANCEL, p_sample, CANCEL_NATIVE);
  }
  remove_locked(p_key);
}

void TouchRecordQueue::cancel_active(int p_reason, double p_now) {
  std::lock_guard<std::mutex> lock(mutex_);
  cancel_active_locked(p_reason, p_now);
}

void TouchRecordQueue::forget_all(int p_reason, double p_now) {
  std::lock_guard<std::mutex> lock(mutex_);
  cancel_active_locked(p_reason, p_now);
  contacts_.clear();
}

std::vector<double> TouchRecordQueue::drain() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<double> out;
  out.swap(records_);
  return out;
}

QueueStats TouchRecordQueue::stats() const {
  std::lock_guard<std::mutex> lock(mutex_);
  QueueStats s;
  for (const Contact &contact : contacts_) {
    if (contact.ignored) {
      s.ignored_contacts += 1;
    } else {
      s.active_contacts += 1;
    }
  }
  s.queued_records = static_cast<int64_t>(queued_locked());
  s.overflow_count = overflow_count_;
  s.records_emitted = records_emitted_;
  return s;
}

} // namespace wpni
