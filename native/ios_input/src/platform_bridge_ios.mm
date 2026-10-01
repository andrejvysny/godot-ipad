// iOS bridge: a passive UIGestureRecognizer on the key window's Godot view
// records every UITouch with its native type, float point location, timestamp,
// force and tilt. Public UIKit API only: no swizzling, no private selectors, no
// Godot internals. See native/ios_input/README.md.

#include <TargetConditionals.h>

#if TARGET_OS_IOS

#include "platform_bridge.h"
#include "touch_record_queue.h"

#include <algorithm>
#include <cmath>
#include <sys/utsname.h>

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <UIKit/UIKit.h>

namespace {

int wp_source_for_touch(UITouch *p_touch) {
  switch (p_touch.type) {
  case UITouchTypePencil:
    return wpni::SOURCE_PENCIL;
  case UITouchTypeDirect:
    return wpni::SOURCE_FINGER;
  default:
    return wpni::SOURCE_UNKNOWN; // indirect / indirectPointer: never guessed as
                                 // Pencil
  }
}

wpni::TouchSample wp_sample_for_touch(UITouch *p_touch, UIView *p_view,
                                      uint32_t p_flags) {
  wpni::TouchSample sample;
  const CGPoint location = [p_touch locationInView:p_view];
  sample.timestamp = p_touch.timestamp;
  sample.x = location.x;
  sample.y = location.y;
  sample.flags = p_flags;
  if (p_touch.type != UITouchTypePencil) {
    return sample;
  }
  const CGFloat max_force = p_touch.maximumPossibleForce;
  const double ratio = max_force > 0.0 ? p_touch.force / max_force : NAN;
  if (std::isfinite(ratio)) {
    sample.pressure_valid = true;
    sample.pressure = std::clamp(ratio, 0.0, 1.0);
    if ((p_touch.estimatedProperties & UITouchPropertyForce) != 0) {
      sample.flags |= wpni::FLAG_FORCE_ESTIMATED;
    }
  }
  // Same convention as Godot's touch_drag tilt: azimuth unit vector scaled by
  // cos(altitude).
  const CGVector azimuth = [p_touch azimuthUnitVectorInView:p_view];
  const double horizontal = std::cos(p_touch.altitudeAngle);
  sample.tilt_valid = true;
  sample.tilt_x = azimuth.dx * horizontal;
  sample.tilt_y = azimuth.dy * horizontal;
  return sample;
}

const char *wp_idiom_name(UIUserInterfaceIdiom p_idiom) {
  switch (p_idiom) {
  case UIUserInterfaceIdiomPad:
    return "pad";
  case UIUserInterfaceIdiomPhone:
    return "phone";
  case UIUserInterfaceIdiomMac:
    return "mac";
  case UIUserInterfaceIdiomTV:
    return "tv";
  default:
    return "other";
  }
}

std::string wp_utf8(NSString *p_string) {
  const char *utf8 = p_string.UTF8String;
  return utf8 != nullptr ? std::string(utf8) : std::string();
}

UIView *wp_find_godot_view(UIView *p_root) {
  Class godot_class = NSClassFromString(@"GDTView");
  if (godot_class != Nil && [p_root isKindOfClass:godot_class]) {
    return p_root;
  }
  for (UIView *child in p_root.subviews) {
    UIView *found = wp_find_godot_view(child);
    if (found != nil) {
      return found;
    }
  }
  return nil;
}

// Godot view of the foreground window scene's key window. A scene that is still
// foreground-inactive is accepted because Godot's first frames can run before
// the launch scene becomes active; UIKit only delivers touches once it is.
UIView *wp_find_root_view(std::string &r_status) {
  UIWindowScene *active = nil;
  UIWindowScene *inactive = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    if (scene.activationState == UISceneActivationStateForegroundActive &&
        active == nil) {
      active = (UIWindowScene *)scene;
    } else if (scene.activationState ==
                   UISceneActivationStateForegroundInactive &&
               inactive == nil) {
      inactive = (UIWindowScene *)scene;
    }
  }
  UIWindowScene *scene = active != nil ? active : inactive;
  if (scene == nil) {
    r_status = "no_foreground_window_scene";
    return nil;
  }
  UIWindow *window = scene.keyWindow;
  if (window == nil) {
    r_status = "no_key_window";
    return nil;
  }
  UIView *root = window.rootViewController.view;
  if (root == nil) {
    r_status = "no_root_view_controller_view";
    return nil;
  }
  // SwiftUI's hosting view has a different contentScaleFactor from the drawable.
  // Observe the pinned engine's GDTView so point-to-pixel mapping uses its scale.
  UIView *view = wp_find_godot_view(root);
  if (view == nil) {
    r_status = "no_godot_render_view";
    return nil;
  }
  r_status = active != nil ? "attached" : "attached_scene_inactive";
  return view;
}

} // namespace

