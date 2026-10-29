#import "CosmosCEF.h"

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <string>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_preference.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"

#pragma mark Application

@interface CosmosApplication () <CefAppProtocol>
@end

@implementation CosmosApplication {
  BOOL _handlingSendEvent;
}
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handling { _handlingSendEvent = handling; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sending;
  [super sendEvent:event];
}
@end

#pragma mark DevTools pipe

static int gCommandDescriptor = -1, gAnswerDescriptor = -1;

BOOL CosmosCEFReservePipe(void) {
  if (gCommandDescriptor >= 0) return YES;
  int commands[2], answers[2];
  if (pipe(commands) != 0) return NO;
  if (pipe(answers) != 0) { close(commands[0]); close(commands[1]); return NO; }
  // All four go above the low numbers first, so that putting one at 3 or 4 cannot close another.
  int ends[4] = {commands[0], commands[1], answers[0], answers[1]}, moved[4];
  for (int i = 0; i < 4; i++) { moved[i] = fcntl(ends[i], F_DUPFD_CLOEXEC, 10); close(ends[i]); }
  if (moved[0] < 0 || moved[1] < 0 || moved[2] < 0 || moved[3] < 0) return NO;
  // Chromium's ends are read and written in this process only: no program Cosmos starts gets them.
  if (dup2(moved[0], 3) != 3 || dup2(moved[3], 4) != 4) return NO;
  fcntl(3, F_SETFD, FD_CLOEXEC);
  fcntl(4, F_SETFD, FD_CLOEXEC);
  close(moved[0]);
  close(moved[3]);
  gCommandDescriptor = moved[1];
  gAnswerDescriptor = moved[2];
  return YES;
}

int CosmosCEFCommandDescriptor(void) { return gCommandDescriptor; }
int CosmosCEFAnswerDescriptor(void) { return gAnswerDescriptor; }

#pragma mark Message pump

// CEF runs on the main thread, in Cosmos's run loop: it says when it wants to do work (OnScheduleMessagePumpWork, from
// any thread) and the work runs on the main queue. A request replaces the one before it; between requests the work runs
// at least every 33 ms, as CEF's own sample client does.
static std::atomic<uint64_t> gPumpRequest{0};
static bool gPumping = false;
static const int64_t kLongestWait = 33;

static void PumpAfter(int64_t delay);

static bool gStopped = false;

static void Pump() {
  if (gStopped) return;
  if (gPumping) { PumpAfter(0); return; }
  uint64_t before = gPumpRequest.load();
  gPumping = true;
  CefDoMessageLoopWork();
  gPumping = false;
  if (gPumpRequest.load() == before) PumpAfter(kLongestWait);
}

static void PumpAfter(int64_t delay) {
  uint64_t request = ++gPumpRequest;
  delay = std::max<int64_t>(0, std::min(delay, kLongestWait));
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    if (gPumpRequest.load() == request) Pump();
  });
}

#pragma mark Preferences

static CefRefPtr<CefValue> Value(id object) {
  CefRefPtr<CefValue> value = CefValue::Create();
  if ([object isKindOfClass:[NSString class]]) {
    value->SetString([object UTF8String]);
  } else if ([object isKindOfClass:[NSNumber class]]) {
    NSNumber *n = object;
    const char *type = n.objCType;
    if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) value->SetBool(n.boolValue);
    else if (strcmp(type, @encode(double)) == 0 || strcmp(type, @encode(float)) == 0) value->SetDouble(n.doubleValue);
    else value->SetInt(n.intValue);
  } else if ([object isKindOfClass:[NSArray class]]) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    NSArray *items = object;
    for (NSUInteger i = 0; i < items.count; i++) list->SetValue(i, Value(items[i]));
    value->SetList(list);
  } else if ([object isKindOfClass:[NSDictionary class]]) {
    CefRefPtr<CefDictionaryValue> dictionary = CefDictionaryValue::Create();
    [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(NSString *key, id item, BOOL *) {
      dictionary->SetValue(key.UTF8String, Value(item));
    }];
    value->SetDictionary(dictionary);
  }
  return value;
}

// A key is either a setting Chromium has (set whole) or a group of them (each set in turn).
static void SetPreferences(CefRefPtr<CefPreferenceManager> manager, NSDictionary *preferences, NSString *prefix) {
  [preferences enumerateKeysAndObjectsUsingBlock:^(NSString *key, id item, BOOL *) {
    NSString *name = prefix ? [NSString stringWithFormat:@"%@.%@", prefix, key] : key;
    if (manager->HasPreference(name.UTF8String)) {
      if (!manager->CanSetPreference(name.UTF8String)) return;
      CefString error;
      manager->SetPreference(name.UTF8String, Value(item), error);
    } else if ([item isKindOfClass:[NSDictionary class]]) {
      SetPreferences(manager, item, name);
    }
  }];
}

#pragma mark CEF application

static bool gRunning = false, gContextReady = false;
static NSString *gLastError = nil;
static std::vector<dispatch_block_t> gWhenReady;

