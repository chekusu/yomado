#ifndef YOMADO_LAYOUT_POLICY_H
#define YOMADO_LAYOUT_POLICY_H

#import <Foundation/Foundation.h>
#include <math.h>

// Append a new workspace after every active display, including other agents'
// virtual displays. Call with the snapshot from BEFORE creation: WindowServer
// can recall a cached arrangement as a new display appears.
static inline NSNumber *YMDesktopRightEdge(NSArray *snapshot) {
    if (![snapshot isKindOfClass:NSArray.class]) return nil;
    NSNumber *right = nil;
    for (id display in snapshot) {
        if (![display isKindOfClass:NSDictionary.class] ||
            ![display[@"isActive"] isKindOfClass:NSNumber.class] || ![display[@"isActive"] boolValue] ||
            ![display[@"isOnline"] isKindOfClass:NSNumber.class] || ![display[@"isOnline"] boolValue] ||
            ![display[@"x"] isKindOfClass:NSNumber.class] ||
            ![display[@"logicalWidth"] isKindOfClass:NSNumber.class]) continue;
        double x = [display[@"x"] doubleValue], width = [display[@"logicalWidth"] doubleValue];
        double edge = x + width;
        if (!isfinite(x) || !isfinite(width) || width <= 0 || !isfinite(edge) ||
            edge < INT32_MIN || edge > INT32_MAX) continue;
        if (!right || edge > right.doubleValue) right = @(edge);
    }
    return right;
}

// Find the physical desktop's right edge without changing its main display,
// positions, or vertical arrangement. A negative edge is a valid result.
static inline NSNumber *YMPhysicalRightEdge(NSArray *snapshot) {
    if (![snapshot isKindOfClass:[NSArray class]]) return nil;
    NSNumber *rightEdge = nil;
    for (id value in snapshot) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *display = value;
        id active = display[@"isActive"];
        id online = display[@"isOnline"];
        id virtualDisplay = display[@"isVirtual"];
        if (![active isKindOfClass:[NSNumber class]] || ![active boolValue] ||
            ![online isKindOfClass:[NSNumber class]] || ![online boolValue] ||
            ![virtualDisplay isKindOfClass:[NSNumber class]] || [virtualDisplay boolValue]) continue;

        id rawX = display[@"x"];
        id rawWidth = display[@"logicalWidth"];
        if (![rawX isKindOfClass:[NSNumber class]] ||
            ![rawWidth isKindOfClass:[NSNumber class]]) continue;
        double x = [rawX doubleValue];
        double width = [rawWidth doubleValue];
        double candidate = x + width;
        if (!isfinite(x) || !isfinite(width) || width <= 0 || !isfinite(candidate)) continue;
        if (rightEdge == nil || candidate > rightEdge.doubleValue) rightEdge = @(candidate);
    }
    return rightEdge;
}

// Active physical outputs to disconnect, sorted by display ID. Vendor, model
// and serial travel with the ID so a reused ID never passes as the same
// monitor. nil when one of them is mirrored or the snapshot is malformed.
static inline NSArray<NSDictionary *> *YMPhysicalOutputTargets(NSArray *snapshot) {
    if (![snapshot isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];
    for (id value in snapshot) {
        if (![value isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *display = value;
        NSArray *keys = @[@"displayID", @"isActive", @"isVirtual", @"isInMirrorSet",
                          @"vendorID", @"modelNumber", @"serialNumber"];
        for (NSString *key in keys)
            if (![display[key] isKindOfClass:NSNumber.class]) return nil;
        if (![display[@"isActive"] boolValue] || [display[@"isVirtual"] boolValue]) continue;
        if ([display[@"isInMirrorSet"] boolValue]) return nil;
        [targets addObject:@{@"displayID": display[@"displayID"], @"vendorID": display[@"vendorID"],
                             @"modelNumber": display[@"modelNumber"], @"serialNumber": display[@"serialNumber"]}];
    }
    [targets sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSNumber *)a[@"displayID"] compare:(NSNumber *)b[@"displayID"]];
    }];
    return targets;
}

typedef NS_ENUM(NSInteger, YMOutputRestoreStep) {
    YMOutputRestoreWait,
    YMOutputRestoreDone,
    YMOutputRestoreGiveUp,
};

static inline BOOL YMRestoreDeadlineReached(NSTimeInterval elapsed) {
    return !isfinite(elapsed) || elapsed >= 60;
}

// Re-enabling is asynchronous: keep waiting while a connected target is still
// dark. A target that went offline was probably unplugged and cannot come
// back, but give a just-enabled output a few seconds to report online first.
// Automatic retries stop after a minute; the user can retry by hand.
static inline YMOutputRestoreStep YMOutputRestoreStepFor(NSUInteger darkConnected, NSUInteger offline,
                                                         NSTimeInterval elapsed) {
    if (!darkConnected && (!offline || elapsed >= 5)) return YMOutputRestoreDone;
    return YMRestoreDeadlineReached(elapsed) ? YMOutputRestoreGiveUp : YMOutputRestoreWait;
}

#endif
