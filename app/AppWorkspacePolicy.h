#ifndef YOMADO_APP_WORKSPACE_POLICY_H
#define YOMADO_APP_WORKSPACE_POLICY_H
#import <Foundation/Foundation.h>
#include <math.h>

// These pure functions accept sanitized geometry only and have no GUI access.
static inline NSDictionary *YMWorkspaceGeometry(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"x", @"y", @"width", @"height"])
        if (![value[key] isKindOfClass:NSNumber.class] || !isfinite([value[key] doubleValue])) return nil;
    double x = [value[@"x"] doubleValue], y = [value[@"y"] doubleValue];
    double w = [value[@"width"] doubleValue], h = [value[@"height"] doubleValue];
    if (fabs(x) > 1000000 || fabs(y) > 1000000 || w < 1 || h < 1 || w > 100000 || h > 100000) return nil;
    return @{@"x": @(x), @"y": @(y), @"width": @(w), @"height": @(h)};
}
static inline BOOL YMWorkspaceUsableDisplay(id value) {
    return [value isKindOfClass:NSDictionary.class] && [value[@"displayID"] isKindOfClass:NSNumber.class] &&
        [value[@"displayID"] unsignedIntValue] > 0 && [value[@"isActive"] boolValue] &&
        [value[@"isOnline"] boolValue] && [value[@"isVirtual"] isKindOfClass:NSNumber.class] &&
        YMWorkspaceGeometry(value[@"bounds"]) != nil;
}
static inline double YMWorkspaceIntersection(NSDictionary *a, NSDictionary *b) {
    if (!YMWorkspaceGeometry(a) || !YMWorkspaceGeometry(b)) return 0;
    double left = fmax([a[@"x"] doubleValue], [b[@"x"] doubleValue]);
    double top = fmax([a[@"y"] doubleValue], [b[@"y"] doubleValue]);
    double right = fmin([a[@"x"] doubleValue] + [a[@"width"] doubleValue], [b[@"x"] doubleValue] + [b[@"width"] doubleValue]);
    double bottom = fmin([a[@"y"] doubleValue] + [a[@"height"] doubleValue], [b[@"y"] doubleValue] + [b[@"height"] doubleValue]);
    return fmax(0, right - left) * fmax(0, bottom - top);
}
// An update origin belongs only to the exact currently visible owned window.
// A closed/replaced ID or a manual physical return cannot pass an old origin to
// another window. Complete update inventory validation is a separate gate.
static inline NSDictionary *YMWorkspaceCheckpointWindow(pid_t pid, uint32_t windowID,
    NSArray<NSDictionary *> *inventory, NSArray<NSNumber *> *ownedIDs) {
    NSDictionary *found=nil;
    for (NSDictionary *window in inventory) {
        if ([window[@"pid"] intValue]!=pid || [window[@"windowID"] unsignedIntValue]!=windowID) continue;
        if (found) return nil;
        found=window;
    }
    return found && [ownedIDs containsObject:found[@"displayID"]] ? found : nil;
}
// One display owns each window: greatest intersecting area. Ties favor a
// physical display, then the smaller ID, independently of enumeration order.
// Thin edge overlaps therefore do not count a window on two displays.
static inline NSDictionary *YMWorkspaceDisplayForFrame(NSDictionary *frame, NSArray *displays) {
    if (!YMWorkspaceGeometry(frame)) return nil;
    NSDictionary *best = nil; double bestArea = 0;
    for (id display in displays) {
        if (!YMWorkspaceUsableDisplay(display)) continue;
        double area = YMWorkspaceIntersection(frame, display[@"bounds"]);
        BOOL tieWins = best && area == bestArea && area > 0 &&
            (([best[@"isVirtual"] boolValue] && ![display[@"isVirtual"] boolValue]) ||
             ([best[@"isVirtual"] boolValue] == [display[@"isVirtual"] boolValue] &&
              [display[@"displayID"] unsignedIntValue] < [best[@"displayID"] unsignedIntValue]));
        if (area > bestArea || tieWins) { best = display; bestArea = area; }
    }
    return best;
}
static inline BOOL YMWorkspaceVisibleOrdinaryGeometry(NSDictionary *frame, NSInteger layer, BOOL onScreen, double alpha) {
    return YMWorkspaceGeometry(frame) && layer == 0 && onScreen && isfinite(alpha) && alpha > 0 &&
        [frame[@"width"] doubleValue] >= 80 && [frame[@"height"] doubleValue] >= 64;
}
static inline BOOL YMWorkspaceSameFrame(NSDictionary *a, NSDictionary *b) {
    if (!YMWorkspaceGeometry(a) || !YMWorkspaceGeometry(b)) return NO;
    for (NSString *key in @[@"x", @"y", @"width", @"height"])
        if (fabs([a[key] doubleValue] - [b[key] doubleValue]) > 3) return NO;
    return YES;
}
static inline NSDictionary *YMWorkspacePhysicalDisplay(NSString *preferredUUID, NSArray *displays) {
    NSDictionary *first = nil, *main = nil;
    for (id display in displays) {
        if (!YMWorkspaceUsableDisplay(display) || [display[@"isVirtual"] boolValue]) continue;
        if (!first || [display[@"displayID"] unsignedIntValue] < [first[@"displayID"] unsignedIntValue]) first = display;
        if ([display[@"isMain"] boolValue]) main = display;
        if (preferredUUID.length && [display[@"displayUUID"] isEqual:preferredUUID]) return display;
    }
    return main ?: first;
}
// An origin stores only geometry relative to the physical display UUID.
static inline NSDictionary *YMWorkspaceOrigin(NSDictionary *frame, NSDictionary *display) {
    if (!YMWorkspaceGeometry(frame) || !YMWorkspaceUsableDisplay(display) || [display[@"isVirtual"] boolValue]) return nil;
    NSDictionary *bounds = display[@"bounds"];
    return @{@"displayUUID": [display[@"displayUUID"] isKindOfClass:NSString.class] ? display[@"displayUUID"] : @"",
        @"relative": @{@"x": @([frame[@"x"] doubleValue] - [bounds[@"x"] doubleValue]),
                       @"y": @([frame[@"y"] doubleValue] - [bounds[@"y"] doubleValue]),
                       @"width": frame[@"width"], @"height": frame[@"height"]}};
}
static inline NSDictionary *YMWorkspaceUsablePlacementBounds(NSDictionary *display) {
    NSDictionary *bounds = YMWorkspaceGeometry(display[@"bounds"]);
    NSDictionary *visible = YMWorkspaceGeometry(display[@"visibleBounds"]);
    if (!bounds) return nil;
    if (visible && YMWorkspaceIntersection(visible, bounds) >=
        [visible[@"width"] doubleValue] * [visible[@"height"] doubleValue] - 0.5) return visible;
    return @{@"x": bounds[@"x"], @"y": @([bounds[@"y"] doubleValue] + fmin(32, [bounds[@"height"] doubleValue] - 1)),
        @"width": bounds[@"width"], @"height": @(fmax(1, [bounds[@"height"] doubleValue] - 32))};
}
static inline NSDictionary *YMWorkspaceFrameOnDisplay(NSDictionary *size, NSDictionary *relative, NSDictionary *display) {
    if (!YMWorkspaceGeometry(size) || !YMWorkspaceUsableDisplay(display)) return nil;
    NSDictionary *bounds = display[@"bounds"], *available = YMWorkspaceUsablePlacementBounds(display);
    double left = [available[@"x"] doubleValue], top = [available[@"y"] doubleValue];
    double bw = [available[@"width"] doubleValue], bh = [available[@"height"] doubleValue];
    double w = fmin([size[@"width"] doubleValue], bw), h = fmin([size[@"height"] doubleValue], bh);
    BOOL remembered = YMWorkspaceGeometry(relative) != nil;
    double x = remembered ? [bounds[@"x"] doubleValue] + [relative[@"x"] doubleValue] : left + (bw - w) / 2;
    double y = remembered ? [bounds[@"y"] doubleValue] + [relative[@"y"] doubleValue] : top + (bh - h) / 2;
    x = fmin(fmax(x, left), left + bw - w); y = fmin(fmax(y, top), top + bh - h);
    return @{@"x": @(x), @"y": @(y), @"width": @(w), @"height": @(h)};
}
static inline BOOL YMWorkspaceFrameFits(NSDictionary *frame, NSDictionary *display) {
    if (!YMWorkspaceGeometry(frame) || !YMWorkspaceUsableDisplay(display)) return NO;
    NSDictionary *b = YMWorkspaceUsablePlacementBounds(display);
    return [frame[@"x"] doubleValue] >= [b[@"x"] doubleValue] - 2 &&
        [frame[@"y"] doubleValue] >= [b[@"y"] doubleValue] - 2 &&
        [frame[@"x"] doubleValue] + [frame[@"width"] doubleValue] <= [b[@"x"] doubleValue] + [b[@"width"] doubleValue] + 2 &&
        [frame[@"y"] doubleValue] + [frame[@"height"] doubleValue] <= [b[@"y"] doubleValue] + [b[@"height"] doubleValue] + 2;
}
// A requested destination is exact, never silently replaced with another
// physical display. A mismatched origin supplies size, but not old coordinates.
static inline BOOL YMWorkspaceOriginBelongsToDisplay(NSDictionary *origin, NSDictionary *display) {
    NSString *uuid = [origin[@"displayUUID"] isKindOfClass:NSString.class] ? origin[@"displayUUID"] : nil;
    return uuid.length && [display[@"displayUUID"] isEqual:uuid];
}
static inline NSDictionary *YMWorkspaceFrameForExplicitPhysicalReturn(NSDictionary *origin, NSDictionary *current, NSDictionary *target) {
    if (!YMWorkspaceUsableDisplay(target) || [target[@"isVirtual"] boolValue]) return nil;
    NSDictionary *remembered = YMWorkspaceGeometry(origin[@"relative"]);
    return YMWorkspaceFrameOnDisplay(remembered ?: current,
        YMWorkspaceOriginBelongsToDisplay(origin, target) ? remembered : nil, target);
}
static inline BOOL YMWorkspaceGenericMutationAllowed(NSString *bundleID) {
    return bundleID.length > 0 && ![bundleID isEqualToString:@"com.tencent.xinWeChat"] &&
        ![bundleID isEqualToString:@"dev.chekusu.yomado"];
}
static inline BOOL YMWorkspaceGenericRestoreAllowed(NSString *bundleID) {
    return bundleID.length > 0 && ![bundleID isEqualToString:@"dev.chekusu.yomado"];
}
// nil is an explicit whole-app drop, 0 is the physical card, and an actual
// display ID is an internal source card. A card drag never sweeps other cards.
static inline BOOL YMWorkspaceMatchesSource(NSDictionary *window, NSNumber *sourceFilter) {
    if (!sourceFilter) return YES;
    if (!sourceFilter.unsignedIntValue) return [window[@"isVirtual"] isKindOfClass:NSNumber.class] && ![window[@"isVirtual"] boolValue];
    return [window[@"displayID"] isKindOfClass:NSNumber.class] &&
        [window[@"displayID"] unsignedIntValue] == sourceFilter.unsignedIntValue;
}
// "「Marvelous Designer」1 个窗口、「文本编辑」3 个窗口": per-app counts of
// windows that will be left for macOS to relocate, merged by app name.
static inline NSString *YMWorkspaceUnmovableSummary(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [item[@"appName"] isKindOfClass:NSString.class] && [item[@"appName"] length] ? item[@"appName"] : @"应用";
        NSUInteger count = [item[@"count"] isKindOfClass:NSNumber.class] ? [item[@"count"] unsignedIntegerValue] : 0;
        if (!count) continue;
        if (!counts[name]) [names addObject:name];
        counts[name] = @(counts[name].unsignedIntegerValue + count);
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *name in names)
        [parts addObject:[NSString stringWithFormat:@"「%@」%lu 个窗口", name, (unsigned long)counts[name].unsignedIntegerValue]];
    return [parts componentsJoinedByString:@"、"];
}
// AX movement can settle before CoreGraphics publishes the new window frame.
// An old physical CG frame alone must not retire a freshly captured origin.
// Confirm a manual physical return only when both independent observations
// agree; absent, stale or inaccessible geometry always preserves the record.
static inline BOOL YMWorkspacePhysicalReturnConfirmed(NSDictionary *cgFrame, NSDictionary *axFrame,
                                                      NSArray *displays, BOOL operationInProgress) {
    if (operationInProgress || !YMWorkspaceSameFrame(cgFrame, axFrame)) return NO;
    NSDictionary *cgDisplay = YMWorkspaceDisplayForFrame(cgFrame, displays);
    NSDictionary *axDisplay = YMWorkspaceDisplayForFrame(axFrame, displays);
    return cgDisplay && axDisplay && ![cgDisplay[@"isVirtual"] boolValue] && ![axDisplay[@"isVirtual"] boolValue] &&
        [cgDisplay[@"displayID"] isEqual:axDisplay[@"displayID"]];
}
#endif