// Passive observer: it never leaves UIGestureRecognizerStatePossible, so it
// keeps receiving every touch and never cancels, delays, or excludes delivery
// to Godot's own view.
@interface WPTouchObserver : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic, assign)
    wpni::TouchRecordQueue *queue; // owned by the bridge; nullptr once detached
- (instancetype)initWithQueue:(wpni::TouchRecordQueue *)queue;
- (void)startObservingLifecycle;
- (void)stopObservingLifecycle;
@end

@implementation WPTouchObserver

- (instancetype)initWithQueue:(wpni::TouchRecordQueue *)queue {
  self = [super initWithTarget:nil action:nil];
  if (self) {
    _queue = queue;
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    self.requiresExclusiveTouchType = NO;
    self.allowedTouchTypes = @[@(UITouchTypeDirect), @(UITouchTypePencil)];
    self.delegate = self;
  }
  return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesBegan:touches withEvent:event];
  UIView *view = self.view;
  if (_queue == nullptr || view == nil) {
    return;
  }
  for (UITouch *touch in touches) {
    // Identity is fixed here, from the native touch type only.
    _queue->touch_began((__bridge const void *)touch,
                        wp_source_for_touch(touch),
                        wp_sample_for_touch(touch, view, 0));
  }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesMoved:touches withEvent:event];
  UIView *view = self.view;
  if (_queue == nullptr || view == nil) {
    return;
  }
  for (UITouch *touch in touches) {
    const void *key = (__bridge const void *)touch;
    // The coalesced list already ends with the primary touch's own sample: emit
    // each element once and never the primary touch again; all but the last are
    // intermediates.
    NSArray<UITouch *> *coalesced = [event coalescedTouchesForTouch:touch];
    const NSUInteger count = coalesced.count;
    if (count == 0) {
      _queue->touch_moved(key, wp_sample_for_touch(touch, view, 0));
      continue;
    }
    for (NSUInteger i = 0; i < count; i++) {
      const uint32_t flags = (i + 1 < count) ? wpni::FLAG_COALESCED : 0;
      _queue->touch_moved(key, wp_sample_for_touch(coalesced[i], view, flags));
    }
  }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesEnded:touches withEvent:event];
  if (_queue == nullptr) {
    return;
  }
  UIView *view = self.view;
  for (UITouch *touch in touches) {
    _queue->touch_ended((__bridge const void *)touch,
                        wp_sample_for_touch(touch, view, 0));
  }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
  [super touchesCancelled:touches withEvent:event];
  if (_queue == nullptr) {
    return;
  }
  UIView *view = self.view;
  for (UITouch *touch in touches) {
    _queue->touch_cancelled((__bridge const void *)touch,
                            wp_sample_for_touch(touch, view, 0));
  }
}

- (void)reset {
  [super reset];
  // After reset UIKit stops delivering the touches this recognizer still
  // tracks; close them here or the consumer would keep stale contacts.
  if (_queue != nullptr) {
    _queue->forget_all(wpni::CANCEL_VIEW_CHANGED, CACurrentMediaTime());
  }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
  return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
  return YES;
}

- (void)startObservingLifecycle {
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserver:self
             selector:@selector(wp_applicationWillResignActive:)
                 name:UIApplicationWillResignActiveNotification
               object:nil];
  [center addObserver:self
             selector:@selector(wp_sceneWillDeactivate:)
                 name:UISceneWillDeactivateNotification
               object:nil];
}

- (void)stopObservingLifecycle {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)wp_applicationWillResignActive:(NSNotification *)notification {
  [self wp_cancelForDeactivation];
}

- (void)wp_sceneWillDeactivate:(NSNotification *)notification {
  UIScene *own_scene = self.view.window.windowScene;
  if (own_scene != nil && notification.object != nil &&
      notification.object != own_scene) {
    return; // another window scene deactivating does not interrupt this view's
            // touches
  }
  [self wp_cancelForDeactivation];
}

- (void)wp_cancelForDeactivation {
  if (_queue != nullptr) {
    _queue->cancel_active(wpni::CANCEL_APP_DEACTIVATED, CACurrentMediaTime());
  }
}

@end

namespace wpni {

namespace {

class IOSPlatformBridge final : public PlatformBridge {
public:
  ~IOSPlatformBridge() override { stop(); }

  bool start() override {
    if (is_active()) {
      return true;
    }
    if (started_) {
      detach("restarted"); // view lost since the last start
    }
    std::string status;
    UIView *view = wp_find_root_view(status);
    attach_status_ = status;
    if (view == nil) {
      return false;
    }
    observer_ = [[WPTouchObserver alloc] initWithQueue:&queue_];
    [view addGestureRecognizer:observer_];
    [observer_ startObservingLifecycle];
    view_ = view;
    view_class_ = wp_utf8(NSStringFromClass([view class]));
    last_size_ = view.bounds.size;
    last_scale_ = view.contentScaleFactor;
    generation_ += 1; // a new observed view is a new mapping
    started_ = true;
    return true;
  }

  void stop() override {
    if (started_) {
      detach("stopped");
    }
  }

