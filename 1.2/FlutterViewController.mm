// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define FML_USED_ON_EMBEDDER

#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformViews_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterViewController_Internal.h"

#include <memory>

#include "flutter/fml/memory/weak_ptr.h"
#include "flutter/fml/message_loop.h"
#include "flutter/fml/platform/darwin/platform_version.h"
#include "flutter/fml/platform/darwin/scoped_nsobject.h"
#include "flutter/shell/common/thread_host.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine_Internal.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformPlugin.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputDelegate.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputPlugin.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterView.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/platform_message_response_darwin.h"
#include "flutter/shell/platform/darwin/ios/platform_view_ios.h"

@implementation FlutterViewController {
  std::unique_ptr<fml::WeakPtrFactory<FlutterViewController>> _weakFactory;
  fml::scoped_nsobject<FlutterEngine> _engine;

  // We keep a separate reference to this and create it ahead of time because we want to be able to
  // setup a shell along with its platform view before the view has to appear.
  fml::scoped_nsobject<FlutterView> _flutterView;
  fml::scoped_nsobject<UIView> _splashScreenView;
  fml::ScopedBlock<void (^)(void)> _flutterViewRenderedCallback;
  UIInterfaceOrientationMask _orientationPreferences;
  UIStatusBarStyle _statusBarStyle;
  blink::ViewportMetrics _viewportMetrics;
  BOOL _initialized;
  BOOL _viewOpaque;
  BOOL _engineNeedsLaunch;
}

#pragma mark - Manage and override all designated initializers

- (instancetype)initWithEngine:(FlutterEngine*)engine
                       nibName:(NSString*)nibNameOrNil
                        bundle:(NSBundle*)nibBundleOrNil {
  NSAssert(engine != nil, @"Engine is required");
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if (self) {
    _viewOpaque = YES;
    _engine.reset([engine retain]);
    _engineNeedsLaunch = NO;
    _flutterView.reset([[FlutterView alloc] initWithDelegate:_engine opaque:self.isViewOpaque]);
    _weakFactory = std::make_unique<fml::WeakPtrFactory<FlutterViewController>>(self);

    [self performCommonViewControllerInitialization];
    [engine setViewController:self];
  }

  return self;
}

- (instancetype)initWithProject:(FlutterDartProject*)projectOrNil
                        nibName:(NSString*)nibNameOrNil
                         bundle:(NSBundle*)nibBundleOrNil {
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if (self) {
    _viewOpaque = YES;
    _weakFactory = std::make_unique<fml::WeakPtrFactory<FlutterViewController>>(self);
    _engine.reset([[FlutterEngine alloc] initWithName:@"io.flutter"
                                              project:projectOrNil
                               allowHeadlessExecution:NO]);
    _flutterView.reset([[FlutterView alloc] initWithDelegate:_engine opaque:self.isViewOpaque]);
    [_engine.get() createShell:nil libraryURI:nil];
    _engineNeedsLaunch = YES;
    [self loadDefaultSplashScreenView];
    [self performCommonViewControllerInitialization];
  }

  return self;
}

- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (instancetype)initWithCoder:(NSCoder*)aDecoder {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (instancetype)init {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (BOOL)isViewOpaque {
  return _viewOpaque;
}

- (void)setViewOpaque:(BOOL)value {
  _viewOpaque = value;
  if (_flutterView.get().layer.opaque != value) {
    _flutterView.get().layer.opaque = value;
    [_flutterView.get().layer setNeedsLayout];
  }
}

#pragma mark - Common view controller initialization tasks

- (void)performCommonViewControllerInitialization {
  if (_initialized)
    return;

  _initialized = YES;

  _orientationPreferences = UIInterfaceOrientationMaskAll;
  _statusBarStyle = UIStatusBarStyleDefault;

  [self setupNotificationCenterObservers];
}

- (FlutterEngine*)engine {
  return _engine.get();
}

- (fml::WeakPtr<FlutterViewController>)getWeakPtr {
  return _weakFactory->GetWeakPtr();
}

- (void)setupNotificationCenterObservers {
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(onOrientationPreferencesUpdated:)
                 name:@(shell::kOrientationUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(onPreferredStatusBarStyleUpdated:)
                 name:@(shell::kOverlayStyleUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(applicationBecameActive:)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationWillResignActive:)
                 name:UIApplicationWillResignActiveNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationDidEnterBackground:)
                 name:UIApplicationDidEnterBackgroundNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationWillEnterForeground:)
                 name:UIApplicationWillEnterForegroundNotification
               object:nil];

  [center addObserver:self
             selector:@selector(keyboardWillChangeFrame:)
                 name:UIKeyboardWillChangeFrameNotification
               object:nil];

  [center addObserver:self
             selector:@selector(keyboardWillBeHidden:)
                 name:UIKeyboardWillHideNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onLocaleUpdated:)
                 name:NSCurrentLocaleDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityVoiceOverStatusChanged
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilitySwitchControlStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilitySpeakScreenStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityInvertColorsStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityReduceMotionStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityBoldTextStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onMemoryWarning:)
                 name:UIApplicationDidReceiveMemoryWarningNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onUserSettingsChanged:)
                 name:UIContentSizeCategoryDidChangeNotification
               object:nil];
}

- (void)setInitialRoute:(NSString*)route {
  [[_engine.get() navigationChannel] invokeMethod:@"setInitialRoute" arguments:route];
}

- (void)popRoute {
  [[_engine.get() navigationChannel] invokeMethod:@"popRoute" arguments:nil];
}

- (void)pushRoute:(NSString*)route {
  [[_engine.get() navigationChannel] invokeMethod:@"pushRoute" arguments:route];
}

#pragma mark - Loading the view

- (void)loadView {
  self.view = _flutterView.get();
  self.view.multipleTouchEnabled = YES;
  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  [self installSplashScreenViewIfNecessary];
}

#pragma mark - Managing launch views

- (void)installSplashScreenViewIfNecessary {
  // Show the launch screen view again on top of the FlutterView if available.
  // This launch screen view will be removed once the first Flutter frame is rendered.
  if (_splashScreenView && (self.isBeingPresented || self.isMovingToParentViewController)) {
    [_splashScreenView.get() removeFromSuperview];
    _splashScreenView.reset();
    return;
  }

  // Use the property getter to initialize the default value.
  UIView* splashScreenView = self.splashScreenView;
  if (splashScreenView == nil) {
    return;
  }
  splashScreenView.frame = self.view.bounds;
  [self.view addSubview:splashScreenView];
}

- (void)removeSplashScreenViewIfPresent {
  if (!_splashScreenView) {
    return;
  }

  [UIView animateWithDuration:0.2
      animations:^{
        _splashScreenView.get().alpha = 0;
      }
      completion:^(BOOL finished) {
        [_splashScreenView.get() removeFromSuperview];
        _splashScreenView.reset();
        if (_flutterViewRenderedCallback != nil) {
          _flutterViewRenderedCallback.get()();
          _flutterViewRenderedCallback.reset();
        }
      }];
}

- (void)installSplashScreenViewCallback {
  if (!_splashScreenView) {
    return;
  }
  auto weak_platform_view = [_engine.get() platformView];
  if (!weak_platform_view) {
    return;
  }
  __unsafe_unretained auto weak_flutter_view_controller = self;
  // This is on the platform thread.
  weak_platform_view->SetNextFrameCallback([weak_platform_view, weak_flutter_view_controller,
                                            task_runner = [_engine.get() platformTaskRunner]]() {
    // This is on the GPU thread.
    task_runner->PostTask([weak_platform_view, weak_flutter_view_controller]() {
      // We check if the weak platform view is alive. If it is alive, then the view controller
      // also has to be alive since the view controller owns the platform view via the shell
      // association. Thus, we are not convinced that the unsafe unretained weak object is in
      // fact alive.
      if (weak_platform_view) {
        [weak_flutter_view_controller removeSplashScreenViewIfPresent];
      }
    });
  });
}

#pragma mark - Properties

- (FlutterView*)flutterView {
  return _flutterView;
}

- (UIView*)splashScreenView {
  if (!_splashScreenView) {
    return nil;
  }
  return _splashScreenView.get();
}