// Every browser CEF has made for Cosmos (popups too), and those asked for and not made yet: CEF stops only once all of
// them have closed.
static std::vector<CefRefPtr<CefBrowser>> gOpenBrowsers;
static int gBeingMade = 0;
static bool gShuttingDown = false;
static std::vector<void (^)(BOOL)> gWhenStopped;

// Runs what waits for CEF to stop, once; with `closed`, every browser closed and CEF stops first.
static void FinishShutdown(bool closed) {
  if (gWhenStopped.empty()) return;
  std::vector<void (^)(BOOL)> waiting;
  waiting.swap(gWhenStopped);
  if (closed) {
    gStopped = true;
    gRunning = false;
    CefShutdown();
  }
  for (void (^work)(BOOL) : waiting) work(closed);
}

// After a browser closed (or one asked for never came): CEF stops when it was the last. Not from inside CEF's own work,
// which CefShutdown must not run in.
static void BrowserGone() {
  if (gShuttingDown && gOpenBrowsers.empty() && gBeingMade <= 0)
    dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(true); });
}

// Work that needs CEF's context, now or once it is there.
static void WhenReady(dispatch_block_t work) {
  if (gContextReady) work(); else gWhenReady.push_back(work);
}

class CosmosCefApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit CosmosCefApp(std::vector<std::string> switches) : switches_(std::move(switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString &type, CefRefPtr<CefCommandLine> line) override {
    if (!type.empty()) return;
    line->AppendSwitch("remote-debugging-pipe");
    for (const std::string &item : switches_) {
      std::string name = item.rfind("--", 0) == 0 ? item.substr(2) : item;
      size_t equals = name.find('=');
      if (equals == std::string::npos) line->AppendSwitch(name);
      else line->AppendSwitchWithValue(name.substr(0, equals), name.substr(equals + 1));
    }
  }

  void OnContextInitialized() override {
    gContextReady = true;
    std::vector<dispatch_block_t> waiting;
    waiting.swap(gWhenReady);
    for (dispatch_block_t work : waiting) work();
  }

  void OnScheduleMessagePumpWork(int64_t delay) override { PumpAfter(delay); }

 private:
  std::vector<std::string> switches_;
  IMPLEMENT_REFCOUNTING(CosmosCefApp);
};

@implementation CosmosCEFRuntime

+ (BOOL)startWithMainBundle:(NSString *)mainBundle
                  framework:(NSString *)framework
                     helper:(NSString *)helper
                  rootCache:(NSString *)rootCache
                globalCache:(NSString *)globalCache
                   switches:(NSArray<NSString *> *)switches
                  sandboxed:(BOOL)sandboxed {
  if (gRunning) return YES;
  if (gStopped) { gLastError = @"Chromium has stopped"; return NO; }
  if (!CosmosCEFReservePipe()) { gLastError = @"No pipe for the DevTools protocol could be made"; return NO; }
  NSString *library = [framework stringByAppendingPathComponent:@"Chromium Embedded Framework"];
  if (!cef_load_library(library.fileSystemRepresentation)) {
    gLastError = [NSString stringWithFormat:@"Could not load %@", library];
    return NO;
  }
  // Chromium reads its switches from the App below, not from Cosmos's own arguments.
  static char name[] = "Cosmos";
  static char *argv[] = {name, nullptr};
  CefMainArgs args(1, argv);
  CefSettings settings;
  settings.no_sandbox = sandboxed ? 0 : 1;
  settings.external_message_pump = 1;
  settings.log_severity = LOGSEVERITY_ERROR;
  if (mainBundle) CefString(&settings.main_bundle_path) = mainBundle.UTF8String;
  CefString(&settings.framework_dir_path) = framework.UTF8String;
  CefString(&settings.browser_subprocess_path) = helper.UTF8String;
  CefString(&settings.root_cache_path) = rootCache.UTF8String;
  CefString(&settings.cache_path) = globalCache.UTF8String;
  CefString(&settings.log_file) = [rootCache stringByAppendingPathComponent:@"engine.log"].UTF8String;
  std::vector<std::string> list;
  for (NSString *item in switches) list.push_back(item.UTF8String);
  if (!CefInitialize(args, settings, new CosmosCefApp(std::move(list)), nullptr)) {
    gLastError = @"CEF did not start";
    return NO;
  }
  gRunning = true;
  PumpAfter(0);
  return YES;
}

+ (void)whenReady:(dispatch_block_t)block { WhenReady(block); }
+ (void)setGlobalPreferences:(NSDictionary<NSString *, id> *)preferences {
  if (gContextReady) SetPreferences(CefPreferenceManager::GetGlobalPreferenceManager(), preferences, nil);
}
+ (void)shutdown:(void (^)(BOOL))done {
  if (!gRunning) { done(gStopped); return; }
  gWhenStopped.push_back([done copy]);
  if (gShuttingDown) return;
  gShuttingDown = true;
  std::vector<CefRefPtr<CefBrowser>> open = gOpenBrowsers;
  for (CefRefPtr<CefBrowser> &browser : open) browser->GetHost()->CloseBrowser(true);
  BrowserGone();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ FinishShutdown(false); });
}

