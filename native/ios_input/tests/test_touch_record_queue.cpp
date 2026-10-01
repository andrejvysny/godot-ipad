// Host regression test for TouchRecordQueue, the contact/overflow policy behind
// WPNativeInput (spec §6.4, IN-10). Pure C++, no UIKit: run with
// `native/ios_input/build.sh test` (built with ASan/UBSan).
#include "touch_record_queue.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <vector>

using namespace wpni;

namespace {

int failures = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);            \
      failures++;                                                              \
    }                                                                          \
  } while (0)

struct Rec {
  int source;
  long id;
  int phase;
  double t, x, y;
  int flags;
  long seq;
  int reason;
};

std::vector<Rec> parse(const std::vector<double> &p_flat) {
  std::vector<Rec> out;
  CHECK(p_flat.size() % RECORD_STRIDE == 0);
  for (size_t i = 0; i + RECORD_STRIDE <= p_flat.size(); i += RECORD_STRIDE) {
    const double *r = &p_flat[i];
    out.push_back({(int)r[F_SOURCE], (long)r[F_POINTER_ID], (int)r[F_PHASE],
                   r[F_TIMESTAMP], r[F_X], r[F_Y], (int)r[F_FLAGS],
                   (long)r[F_SEQUENCE], (int)r[F_CANCEL_REASON]});
  }
  return out;
}

TouchSample sample(double p_t, double p_x, double p_y, uint32_t p_flags = 0) {
  TouchSample s;
  s.timestamp = p_t;
  s.x = p_x;
  s.y = p_y;
  s.flags = p_flags;
  return s;
}

// What the GDScript side relies on: every delivered BEGIN gets exactly one
// terminal, no record for an unseen id, strictly increasing sequence.
struct Consumer {
  std::set<long> open;
  std::set<long> closed;
  long last_seq = 0;
  int violations = 0;

  void feed(const std::vector<Rec> &p_records) {
    for (const Rec &r : p_records) {
      if (r.seq <= last_seq) {
        violations++;
      }
      last_seq = r.seq;
      if (r.phase == PHASE_BEGIN) {
        if (open.count(r.id) != 0 || closed.count(r.id) != 0) {
          violations++;
        }
        open.insert(r.id);
        continue;
      }
      if (open.count(r.id) == 0) {
        violations++; // MOVE/END/CANCEL for an id the consumer never saw open
      }
      if (r.phase != PHASE_MOVE) {
        open.erase(r.id);
        closed.insert(r.id);
      }
    }
  }
};

void fill_moves(TouchRecordQueue &p_queue, const void *p_key, int p_count) {
  for (int i = 0; i < p_count; i++) {
    p_queue.touch_moved(p_key, sample(1 + i * 0.001, i, i));
  }
}

void test_lifecycle_identity_and_flags() {
  TouchRecordQueue q;
  int k1 = 0;
  q.touch_began(&k1, SOURCE_PENCIL, sample(1.0, 10.5, 20.25));
  q.touch_moved(&k1, sample(1.1, 11, 21, FLAG_COALESCED));
  q.touch_moved(&k1, sample(1.2, 12, 22));
  q.touch_ended(&k1, sample(1.3, 13, 23));
  const std::vector<Rec> r = parse(q.drain());
  CHECK(r.size() == 4);
  if (r.size() != 4) {
    return;
  }
  CHECK(r[0].phase == PHASE_BEGIN && r[0].source == SOURCE_PENCIL &&
        r[0].id == 1 && r[0].x == 10.5 && r[0].y == 20.25);
  CHECK(r[1].flags == FLAG_COALESCED && r[2].flags == 0);
  CHECK(r[3].phase == PHASE_END && r[3].source == SOURCE_PENCIL &&
        r[3].reason == CANCEL_NONE);
  CHECK(r[0].seq == 1 && r[3].seq == 4);
  CHECK(q.stats().active_contacts == 0 && q.drain().empty());
}

void test_major_radius_field() {
  CHECK(RECORD_STRIDE == 15 && F_MAJOR_RADIUS == 14);
  TouchRecordQueue q;
  int k1 = 0;
  TouchSample with_radius = sample(1.0, 1, 1);
  with_radius.radius_valid = true;
  with_radius.major_radius = 22.5;
  q.touch_began(&k1, SOURCE_FINGER, with_radius);
  q.touch_moved(&k1, sample(1.1, 2, 2));  // radius unknown
  const std::vector<double> flat = q.drain();
  CHECK(flat.size() == 2 * RECORD_STRIDE);
  if (flat.size() == 2 * RECORD_STRIDE) {
    CHECK(flat[F_MAJOR_RADIUS] == 22.5);
    CHECK(std::isnan(flat[RECORD_STRIDE + F_MAJOR_RADIUS]));
  }
}

