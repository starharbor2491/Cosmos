// Chromium, through CEF, inside Cosmos's process. Pages are CEF browsers drawn in views Cosmos owns; everything else
// goes over the DevTools protocol on the pipe CosmosCEFReservePipe sets up (see docs/cef-engine.md).
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The application class. CEF needs NSApp to tell it when an event is being sent (CefAppProtocol), so this has to be
/// the class of NSApp before anything makes a plain NSApplication.
@interface CosmosApplication : NSApplication
@end

/// Takes descriptors 3 and 4 of this process for Chromium's DevTools pipe: Chromium reads commands from 3 and writes its
/// answers to 4 of its browser process, which is this one. Call it before anything else opens a file, which could be
/// given one of those numbers. Does nothing the second time. NO when no pipe could be made.
FOUNDATION_EXPORT BOOL CosmosCEFReservePipe(void);
/// Cosmos's ends of the pipe: commands are written to the first and answers read from the second (-1 before reserving).
FOUNDATION_EXPORT int CosmosCEFCommandDescriptor(void);
FOUNDATION_EXPORT int CosmosCEFAnswerDescriptor(void);

@interface CosmosCEFRuntime : NSObject
/// Starts CEF in this process; a second call does nothing. `mainBundle` is the app the helper apps are inside (nil: this
/// process's own; the helpers find the browser by that app's bundle identifier). `framework` is the Chromium Embedded
/// Framework.framework, `helper` the executable of `Cosmos Helper.app` (its GPU, renderer, plugin and alerts siblings sit
/// next to it), `rootCache` the folder every profile's folder is inside, `globalCache` the folder of the profile CEF
/// starts with (inside `rootCache`), `switches` Chromium switches ("--name" or "--name=value"). `keychainName` names the
/// Keychain item Chromium keeps the key of cookies and saved data in, "<name> Safe Storage" (account <name>); nil leaves
/// Chromium's own, "Chromium Safe Storage", which other Chromium-based apps share. With `sandboxed`, the
/// helpers run in Chromium's sandbox, which lets them read only the app this process is: NO only where this process is not
/// that app (a test runner). The DevTools pipe is always on. NO, with the reason in `lastError`, when CEF did not start.
+ (BOOL)startWithMainBundle:(nullable NSString *)mainBundle
                  framework:(NSString *)framework
                     helper:(NSString *)helper
                  rootCache:(NSString *)rootCache
                globalCache:(NSString *)globalCache
                   switches:(NSArray<NSString *> *)switches
               keychainName:(nullable NSString *)keychainName
                  sandboxed:(BOOL)sandboxed;
/// Closes every page and stops CEF, so that what Chromium has not written yet (cookies, settings) reaches the disk, then
/// runs `done` on the main thread with YES. A page that does not close within three seconds leaves CEF running, and
/// `done` runs then with NO. CEF does not start again in this process.
+ (void)shutdown:(void (^)(BOOL stopped))done;
/// `block` runs on the main thread once CEF's own context is ready for profiles and pages (at once if it is).
+ (void)whenReady:(dispatch_block_t)block;
/// Puts settings of the whole browser (what `Local State` holds) into the running Chromium, as `setPreferences:` does.
+ (void)setGlobalPreferences:(NSDictionary<NSString *, id> *)preferences;
/// Loads the framework (once). Loading it puts Chromium's memory allocator in place of the system's for the whole process,
/// and another thread freeing memory while that happens can crash: load it before other threads start.
+ (BOOL)loadFramework:(NSString *)framework;
/// True while CEF does its work on the main thread. What runs then (a key Chromium hands back to the menus, say) must not
/// wait for CEF: nothing CEF has to do runs until its work returns.
@property (class, readonly) BOOL isDoingWork;
@property (class, readonly) BOOL isRunning;
/// The browsers CEF has made for Cosmos and not yet closed, and those asked for and not made yet.
@property (class, readonly) NSInteger openBrowserCount;
@property (class, readonly, nullable) NSString *lastError;
@property (class, readonly) NSString *chromiumVersion;
@end

typedef NS_ENUM(NSInteger, CosmosCEFPermission) {
  CosmosCEFPermissionCamera,
  CosmosCEFPermissionMicrophone,
  CosmosCEFPermissionLocation,
  CosmosCEFPermissionNotifications,
};

typedef NS_ENUM(NSInteger, CosmosCEFPermissionSetting) {
  /// Asked again: the profile's default.
  CosmosCEFPermissionSettingDefault,
  CosmosCEFPermissionSettingAllow,
  CosmosCEFPermissionSettingBlock,
};

/// A cookie to put into a profile.
@interface CosmosCEFCookie : NSObject
/// "example.com" for a cookie only that host gets, ".example.com" for one its subdomains get too.
@property (nonatomic, copy) NSString *domain;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *path;
/// Nil for a cookie that ends with the session.
@property (nonatomic, copy, nullable) NSDate *expires;
@property (nonatomic) BOOL secure;
@property (nonatomic) BOOL httpOnly;
/// Chromium's numbers: -1 unspecified, 0 none, 1 lax, 2 strict.
@property (nonatomic) NSInteger sameSite;
@end