+ (BOOL)isRunning { return gRunning; }
+ (NSInteger)openBrowserCount { return (NSInteger)gOpenBrowsers.size() + gBeingMade; }
+ (NSString *)lastError { return gLastError; }
+ (NSString *)chromiumVersion {
  return [NSString stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD,
                                    CHROME_VERSION_PATCH];
}

@end

#pragma mark Contexts

@implementation CosmosCEFCookie
@end

// CEF's times are microseconds since 1601.
static cef_basetime_t BaseTime(NSDate *date) {
  cef_basetime_t t;
  t.val = (int64_t)((date.timeIntervalSince1970 + 11644473600.0) * 1000000.0);
  return t;
}

class CookieSet : public CefSetCookieCallback {
 public:
  explicit CookieSet(void (^taken)(BOOL)) : taken_([taken copy]) {}
  // One CEF lets go of without an answer (it refused the cookie, or is shutting down) counts as not taken, so that the
  // caller hears about every cookie.
  ~CookieSet() override { Answer(NO); }
  void OnComplete(bool success) override { Answer(success); }

 private:
  void Answer(BOOL ok) {
    void (^taken)(BOOL) = taken_;
    taken_ = nil;
    if (taken) dispatch_async(dispatch_get_main_queue(), ^{ taken(ok); });
  }

  void (^taken_)(BOOL);
  IMPLEMENT_REFCOUNTING(CookieSet);
};

@implementation CosmosCEFContext {
 @public
  CefRefPtr<CefRequestContext> _context;
}

// Once CEF has stopped, letting go of something it made would call into it: the process is ending, so it is kept.
- (void)dealloc {
  if (gStopped) (void)_context.release();
}

- (instancetype)initWithCachePath:(NSString *)cachePath {
  if ((self = [super init])) {
    CefRequestContextSettings settings;
    if (cachePath) CefString(&settings.cache_path) = cachePath.UTF8String;
    _context = CefRequestContext::CreateContext(settings, nullptr);
  }
  return self;
}

- (instancetype)initGlobal {
  if ((self = [super init])) _context = CefRequestContext::GetGlobalContext();
  return self;
}

+ (CosmosCEFContext *)globalContext {
  static CosmosCEFContext *global = [[CosmosCEFContext alloc] initGlobal];
  return global;
}

- (void)setPermission:(CosmosCEFPermission)permission origin:(NSString *)origin to:(CosmosCEFPermissionSetting)setting {
  cef_content_setting_types_t type = CEF_CONTENT_SETTING_TYPE_GEOLOCATION;
  switch (permission) {
    case CosmosCEFPermissionCamera: type = CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA; break;
    case CosmosCEFPermissionMicrophone: type = CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC; break;
    case CosmosCEFPermissionLocation: type = CEF_CONTENT_SETTING_TYPE_GEOLOCATION; break;
    case CosmosCEFPermissionNotifications: type = CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS; break;
  }
  cef_content_setting_values_t value = setting == CosmosCEFPermissionSettingAllow   ? CEF_CONTENT_SETTING_VALUE_ALLOW
                                       : setting == CosmosCEFPermissionSettingBlock ? CEF_CONTENT_SETTING_VALUE_BLOCK
                                                                                    : CEF_CONTENT_SETTING_VALUE_DEFAULT;
  _context->SetContentSetting(origin.UTF8String, origin.UTF8String, type, value);
}

class CookiesDeleted : public CefDeleteCookiesCallback {
 public:
  explicit CookiesDeleted(dispatch_block_t done) : done_([done copy]) {}
  void OnComplete(int) override { dispatch_async(dispatch_get_main_queue(), done_); }

 private:
  dispatch_block_t done_;
  IMPLEMENT_REFCOUNTING(CookiesDeleted);
};

- (void)setPreferences:(NSDictionary<NSString *, id> *)preferences {
  SetPreferences(_context, preferences, nil);
}

- (void)deleteCookies:(dispatch_block_t)done {
  CefRefPtr<CefCookieManager> cookies = _context->GetCookieManager(nullptr);
  if (!cookies || !cookies->DeleteCookies("", "", new CookiesDeleted(done))) dispatch_async(dispatch_get_main_queue(), done);
}