- (BOOL)loadDefaultSplashScreenView {
  NSString* launchscreenName =
      [[[NSBundle mainBundle] infoDictionary] objectForKey:@"UILaunchStoryboardName"];
  if (launchscreenName == nil) {
    return NO;
  }
  UIView* splashView = [self splashScreenFromStoryboard:launchscreenName];
  if (!splashView) {
    splashView = [self splashScreenFromXib:launchscreenName];
  }
  if (!splashView) {
    return NO;
  }
  self.splashScreenView = splashView;
  return YES;
}

- (UIView*)splashScreenFromStoryboard:(NSString*)name {
  UIStoryboard* storyboard = nil;
  @try {
    storyboard = [UIStoryboard storyboardWithName:name bundle:nil];
  } @catch (NSException* exception) {
    return nil;
  }
  if (storyboard) {
    UIViewController* splashScreenViewController = [storyboard instantiateInitialViewController];
    return splashScreenViewController.view;
  }
  return nil;
}

- (UIView*)splashScreenFromXib:(NSString*)name {
  NSArray* objects = [[NSBundle mainBundle] loadNibNamed:name owner:self options:nil];
  if ([objects count] != 0) {
    UIView* view = [objects objectAtIndex:0];
    return view;
  }
  return nil;
}

- (void)setSplashScreenView:(UIView*)view {
  if (!view) {
    // Special case: user wants to remove the splash screen view.
    [self removeSplashScreenViewIfPresent];
    _splashScreenView.reset();
    return;
  }

  _splashScreenView.reset([view retain]);
  _splashScreenView.get().autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

- (void)setFlutterViewDidRenderCallback:(void (^)(void))callback {
  _flutterViewRenderedCallback.reset(callback, fml::OwnershipPolicy::Retain);
}

#pragma mark - Surface creation and teardown updates

- (void)surfaceUpdated:(BOOL)appeared {
  // NotifyCreated/NotifyDestroyed are synchronous and require hops between the UI and GPU thread.
  if (appeared) {
    [self installSplashScreenViewCallback];
    [_engine.get() platformViewsController] -> SetFlutterView(_flutterView.get());
    [_engine.get() platformView] -> NotifyCreated();
  } else {
    [_engine.get() platformView] -> NotifyDestroyed();
    [_engine.get() platformViewsController] -> SetFlutterView(nullptr);
  }
}

#pragma mark - UIViewController lifecycle notifications

- (void)viewWillAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewWillAppear");
   NSLog(@"%s",__FUNCTION__);
    
  if (_engineNeedsLaunch) {
    [_engine.get() launchEngine:nil libraryURI:nil];
    [_engine.get() setViewController:self];
    _engineNeedsLaunch = NO;
  }

  // Only recreate surface on subsequent appearances when viewport metrics are known.
  // First time surface creation is done on viewDidLayoutSubviews.
  if (_viewportMetrics.physical_width)
    [self surfaceUpdated:YES];
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.inactive"];

  [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewDidAppear");
  NSLog(@"%s",__FUNCTION__);
    
  [self onLocaleUpdated:nil];
  [self onUserSettingsChanged:nil];
  [self onAccessibilityStatusChanged:nil];
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.resumed"];

  [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewWillDisappear");
  NSLog(@"%s",__FUNCTION__);
  
  [[[UIApplication sharedApplication] keyWindow] endEditing:YES];

  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.inactive"];

  [super viewWillDisappear:animated];
}



- (FlutterEngine *)getEngine{
    return [self engine];
}

- (void)clearChannels {
    [[[UIApplication sharedApplication] keyWindow] endEditing:YES];
    //    [_engine.get() clearChannels];
}


- (void)viewDidDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewDidDisappear");
  NSLog(@"%s",__FUNCTION__);
  [self surfaceUpdated:NO];
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.paused"];
  [super viewDidDisappear:animated];
}

- (void)dealloc {
  NSLog(@"%s",__FUNCTION__);
  [_engine.get() notifyViewControllerDeallocated];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super dealloc];
}

#pragma mark - Application lifecycle notifications

