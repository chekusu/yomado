#ifndef YOMADO_APP_WORKSPACE_H
#define YOMADO_APP_WORKSPACE_H

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "AppWorkspaceAccess.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const YMAppWorkspaceErrorDomain;

// Main-thread-only window placement manager. Inventory reads window geometry,
// never titles, content or screenshots. An inventory entry means a visible
// ordinary window exists on the display; it does not prove GPU rendering.
// Original placements and retained AX identities live in memory only. Closing
// yomado must call restoreAll: before removing its displays. Never instantiate
// this manager in the synthetic UI preview path.
@interface YMAppWorkspace : NSObject
- (instancetype)initWithWindowAccess:(id<YMWorkspaceWindowAccess>)access;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *rows;
@property(nonatomic, copy, readonly) NSString *statusText;
@property(nonatomic, readonly) BOOL accessibilityTrusted;
@property(nonatomic, copy, nullable) void (^inventoryDidChange)(void);
// Complete published observation matching current topology/permission algebra.
// Pending, failed, or expired inventory is never ready for close/export gates.
@property(nonatomic, readonly) BOOL inventoryReady;
@property(nonatomic, readonly) BOOL needsRestoreBeforeRemovingVirtualDisplay;
- (void)refreshWithVirtualDisplayIDs:(NSArray<NSNumber *> *)displayIDs
                   displaySnapshot:(NSArray<NSDictionary *> *)snapshot;
// ID 0 groups physical displays; an actual ID selects just that display.
// Rows contain appName, bundleIdentifier, pid, pids, windowCount,
// managedWindowCount, appURL (NSURL), and optional appIcon (NSImage).
- (NSArray<NSDictionary *> *)rowsForDisplayID:(CGDirectDisplayID)displayID;
- (BOOL)moveApplicationAtURL:(NSURL *)URL toDisplayID:(CGDirectDisplayID)displayID
                      error:(NSError * _Nullable * _Nullable)error;
// Internal card dragging is source-scoped. Source 0 means physical displays;
// other source IDs select only that display, preserving the app's other windows.
- (BOOL)moveApplicationAtURL:(NSURL *)URL fromDisplayID:(CGDirectDisplayID)sourceID
                toDisplayID:(CGDirectDisplayID)displayID error:(NSError * _Nullable * _Nullable)error;
- (BOOL)restoreApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
                                fromDisplayID:(CGDirectDisplayID)displayID
                                        error:(NSError * _Nullable * _Nullable)error;
// Explicit virtual -> physical tile drag. Only windows on the source workspace
// move. Reuse the remembered placement only when it belongs to the requested
// physical display; otherwise center safely on that display. Physical ->
// physical transfers are intentionally not handled by this recovery method.
- (BOOL)restoreApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
                                fromDisplayID:(CGDirectDisplayID)sourceDisplayID
                          toPhysicalDisplayID:(CGDirectDisplayID)physicalDisplayID
                                        error:(NSError * _Nullable * _Nullable)error;
- (BOOL)restoreDisplayID:(CGDirectDisplayID)displayID error:(NSError * _Nullable * _Nullable)error;
- (BOOL)restoreAll:(NSError * _Nullable * _Nullable)error;
- (BOOL)needsRestoreForDisplayID:(CGDirectDisplayID)displayID;
- (BOOL)inventoryReadyForClosingDisplayID:(CGDirectDisplayID)displayID;
// Before closing a display: per-app counts ({appName, count}) of visible
// windows that cannot be matched to a movable ordinary window, such as
// dialogs, splash screens and tool windows. nil means evidence is pending or
// unreliable, not an empty display. Read-only; never moves a window.
- (nullable NSArray<NSDictionary *> *)unmovableWindowsForDisplayID:(CGDirectDisplayID)displayID;
// After the user agrees, restoring this display returns the matched windows
// and leaves only the exact windows just offered for confirmation to macOS.
- (void)allowUnmovableWindowsOnDisplayID:(CGDirectDisplayID)displayID;
- (void)cancelUnmovableWindowAllowances;
// Update-only handoff. These methods preserve existing physical origins for
// exact extant windows, never application-level matching or content state.
- (nullable NSArray<NSDictionary *> *)restartOriginCheckpointsWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)adoptRestartOriginCheckpoints:(NSArray<NSDictionary *> *)checkpoints
                               error:(NSError * _Nullable * _Nullable)error;

// Compatibility with the single-display controller. Multi-display callers
// should use the explicit destination/source methods above.
- (void)refreshWithVirtualDisplayID:(CGDirectDisplayID)displayID displaySnapshot:(NSArray<NSDictionary *> *)snapshot;
- (BOOL)moveApplicationAtURL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)restoreApplicationWithBundleIdentifier:(NSString *)bundleIdentifier error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
