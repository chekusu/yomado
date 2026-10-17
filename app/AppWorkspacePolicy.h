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
// Exact five-field identity: valid integers/string, then full equality. No geometry join.
static inline BOOL YMWorkspaceIdentityInteger(id value, uint64_t minimum, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= minimum && number <= maximum && floor(number) == number;
}
static inline BOOL YMWorkspaceIdentityValid(NSDictionary *identity) {
    return [identity isKindOfClass:NSDictionary.class] && identity.count == 5 &&
        YMWorkspaceIdentityInteger(identity[@"pid"], 1, INT_MAX) &&
        YMWorkspaceIdentityInteger(identity[@"windowID"], 1, UINT32_MAX) &&
        YMWorkspaceIdentityInteger(identity[@"startSeconds"], 1, UINT64_C(9999999999)) &&
        YMWorkspaceIdentityInteger(identity[@"startMicroseconds"], 0, 999999) &&
        [identity[@"bundleID"] isKindOfClass:NSString.class] && [identity[@"bundleID"] length] > 0 &&
        [identity[@"bundleID"] length] <= 255;
}
static inline BOOL YMWorkspaceSameWindowIdentity(NSDictionary *a, NSDictionary *b) {
    return YMWorkspaceIdentityValid(a) && YMWorkspaceIdentityValid(b) && [a isEqual:b];
}
static inline BOOL YMWorkspaceCGCandidateIdentity(NSDictionary *cg) {
    return [cg isKindOfClass:NSDictionary.class] &&
        YMWorkspaceIdentityInteger(cg[@"pid"], 1, INT_MAX) &&
        YMWorkspaceIdentityInteger(cg[@"windowID"], 1, UINT32_MAX);
}
// True only for surfaces that are classifiable and clearly not candidates.
static inline BOOL YMWorkspaceCGCandidateClearlyInvisible(NSDictionary *cg) {
    if (!YMWorkspaceCGCandidateIdentity(cg) || !YMWorkspaceGeometry(cg[@"frame"])) return NO;
    if (![cg[@"layer"] isKindOfClass:NSNumber.class] ||
        ![cg[@"onScreen"] isKindOfClass:NSNumber.class] ||
        ![cg[@"alpha"] isKindOfClass:NSNumber.class] ||
        !isfinite([cg[@"alpha"] doubleValue])) return NO;
    return [cg[@"layer"] integerValue] != 0 || ![cg[@"onScreen"] boolValue] ||
        [cg[@"alpha"] doubleValue] <= 0;
}
static inline BOOL YMWorkspaceCGCandidateVisible(NSDictionary *cg) {
    if (!YMWorkspaceCGCandidateIdentity(cg) || !YMWorkspaceGeometry(cg[@"frame"])) return NO;
    return [cg[@"layer"] isKindOfClass:NSNumber.class] && [cg[@"layer"] integerValue] == 0 &&
        [cg[@"onScreen"] isKindOfClass:NSNumber.class] && [cg[@"onScreen"] boolValue] &&
        [cg[@"alpha"] isKindOfClass:NSNumber.class] && isfinite([cg[@"alpha"] doubleValue]) &&
        [cg[@"alpha"] doubleValue] > 0;
}
static inline BOOL YMWorkspaceAXStateNumber(id value) {
    return [value isKindOfClass:NSNumber.class];
}
static inline BOOL YMWorkspaceCGMeetsOldSize(NSDictionary *frame) {
    return YMWorkspaceGeometry(frame) &&
        [frame[@"width"] doubleValue] >= 80 && [frame[@"height"] doubleValue] >= 64;
}
static inline NSString *YMWorkspaceWindowKey(id pid, id windowID) {
    return [NSString stringWithFormat:@"%@:%@", pid, windowID];
}
static inline NSDictionary *YMWorkspaceBlocker(id pid, id windowID, NSString *reason,
                                               NSDictionary *display) {
    NSMutableDictionary *blocker = [@{@"pid": pid, @"windowID": windowID, @"reason": reason} mutableCopy];
    if (display) {
        blocker[@"displayID"] = display[@"displayID"];
        blocker[@"isVirtual"] = display[@"isVirtual"];
    }
    return blocker;
}
// Associate CG visibility with AX identity, then size and own by real AX geometry.
static inline NSDictionary *YMWorkspaceNormalizeWindowSnapshot(
    NSArray<NSDictionary *> *cgWindows, NSArray<NSDictionary *> *axWindows,
    BOOL enumerationComplete, NSArray<NSDictionary *> *displays) {
    if (!enumerationComplete || ![cgWindows isKindOfClass:NSArray.class] ||
        ![axWindows isKindOfClass:NSArray.class] || ![displays isKindOfClass:NSArray.class])
        return @{@"windows": @[], @"blockers": @[], @"complete": @NO};

    NSMutableDictionary *cgByKey = [NSMutableDictionary dictionary];
    NSMutableDictionary *axByKey = [NSMutableDictionary dictionary];
    NSMutableSet *duplicateKeys = [NSMutableSet set];
    NSMutableDictionary *pidByWindowID = [NSMutableDictionary dictionary];
    NSMutableSet *crossPIDWindowIDs = [NSMutableSet set];
    NSMutableArray *blockers = [NSMutableArray array];
    NSMutableArray *windows = [NSMutableArray array];
    BOOL complete = YES;

    for (NSDictionary *cg in cgWindows) {
        if (![cg isKindOfClass:NSDictionary.class]) { complete = NO; continue; }
        if (!YMWorkspaceCGCandidateIdentity(cg)) { complete = NO; continue; }
        if (YMWorkspaceCGCandidateClearlyInvisible(cg)) continue;
        if (!YMWorkspaceCGCandidateVisible(cg)) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"invalidCG", nil)];
            continue;
        }
        NSString *key = YMWorkspaceWindowKey(cg[@"pid"], cg[@"windowID"]);
        if (cgByKey[key]) [duplicateKeys addObject:key];
        else cgByKey[key] = cg;
        NSNumber *prior = pidByWindowID[cg[@"windowID"]];
        if (prior && ![prior isEqual:cg[@"pid"]]) [crossPIDWindowIDs addObject:cg[@"windowID"]];
        else pidByWindowID[cg[@"windowID"]] = cg[@"pid"];
    }
    for (NSDictionary *ax in axWindows) {
        if (![ax isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *identity = ax[@"identity"];
        if (![identity isKindOfClass:NSDictionary.class] ||
            !YMWorkspaceIdentityInteger(identity[@"pid"], 1, INT_MAX) ||
            !YMWorkspaceIdentityInteger(identity[@"windowID"], 1, UINT32_MAX)) continue;
        NSString *key = YMWorkspaceWindowKey(identity[@"pid"], identity[@"windowID"]);
        if (axByKey[key]) [duplicateKeys addObject:key];
        else axByKey[key] = ax;
        NSNumber *prior = pidByWindowID[identity[@"windowID"]];
        if (prior && ![prior isEqual:identity[@"pid"]]) [crossPIDWindowIDs addObject:identity[@"windowID"]];
        else pidByWindowID[identity[@"windowID"]] = identity[@"pid"];
    }

    if (duplicateKeys.count || crossPIDWindowIDs.count) {
        for (NSString *key in duplicateKeys) {
            NSDictionary *cg = cgByKey[key];
            NSDictionary *ax = axByKey[key];
            id pid = cg[@"pid"] ?: ax[@"identity"][@"pid"];
            id windowID = cg[@"windowID"] ?: ax[@"identity"][@"windowID"];
            if (pid && windowID)
                [blockers addObject:YMWorkspaceBlocker(pid, windowID, @"duplicate", nil)];
        }
        for (NSNumber *windowID in crossPIDWindowIDs)
            [blockers addObject:YMWorkspaceBlocker(@0, windowID, @"crossPID", nil)];
        return @{@"windows": @[], @"blockers": blockers, @"complete": @YES};
    }

    for (NSString *key in cgByKey) {
        NSDictionary *cg = cgByKey[key];
        NSDictionary *ax = axByKey[key];
        if (!ax) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"unmatched", nil)];
            complete = NO;
            continue;
        }
        NSDictionary *identity = ax[@"identity"];
        if (!YMWorkspaceIdentityValid(identity) ||
            ![identity[@"pid"] isEqual:cg[@"pid"]] || ![identity[@"windowID"] isEqual:cg[@"windowID"]]) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"invalidIdentity", nil)];
            continue;
        }
        if (![ax[@"readable"] isKindOfClass:NSNumber.class] || ![ax[@"readable"] boolValue]) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"unreadable", nil)];
            continue;
        }
        if (!YMWorkspaceAXStateNumber(ax[@"ordinary"]) || !YMWorkspaceAXStateNumber(ax[@"minimized"])) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"unknownState", nil)];
            continue;
        }
        NSDictionary *axFrame = YMWorkspaceGeometry(ax[@"frame"]);
        NSDictionary *display = axFrame ? YMWorkspaceDisplayForFrame(axFrame, displays) : nil;
        BOOL ordinary = [ax[@"ordinary"] boolValue];
        BOOL minimized = [ax[@"minimized"] boolValue];
        if (!ordinary || minimized) {
            if (!axFrame) {
                [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"],
                    minimized ? @"minimized" : @"nonOrdinary", nil)];
            } else if (YMWorkspaceCGMeetsOldSize(axFrame)) {
                [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"],
                    minimized ? @"minimized" : @"nonOrdinary", display)];
            }
            // Exact classified small non-ordinary/minimized: omit without blocker.
            // Manager privately re-classifies current CG/AX to confirm exclusion.
            continue;
        }
        if (!axFrame) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"invalidFrame", nil)];
            continue;
        }
        if (!YMWorkspaceCGMeetsOldSize(axFrame)) {
            // Exact classified undersized ordinary: omit without blocker.
            continue;
        }
        if (!display) {
            [blockers addObject:YMWorkspaceBlocker(cg[@"pid"], cg[@"windowID"], @"unowned", nil)];
            continue;
        }
        NSMutableDictionary *entry = [@{
            @"pid": cg[@"pid"], @"windowID": cg[@"windowID"], @"identity": identity,
            @"frame": axFrame, @"cgFrame": cg[@"frame"],
            @"displayID": display[@"displayID"], @"isVirtual": display[@"isVirtual"],
            @"positionSettable": [ax[@"positionSettable"] isKindOfClass:NSNumber.class] ?
                ax[@"positionSettable"] : @NO
        } mutableCopy];
        if (ax[@"element"]) entry[@"element"] = ax[@"element"];
        [windows addObject:entry];
    }

    return @{@"windows": windows, @"blockers": blockers, @"complete": @(complete)};
}
// Source eligibility for a normalized snapshot; unknown blockers close every source.
static inline BOOL YMWorkspaceSnapshotAllowsSource(NSDictionary *snapshot,
                                                   NSNumber *sourceFilter) {
    if (![snapshot isKindOfClass:NSDictionary.class] ||
        ![snapshot[@"complete"] isKindOfClass:NSNumber.class] || ![snapshot[@"complete"] boolValue] ||
        ![snapshot[@"blockers"] isKindOfClass:NSArray.class]) return NO;
    for (NSDictionary *blocker in snapshot[@"blockers"]) {
        if (![blocker isKindOfClass:NSDictionary.class]) return NO;
        if (![blocker[@"displayID"] isKindOfClass:NSNumber.class] ||
            ![blocker[@"isVirtual"] isKindOfClass:NSNumber.class]) return NO;
        if (YMWorkspaceMatchesSource(blocker, sourceFilter)) return NO;
    }
    return YES;
}
#endif
