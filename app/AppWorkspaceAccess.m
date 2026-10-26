#import "AppWorkspaceAccess.h"
#import "AppWorkspacePolicy.h"
#import "UpdateWorkspaceRecovery.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static const NSUInteger kYMWorkspaceMaxWindowsPerPID = 128;
static const NSTimeInterval kYMWorkspaceAXCallCap = 0.1;
static NSString * const YMWorkspaceDeadlineStackKey = @"YMWorkspaceDeadlineStack";

@implementation YMSystemWorkspaceWindowAccess

- (NSMutableArray *)deadlineStack {
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    NSMutableArray *stack = threadDictionary[YMWorkspaceDeadlineStackKey];
    if (![stack isKindOfClass:NSMutableArray.class]) {
        stack = [NSMutableArray array];
        threadDictionary[YMWorkspaceDeadlineStackKey] = stack;
    }
    return stack;
}

- (void)pushDeadline:(NSTimeInterval)deadline {
    [self.deadlineStack addObject:@(deadline)];
}

- (void)popDeadline {
    NSMutableArray *stack = self.deadlineStack;
    if (stack.count) [stack removeLastObject];
}

- (BOOL)hasActiveDeadline {
    return self.deadlineStack.count > 0;
}

- (NSTimeInterval)activeDeadline {
    return [self.deadlineStack.lastObject doubleValue];
}

- (BOOL)accessibilityTrusted {
    return AXIsProcessTrusted();
}

- (nullable NSArray<NSDictionary *> *)whitelistedWindowsFromCGEntries:(NSArray *)raw {
    // CoreGraphics may include window titles; only this allowlist is retained.
    // Unknown / incomplete fields stay omitable so the normalizer can fail closed
    // instead of treating drops or invisible defaults as a confirmed empty set.
    if (!raw) return nil;
    NSMutableArray *windows = [NSMutableArray array];
    for (id entryValue in raw) {
        if (![entryValue isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *entry = entryValue;
        NSMutableDictionary *window = [NSMutableDictionary dictionary];
        id pid = entry[(__bridge NSString *)kCGWindowOwnerPID];
        id windowID = entry[(__bridge NSString *)kCGWindowNumber];
        if (pid) window[@"pid"] = pid;
        if (windowID) window[@"windowID"] = windowID;

        id bounds = entry[(__bridge NSString *)kCGWindowBounds];
        if ([bounds isKindOfClass:NSDictionary.class]) {
            id x = bounds[@"X"], y = bounds[@"Y"], width = bounds[@"Width"], height = bounds[@"Height"];
            if ([x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
                [width isKindOfClass:NSNumber.class] && [height isKindOfClass:NSNumber.class]) {
                CGRect rect;
                if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect)) {
                    NSDictionary *frame = YMWorkspaceGeometry(@{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
                        @"width": @(rect.size.width), @"height": @(rect.size.height)});
                    if (frame) window[@"frame"] = frame;
                }
            }
        }

        id layer = entry[(__bridge NSString *)kCGWindowLayer];
        if (layer) window[@"layer"] = layer;
        id onScreen = entry[(__bridge NSString *)kCGWindowIsOnscreen];
        if (onScreen) window[@"onScreen"] = onScreen;
        id alpha = entry[(__bridge NSString *)kCGWindowAlpha];
        if (alpha) window[@"alpha"] = alpha;
        [windows addObject:window];
    }
    return windows;
}

- (nullable NSArray<NSDictionary *> *)visibleWindows {
    NSArray *raw = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    return [self whitelistedWindowsFromCGEntries:raw];
}

- (nullable NSRunningApplication *)applicationForPID:(pid_t)pid {
    return [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
}

- (NSArray<NSRunningApplication *> *)applicationsForBundleIdentifier:(NSString *)bundleID {
    if (!bundleID.length) return @[];
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID] ?: @[];
}

- (AXUIElementRef)axElement:(id)value {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == AXUIElementGetTypeID()
        ? (__bridge AXUIElementRef)value : NULL;
}

- (BOOL)prepareAXElement:(id)element {
    if (![self budgetRemaining]) return NO;
    AXUIElementRef ref = [self axElement:element];
    if (!ref) return YES;
    NSTimeInterval timeout = kYMWorkspaceAXCallCap;
    if ([self hasActiveDeadline]) {
        NSTimeInterval remaining = [self activeDeadline] - [self monotonicTime];
        if (remaining <= 0) return NO;
        timeout = fmin(remaining, kYMWorkspaceAXCallCap);
    }
    AXUIElementSetMessagingTimeout(ref, timeout);
    return YES;
}

- (id)copyWindowsForApplication:(NSRunningApplication *)application {
    if (!application || application.terminated) return nil;
    AXUIElementRef ref = AXUIElementCreateApplication(application.processIdentifier);
    if (!ref) return nil;
    id app = CFBridgingRelease(ref);
    if (![self prepareAXElement:app]) return nil;
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue((__bridge AXUIElementRef)app, kAXWindowsAttribute, &value);
    if (error != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

- (id)copyAttribute:(CFStringRef)attribute element:(id)element {
    AXUIElementRef ref = [self axElement:element];
    if (!ref || ![self prepareAXElement:element]) return nil;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(ref, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

- (NSNumber *)isAttributeSettable:(CFStringRef)attribute element:(id)element {
    AXUIElementRef ref = [self axElement:element];
    if (!ref || ![self prepareAXElement:element]) return nil;
    Boolean settable = false;
    if (AXUIElementIsAttributeSettable(ref, attribute, &settable) != kAXErrorSuccess) return nil;
    return @(settable);
}

- (NSDictionary *)identityForElement:(id)element {
    if (![self prepareAXElement:element]) return nil;
    return YMUpdateIdentityForWindowElement(element);
}

- (BOOL)writeAttribute:(CFStringRef)attribute value:(id)value element:(id)element {
    AXUIElementRef ref = [self axElement:element];
    if (!ref || !value || ![self prepareAXElement:element]) return NO;
    return AXUIElementSetAttributeValue(ref, attribute, (__bridge CFTypeRef)value) == kAXErrorSuccess;
}

- (NSTimeInterval)monotonicTime {
    return NSProcessInfo.processInfo.systemUptime;
}

- (NSDictionary *)observationFailure:(NSString *)reason windows:(NSArray *)windows {
    return @{@"windows": windows ?: @[], @"complete": @NO, @"reason": reason ?: @"incomplete"};
}

- (NSDictionary *)observationSuccess:(NSArray *)windows {
    return @{@"windows": windows ?: @[], @"complete": @YES, @"reason": @""};
}

- (nullable NSDictionary *)frameFromElement:(id)element {
    if (![self budgetRemaining]) return nil;
    id position = [self copyAttribute:kAXPositionAttribute element:element];
    if (!position || ![self budgetRemaining]) return nil;
    id size = [self copyAttribute:kAXSizeAttribute element:element];
    if (!size) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)position) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)size) != AXValueGetTypeID()) return nil;
    CGPoint point; CGSize extent;
    if (!AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &point) ||
        !AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &extent)) return nil;
    return YMWorkspaceGeometry(@{@"x": @(point.x), @"y": @(point.y),
                                 @"width": @(extent.width), @"height": @(extent.height)});
}

