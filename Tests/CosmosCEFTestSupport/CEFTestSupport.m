#import <AppKit/AppKit.h>
#import "CosmosCEF.h"

// Runs as the test bundle loads, before any test: descriptors 3 and 4 are still free for Chromium's pipe, and NSApp has
// to be CEF's kind of application before anything makes a plain one.
@interface CosmosCEFTestSupport : NSObject
@end

@implementation CosmosCEFTestSupport
+ (void)load {
  CosmosCEFReservePipe();
  [CosmosApplication sharedApplication];
}
@end