- (void)setCookies:(NSArray<CosmosCEFCookie *> *)cookies done:(void (^)(NSInteger))done {
  CefRefPtr<CefCookieManager> manager = _context->GetCookieManager(nullptr);
  if (!manager || cookies.count == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(0); });
    return;
  }
  // Each answer comes on the main thread; the last one says how many were taken.
  __block NSInteger left = (NSInteger)cookies.count, taken = 0;
  void (^one)(BOOL) = ^(BOOL ok) {
    if (ok) taken++;
    if (--left == 0) done(taken);
  };
  NSDate *now = [NSDate date];
  for (CosmosCEFCookie *c in cookies) {
    BOOL domainCookie = [c.domain hasPrefix:@"."];
    NSString *host = domainCookie ? [c.domain substringFromIndex:1] : c.domain;
    NSString *path = c.path.length ? c.path : @"/";
    NSString *url = [NSString stringWithFormat:@"%@://%@%@", c.secure ? @"https" : @"http", host, path];
    CefCookie cookie;
    CefString(&cookie.name) = c.name.UTF8String;
    CefString(&cookie.value) = c.value.UTF8String;
    // A cookie only its host gets has no domain of its own; one for the subdomains too keeps its leading dot.
    if (domainCookie) CefString(&cookie.domain) = c.domain.UTF8String;
    CefString(&cookie.path) = path.UTF8String;
    cookie.secure = c.secure;
    cookie.httponly = c.httpOnly;
    // Made now: Chromium caps how long a cookie lasts from when it was made, and one another browser made long ago and
    // kept renewing would come in already over that cap.
    cookie.creation = BaseTime(now);
    cookie.last_access = BaseTime(now);
    cookie.has_expires = c.expires != nil;
    if (c.expires) cookie.expires = BaseTime(c.expires);
    switch (c.sameSite) {
      case 0: cookie.same_site = CEF_COOKIE_SAME_SITE_NO_RESTRICTION; break;
      case 1: cookie.same_site = CEF_COOKIE_SAME_SITE_LAX_MODE; break;
      case 2: cookie.same_site = CEF_COOKIE_SAME_SITE_STRICT_MODE; break;
      default: cookie.same_site = CEF_COOKIE_SAME_SITE_UNSPECIFIED; break;
    }
    cookie.priority = CEF_COOKIE_PRIORITY_MEDIUM;
    manager->SetCookie(url.UTF8String, cookie, new CookieSet(one));
  }
}

@end

#pragma mark Downloads

@interface CosmosCEFDownload ()
- (instancetype)initWithItem:(CefRefPtr<CefDownloadItem>)item;
- (void)update:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

@implementation CosmosCEFDownload {
  CefRefPtr<CefDownloadItemCallback> _callback;
  BOOL _cancelWhenPossible;
}

- (void)dealloc {
  if (gStopped) (void)_callback.release();
}

- (instancetype)initWithItem:(CefRefPtr<CefDownloadItem>)item {
  if ((self = [super init])) {
    _url = [NSString stringWithUTF8String:item->GetURL().ToString().c_str()];
    _suggestedName = [NSString stringWithUTF8String:item->GetSuggestedFileName().ToString().c_str()];
    _total = -1;
  }
  return self;
}

- (void)update:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  _callback = callback;
  _received = item->GetReceivedBytes();
  _total = item->GetTotalBytes() > 0 ? item->GetTotalBytes() : -1;
  _isComplete = item->IsComplete();
  _isCanceled = item->IsCanceled();
  _isInterrupted = item->IsInterrupted();
  if (_cancelWhenPossible && !_isComplete && !_isCanceled) callback->Cancel();
}

- (void)cancel {
  if (_callback) _callback->Cancel(); else _cancelWhenPossible = YES;
}

@end

// Downloads by CEF's id, from the moment Cosmos says where one goes until it ends.
static NSMutableDictionary<NSNumber *, CosmosCEFDownload *> *gDownloads() {
  static NSMutableDictionary *table = [NSMutableDictionary dictionary];
  return table;
}
static NSString *_Nullable (^gDownloadStarted)(CosmosCEFBrowser *, CosmosCEFDownload *) = nil;
static void (^gDownloadUpdated)(CosmosCEFDownload *) = nil;
static void (^gDialog)(CosmosCEFBrowser *, CosmosCEFDialogKind, NSString *, NSString *, NSString *, void (^)(BOOL, NSString *)) = nil;
static BOOL (^gNavigation)(CosmosCEFBrowser *, NSString *, BOOL) = nil;

static NSString *String(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()]; }

#pragma mark Browsers

@interface CosmosCEFBrowser ()
- (instancetype)initPopupInView:(NSView *)holder opener:(CosmosCEFBrowser *)opener;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
- (void)targetFound:(NSString *)targetID;
- (void)targetNotFound;
// The profile the page is in (a popup is in its opener's).
@property (nonatomic, strong, nullable) CosmosCEFContext *context;
// A popup's key in gPopupsBeingMade, until CEF has made it.
@property (nonatomic, copy, nullable) NSString *popupKey;
@end

// Popups CEF is making, until they are made or CEF gives up on one: by opener and popup id.
static NSMutableDictionary<NSString *, CosmosCEFBrowser *> *gPopupsBeingMade() {
  static NSMutableDictionary *table = [NSMutableDictionary dictionary];
  return table;
}
static NSString *PopupKey(CefRefPtr<CefBrowser> opener, int popupID) {
  return [NSString stringWithFormat:@"%d/%d", opener->GetIdentifier(), popupID];
}