/// A profile: its cookies, storage and cache in its own folder inside the root cache, or in memory only. The DevTools
/// protocol finds only the global one by its browser context id, so what is set per profile is set here.
@interface CosmosCEFContext : NSObject
/// `cachePath` nil keeps nothing on disk (a private window).
- (instancetype)initWithCachePath:(nullable NSString *)cachePath;
/// The profile CEF starts with (the DevTools protocol loads extensions into this one only).
@property (class, readonly) CosmosCEFContext *globalContext;
- (instancetype)init NS_UNAVAILABLE;
/// What the profile lets `origin` ("https://host:port") do. Camera and microphone are granted to a page only when this
/// allows them.
- (void)setPermission:(CosmosCEFPermission)permission origin:(NSString *)origin to:(CosmosCEFPermissionSetting)setting;
/// Deletes every cookie of the profile; `done` runs on the main thread after.
- (void)deleteCookies:(dispatch_block_t)done;
/// Puts `cookies` into the profile; `done` runs on the main thread with how many Chromium took (it refuses one that is
/// not valid for its site, such as a SameSite=None cookie that is not secure).
- (void)setCookies:(NSArray<CosmosCEFCookie *> *)cookies done:(void (^)(NSInteger taken))done;
/// Asked about each request of the profile's pages before it is made, on CEF's network thread (not the main one): YES
/// stops it. It gets the request's address, its kind ("main_frame", "script", … as declarativeNetRequest names them), the
/// origin that made it, and the address of the document it is for and of each document that one is in, nearest first.
@property (atomic, copy, nullable) BOOL (^blocksRequest)(NSString *url, NSString *type, NSString *_Nullable initiator,
                                                         NSArray<NSString *> *documents);
/// Puts settings into the running profile, as its `Preferences` file holds them: each key is a setting Chromium has, or
/// a group of them. Settings Chromium does not have, or does not let be set, are left out.
- (void)setPreferences:(NSDictionary<NSString *, id> *)preferences;
@end

/// A file a page is downloading.
@interface CosmosCEFDownload : NSObject
@property (readonly) NSString *url;
@property (readonly) NSString *suggestedName;
@property (readonly) int64_t received;
/// -1 while it is not known.
@property (readonly) int64_t total;
@property (readonly) BOOL isComplete;
@property (readonly) BOOL isCanceled;
/// It stopped before the end (the connection went, the disk was full).
@property (readonly) BOOL isInterrupted;
- (void)cancel;
- (instancetype)init NS_UNAVAILABLE;
@end

/// What a page's `alert`, `confirm`, `prompt` or leave-the-page question asks.
typedef NS_ENUM(NSInteger, CosmosCEFDialogKind) {
  CosmosCEFDialogKindAlert,
  CosmosCEFDialogKindConfirm,
  CosmosCEFDialogKindPrompt,
  CosmosCEFDialogKindBeforeUnload,
};

/// One page: a CEF browser drawn inside `parent`, filling it. It appears over the DevTools pipe as a page target whose
/// first address is `url`; Cosmos finds it there.
@interface CosmosCEFBrowser : NSObject
- (instancetype)initInView:(NSView *)parent context:(CosmosCEFContext *)context url:(NSString *)url;
- (instancetype)init NS_UNAVAILABLE;
/// The view CEF draws in, once it has made it.
@property (readonly, nullable) NSView *view;
@property (readonly) BOOL isClosed;
/// Its page target in the DevTools protocol, once CEF has made the browser and the browser has said which it is.
@property (readonly, nullable) NSString *targetID;
/// `block` runs on the main thread with `targetID` once it is known (at once if it is), or with nil if the browser
/// closes first.
- (void)whenTargetKnown:(void (^)(NSString *_Nullable targetID))block;
/// The browser whose page opened this one, for a popup.
@property (readonly, weak, nullable) CosmosCEFBrowser *opener;
/// The browser of the page target `targetID`: one Cosmos made, or a popup a page opened. Nil when there is none (yet).
+ (nullable CosmosCEFBrowser *)browserForTarget:(NSString *)targetID NS_SWIFT_NAME(browser(forTarget:));
/// Called on the main thread for every browser, popups included, once its target is known.
@property (class, nonatomic, copy, nullable) void (^targetKnown)(CosmosCEFBrowser *browser);
/// Page zoom, 1 for 100%. Chromium keeps it by site, so it is what the site has once the page has loaded.
@property (nonatomic) double zoomFactor;
/// A download began in `browser`: the block says where the file goes (nil cancels it). Its progress then comes to
/// `downloadUpdated`. Both run on the main thread.
@property (class, nonatomic, copy, nullable) NSString *_Nullable (^downloadStarted)(CosmosCEFBrowser *browser, CosmosCEFDownload *download);
@property (class, nonatomic, copy, nullable) void (^downloadUpdated)(CosmosCEFDownload *download);
/// Asked on the main thread before every navigation of every page and frame, redirects included: NO stops it before
/// anything is sent. Without it every navigation goes on.
@property (class, nonatomic, copy, nullable) BOOL (^navigation)(CosmosCEFBrowser *browser, NSString *url, BOOL isMainFrame);
/// A page's dialog: the block shows it and calls `answer` once (with the text typed, for a prompt). Without it the
/// dialog is refused.
@property (class, nonatomic, copy, nullable) void (^dialog)(CosmosCEFBrowser *browser, CosmosCEFDialogKind kind, NSString *message,
                                                            NSString *defaultText, NSString *origin,
                                                            void (^answer)(BOOL accepted, NSString *_Nullable text));
/// Moves the page into another view (a tab's, a split pane's), filling it.
- (void)moveToView:(NSView *)parent;
/// Downloads `url` with this page's profile and cookies, as "Download Linked File" does: it goes to `downloadStarted`.
- (void)startDownload:(NSString *)url;
/// Gives the page the keyboard: its view becomes its window's first responder.
- (void)focus;
/// Chromium's DevTools for this page, in a window of CEF's own (CEF draws them in no view of Cosmos's), closed with it.
- (void)showDevTools;
- (void)closeDevTools;
@property (readonly) BOOL hasDevTools;
- (void)close;
@end

NS_ASSUME_NONNULL_END