- (BOOL)ordinaryRole:(NSString *)role subrole:(NSString *)subrole {
    return [role isEqualToString:(__bridge NSString *)kAXWindowRole] &&
        ![subrole isEqualToString:(__bridge NSString *)kAXDialogSubrole] &&
        ![subrole isEqualToString:(__bridge NSString *)kAXSystemDialogSubrole] &&
        ![subrole isEqualToString:(__bridge NSString *)kAXFloatingWindowSubrole];
}

- (nullable NSDictionary *)recordForElement:(id)element {
    if (!element) return nil;
    if (![self budgetRemaining]) return nil;
    NSString *role = [self copyAttribute:kAXRoleAttribute element:element];
    if (![role isKindOfClass:NSString.class] || ![self budgetRemaining]) return nil;
    NSString *subrole = [self copyAttribute:kAXSubroleAttribute element:element];
    if (![subrole isKindOfClass:NSString.class] || ![self budgetRemaining]) return nil;
    id minimizedValue = [self copyAttribute:kAXMinimizedAttribute element:element];
    if (![minimizedValue isKindOfClass:NSNumber.class] || ![self budgetRemaining]) return nil;
    NSDictionary *frame = [self frameFromElement:element];
    if (!frame || ![self budgetRemaining]) return nil;
    NSNumber *positionSettable = [self isAttributeSettable:kAXPositionAttribute element:element];
    if (![positionSettable isKindOfClass:NSNumber.class] || ![self budgetRemaining]) return nil;
    NSNumber *sizeSettable = [self isAttributeSettable:kAXSizeAttribute element:element];
    if (![sizeSettable isKindOfClass:NSNumber.class] || ![self budgetRemaining]) return nil;
    NSDictionary *identity = [self identityForElement:element];
    if (!YMWorkspaceIdentityValid(identity)) return nil;
    return @{
        @"identity": identity,
        @"frame": frame,
        @"ordinary": @([self ordinaryRole:role subrole:subrole]),
        @"minimized": minimizedValue,
        @"readable": @YES,
        @"positionSettable": positionSettable,
        @"element": element
    };
}