// Every browser by its target, and popups CEF made until Cosmos has them (nothing else holds them before that).
static NSMutableDictionary<NSString *, CosmosCEFBrowser *> *gBrowsersByTarget() {
  static NSMutableDictionary *table = [NSMutableDictionary dictionary];
  return table;
}
static NSMutableSet<CosmosCEFBrowser *> *gUnclaimedPopups() {
  static NSMutableSet *set = [NSMutableSet set];
  return set;
}

// Where popups are made: a view of a window that is never shown, until Cosmos moves each into a tab.
static NSView *PopupHolder() {
  static NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1024, 768)
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
  window.releasedWhenClosed = NO;
  return window.contentView;
}

// The answer to the browser's own `Target.getTargetInfo`: which page target it is.
class TargetLookup : public CefDevToolsMessageObserver {
 public:
  explicit TargetLookup(CosmosCEFBrowser *owner) : owner_(owner) {}
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void *result,
                              size_t result_size) override {
    if (message_id != id_) return;
    NSString *target = nil;
    if (success) {
      NSData *data = [NSData dataWithBytes:result length:result_size];
      NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      id found = [answer isKindOfClass:[NSDictionary class]] ? answer[@"targetInfo"][@"targetId"] : nil;
      if ([found isKindOfClass:[NSString class]]) target = found;
    }
    Finish(target);
  }
  // The answer can come before ExecuteDevToolsMethod returns, so the message id is chosen first.
  void Start(CefRefPtr<CefBrowser> browser) {
    static int next = 1000;
    id_ = ++next;
    registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (browser->GetHost()->ExecuteDevToolsMethod(id_, "Target.getTargetInfo", nullptr) == 0) Finish(nil);
  }

 private:
  // The owner learns the answer (nil: none came), and the observer goes, after this call: the registration is all that
  // holds it.
  void Finish(NSString *target) {
    if (!registration_) return;
    CefRefPtr<CefRegistration> registration = registration_;
    registration_ = nullptr;
    CosmosCEFBrowser *owner = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      (void)registration;
      if (target) [owner targetFound:target]; else [owner targetNotFound];
    });
  }

  __weak CosmosCEFBrowser *owner_;
  CefRefPtr<CefRegistration> registration_;
  int id_ = 0;
  IMPLEMENT_REFCOUNTING(TargetLookup);
};

// DevTools' own window: CEF's defaults, none of a page's handling.
class DevToolsClient : public CefClient {
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

// The kind of a request, as declarativeNetRequest names it.
static NSString *RequestType(cef_resource_type_t type) {
  switch (type) {
    case RT_MAIN_FRAME: return @"main_frame";
    case RT_SUB_FRAME: return @"sub_frame";
    case RT_STYLESHEET: return @"stylesheet";
    case RT_SCRIPT: return @"script";
    case RT_IMAGE: case RT_FAVICON: return @"image";
    case RT_FONT_RESOURCE: return @"font";
    case RT_OBJECT: case RT_PLUGIN_RESOURCE: return @"object";
    case RT_MEDIA: return @"media";
    case RT_XHR: return @"xmlhttprequest";
    case RT_PING: return @"ping";
    case RT_CSP_REPORT: return @"csp_report";
    default: return @"other";
  }
}

// A profile's own request check (CosmosCEFContext.blocksRequest), on the network thread.
class RequestCheck : public CefResourceRequestHandler {
 public:
  RequestCheck(BOOL (^blocks)(NSString *, NSString *, NSString *, NSArray<NSString *> *), NSString *initiator)
      : blocks_([blocks copy]), initiator_(initiator) {}

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback>) override {
    // The network thread has no autorelease pool of its own.
    @autoreleasepool {
      cef_resource_type_t type = request->GetResourceType();
      // The documents the request is for: a frame's own navigation is for the documents above it.
      NSMutableArray<NSString *> *documents = [NSMutableArray array];
      CefRefPtr<CefFrame> f = (type == RT_MAIN_FRAME || type == RT_SUB_FRAME) && frame ? frame->GetParent() : frame;
      if (type == RT_MAIN_FRAME) f = nullptr;
      for (; f; f = f->GetParent()) [documents addObject:String(f->GetURL())];
      return blocks_(String(request->GetURL()), RequestType(type), initiator_, documents) ? RV_CANCEL : RV_CONTINUE;
    }
  }

 private:
  BOOL (^blocks_)(NSString *, NSString *, NSString *, NSArray<NSString *> *);
  NSString *initiator_;
  IMPLEMENT_REFCOUNTING(RequestCheck);
};