- (void)applicationBecameActive:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationBecameActive");
  if (_viewportMetrics.physical_width)
    [self surfaceUpdated:YES];
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.resumed"];
}

- (void)applicationWillResignActive:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationWillResignActive");
  [self surfaceUpdated:NO];
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.inactive"];
}

- (void)applicationDidEnterBackground:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationDidEnterBackground");
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.paused"];
}

- (void)applicationWillEnterForeground:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationWillEnterForeground");
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.inactive"];
}

#pragma mark - Touch event handling

static blink::PointerData::Change PointerDataChangeFromUITouchPhase(UITouchPhase phase) {
  switch (phase) {
    case UITouchPhaseBegan:
      return blink::PointerData::Change::kDown;
    case UITouchPhaseMoved:
    case UITouchPhaseStationary:
      // There is no EVENT_TYPE_POINTER_STATIONARY. So we just pass a move type
      // with the same coordinates
      return blink::PointerData::Change::kMove;
    case UITouchPhaseEnded:
      return blink::PointerData::Change::kUp;
    case UITouchPhaseCancelled:
      return blink::PointerData::Change::kCancel;
  }

  return blink::PointerData::Change::kCancel;
}

static blink::PointerData::DeviceKind DeviceKindFromTouchType(UITouch* touch) {
  if (@available(iOS 9, *)) {
    switch (touch.type) {
      case UITouchTypeDirect:
      case UITouchTypeIndirect:
        return blink::PointerData::DeviceKind::kTouch;
      case UITouchTypeStylus:
        return blink::PointerData::DeviceKind::kStylus;
    }
  } else {
    return blink::PointerData::DeviceKind::kTouch;
  }

  return blink::PointerData::DeviceKind::kTouch;
}