- (BOOL)budgetRemaining {
    return ![self hasActiveDeadline] || [self monotonicTime] < [self activeDeadline];
}

- (NSDictionary *)observeApplicationUnderBudget:(NSRunningApplication *)application {
    if (!application) {
        return [self observationFailure:@"missingApplication" windows:@[]];
    }
    if (application.terminated) {
        return [self observationFailure:@"processTerminated" windows:@[]];
    }
    if (![self budgetRemaining]) {
        return [self observationFailure:@"timeout" windows:@[]];
    }
    id windowsValue = [self copyWindowsForApplication:application];
    if (![windowsValue isKindOfClass:NSArray.class]) {
        return [self observationFailure:@"enumerationFailed" windows:@[]];
    }
    NSArray *windows = windowsValue;
    if (windows.count > kYMWorkspaceMaxWindowsPerPID) {
        return [self observationFailure:@"windowLimit" windows:@[]];
    }
    if (application.terminated) {
        return [self observationFailure:@"processTerminated" windows:@[]];
    }

    NSMutableArray *records = [NSMutableArray array];
    NSMutableSet *seenKeys = [NSMutableSet set];
    BOOL complete = YES;
    NSString *reason = @"";

    for (id window in windows) {
        if (![self budgetRemaining]) {
            complete = NO;
            reason = @"timeout";
            break;
        }
        NSDictionary *record = [self recordForElement:window];
        if (!record) {
            complete = NO;
            if (![reason length]) reason = @"incompleteMetadata";
            if (![self budgetRemaining]) {
                reason = @"timeout";
                break;
            }
            continue;
        }
        NSDictionary *identity = record[@"identity"];
        NSString *key = YMWorkspaceWindowKey(identity[@"pid"], identity[@"windowID"]);
        if ([seenKeys containsObject:key]) {
            complete = NO;
            reason = @"duplicateIdentity";
            [records removeAllObjects];
            break;
        }
        [seenKeys addObject:key];
        [records addObject:record];
        if (application.terminated) {
            complete = NO;
            reason = @"processTerminated";
            break;
        }
    }

    if (application.terminated) {
        complete = NO;
        reason = @"processTerminated";
    }

    if (complete && ![self budgetRemaining]) {
        complete = NO;
        reason = @"timeout";
    }
    if (!complete) return [self observationFailure:reason windows:records];
    return [self observationSuccess:records];
}

- (NSDictionary *)observeApplication:(NSRunningApplication *)application
                           deadline:(NSTimeInterval)deadline {
    [self pushDeadline:deadline];
    NSDictionary *observation = nil;
    @try {
        observation = [self observeApplicationUnderBudget:application];
    } @finally {
        [self popDeadline];
    }
    return observation;
}

- (nullable NSDictionary *)observeElement:(id)element {
    return [self recordForElement:element];
}

- (nullable id)resolveIdentity:(NSDictionary *)identity error:(NSError **)error {
    return YMUpdateResolveWindowIdentity(identity, error);
}

- (BOOL)setPosition:(CGPoint)position element:(id)element
   expectedIdentity:(NSDictionary *)identity {
    if (!YMWorkspaceSameWindowIdentity([self identityForElement:element], identity)) return NO;
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &position);
    if (!value) return NO;
    BOOL ok = [self writeAttribute:kAXPositionAttribute value:(__bridge id)value element:element];
    CFRelease(value);
    return ok;
}

- (BOOL)setSize:(CGSize)size element:(id)element
expectedIdentity:(NSDictionary *)identity {
    if (!YMWorkspaceSameWindowIdentity([self identityForElement:element], identity)) return NO;
    AXValueRef value = AXValueCreate(kAXValueCGSizeType, &size);
    if (!value) return NO;
    BOOL ok = [self writeAttribute:kAXSizeAttribute value:(__bridge id)value element:element];
    CFRelease(value);
    return ok;
}

@end