// What CEF tells one browser, and asks of it. Everything else goes through the DevTools protocol.
class CosmosBrowserClient : public CefClient,
                            public CefLifeSpanHandler,
                            public CefContextMenuHandler,
                            public CefDownloadHandler,
                            public CefJSDialogHandler,
                            public CefPermissionHandler,
                            public CefRequestHandler {
 public:
  CosmosBrowserClient(CosmosCEFBrowser *owner, CosmosCEFContext *context) : owner_(owner), context_(context) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // A profile that matches its requests itself (CosmosCEFContext.blocksRequest) is asked about each, on the network thread.
  // The client keeps the profile itself: the page, which lives on the main thread, is not touched here.
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool,
                                                                 bool, const CefString &initiator, bool &) override {
    @autoreleasepool {
      BOOL (^blocks)(NSString *, NSString *, NSString *, NSArray<NSString *> *) = context_.blocksRequest;
      if (!blocks) return nullptr;
      return new RequestCheck(blocks, initiator.empty() ? nil : String(initiator));
    }
  }

  // Before anything is asked of the site: Cosmos stops pages and frames from dangerous sites here, so it covers the
  // first page of a popup too, which runs before Cosmos is attached to it.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool, bool) override {
    CosmosCEFBrowser *owner = owner_;
    if (!owner || !gNavigation) return false;
    return !gNavigation(owner, String(request->GetURL()), frame->IsMain());
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    gBeingMade--;
    gOpenBrowsers.push_back(browser);
    if (gShuttingDown) { browser->GetHost()->CloseBrowser(true); return; }
    [owner_ browserCreated:browser];
  }
  // A page closes on its own: CEF's way (DoClose answering false) would ask the window the page is in to close, every
  // other tab with it. Taking the page's view out of the window ends the browser instead.
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    [(__bridge NSView *)browser->GetHost()->GetWindowHandle() removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    // Popups it was making that CEF will not say more of (it tells an opener that is gone nothing).
    NSString *prefix = [NSString stringWithFormat:@"%d/", browser->GetIdentifier()];
    for (NSString *key in gPopupsBeingMade().allKeys) {
      if (![key hasPrefix:prefix]) continue;
      [gPopupsBeingMade()[key] browserClosed];
      [gPopupsBeingMade() removeObjectForKey:key];
      gBeingMade--;
    }
    gOpenBrowsers.erase(std::remove_if(gOpenBrowsers.begin(), gOpenBrowsers.end(),
                                       [&](const CefRefPtr<CefBrowser> &b) { return b->IsSame(browser); }),
                        gOpenBrowsers.end());
    [owner_ browserClosed];
    BrowserGone();
  }

  // Cosmos shows a context menu of its own (the page agent reports the click), so CEF's is left empty, which shows none.
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams>,
                           CefRefPtr<CefMenuModel> model) override {
    model->Clear();
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString &,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    CosmosCEFBrowser *owner = owner_;
    CosmosCEFDownload *download = [[CosmosCEFDownload alloc] initWithItem:item];
    NSString *path = owner && gDownloadStarted ? gDownloadStarted(owner, download) : nil;
    // A callback that is let go without being run cancels the download.
    if (!path) return true;
    gDownloads()[@(item->GetId())] = download;
    callback->Continue(path.fileSystemRepresentation, false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    NSNumber *key = @(item->GetId());
    CosmosCEFDownload *download = gDownloads()[key];
    if (!download) return;
    [download update:item callback:callback];
    if (download.isComplete || download.isCanceled || download.isInterrupted) [gDownloads() removeObjectForKey:key];
    if (gDownloadUpdated) gDownloadUpdated(download);
  }

  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString &origin, JSDialogType type, const CefString &message,
                  const CefString &defaultText, CefRefPtr<CefJSDialogCallback> callback, bool &) override {
    CosmosCEFDialogKind kind = type == JSDIALOGTYPE_CONFIRM  ? CosmosCEFDialogKindConfirm
                               : type == JSDIALOGTYPE_PROMPT ? CosmosCEFDialogKindPrompt
                                                             : CosmosCEFDialogKindAlert;
    Ask(kind, String(message), String(defaultText), String(origin), callback);
    return true;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString &message, bool,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    Ask(CosmosCEFDialogKindBeforeUnload, String(message), @"", String(browser->GetMainFrame()->GetURL()), callback);
    return true;
  }

  // Camera and microphone go to a page whose site the profile allows them (what Cosmos set after asking the user); the
  // screen is not shared.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, const CefString &,
                                      uint32_t requested, CefRefPtr<CefMediaAccessCallback> callback) override {
    const uint32_t devices = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    if (requested & ~devices) { callback->Cancel(); return true; }
    CefRefPtr<CefRequestContext> context = browser->GetHost()->GetRequestContext();
    // As in Chrome, a frame only gets what its page has.
    CefString page = browser->GetMainFrame()->GetURL();
    bool allowed = true;
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE)
      allowed &= context->GetContentSetting(page, page, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC) == CEF_CONTENT_SETTING_VALUE_ALLOW;
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE)
      allowed &= context->GetContentSetting(page, page, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA) == CEF_CONTENT_SETTING_VALUE_ALLOW;
    callback->Continue(allowed ? requested : CEF_MEDIA_PERMISSION_NONE);
    return true;
  }

  // Cosmos asks the user before a page's call reaches Chromium (page-bridge.js) and puts the answer into the profile, so
  // a prompt is answered from there: allowed when the profile allows every kind asked about, refused otherwise. CEF's
  // own answer, in a view of Cosmos's, would be none at all, and the page would wait for ever.
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t, const CefString &, uint32_t requested,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    CefRefPtr<CefRequestContext> context = browser->GetHost()->GetRequestContext();
    CefString page = browser->GetMainFrame()->GetURL();
    const struct { uint32_t type; cef_content_setting_types_t setting; } kinds[] = {
        {CEF_PERMISSION_TYPE_GEOLOCATION, CEF_CONTENT_SETTING_TYPE_GEOLOCATION},
        {CEF_PERMISSION_TYPE_NOTIFICATIONS, CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
        {CEF_PERMISSION_TYPE_CAMERA_STREAM, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA},
        {CEF_PERMISSION_TYPE_MIC_STREAM, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC},
    };
    uint32_t known = 0;
    bool allowed = requested != 0;
    for (const auto &kind : kinds) {
      known |= kind.type;
      if (requested & kind.type)
        allowed &= context->GetContentSetting(page, page, kind.setting) == CEF_CONTENT_SETTING_VALUE_ALLOW;
    }
    if (requested & ~known) allowed = false;
    callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  // A page opens one (window.open, a link to a new tab): CEF makes it in the holding view, never a window of its own,
  // and Cosmos decides where it goes when it shows up over the DevTools protocol.
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id, const CefString &target_url,
                     const CefString &target_frame_name, WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures &features, CefWindowInfo &info, CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override {
    // Cosmos is quitting: no new pages.
    if (gShuttingDown) return true;
    NSView *holder = PopupHolder();
    CosmosCEFBrowser *popup = [[CosmosCEFBrowser alloc] initPopupInView:holder opener:owner_];
    [gUnclaimedPopups() addObject:popup];
    popup.popupKey = PopupKey(browser, popup_id);
    gPopupsBeingMade()[popup.popupKey] = popup;
    gBeingMade++;
    NSRect bounds = holder.bounds;
    info.SetAsChild((__bridge CefWindowHandle)holder, CefRect(0, 0, (int)bounds.size.width, (int)bounds.size.height));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = new CosmosBrowserClient(popup, context_);
    return false;
  }

  // CEF did not make a popup it was going to (the opener closed, say): it is let go.
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
    NSString *key = PopupKey(browser, popup_id);
    CosmosCEFBrowser *popup = gPopupsBeingMade()[key];
    if (!popup) return;
    [gPopupsBeingMade() removeObjectForKey:key];
    gBeingMade--;
    [popup browserClosed];
    BrowserGone();
  }

 private:
  // Cosmos answers (with `gDialog`) once; a dialog nobody can show is refused.
  void Ask(CosmosCEFDialogKind kind, NSString *message, NSString *defaultText, NSString *origin,
           CefRefPtr<CefJSDialogCallback> callback) {
    CosmosCEFBrowser *owner = owner_;
    if (!owner || !gDialog) { callback->Continue(false, ""); return; }
    __block CefRefPtr<CefJSDialogCallback> pending = callback;
    gDialog(owner, kind, message, defaultText, origin, ^(BOOL accepted, NSString *text) {
      if (!pending) return;
      pending->Continue(accepted, text ? text.UTF8String : "");
      pending = nullptr;
    });
  }

  __weak CosmosCEFBrowser *owner_;
  CosmosCEFContext *context_;
  IMPLEMENT_REFCOUNTING(CosmosBrowserClient);
};