// Dispatches the UITouches to the engine. Usually, the type of change of the touch is determined
// from the UITouch's phase. However, FlutterAppDelegate fakes touches to ensure that touch events
// in the status bar area are available to framework code. The change type (optional) of the faked
// touch is specified in the second argument.
- (void)dispatchTouches:(NSSet*)touches
    pointerDataChangeOverride:(blink::PointerData::Change*)overridden_change {
  const CGFloat scale = [UIScreen mainScreen].scale;
  auto packet = std::make_unique<blink::PointerDataPacket>(touches.count);

  size_t pointer_index = 0;

  for (UITouch* touch in touches) {
    CGPoint windowCoordinates = [touch locationInView:self.view];

    blink::PointerData pointer_data;
    pointer_data.Clear();

    constexpr int kMicrosecondsPerSecond = 1000 * 1000;
    pointer_data.time_stamp = touch.timestamp * kMicrosecondsPerSecond;

    pointer_data.change = overridden_change != nullptr
                              ? *overridden_change
                              : PointerDataChangeFromUITouchPhase(touch.phase);

    pointer_data.kind = DeviceKindFromTouchType(touch);

    pointer_data.device = reinterpret_cast<int64_t>(touch);

    pointer_data.physical_x = windowCoordinates.x * scale;
    pointer_data.physical_y = windowCoordinates.y * scale;

    // pressure_min is always 0.0
    if (@available(iOS 9, *)) {
      // These properties were introduced in iOS 9.0.
      pointer_data.pressure = touch.force;
      pointer_data.pressure_max = touch.maximumPossibleForce;
    } else {
      pointer_data.pressure = 1.0;
      pointer_data.pressure_max = 1.0;
    }

    // These properties were introduced in iOS 8.0
    pointer_data.radius_major = touch.majorRadius;
    pointer_data.radius_min = touch.majorRadius - touch.majorRadiusTolerance;
    pointer_data.radius_max = touch.majorRadius + touch.majorRadiusTolerance;

    // These properties were introduced in iOS 9.1
    if (@available(iOS 9.1, *)) {
      // iOS Documentation: altitudeAngle
      // A value of 0 radians indicates that the stylus is parallel to the surface. The value of
      // this property is Pi/2 when the stylus is perpendicular to the surface.
      //
      // PointerData Documentation: tilt
      // The angle of the stylus, in radians in the range:
      //    0 <= tilt <= pi/2
      // giving the angle of the axis of the stylus, relative to the axis perpendicular to the input
      // surface (thus 0.0 indicates the stylus is orthogonal to the plane of the input surface,
      // while pi/2 indicates that the stylus is flat on that surface).
      //
      // Discussion:
      // The ranges are the same. Origins are swapped.
      pointer_data.tilt = M_PI_2 - touch.altitudeAngle;

      // iOS Documentation: azimuthAngleInView:
      // With the tip of the stylus touching the screen, the value of this property is 0 radians
      // when the cap end of the stylus (that is, the end opposite of the tip) points along the
      // positive x axis of the device's screen. The azimuth angle increases as the user swings the
      // cap end of the stylus in a clockwise direction around the tip.
      //
      // PointerData Documentation: orientation
      // The angle of the stylus, in radians in the range:
      //    -pi < orientation <= pi
      // giving the angle of the axis of the stylus projected onto the input surface, relative to
      // the positive y-axis of that surface (thus 0.0 indicates the stylus, if projected onto that
      // surface, would go from the contact point vertically up in the positive y-axis direction, pi
      // would indicate that the stylus would go down in the negative y-axis direction; pi/4 would
      // indicate that the stylus goes up and to the right, -pi/2 would indicate that the stylus
      // goes to the left, etc).
      //
      // Discussion:
      // Sweep direction is the same. Phase of M_PI_2.
      pointer_data.orientation = [touch azimuthAngleInView:nil] - M_PI_2;
    }

    packet->SetPointerData(pointer_index++, pointer_data);
  }

  [_engine.get() dispatchPointerDataPacket:std::move(packet)];
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

#pragma mark - Handle view resizing

- (void)updateViewportMetrics {
  [_engine.get() updateViewportMetrics:_viewportMetrics];
}

- (CGFloat)statusBarPadding {
  UIScreen* screen = self.view.window.screen;
  CGRect statusFrame = [UIApplication sharedApplication].statusBarFrame;
  CGRect viewFrame = [self.view convertRect:self.view.bounds
                          toCoordinateSpace:screen.coordinateSpace];
  CGRect intersection = CGRectIntersection(statusFrame, viewFrame);
  return CGRectIsNull(intersection) ? 0.0 : intersection.size.height;
}

- (void)viewDidLayoutSubviews {
  CGSize viewSize = self.view.bounds.size;
  CGFloat scale = [UIScreen mainScreen].scale;

  // First time since creation that the dimensions of its view is known.
  bool firstViewBoundsUpdate = !_viewportMetrics.physical_width;
  _viewportMetrics.device_pixel_ratio = scale;
  _viewportMetrics.physical_width = viewSize.width * scale;
  _viewportMetrics.physical_height = viewSize.height * scale;

  [self updateViewportPadding];
  [self updateViewportMetrics];

  // This must run after updateViewportMetrics so that the surface creation tasks are queued after
  // the viewport metrics update tasks.
  if (firstViewBoundsUpdate)
    [self surfaceUpdated:YES];
}

- (void)viewSafeAreaInsetsDidChange {
  [self updateViewportPadding];
  [self updateViewportMetrics];
  [super viewSafeAreaInsetsDidChange];
}

// Updates _viewportMetrics physical padding.
//
// Viewport padding represents the iOS safe area insets.
- (void)updateViewportPadding {
  CGFloat scale = [UIScreen mainScreen].scale;
  if (@available(iOS 11, *)) {
    _viewportMetrics.physical_padding_top = self.view.safeAreaInsets.top * scale;
    _viewportMetrics.physical_padding_left = self.view.safeAreaInsets.left * scale;
    _viewportMetrics.physical_padding_right = self.view.safeAreaInsets.right * scale;
    _viewportMetrics.physical_padding_bottom = self.view.safeAreaInsets.bottom * scale;
  } else {
    _viewportMetrics.physical_padding_top = [self statusBarPadding] * scale;
  }
}

#pragma mark - Keyboard events

- (void)keyboardWillChangeFrame:(NSNotification*)notification {
  NSDictionary* info = [notification userInfo];
  CGFloat bottom = CGRectGetHeight([[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue]);
  CGFloat scale = [UIScreen mainScreen].scale;

  // The keyboard is treated as an inset since we want to effectively reduce the window size by the
  // keyboard height. We also eliminate any bottom safe-area padding since they keyboard 'consumes'
  // the home indicator widget.
  _viewportMetrics.physical_view_inset_bottom = bottom * scale;
  _viewportMetrics.physical_padding_bottom = 0;
  [self updateViewportMetrics];
}

- (void)keyboardWillBeHidden:(NSNotification*)notification {
  CGFloat scale = [UIScreen mainScreen].scale;
  _viewportMetrics.physical_view_inset_bottom = 0;

  // Restore any safe area padding that the keyboard had consumed.
  if (@available(iOS 11, *)) {
    _viewportMetrics.physical_padding_bottom = self.view.safeAreaInsets.bottom * scale;
  } else {
    _viewportMetrics.physical_padding_top = [self statusBarPadding] * scale;
  }
  [self updateViewportMetrics];
}

#pragma mark - Orientation updates

- (void)onOrientationPreferencesUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(shell::kOrientationUpdateNotificationKey)];

    if (update == nil) {
      return;
    }

    NSUInteger new_preferences = update.unsignedIntegerValue;

    if (new_preferences != _orientationPreferences) {
      _orientationPreferences = new_preferences;
      [UIViewController attemptRotationToDeviceOrientation];
    }
  });
}

