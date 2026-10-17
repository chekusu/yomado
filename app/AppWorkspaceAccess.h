#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Injected boundary for CG/AX window inventory and guarded writes.
/// Implementations must never read titles, children or document contents.
@protocol YMWorkspaceWindowAccess <NSObject>
- (BOOL)accessibilityTrusted;
- (nullable NSArray<NSDictionary *> *)visibleWindows;
- (nullable NSRunningApplication *)applicationForPID:(pid_t)pid;
- (NSArray<NSRunningApplication *> *)applicationsForBundleIdentifier:(NSString *)bundleID;
/// deadline is absolute NSProcessInfo.systemUptime. Returns
/// {windows: AXRecords, complete: BOOL, reason: NSString}.
- (NSDictionary *)observeApplication:(NSRunningApplication *)application
                           deadline:(NSTimeInterval)deadline;
- (nullable NSDictionary *)observeElement:(id)element;
- (nullable id)resolveIdentity:(NSDictionary *)identity error:(NSError **)error;
- (BOOL)setPosition:(CGPoint)position element:(id)element
   expectedIdentity:(NSDictionary *)identity;
- (BOOL)setSize:(CGSize)size element:(id)element
expectedIdentity:(NSDictionary *)identity;
@end

@interface YMSystemWorkspaceWindowAccess : NSObject <YMWorkspaceWindowAccess>
@end

NS_ASSUME_NONNULL_END