@implementation CosmosCEFBrowser {
  CefRefPtr<CefBrowser> _browser;
  NSView *_parent;
  BOOL _closeWhenMade;
  NSMutableArray<void (^)(NSString *)> *_waitingForTarget;
  double _zoomFactor;
}

- (void)dealloc {
  if (gStopped) (void)_browser.release();
}

- (instancetype)initPopupInView:(NSView *)holder opener:(CosmosCEFBrowser *)opener {
  if ((self = [super init])) {
    _parent = holder;
    _context = opener.context;
    _opener = opener;
    _zoomFactor = 1;
    _waitingForTarget = [NSMutableArray array];
  }
  return self;
}

- (instancetype)initInView:(NSView *)parent context:(CosmosCEFContext *)context url:(NSString *)url {
  if ((self = [super init])) {
    _parent = parent;
    _context = context;
    _zoomFactor = 1;
    _waitingForTarget = [NSMutableArray array];
    std::string address = url.UTF8String;
    CefRefPtr<CefRequestContext> requestContext = context->_context;
    CefRefPtr<CosmosBrowserClient> client = new CosmosBrowserClient(self, context);
    NSRect bounds = parent.bounds;
    __weak NSView *weakParent = parent;
    WhenReady(^{
      NSView *into = weakParent;
      if (!into) return;
      CefWindowInfo info;
      info.SetAsChild((__bridge CefWindowHandle)into,
                      CefRect(0, 0, (int)bounds.size.width, (int)bounds.size.height));
      info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
      CefBrowserSettings settings;
      if (gShuttingDown) return;
      gBeingMade++;
      if (!CefBrowserHost::CreateBrowser(info, client, address, settings, nullptr, requestContext)) gBeingMade--;
    });
  }
  return self;
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  if (_popupKey) [gPopupsBeingMade() removeObjectForKey:_popupKey];
  _popupKey = nil;
  NSView *view = self.view;
  // Cosmos moved it while CEF was making it.
  if (view.superview != _parent) {
    [view removeFromSuperview];
    [_parent addSubview:view];
  }
  view.frame = _parent.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (_closeWhenMade) { [self close]; return; }
  CefRefPtr<TargetLookup> lookup = new TargetLookup(self);
  lookup->Start(browser);
}