- (BOOL)shouldAutorotate {
  return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
  return _orientationPreferences;
}

#pragma mark - Accessibility

- (void)onAccessibilityStatusChanged:(NSNotification*)notification {
  auto platformView = [_engine.get() platformView];
  int32_t flags = 0;
  if (UIAccessibilityIsInvertColorsEnabled())
    flags |= static_cast<int32_t>(blink::AccessibilityFeatureFlag::kInvertColors);
  if (UIAccessibilityIsReduceMotionEnabled())
    flags |= static_cast<int32_t>(blink::AccessibilityFeatureFlag::kReduceMotion);
  if (UIAccessibilityIsBoldTextEnabled())
    flags |= static_cast<int32_t>(blink::AccessibilityFeatureFlag::kBoldText);
#if TARGET_OS_SIMULATOR
  // There doesn't appear to be any way to determine whether the accessibility
  // inspector is enabled on the simulator. We conservatively always turn on the
  // accessibility bridge in the simulator, but never assistive technology.
  platformView->SetSemanticsEnabled(true);
  platformView->SetAccessibilityFeatures(flags);
#else
  bool enabled = UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning();
  if (enabled)
    flags |= static_cast<int32_t>(blink::AccessibilityFeatureFlag::kAccessibleNavigation);
  platformView->SetSemanticsEnabled(enabled || UIAccessibilityIsSpeakScreenEnabled());
  platformView->SetAccessibilityFeatures(flags);
#endif
}

#pragma mark - Memory Notifications

- (void)onMemoryWarning:(NSNotification*)notification {
  [[_engine.get() systemChannel] sendMessage:@{@"type" : @"memoryPressure"}];
}

#pragma mark - Locale updates

- (void)onLocaleUpdated:(NSNotification*)notification {
  NSArray<NSString*>* preferredLocales = [NSLocale preferredLanguages];
  NSMutableArray<NSString*>* data = [[NSMutableArray new] autorelease];

  // Force prepend the [NSLocale currentLocale] to the front of the list
  // to ensure we are including the full default locale. preferredLocales
  // is not guaranteed to include anything beyond the languageCode.
  NSLocale* currentLocale = [NSLocale currentLocale];
  NSString* languageCode = [currentLocale objectForKey:NSLocaleLanguageCode];
  NSString* countryCode = [currentLocale objectForKey:NSLocaleCountryCode];
  NSString* scriptCode = [currentLocale objectForKey:NSLocaleScriptCode];
  NSString* variantCode = [currentLocale objectForKey:NSLocaleVariantCode];
  if (languageCode) {
    [data addObject:languageCode];
    [data addObject:(countryCode ? countryCode : @"")];
    [data addObject:(scriptCode ? scriptCode : @"")];
    [data addObject:(variantCode ? variantCode : @"")];
  }

  // Add any secondary locales/languages to the list.
  for (NSString* localeID in preferredLocales) {
    NSLocale* currentLocale = [[[NSLocale alloc] initWithLocaleIdentifier:localeID] autorelease];
    NSString* languageCode = [currentLocale objectForKey:NSLocaleLanguageCode];
    NSString* countryCode = [currentLocale objectForKey:NSLocaleCountryCode];
    NSString* scriptCode = [currentLocale objectForKey:NSLocaleScriptCode];
    NSString* variantCode = [currentLocale objectForKey:NSLocaleVariantCode];
    if (!languageCode) {
      continue;
    }
    [data addObject:languageCode];
    [data addObject:(countryCode ? countryCode : @"")];
    [data addObject:(scriptCode ? scriptCode : @"")];
    [data addObject:(variantCode ? variantCode : @"")];
  }
  if (data.count == 0) {
    return;
  }
  [[_engine.get() localizationChannel] invokeMethod:@"setLocale" arguments:data];
}