void test_native_cancel_is_never_an_end() {
  TouchRecordQueue q;
  int k1 = 0;
  q.touch_began(&k1, SOURCE_FINGER, sample(1, 0, 0));
  q.touch_cancelled(&k1, sample(2, 5, 5));
  const std::vector<Rec> r = parse(q.drain());
  CHECK(r.size() == 2 && r[1].phase == PHASE_CANCEL &&
        r[1].reason == CANCEL_NATIVE && r[1].source == SOURCE_FINGER);
}

void test_cancel_active_then_ignored_until_lift() {
  TouchRecordQueue q;
  int k1 = 0, k2 = 0;
  q.touch_began(&k1, SOURCE_PENCIL, sample(1, 1, 1));
  q.touch_began(&k2, SOURCE_FINGER, sample(1, 2, 2));
  q.touch_moved(&k1, sample(1.5, 3, 3));
  q.cancel_active(CANCEL_APP_DEACTIVATED, 9.0);
  CHECK(q.stats().ignored_contacts == 2 && q.stats().active_contacts == 0);
  q.touch_moved(&k1, sample(2, 4, 4));
  q.touch_ended(&k1, sample(3, 4, 4));
  q.touch_cancelled(&k2, sample(3, 4, 4));
  const std::vector<Rec> r = parse(q.drain());
  CHECK(r.size() == 5);
  if (r.size() == 5) {
    CHECK(r[3].phase == PHASE_CANCEL && r[3].id == 1 &&
          r[3].reason == CANCEL_APP_DEACTIVATED && r[3].t == 9.0 &&
          r[3].x == 3);
    CHECK(r[4].phase == PHASE_CANCEL && r[4].id == 2 &&
          r[4].reason == CANCEL_APP_DEACTIVATED);
  }
  CHECK(q.stats().ignored_contacts == 0);
  q.cancel_active(CANCEL_EXPLICIT, 10);
  CHECK(q.drain().empty());
}

void test_forget_all_and_stale_key() {
  TouchRecordQueue q;
  int k1 = 0, k2 = 0;
  q.touch_began(&k1, SOURCE_PENCIL, sample(1, 1, 1));
  q.touch_began(&k1, SOURCE_FINGER, sample(2, 7, 7)); // end never delivered
  q.touch_began(&k2, SOURCE_UNKNOWN, sample(3, 1, 1));
  q.forget_all(CANCEL_VIEW_CHANGED, 4);
  const std::vector<Rec> r = parse(q.drain());
  CHECK(r.size() == 6);
  if (r.size() == 6) {
    CHECK(r[1].phase == PHASE_CANCEL && r[1].id == 1 &&
          r[1].reason == CANCEL_VIEW_CHANGED);
    CHECK(r[2].phase == PHASE_BEGIN && r[2].id == 2 &&
          r[2].source == SOURCE_FINGER);
    CHECK(r[5].phase == PHASE_CANCEL && r[5].source == SOURCE_UNKNOWN);
  }
  CHECK(q.stats().active_contacts == 0 && q.stats().ignored_contacts == 0);
  q.touch_ended(&k1, sample(5, 1, 1)); // untracked after forget_all
  CHECK(q.drain().empty());
}

void test_overflow_cancels_delivered_contact_and_keeps_ending() {
  TouchRecordQueue q;
  Consumer c;
  int k1 = 0, k2 = 0;
  q.touch_began(&k1, SOURCE_PENCIL, sample(0, 0, 0));
  q.touch_began(&k2, SOURCE_FINGER, sample(0, 0, 0));
  c.feed(parse(q.drain()));
  q.touch_ended(&k2, sample(0.5, 9, 9)); // queued END of a delivered contact
  fill_moves(q, &k1, 4095);
  CHECK(q.stats().queued_records == 4096 && q.stats().overflow_count == 0);
  q.touch_moved(&k1, sample(10, 1, 1));
  CHECK(q.stats().overflow_count == 1);
  const std::vector<Rec> r = parse(q.drain());
  c.feed(r);
  CHECK(r.size() == 2);
  for (const Rec &x : r) {
    CHECK(x.phase == PHASE_CANCEL && x.reason == CANCEL_QUEUE_OVERFLOW);
  }
  q.touch_moved(&k1, sample(11, 1, 1));
  q.touch_ended(&k1, sample(12, 1, 1));
  CHECK(q.drain().empty());
  CHECK(c.violations == 0 && c.open.empty());
}