static void (^gTargetKnown)(CosmosCEFBrowser *) = nil;
+ (void (^)(CosmosCEFBrowser *))targetKnown { return gTargetKnown; }
+ (void)setTargetKnown:(void (^)(CosmosCEFBrowser *))block { gTargetKnown = [block copy]; }
+ (NSString *_Nullable (^)(CosmosCEFBrowser *, CosmosCEFDownload *))downloadStarted { return gDownloadStarted; }
+ (void)setDownloadStarted:(NSString *_Nullable (^)(CosmosCEFBrowser *, CosmosCEFDownload *))block { gDownloadStarted = [block copy]; }
+ (void (^)(CosmosCEFDownload *))downloadUpdated { return gDownloadUpdated; }
+ (void)setDownloadUpdated:(void (^)(CosmosCEFDownload *))block { gDownloadUpdated = [block copy]; }
+ (BOOL (^)(CosmosCEFBrowser *, NSString *, BOOL))navigation { return gNavigation; }
+ (void)setNavigation:(BOOL (^)(CosmosCEFBrowser *, NSString *, BOOL))block { gNavigation = [block copy]; }
+ (void (^)(CosmosCEFBrowser *, CosmosCEFDialogKind, NSString *, NSString *, NSString *, void (^)(BOOL, NSString *)))dialog {
  return gDialog;
}
+ (void)setDialog:(void (^)(CosmosCEFBrowser *, CosmosCEFDialogKind, NSString *, NSString *, NSString *, void (^)(BOOL, NSString *)))block {
  gDialog = [block copy];
}

- (void)targetNotFound {
  if (_isClosed || _targetID) return;
  NSArray *waiting = [_waitingForTarget copy];
  [_waitingForTarget removeAllObjects];
  for (void (^block)(NSString *) in waiting) block(nil);
}

- (void)targetFound:(NSString *)targetID {
  if (_isClosed || _targetID) return;
  _targetID = [targetID copy];
  gBrowsersByTarget()[_targetID] = self;
  NSArray *waiting = [_waitingForTarget copy];
  [_waitingForTarget removeAllObjects];
  for (void (^block)(NSString *) in waiting) block(_targetID);
  if (gTargetKnown) gTargetKnown(self);
}

- (void)whenTargetKnown:(void (^)(NSString *))block {
  if (_targetID) block(_targetID); else [_waitingForTarget addObject:[block copy]];
}

+ (CosmosCEFBrowser *)browserForTarget:(NSString *)targetID {
  CosmosCEFBrowser *browser = gBrowsersByTarget()[targetID];
  // Cosmos has it now: from here on it lives as long as Cosmos's page does.
  if (browser) [gUnclaimedPopups() removeObject:browser];
  return browser;
}

- (void)browserClosed {
  _browser = nullptr;
  _isClosed = YES;
  if (_targetID) [gBrowsersByTarget() removeObjectForKey:_targetID];
  [gUnclaimedPopups() removeObject:self];
  NSArray *waiting = [_waitingForTarget copy];
  [_waitingForTarget removeAllObjects];
  if (!_targetID) for (void (^block)(NSString *) in waiting) block(nil);
}

- (double)zoomFactor {
  if (_browser) return std::pow(1.2, _browser->GetHost()->GetZoomLevel());
  return _zoomFactor;
}

- (void)setZoomFactor:(double)factor {
  _zoomFactor = factor;
  if (_browser) _browser->GetHost()->SetZoomLevel(std::log(factor) / std::log(1.2));
}

- (void)showDevTools {
  if (!_browser) return;
  CefWindowInfo info;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(info, new DevToolsClient(), settings, CefPoint());
}

- (BOOL)hasDevTools {
  return _browser && _browser->GetHost()->HasDevTools();
}

- (void)closeDevTools {
  if (_browser) _browser->GetHost()->CloseDevTools();
}

- (NSView *)view {
  if (!_browser) return nil;
  return (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
}

- (void)moveToView:(NSView *)parent {
  _parent = parent;
  NSView *view = self.view;
  if (!view) return;
  [view removeFromSuperview];
  view.frame = parent.bounds;
  [parent addSubview:view];
  _browser->GetHost()->WasResized();
}

- (void)startDownload:(NSString *)url {
  if (_browser) _browser->GetHost()->StartDownload(url.UTF8String);
}

- (void)focus {
  if (_browser) _browser->GetHost()->SetFocus(true);
}

- (void)close {
  if (_isClosed) return;
  if (!_browser) { _closeWhenMade = YES; return; }
  _browser->GetHost()->CloseBrowser(true);
}

@end