#pragma mark - Set user settings

- (void)onUserSettingsChanged:(NSNotification*)notification {
  [[_engine.get() settingsChannel] sendMessage:@{
    @"textScaleFactor" : @([self textScaleFactor]),
    @"alwaysUse24HourFormat" : @([self isAlwaysUse24HourFormat]),
  }];
}

- (CGFloat)textScaleFactor {
  UIContentSizeCategory category = [UIApplication sharedApplication].preferredContentSizeCategory;
  // The delta is computed by approximating Apple's typography guidelines:
  // https://developer.apple.com/ios/human-interface-guidelines/visual-design/typography/
  //
  // Specifically:
  // Non-accessibility sizes for "body" text are:
  const CGFloat xs = 14;
  const CGFloat s = 15;
  const CGFloat m = 16;
  const CGFloat l = 17;
  const CGFloat xl = 19;
  const CGFloat xxl = 21;
  const CGFloat xxxl = 23;

  // Accessibility sizes for "body" text are:
  const CGFloat ax1 = 28;
  const CGFloat ax2 = 33;
  const CGFloat ax3 = 40;
  const CGFloat ax4 = 47;
  const CGFloat ax5 = 53;

  // We compute the scale as relative difference from size L (large, the default size), where
  // L is assumed to have scale 1.0.
  if ([category isEqualToString:UIContentSizeCategoryExtraSmall])
    return xs / l;
  else if ([category isEqualToString:UIContentSizeCategorySmall])
    return s / l;
  else if ([category isEqualToString:UIContentSizeCategoryMedium])
    return m / l;
  else if ([category isEqualToString:UIContentSizeCategoryLarge])
    return 1.0;
  else if ([category isEqualToString:UIContentSizeCategoryExtraLarge])
    return xl / l;
  else if ([category isEqualToString:UIContentSizeCategoryExtraExtraLarge])
    return xxl / l;
  else if ([category isEqualToString:UIContentSizeCategoryExtraExtraExtraLarge])
    return xxxl / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityMedium])
    return ax1 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityLarge])
    return ax2 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraLarge])
    return ax3 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraLarge])
    return ax4 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge])
    return ax5 / l;
  else
    return 1.0;
}

- (BOOL)isAlwaysUse24HourFormat {
  // iOS does not report its "24-Hour Time" user setting in the API. Instead, it applies
  // it automatically to NSDateFormatter when used with [NSLocale currentLocale]. It is
  // essential that [NSLocale currentLocale] is used. Any custom locale, even the one
  // that's the same as [NSLocale currentLocale] will ignore the 24-hour option (there
  // must be some internal field that's not exposed to developers).
  //
  // Therefore this option behaves differently across Android and iOS. On Android this
  // setting is exposed standalone, and can therefore be applied to all locales, whether
  // the "current system locale" or a custom one. On iOS it only applies to the current
  // system locale. Widget implementors must take this into account in order to provide
  // platform-idiomatic behavior in their widgets.
  NSString* dateFormat = [NSDateFormatter dateFormatFromTemplate:@"j"
                                                         options:0
                                                          locale:[NSLocale currentLocale]];
  return [dateFormat rangeOfString:@"a"].location == NSNotFound;
}