void test_overflow_drops_undelivered_contacts_whole() {
  TouchRecordQueue q;
  Consumer c;
  int k1 = 0;
  q.touch_began(&k1, SOURCE_PENCIL, sample(0, 0, 0));
  fill_moves(q, &k1, 5000);
  const std::vector<Rec> r = parse(q.drain());
  c.feed(r);
  CHECK(r.empty());
  CHECK(q.stats().ignored_contacts == 1);
  q.touch_ended(&k1, sample(9, 0, 0));
  CHECK(q.drain().empty() && q.stats().ignored_contacts == 0);
  CHECK(c.violations == 0);
}

// Regression (review finding): a touch whose began triggers the overflow must
// not start fresh. The provider reports the overflow, the input system reacts
// with cancel_all, and a fresh contact would come back as CANCEL(explicit).
void test_began_that_overflows_is_ignored_until_lift() {
  TouchRecordQueue q;
  Consumer c;
  int k1 = 0, k2 = 0;
  q.touch_began(&k1, SOURCE_PENCIL, sample(0, 0, 0));
  c.feed(parse(q.drain()));
  fill_moves(q, &k1, 4096);
  q.touch_began(&k2, SOURCE_FINGER, sample(5, 50, 50)); // overflows
  CHECK(q.stats().overflow_count == 1);
  CHECK(q.stats().active_contacts == 0 && q.stats().ignored_contacts == 2);
  q.cancel_active(CANCEL_EXPLICIT, 6); // the input system's reaction
  q.touch_moved(&k2, sample(7, 51, 51));
  const std::vector<Rec> r = parse(q.drain());
  c.feed(r);
  CHECK(r.size() == 1);
  if (r.size() == 1) {
    CHECK(r[0].id == 1 && r[0].phase == PHASE_CANCEL &&
          r[0].reason == CANCEL_QUEUE_OVERFLOW);
  }
  q.touch_ended(&k2, sample(8, 52, 52));
  q.touch_ended(&k1, sample(8, 1, 1));
  CHECK(q.drain().empty());
  CHECK(q.stats().active_contacts == 0 && q.stats().ignored_contacts == 0);
  int k3 = 0;
  q.touch_began(&k3, SOURCE_PENCIL, sample(9, 0, 0)); // after the overflow
  const std::vector<Rec> fresh = parse(q.drain());
  c.feed(fresh);
  CHECK(fresh.size() == 1 && fresh[0].phase == PHASE_BEGIN);
  CHECK(c.violations == 0);
}

// The stale contact's CANCEL fits the headroom, then the new BEGIN overflows:
// the stale CANCEL survives verbatim and the new touch is ignored.
void test_stale_key_then_overflow_ignores_new_contact() {
  TouchRecordQueue q;
  Consumer c;
  int k = 0;
  q.touch_began(&k, SOURCE_PENCIL, sample(0, 0, 0));
  c.feed(parse(q.drain()));
  fill_moves(q, &k, 4096);
  q.touch_began(&k, SOURCE_FINGER, sample(5, 0, 0)); // end never delivered
  CHECK(q.stats().overflow_count == 1);
  CHECK(q.stats().active_contacts == 0 && q.stats().ignored_contacts == 1);
  const std::vector<Rec> r = parse(q.drain());
  c.feed(r);
  CHECK(r.size() == 1);
  if (r.size() == 1) {
    CHECK(r[0].id == 1 && r[0].phase == PHASE_CANCEL &&
          r[0].reason == CANCEL_VIEW_CHANGED);
  }
  q.touch_ended(&k, sample(6, 0, 0));
  CHECK(q.drain().empty() && q.stats().ignored_contacts == 0);
  CHECK(c.violations == 0 && c.open.empty());
}