  bool is_active() override {
    UIView *view = view_;
    return started_ && view != nil && observer_ != nil &&
           observer_.view == view;
  }

  std::vector<double> drain() override {
    refresh_attachment();
    return queue_.drain();
  }

  double native_now() override { return CACurrentMediaTime(); }

  ViewMetrics view_metrics() override {
    refresh_attachment();
    ViewMetrics metrics;
    metrics.generation = generation_;
    UIView *view = view_;
    if (view == nil) {
      return metrics;
    }
    const CGSize size = view.bounds.size;
    const UIEdgeInsets insets = view.safeAreaInsets;
    metrics.width_points = size.width;
    metrics.height_points = size.height;
    metrics.content_scale = view.contentScaleFactor;
    metrics.safe_x = insets.left;
    metrics.safe_y = insets.top;
    metrics.safe_width =
        std::max(0.0, double(size.width - insets.left - insets.right));
    metrics.safe_height =
        std::max(0.0, double(size.height - insets.top - insets.bottom));
    return metrics;
  }

  Capabilities capabilities() override {
    Capabilities caps;
#if TARGET_OS_SIMULATOR
    caps.platform = "ios_simulator";
#else
    caps.platform = "ios";
#endif
    caps.supported = true;
    caps.source_identity = true;
    caps.pressure = true;
    caps.tilt = true;
    caps.coalesced = true;
    caps.native_cancel = true;
    caps.native_timestamps = true;
    return caps;
  }

  void cancel_all(int p_reason) override {
    queue_.cancel_active(p_reason, CACurrentMediaTime());
  }

  BridgeDiagnostics diagnostics() override {
    const QueueStats stats = queue_.stats();
    BridgeDiagnostics diag;
    diag.active_contacts = stats.active_contacts;
    diag.queued_records = stats.queued_records;
    diag.overflow_count = stats.overflow_count;
    diag.records_emitted = stats.records_emitted;
    diag.ignored_contacts = stats.ignored_contacts;
    diag.observer_attached = is_active();
    promote_attach_status();
    diag.attach_status = attach_status_;
    diag.observed_view_class = view_class_;
    return diag;
  }

  PlatformInfo platform_info() override {
    PlatformInfo info;
    struct utsname name;
    if (uname(&name) == 0) {
      info.machine = name.machine;
    }
    UIDevice *device = UIDevice.currentDevice;
    info.system_name = wp_utf8(device.systemName);
    info.system_version = wp_utf8(device.systemVersion);
    info.model = wp_utf8(device.model);
    info.idiom = wp_idiom_name(device.userInterfaceIdiom);
    return info;
  }

private:
  // A lost view ends the session; a resized/rescaled view invalidates the
  // mapping. Both cancel live contacts so no operation continues across the
  // change.
  void refresh_attachment() {
    if (!started_) {
      return;
    }
    UIView *view = view_;
    if (view == nil || observer_.view != view) {
      detach("view_lost");
      return;
    }
    promote_attach_status();
    const CGSize size = view.bounds.size;
    const CGFloat scale = view.contentScaleFactor;
    if (CGSizeEqualToSize(size, last_size_) && scale == last_scale_) {
      return;
    }
    last_size_ = size;
    last_scale_ = scale;
    generation_ += 1;
    queue_.cancel_active(CANCEL_VIEW_CHANGED, CACurrentMediaTime());
  }

  // start() may attach while the launch scene is still foreground-inactive
  // (see wp_find_root_view); report plain "attached" once it has activated.
  // The explicit nil check matters: ForegroundActive is 0, which is also
  // what messaging a nil scene returns.
  void promote_attach_status() {
    UIView *view = view_;
    UIWindowScene *scene = view.window.windowScene;
    if (attach_status_ == "attached_scene_inactive" && scene != nil &&
        scene.activationState == UISceneActivationStateForegroundActive) {
      attach_status_ = "attached";
    }
  }

  void detach(const char *p_status) {
    // Detaching mid-contact must still close every contact the consumer knows
    // about.
    queue_.forget_all(CANCEL_VIEW_CHANGED, CACurrentMediaTime());
    if (observer_ != nil) {
      [observer_ stopObservingLifecycle];
      observer_.queue =
          nullptr; // removal may call -reset; the queue is already closed
      [observer_.view removeGestureRecognizer:observer_];
      observer_ = nil;
    }
    view_ = nil;
    started_ = false;
    attach_status_ = p_status;
  }

  TouchRecordQueue queue_;
  WPTouchObserver *observer_ = nil;
  __weak UIView *view_ = nil;
  bool started_ = false;
  std::string attach_status_ = "not_started";
  std::string view_class_;
  CGSize last_size_ = {0.0, 0.0};
  CGFloat last_scale_ = 0.0;
  int64_t generation_ = 0;
};

} // namespace

std::unique_ptr<PlatformBridge> create_platform_bridge() {
  return std::make_unique<IOSPlatformBridge>();
}

} // namespace wpni

#endif // TARGET_OS_IOS