#pragma mark - Status Bar touch event handling

// Standard iOS status bar height in pixels.
constexpr CGFloat kStandardStatusBarHeight = 20.0;

- (void)handleStatusBarTouches:(UIEvent*)event {
  CGFloat standardStatusBarHeight = kStandardStatusBarHeight;
  if (@available(iOS 11, *)) {
    standardStatusBarHeight = self.view.safeAreaInsets.top;
  }

  // If the status bar is double-height, don't handle status bar taps. iOS
  // should open the app associated with the status bar.
  CGRect statusBarFrame = [UIApplication sharedApplication].statusBarFrame;
  if (statusBarFrame.size.height != standardStatusBarHeight) {
    return;
  }

  // If we detect a touch in the status bar, synthesize a fake touch begin/end.
  for (UITouch* touch in event.allTouches) {
    if (touch.phase == UITouchPhaseBegan && touch.tapCount > 0) {
      CGPoint windowLoc = [touch locationInView:nil];
      CGPoint screenLoc = [touch.window convertPoint:windowLoc toWindow:nil];
      if (CGRectContainsPoint(statusBarFrame, screenLoc)) {
        NSSet* statusbarTouches = [NSSet setWithObject:touch];

        blink::PointerData::Change change = blink::PointerData::Change::kDown;
        [self dispatchTouches:statusbarTouches pointerDataChangeOverride:&change];
        change = blink::PointerData::Change::kUp;
        [self dispatchTouches:statusbarTouches pointerDataChangeOverride:&change];
        return;
      }
    }
  }
}

#pragma mark - Status bar style

- (UIStatusBarStyle)preferredStatusBarStyle {
  return _statusBarStyle;
}

- (void)onPreferredStatusBarStyleUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(shell::kOverlayStyleUpdateNotificationKey)];

    if (update == nil) {
      return;
    }

    NSInteger style = update.integerValue;

    if (style != _statusBarStyle) {
      _statusBarStyle = static_cast<UIStatusBarStyle>(style);
      [self setNeedsStatusBarAppearanceUpdate];
    }
  });
}

#pragma mark - Platform views

- (shell::FlutterPlatformViewsController*)platformViewsController {
  return [_engine.get() platformViewsController];
}

#pragma mark - FlutterBinaryMessenger

- (void)sendOnChannel:(NSString*)channel message:(NSData*)message {
  [_engine.get() sendOnChannel:channel message:message];
}

- (void)sendOnChannel:(NSString*)channel
              message:(NSData*)message
          binaryReply:(FlutterBinaryReply)callback {
  NSAssert(channel, @"The channel must not be null");
  [_engine.get() sendOnChannel:channel message:message binaryReply:callback];
}

- (void)setMessageHandlerOnChannel:(NSString*)channel
              binaryMessageHandler:(FlutterBinaryMessageHandler)handler {
  NSAssert(channel, @"The channel must not be null");
  [_engine.get() setMessageHandlerOnChannel:channel binaryMessageHandler:handler];
}

#pragma mark - FlutterTextureRegistry

- (int64_t)registerTexture:(NSObject<FlutterTexture>*)texture {
  return [_engine.get() registerTexture:texture];
}

- (void)unregisterTexture:(int64_t)textureId {
  [_engine.get() unregisterTexture:textureId];
}

- (void)textureFrameAvailable:(int64_t)textureId {
  [_engine.get() textureFrameAvailable:textureId];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [FlutterDartProject lookupKeyForAsset:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [FlutterDartProject lookupKeyForAsset:asset fromPackage:package];
}

- (id<FlutterPluginRegistry>)pluginRegistry {
  return _engine;
}

#pragma mark - FlutterPluginRegistry

- (NSObject<FlutterPluginRegistrar>*)registrarForPlugin:(NSString*)pluginKey {
  return [_engine.get() registrarForPlugin:pluginKey];
}

- (BOOL)hasPlugin:(NSString*)pluginKey {
  return [_engine.get() hasPlugin:pluginKey];
}

- (NSObject*)valuePublishedByPlugin:(NSString*)pluginKey {
  return [_engine.get() valuePublishedByPlugin:pluginKey];
}

@end