void test_cancel_headroom() {
  TouchRecordQueue q;
  Consumer c;
  int keys[100] = {};
  for (int i = 0; i < 100; i++) {
    q.touch_began(&keys[i], SOURCE_FINGER, sample(0, 0, 0));
  }
  c.feed(parse(q.drain()));
  fill_moves(q, &keys[0], 4096);
  q.cancel_active(CANCEL_EXPLICIT, 2);
  CHECK(q.stats().overflow_count == 1);
  const std::vector<Rec> r = parse(q.drain());
  c.feed(r);
  CHECK(r.size() == 100);
  int explicit_count = 0;
  for (const Rec &x : r) {
    explicit_count += x.reason == CANCEL_EXPLICIT ? 1 : 0;
  }
  CHECK(explicit_count == (int)TouchRecordQueue::CANCEL_HEADROOM_RECORDS);
  CHECK(c.violations == 0 && c.open.empty());
}

bool fuzz_round(int p_round, long &r_overflows) {
  TouchRecordQueue q;
  Consumer c;
  int keys[8] = {};
  std::map<int, bool> down;
  for (int step = 0; step < 20000; step++) {
    const int k = rand() % 8;
    const int op = rand() % 100;
    if (!down[k] && op < 3) {
      q.touch_began(&keys[k], rand() % 3, sample(step, 0, 0));
      down[k] = true;
    } else if (down[k] && op < 90) {
      q.touch_moved(&keys[k], sample(step, 1, 1));
    } else if (down[k] && op < 93) {
      q.touch_ended(&keys[k], sample(step, 1, 1));
      down[k] = false;
    } else if (down[k] && op < 94) {
      q.touch_cancelled(&keys[k], sample(step, 1, 1));
      down[k] = false;
    } else if (op == 94 && rand() % 50 == 0) {
      q.cancel_active(1 + rand() % 5, step);
    } else if (op == 95 && rand() % 200 == 0) {
      q.forget_all(CANCEL_VIEW_CHANGED, step);
      down.clear();
    }
    if (rand() % (p_round % 2 ? 50 : 6000) == 0) {
      c.feed(parse(q.drain()));
    }
  }
  for (const auto &entry : down) {
    if (entry.second) {
      q.touch_ended(&keys[entry.first], sample(1e9, 0, 0));
    }
  }
  c.feed(parse(q.drain()));
  const QueueStats st = q.stats();
  r_overflows += st.overflow_count;
  return c.violations == 0 && c.open.empty() && st.active_contacts == 0 &&
         st.ignored_contacts == 0;
}

void test_fuzz_consumer_invariant() {
  srand(1234);
  long overflows = 0;
  for (int round = 0; round < 200; round++) {
    if (!fuzz_round(round, overflows)) {
      std::printf("  fuzz round %d broke the consumer invariant\n", round);
      failures++;
      return;
    }
  }
  CHECK(overflows > 0); // the fuzz must actually exercise overflow
  std::printf("  fuzz: 200 rounds, %ld overflows\n", overflows);
}

} // namespace

int main() {
  struct Case {
    const char *name;
    void (*fn)();
  };
  const Case cases[] = {
      {"lifecycle_identity_and_flags", test_lifecycle_identity_and_flags},
      {"major_radius_field", test_major_radius_field},
      {"native_cancel_is_never_an_end", test_native_cancel_is_never_an_end},
      {"cancel_active_then_ignored_until_lift",
       test_cancel_active_then_ignored_until_lift},
      {"forget_all_and_stale_key", test_forget_all_and_stale_key},
      {"overflow_cancels_delivered_contact_and_keeps_ending",
       test_overflow_cancels_delivered_contact_and_keeps_ending},
      {"overflow_drops_undelivered_contacts_whole",
       test_overflow_drops_undelivered_contacts_whole},
      {"began_that_overflows_is_ignored_until_lift",
       test_began_that_overflows_is_ignored_until_lift},
      {"stale_key_then_overflow_ignores_new_contact",
       test_stale_key_then_overflow_ignores_new_contact},
      {"cancel_headroom", test_cancel_headroom},
      {"fuzz_consumer_invariant", test_fuzz_consumer_invariant},
  };
  int failed_cases = 0;
  for (const Case &c : cases) {
    const int before = failures;
    c.fn();
    const bool ok = failures == before;
    failed_cases += ok ? 0 : 1;
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", c.name);
  }
  const int total = (int)(sizeof(cases) / sizeof(cases[0]));
  std::printf("%d tests, %d failures\n", total, failed_cases);
  return failed_cases == 0 ? 0 : 1;
}
