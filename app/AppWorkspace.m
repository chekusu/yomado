#import "AppWorkspace.h"
#import "AppWorkspacePolicy.h"
#import "UpdateWorkspaceRecovery.h"
#import <ApplicationServices/ApplicationServices.h>

NSString * const YMAppWorkspaceErrorDomain = @"dev.chekusu.yomado.app-workspace";

static AXUIElementRef YMWElement(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == AXUIElementGetTypeID() ? (__bridge AXUIElementRef)value : NULL;
}
static id YMWRead(id element, CFStringRef attribute) {
    AXUIElementRef ref = YMWElement(element); CFTypeRef value = NULL;
    if (!ref || AXUIElementCopyAttributeValue(ref, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static NSDictionary *YMWFrame(id element) {
    id p = YMWRead(element, kAXPositionAttribute), s = YMWRead(element, kAXSizeAttribute);
    if (!p || !s || CFGetTypeID((__bridge CFTypeRef)p) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)s) != AXValueGetTypeID()) return nil;
    CGPoint point; CGSize size;
    if (!AXValueGetValue((__bridge AXValueRef)p, kAXValueCGPointType, &point) ||
        !AXValueGetValue((__bridge AXValueRef)s, kAXValueCGSizeType, &size)) return nil;
    return YMWorkspaceGeometry(@{@"x": @(point.x), @"y": @(point.y), @"width": @(size.width), @"height": @(size.height)});
}
static BOOL YMWOrdinaryWindow(id element) {
    NSString *role = YMWRead(element, kAXRoleAttribute), *subrole = YMWRead(element, kAXSubroleAttribute);
    return [role isEqualToString:(__bridge NSString *)kAXWindowRole] &&
        ![subrole isEqualToString:(__bridge NSString *)kAXDialogSubrole] &&
        ![subrole isEqualToString:(__bridge NSString *)kAXSystemDialogSubrole] &&
        ![subrole isEqualToString:(__bridge NSString *)kAXFloatingWindowSubrole];
}

@interface YMWPlacement : NSObject
@property(nonatomic, strong) id element;
@property(nonatomic, strong) NSRunningApplication *application;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSDictionary *origin;
@property(nonatomic) CGWindowID windowID;
@property(nonatomic) CGDirectDisplayID lastDisplayID;
@end
@implementation YMWPlacement
@end

@interface YMAppWorkspace ()
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *rows;
@property(nonatomic, copy, readwrite) NSString *statusText;
@property(nonatomic, copy) NSArray<NSNumber *> *ownedIDs;
@property(nonatomic, copy) NSArray<NSDictionary *> *displays;
@property(nonatomic, copy) NSArray<NSDictionary *> *windows;
@property(nonatomic, strong) NSMutableArray<YMWPlacement *> *placements;
@property(nonatomic) BOOL inventoryValid;
@property(nonatomic) BOOL operationInProgress;
// Displays whose unmatched windows the user agreed to leave for macOS to
// relocate when the display is removed.
@property(nonatomic, strong) NSMutableSet<NSNumber *> *unmovableAllowedIDs;
@end

@implementation YMAppWorkspace
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _rows = @[]; _ownedIDs = @[]; _displays = @[]; _windows = @[];
    _placements = [NSMutableArray array];
    _unmovableAllowedIDs = [NSMutableSet set];
    _statusText = @"拖入已打开的 App，或手动把窗口拖到虚拟屏。原位置只保留到退出 yomado。";
    return self;
}
- (BOOL)accessibilityTrusted { return AXIsProcessTrusted(); }
- (BOOL)fail:(NSError **)error code:(NSInteger)code text:(NSString *)text {
    self.statusText = text;
    if (error) *error = [NSError errorWithDomain:YMAppWorkspaceErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: text}];
    return NO;
}
- (NSDictionary *)display:(CGDirectDisplayID)ID {
    for (NSDictionary *display in self.displays)
        if ([display[@"displayID"] unsignedIntValue] == ID && YMWorkspaceUsableDisplay(display)) return display;
    return nil;
}
- (void)refreshWithVirtualDisplayIDs:(NSArray<NSNumber *> *)displayIDs displaySnapshot:(NSArray<NSDictionary *> *)snapshot {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    NSMutableOrderedSet *IDs = [NSMutableOrderedSet orderedSet];
    for (id value in displayIDs) if ([value isKindOfClass:NSNumber.class] && [value unsignedIntValue]) [IDs addObject:value];
    self.ownedIDs = IDs.array;
    [self.unmovableAllowedIDs intersectSet:[NSSet setWithArray:self.ownedIDs]];
    NSMutableArray *normalized = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSScreen *> *screens = [NSMutableDictionary dictionary];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *ID = screen.deviceDescription[@"NSScreenNumber"];
        if ([ID isKindOfClass:NSNumber.class]) screens[ID] = screen;
    }
    for (id raw in snapshot) {
        if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"displayID"] isKindOfClass:NSNumber.class]) continue;
        CGDirectDisplayID ID = [raw[@"displayID"] unsignedIntValue];
        NSDictionary *bounds = YMWorkspaceGeometry(raw[@"bounds"]) ?: YMWorkspaceGeometry(@{
            @"x": raw[@"x"] ?: NSNull.null, @"y": raw[@"y"] ?: NSNull.null,
            @"width": raw[@"logicalWidth"] ?: NSNull.null, @"height": raw[@"logicalHeight"] ?: NSNull.null});
        if (!bounds) continue;
        BOOL virtualDisplay = [self.ownedIDs containsObject:@(ID)] || [raw[@"isVirtual"] boolValue];
        NSString *uuid = [raw[@"displayUUID"] isKindOfClass:NSString.class] ? raw[@"displayUUID"] : nil;
        if (!uuid && !virtualDisplay) {
            CFUUIDRef value = CGDisplayCreateUUIDFromDisplayID(ID);
            if (value) { uuid = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, value)); CFRelease(value); }
        }
        NSMutableDictionary *display = [@{@"displayID": @(ID), @"displayUUID": uuid ?: @"", @"bounds": bounds,
            @"isMain": @([raw[@"isMain"] boolValue]), @"isActive": @([raw[@"isActive"] boolValue]),
            @"isOnline": @([raw[@"isOnline"] boolValue]), @"isVirtual": @(virtualDisplay)} mutableCopy];
        NSScreen *screen = screens[@(ID)];
        if (!virtualDisplay && screen) {
            // AppKit frames have an upward Y axis. Use per-screen offsets to
            // express the menu-bar/Dock-excluded visible area in CG coordinates.
            NSRect frame = screen.frame, visible = screen.visibleFrame;
            NSDictionary *visibleBounds = YMWorkspaceGeometry(@{
                @"x": @([bounds[@"x"] doubleValue] + NSMinX(visible) - NSMinX(frame)),
                @"y": @([bounds[@"y"] doubleValue] + NSMaxY(frame) - NSMaxY(visible)),
                @"width": @(visible.size.width), @"height": @(visible.size.height)});
            if (visibleBounds) display[@"visibleBounds"] = visibleBounds;
        }
        [normalized addObject:display];
    }
    self.displays = normalized;
    [self refreshInventory];
}
- (void)refreshInventory {
    // CoreGraphics may provide window titles in its dictionary; no title key is
    // read, copied, logged, or retained. Only this allowlist leaves the loop.
    NSArray *raw = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    if (!raw) { self.inventoryValid = NO; self.statusText = @"暂时无法读取窗口清单；保留显示器，稍后刷新。"; return; }
    NSMutableArray *windows = [NSMutableArray array];
    for (NSDictionary *entry in raw) {
        CGRect rect;
        if (![entry[(__bridge NSString *)kCGWindowBounds] isKindOfClass:NSDictionary.class]) continue;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds], &rect)) continue;
        NSDictionary *frame = YMWorkspaceGeometry(@{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
            @"width": @(rect.size.width), @"height": @(rect.size.height)});
        if (!YMWorkspaceVisibleOrdinaryGeometry(frame, [entry[(__bridge NSString *)kCGWindowLayer] integerValue],
            [entry[(__bridge NSString *)kCGWindowIsOnscreen] boolValue], [entry[(__bridge NSString *)kCGWindowAlpha] doubleValue])) continue;
        pid_t PID = [entry[(__bridge NSString *)kCGWindowOwnerPID] intValue];
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:PID];
        if (!app || app.terminated || !app.bundleIdentifier.length || !app.bundleURL) continue;
        NSDictionary *display = YMWorkspaceDisplayForFrame(frame, self.displays);
        if (!display) continue;
        [windows addObject:@{@"windowID": entry[(__bridge NSString *)kCGWindowNumber], @"pid": @(PID),
            @"bundleIdentifier": app.bundleIdentifier, @"appName": app.localizedName ?: app.bundleIdentifier,
            @"appURL": app.bundleURL, @"frame": frame, @"displayID": display[@"displayID"],
            @"isVirtual": display[@"isVirtual"]}];
    }
    self.windows = windows; self.inventoryValid = YES;
    // A closed process is decisive evidence; an absent or unreadable window is
    // not. Retain such checkpoints until an explicit restore can inspect AX.
    for (YMWPlacement *placement in self.placements.copy) {
        if (placement.application.terminated) { [self.placements removeObject:placement]; continue; }
        for (NSDictionary *window in windows) {
            if ([window[@"windowID"] unsignedIntValue] != placement.windowID ||
                [window[@"pid"] intValue] != placement.application.processIdentifier) continue;
            if ([window[@"isVirtual"] boolValue]) placement.lastDisplayID = [window[@"displayID"] unsignedIntValue];
            // CG may still report the pre-move physical frame after AX has
            // already confirmed the virtual destination. Do not mistake that
            // transient snapshot for a user's manual return and lose origin.
            // Read only the retained window's geometry, never application text.
            else if (!self.operationInProgress && self.accessibilityTrusted &&
                     YMWorkspacePhysicalReturnConfirmed(window[@"frame"], YMWFrame(placement.element), self.displays, NO))
                [self.placements removeObject:placement];
            break;
        }
    }
    self.rows = [self groupedRowsForDisplay:0 ownedOnly:YES];
}
- (NSArray<NSDictionary *> *)groupedRowsForDisplay:(CGDirectDisplayID)ID ownedOnly:(BOOL)ownedOnly {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *window in self.windows) {
        BOOL include = ownedOnly ? [self.ownedIDs containsObject:window[@"displayID"]] :
            (ID ? [window[@"displayID"] unsignedIntValue] == ID : ![window[@"isVirtual"] boolValue]);
        if (!include) continue;
        NSString *bundle = window[@"bundleIdentifier"];
        NSMutableDictionary *row = groups[bundle];
        if (!row) {
            row = [@{@"appName": window[@"appName"], @"bundleIdentifier": bundle, @"appURL": window[@"appURL"],
                @"pid": window[@"pid"], @"pids": [NSMutableArray array], @"windowCount": @0, @"managedWindowCount": @0} mutableCopy];
            NSImage *icon = [NSRunningApplication runningApplicationWithProcessIdentifier:[window[@"pid"] intValue]].icon;
            if (icon) row[@"appIcon"] = icon;
            groups[bundle] = row;
        }
        if (![row[@"pids"] containsObject:window[@"pid"]]) [row[@"pids"] addObject:window[@"pid"]];
        row[@"windowCount"] = @([row[@"windowCount"] unsignedIntegerValue] + 1);
        for (YMWPlacement *placement in self.placements)
            if (placement.windowID == [window[@"windowID"] unsignedIntValue] &&
                placement.application.processIdentifier == [window[@"pid"] intValue]) {
                row[@"managedWindowCount"] = @([row[@"managedWindowCount"] unsignedIntegerValue] + 1); break;
            }
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSMutableDictionary *row in groups.allValues) {
        row[@"pids"] = [row[@"pids"] copy]; [result addObject:[row copy]];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"appName"] localizedCaseInsensitiveCompare:b[@"appName"]];
        return result == NSOrderedSame ? [a[@"bundleIdentifier"] compare:b[@"bundleIdentifier"]] : result;
    }];
    return result;
}
- (NSArray<NSDictionary *> *)rowsForDisplayID:(CGDirectDisplayID)ID { return [self groupedRowsForDisplay:ID ownedOnly:NO]; }
- (BOOL)needsRestoreForDisplayID:(CGDirectDisplayID)ID {
    if (![self.ownedIDs containsObject:@(ID)]) return NO;
    if (!self.inventoryValid) return YES;
    if ([self rowsForDisplayID:ID].count && ![self.unmovableAllowedIDs containsObject:@(ID)]) return YES;
    for (YMWPlacement *placement in self.placements) if (placement.lastDisplayID == ID) return YES;
    return NO;
}
- (BOOL)needsRestoreBeforeRemovingVirtualDisplay {
    for (NSNumber *ID in self.ownedIDs) if ([self needsRestoreForDisplayID:ID.unsignedIntValue]) return YES;
    return NO;
}
- (BOOL)preflight:(NSError **)error {
    if (self.operationInProgress) return [self fail:error code:1 text:@"正在核对窗口位置，请稍候。"];
    if (!self.accessibilityTrusted) return [self fail:error code:2 text:@"移动窗口需要控制权限；请先打开控制权限设置。"];
    [self refreshInventory];
    if (!self.inventoryValid) return [self fail:error code:3 text:@"无法读取窗口清单，尚未移动任何窗口。"];
    return YES;
}
- (BOOL)genericBundleAllowed:(NSString *)bundle error:(NSError **)error {
    if (YMWorkspaceGenericMutationAllowed(bundle)) return YES;
    return [self fail:error code:4 text:[bundle isEqualToString:@"com.tencent.xinWeChat"] ?
        @"微信由专用安全恢复器处理，请通过控制面板的微信条目操作。" : @"此应用的窗口由系统或 yomado 自身管理，不能移入。"];
}
- (YMWPlacement *)placementForElement:(id)element application:(NSRunningApplication *)application windowID:(CGWindowID)windowID {
    for (YMWPlacement *p in self.placements.copy)
        if (p.application.processIdentifier == application.processIdentifier && !p.application.terminated &&
            CFEqual((__bridge CFTypeRef)p.element, (__bridge CFTypeRef)element)) {
            if (p.windowID == windowID) return p;
            // An app may reuse an AX identity after closing a window. A newly
            // observed CG window ID must never inherit that old window's frame.
            [self.placements removeObject:p];
        }
    return nil;
}
- (NSArray<NSDictionary *> *)candidatesForApplication:(NSRunningApplication *)app sourceFilter:(NSNumber *)filter error:(NSError **)error {
    NSUInteger visibleCount = 0;
    NSArray *result = [self matchedWindowsForApplication:app sourceFilter:filter visibleCount:&visibleCount error:error];
    if (!result || result.count == visibleCount) return result;
    if (filter.unsignedIntValue && [self.unmovableAllowedIDs containsObject:filter]) return result;
    NSString *name = app.localizedName.length ? app.localizedName : (app.bundleIdentifier ?: @"应用");
    [self fail:error code:7 text:[NSString stringWithFormat:@"「%@」有 %lu 个窗口无法可靠匹配或移动（常见于弹窗、启动画面或工具窗）。请关闭这些窗口、展开普通窗口后重试；尚未继续移屏。",
        name, (unsigned long)(visibleCount - result.count)]];
    return nil;
}
// Visible CG windows that match exactly one movable ordinary AX window. The
// rest (dialogs, splash screens, tool windows, overlapping twins) cannot be
// returned to a remembered origin; visibleCount lets callers count them.
- (NSArray<NSDictionary *> *)matchedWindowsForApplication:(NSRunningApplication *)app sourceFilter:(NSNumber *)filter
                                             visibleCount:(NSUInteger *)visibleCount error:(NSError **)error {
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *window in self.windows)
        if ([window[@"pid"] intValue] == app.processIdentifier && YMWorkspaceMatchesSource(window, filter))
            [visible addObject:window];
    AXUIElementRef ref = AXUIElementCreateApplication(app.processIdentifier);
    if (!ref) { [self fail:error code:5 text:@"无法访问应用窗口；请先打开应用主窗口。 "]; return nil; }
    AXUIElementSetMessagingTimeout(ref, 0.8);
    id element = CFBridgingRelease(ref), raw = YMWRead(element, kAXWindowsAttribute);
    if (![raw isKindOfClass:NSArray.class]) { [self fail:error code:6 text:@"应用暂时没有响应窗口查询；已保留原位置记录。 "]; return nil; }
    // Only a successful enumeration may retire a closed AX identity. A new
    // window never receives an old window's checkpoint, even after relaunch.
    for (YMWPlacement *placement in self.placements.copy) {
        if (placement.application.processIdentifier != app.processIdentifier) continue;
        BOOL found = NO;
        for (id window in raw) if (YMWElement(window) && CFEqual((__bridge CFTypeRef)window, (__bridge CFTypeRef)placement.element)) { found = YES; break; }
        if (!found) [self.placements removeObject:placement];
    }
    NSMutableArray *result = [NSMutableArray array]; NSMutableSet *used = [NSMutableSet set];
    for (id window in raw) {
        if (!YMWOrdinaryWindow(window) || [YMWRead(window, kAXMinimizedAttribute) boolValue]) continue;
        NSDictionary *frame = YMWFrame(window); if (!frame) continue;
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *entry in visible)
            if (![used containsObject:entry[@"windowID"]] && YMWorkspaceSameFrame(frame, entry[@"frame"])) [matches addObject:entry];
        // Overlapping identical windows cannot be associated reliably without
        // private AX APIs. Refuse rather than bind a checkpoint to the wrong one.
        if (matches.count != 1) continue;
        Boolean settable = false;
        if (AXUIElementIsAttributeSettable(YMWElement(window), kAXPositionAttribute, &settable) != kAXErrorSuccess || !settable) continue;
        NSDictionary *entry = matches.firstObject; [used addObject:entry[@"windowID"]];
        [result addObject:@{@"element": window, @"frame": frame, @"windowID": entry[@"windowID"], @"displayID": entry[@"displayID"]}];
    }
    if (visibleCount) *visibleCount = visible.count;
    return result;
}
- (NSArray<NSDictionary *> *)unmovableWindowsForDisplayID:(CGDirectDisplayID)ID {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (self.operationInProgress || !self.accessibilityTrusted || ![self.ownedIDs containsObject:@(ID)] ||
        [self.unmovableAllowedIDs containsObject:@(ID)]) return @[];
    [self refreshInventory];
    if (!self.inventoryValid) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *row in [self rowsForDisplayID:ID]) {
        NSString *bundle = row[@"bundleIdentifier"];
        if (!YMWorkspaceGenericRestoreAllowed(bundle)) continue;
        NSUInteger unmatched = 0;
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle]) {
            if (app.terminated) continue;
            NSUInteger visibleCount = 0;
            // An app that does not answer AX is not listed: the restore itself
            // reports that failure and keeps the display.
            NSArray *matched = [self matchedWindowsForApplication:app sourceFilter:@(ID) visibleCount:&visibleCount error:NULL];
            if (matched) unmatched += visibleCount - matched.count;
        }
        if (unmatched) [result addObject:@{@"appName": row[@"appName"], @"count": @(unmatched)}];
    }
    return result;
}
- (void)allowUnmovableWindowsOnDisplayID:(CGDirectDisplayID)ID {
    if ([self.ownedIDs containsObject:@(ID)]) [self.unmovableAllowedIDs addObject:@(ID)];
}
- (BOOL)displayStillCurrent:(NSDictionary *)display {
    CGDirectDisplayID ID = [display[@"displayID"] unsignedIntValue];
    if (!YMWorkspaceUsableDisplay(display) || !CGDisplayIsActive(ID) || !CGDisplayIsOnline(ID)) return NO;
    if ([self.ownedIDs containsObject:@(ID)] &&
        (CGDisplayIsInMirrorSet(ID) || CGDisplayMirrorsDisplay(ID) != kCGNullDirectDisplay)) return NO;
    CGRect rect = CGDisplayBounds(ID);
    return YMWorkspaceSameFrame(display[@"bounds"], @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
        @"width": @(rect.size.width), @"height": @(rect.size.height)});
}
- (BOOL)placeElement:(id)element frame:(NSDictionary *)frame display:(NSDictionary *)display application:(NSRunningApplication *)app {
    pid_t PID = 0; AXUIElementRef ref = YMWElement(element);
    if (!ref || app.terminated || AXUIElementGetPid(ref, &PID) != kAXErrorSuccess || PID != app.processIdentifier ||
        ![self displayStillCurrent:display] || !YMWorkspaceGeometry(frame)) return NO;
    AXUIElementSetMessagingTimeout(ref, 0.8);
    NSDictionary *before = YMWFrame(element); if (!before) return NO;
    CGSize size = CGSizeMake([frame[@"width"] doubleValue], [frame[@"height"] doubleValue]);
    Boolean resizable = false;
    if ((fabs([before[@"width"] doubleValue] - size.width) > 1 || fabs([before[@"height"] doubleValue] - size.height) > 1) &&
        AXUIElementIsAttributeSettable(ref, kAXSizeAttribute, &resizable) == kAXErrorSuccess && resizable) {
        AXValueRef value = AXValueCreate(kAXValueCGSizeType, &size);
        if (value) { (void)AXUIElementSetAttributeValue(ref, kAXSizeAttribute, value); CFRelease(value); }
    }
    if (![self displayStillCurrent:display]) return NO;
    CGPoint point = CGPointMake([frame[@"x"] doubleValue], [frame[@"y"] doubleValue]);
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &point);
    AXError moved = value ? AXUIElementSetAttributeValue(ref, kAXPositionAttribute, value) : kAXErrorFailure;
    if (value) CFRelease(value);
    if (moved != kAXErrorSuccess) return NO;
    for (NSUInteger observation = 0; observation < 4; observation++) {
        // The run loop permits external screen changes while settling. Never
        // accept a frame against stale bounds after a display moves/disappears.
        if (![self displayStillCurrent:display]) return NO;
        NSDictionary *actual = YMWFrame(element);
        if (!actual) return NO;
        if (YMWorkspaceFrameFits(actual, display)) return YES;
        if (observation < 3) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    }
    return NO;
}
- (BOOL)performMoveApplicationAtURL:(NSURL *)URL sourceFilter:(NSNumber *)filter toDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (![self preflight:error]) return NO;
    NSDictionary *target = [self display:ID];
    if (![self.ownedIDs containsObject:@(ID)] || ![self displayStillCurrent:target])
        return [self fail:error code:8 text:@"目标虚拟屏不可用，请先创建虚拟屏。"];
    NSURL *canonical = URL.isFileURL ? URL.URLByResolvingSymlinksInPath.URLByStandardizingPath : nil;
    NSBundle *bundle = canonical ? [NSBundle bundleWithURL:canonical] : nil;
    if (![canonical.pathExtension.lowercaseString isEqualToString:@"app"] || !bundle.bundleIdentifier.length)
        return [self fail:error code:9 text:@"请拖入一个 macOS 应用（.app）。"];
    if (![self genericBundleAllowed:bundle.bundleIdentifier error:error]) return NO;
    NSMutableArray *operations = [NSMutableArray array]; BOOL running = NO;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle.bundleIdentifier]) {
        if (app.terminated || ![app.bundleURL.URLByResolvingSymlinksInPath.URLByStandardizingPath isEqual:canonical]) continue;
        running = YES;
        NSArray *candidates = [self candidatesForApplication:app sourceFilter:filter error:error]; if (!candidates) return NO;
        for (NSDictionary *candidate in candidates) if ([candidate[@"displayID"] unsignedIntValue] != ID)
            [operations addObject:@{@"application": app, @"candidate": candidate}];
    }
    if (!running) return [self fail:error code:10 text:@"请先打开这个 App 的窗口，再将 App 拖入虚拟屏。"];
    if (!operations.count) return [self fail:error code:18 text:@"没有需要移动的可见普通窗口；窗口可能已在目标屏，或仍处于隐藏、最小化状态。请先显示要移动的窗口。"];
    self.operationInProgress = YES; NSUInteger moved = 0;
    @try {
        for (NSDictionary *operation in operations) {
            NSRunningApplication *app = operation[@"application"]; NSDictionary *candidate = operation[@"candidate"];
            id element = candidate[@"element"]; NSDictionary *before = YMWFrame(element);
            if (!YMWorkspaceSameFrame(before, candidate[@"frame"]))
                return [self fail:error code:11 text:@"窗口位置已变化，已停止后续移动；可以返回已移动的窗口。"];
            NSDictionary *source = [self display:[candidate[@"displayID"] unsignedIntValue]];
            YMWPlacement *placement = [self placementForElement:element application:app windowID:[candidate[@"windowID"] unsignedIntValue]];
            BOOL created = !placement;
            if (!placement) {
                placement = [YMWPlacement new]; placement.element = element; placement.application = app;
                placement.bundleID = app.bundleIdentifier; placement.windowID = [candidate[@"windowID"] unsignedIntValue];
                placement.origin = YMWorkspaceOrigin(before, source);
                [self.placements addObject:placement]; // Original geometry precedes every write.
            }
            CGDirectDisplayID priorID = placement.lastDisplayID;
            placement.lastDisplayID = ID;
            NSDictionary *destination = YMWorkspaceFrameOnDisplay(before, nil, target);
            if (![self placeElement:element frame:destination display:target application:app]) {
                BOOL returned = [self placeElement:element frame:before display:source application:app];
                if (returned && created && placement.origin) [self.placements removeObject:placement];
                else if (returned) placement.lastDisplayID = priorID ?: [source[@"displayID"] unsignedIntValue];
                return [self fail:error code:12 text:returned ? @"移屏未获验证，当前窗口已退回；已停止后续移动。" :
                    @"尚未确认窗口位置；保留显示器和原位置记录，请使用返回操作。"];
            }
            moved++;
        }
        self.statusText = [NSString stringWithFormat:@"已移入 %lu 个窗口。原位置在本次 yomado 运行期间保留。", (unsigned long)moved];
        return YES;
    } @finally { self.operationInProgress = NO; [self refreshInventory]; }
}
- (BOOL)moveApplicationAtURL:(NSURL *)URL toDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    return [self performMoveApplicationAtURL:URL sourceFilter:nil toDisplayID:ID error:error];
}
- (BOOL)moveApplicationAtURL:(NSURL *)URL fromDisplayID:(CGDirectDisplayID)sourceID toDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    return [self performMoveApplicationAtURL:URL sourceFilter:@(sourceID) toDisplayID:ID error:error];
}
- (BOOL)performRestoreBundle:(NSString *)bundle sourceID:(CGDirectDisplayID)sourceID physicalTarget:(NSDictionary *)physicalTarget error:(NSError **)error {
    if (!YMWorkspaceGenericRestoreAllowed(bundle)) return [self fail:error code:4 text:@"请先把 yomado 控制面板移回实体屏，再关闭此虚拟屏。"];
    NSUInteger restored = 0, fallback = 0;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle]) {
        if (app.terminated) continue;
        NSArray *candidates = [self candidatesForApplication:app sourceFilter:sourceID ? @(sourceID) : nil error:error]; if (!candidates) return NO;
        for (NSDictionary *candidate in candidates) {
            NSDictionary *source = [self display:[candidate[@"displayID"] unsignedIntValue]];
            if (![self.ownedIDs containsObject:source[@"displayID"]]) continue;
            id element = candidate[@"element"]; YMWPlacement *placement = [self placementForElement:element application:app windowID:[candidate[@"windowID"] unsignedIntValue]];
            NSDictionary *origin = placement.origin, *before = YMWFrame(element);
            if (!YMWorkspaceSameFrame(before, candidate[@"frame"]))
                return [self fail:error code:13 text:@"窗口位置已变化，已停止恢复；请刷新后再试。"];
            NSDictionary *target = physicalTarget ?: YMWorkspacePhysicalDisplay(origin[@"displayUUID"], self.displays);
            NSDictionary *destination = physicalTarget ? YMWorkspaceFrameForExplicitPhysicalReturn(origin, before, target) :
                YMWorkspaceFrameOnDisplay(origin[@"relative"] ?: before, origin[@"relative"], target);
            if (!target || !destination) return [self fail:error code:14 text:@"没有可用的实体显示器；保留虚拟屏和窗口记录。"];
            if (![self placeElement:element frame:destination display:target application:app])
                return [self fail:error code:15 text:@"尚未确认窗口已返回实体屏；保留虚拟屏和原位置记录。"];
            if (!origin || (physicalTarget && !YMWorkspaceOriginBelongsToDisplay(origin, target))) fallback++;
            if (placement) [self.placements removeObject:placement];
            restored++;
        }
    }
    for (YMWPlacement *placement in self.placements)
        if ([placement.bundleID isEqual:bundle] && (!sourceID || placement.lastDisplayID == sourceID))
            return [self fail:error code:16 text:@"还有隐藏、最小化或暂时不可访问的窗口记录；请显示这些窗口后再返回，虚拟屏保持开启。"];
    if (physicalTarget) {
        if (!restored) return [self fail:error code:18 text:@"所选虚拟屏中没有这个 App 的可见普通窗口；未移动其他屏幕上的窗口。"];
        self.statusText = fallback ? [NSString stringWithFormat:@"已将 %lu 个窗口放到指定实体屏；其中 %lu 个窗口使用该屏可见区域中央。", (unsigned long)restored, (unsigned long)fallback] :
            [NSString stringWithFormat:@"已将 %lu 个窗口返回指定实体屏的原位置。", (unsigned long)restored];
        return YES;
    }
    self.statusText = fallback ? [NSString stringWithFormat:@"已返回 %lu 个窗口；其中 %lu 个手动移入窗口没有原位置记录，已放到实体主屏中央。", (unsigned long)restored, (unsigned long)fallback] :
        [NSString stringWithFormat:@"已将 %lu 个窗口返回原实体屏；原屏不可用时使用当前实体主屏。", (unsigned long)restored];
    return YES;
}
- (BOOL)restoreApplicationWithBundleIdentifier:(NSString *)bundle fromDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (![self preflight:error]) return NO;
    if (ID && ![self.ownedIDs containsObject:@(ID)]) return [self fail:error code:17 text:@"只能返回 yomado 虚拟屏中的窗口。"];
    self.operationInProgress = YES;
    @try { return [self performRestoreBundle:bundle sourceID:ID physicalTarget:nil error:error]; }
    @finally { self.operationInProgress = NO; [self refreshInventory]; }
}
- (BOOL)restoreApplicationWithBundleIdentifier:(NSString *)bundle fromDisplayID:(CGDirectDisplayID)sourceID
                          toPhysicalDisplayID:(CGDirectDisplayID)physicalID error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (![self preflight:error]) return NO;
    if (!sourceID || ![self.ownedIDs containsObject:@(sourceID)])
        return [self fail:error code:17 text:@"请从具体虚拟屏拖动 App 到实体屏；不会移动其他屏幕上的窗口。"];
    NSDictionary *target = [self display:physicalID];
    if (!target || [target[@"isVirtual"] boolValue] || ![self displayStillCurrent:target])
        return [self fail:error code:19 text:@"指定的实体显示器当前不可用；窗口保持原位。"];
    self.operationInProgress = YES;
    @try { return [self performRestoreBundle:bundle sourceID:sourceID physicalTarget:target error:error]; }
    @finally { self.operationInProgress = NO; [self refreshInventory]; }
}
- (BOOL)restoreDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (self.operationInProgress) return [self fail:error code:1 text:@"正在核对窗口位置，请稍候。"];
    [self refreshInventory];
    if (!self.inventoryValid) return [self fail:error code:3 text:@"无法读取窗口清单；保留虚拟屏，稍后再试。"];
    if (![self.ownedIDs containsObject:@(ID)]) return [self fail:error code:17 text:@"只能返回 yomado 虚拟屏中的窗口。"];
    NSMutableOrderedSet *bundles = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *row in [self rowsForDisplayID:ID]) [bundles addObject:row[@"bundleIdentifier"]];
    for (YMWPlacement *placement in self.placements) if (placement.lastDisplayID == ID) [bundles addObject:placement.bundleID];
    // Read-only inventory is enough to close an empty workspace. Do not trap
    // users in an empty virtual display just because AX permission is absent.
    if (!bundles.count) { self.statusText = @"此虚拟屏没有需要返回的窗口。"; return YES; }
    if (!self.accessibilityTrusted) return [self fail:error code:2 text:@"返回窗口需要控制权限；请先打开控制权限设置，或手动移回窗口。"];
    self.operationInProgress = YES;
    @try {
        for (NSString *bundle in bundles) {
            // The controller first handles any pending WeChat safety checkpoint
            // with YMWindowRecovery. A manually dragged ordinary WeChat window
            // without a checkpoint can then return to physical main here.
            if (![self performRestoreBundle:bundle sourceID:ID physicalTarget:nil error:error]) return NO;
        }
        return YES;
    } @finally { self.operationInProgress = NO; [self refreshInventory]; }
}
- (NSArray<NSDictionary *> *)restartOriginCheckpointsWithError:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (self.operationInProgress) { [self fail:error code:30 text:@"窗口操作尚未结束，稍后再更新。"]; return nil; }
    [self refreshInventory];
    if (!self.inventoryValid) { [self fail:error code:30 text:@"无法核对窗口清单，保留当前工作区。"]; return nil; }
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (YMWPlacement *placement in self.placements) {
        if (!placement.origin || !YMWorkspaceCheckpointWindow(placement.application.processIdentifier,
            placement.windowID,self.windows,self.ownedIDs)) continue;
        NSDictionary *identity = YMUpdateIdentityForWindowElement(placement.element);
        NSDictionary *frame = YMWFrame(placement.element);
        NSDictionary *display = YMWorkspaceDisplayForFrame(frame, self.displays);
        NSDictionary *relative = YMWorkspaceGeometry(placement.origin[@"relative"]);
        NSString *uuid = placement.origin[@"displayUUID"];
        if (!identity || [identity[@"pid"] intValue] != placement.application.processIdentifier ||
            [identity[@"windowID"] unsignedIntValue] != placement.windowID || !frame ||
            ![self.ownedIDs containsObject:display[@"displayID"]] || !relative ||
            ![uuid isKindOfClass:NSString.class] || !uuid.length || [seen containsObject:identity]) {
            [self fail:error code:31 text:@"已有窗口的原位置无法精确交接，已暂停更新。"]; return nil;
        }
        [seen addObject:identity];
        [result addObject:@{@"identity": identity, @"origin": @{@"displayUUID": uuid, @"relative": relative}}];
    }
    return result.copy;
}
- (BOOL)adoptRestartOriginCheckpoints:(NSArray<NSDictionary *> *)checkpoints error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (self.operationInProgress || ![checkpoints isKindOfClass:NSArray.class])
        return [self fail:error code:30 text:@"窗口恢复尚未完成。"];
    NSMutableArray *pending = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *checkpoint in checkpoints) {
        NSDictionary *identity = checkpoint[@"identity"], *origin = checkpoint[@"origin"];
        NSDictionary *relative = YMWorkspaceGeometry(origin[@"relative"]);
        NSString *uuid = origin[@"displayUUID"];
        id element = YMUpdateResolveWindowIdentity(identity, error);
        NSDictionary *frame = element ? YMWFrame(element) : nil;
        NSDictionary *display = YMWorkspaceDisplayForFrame(frame, self.displays);
        if (!element || !frame || ![self.ownedIDs containsObject:display[@"displayID"]] || !relative ||
            ![uuid isKindOfClass:NSString.class] || !uuid.length || [seen containsObject:identity])
            return [self fail:error code:31 text:@"窗口原位置接管未完成，保留恢复记录供重试。"];
        [seen addObject:identity];
        YMWPlacement *placement = [YMWPlacement new];
        placement.element = element;
        placement.application = [NSRunningApplication runningApplicationWithProcessIdentifier:[identity[@"pid"] intValue]];
        placement.bundleID = identity[@"bundleID"];
        placement.windowID = [identity[@"windowID"] unsignedIntValue];
        placement.lastDisplayID = [display[@"displayID"] unsignedIntValue];
        placement.origin = @{@"displayUUID": uuid, @"relative": relative};
        [pending addObject:placement];
    }
    // All exact lookups complete before changing any in-memory ownership.
    for (YMWPlacement *placement in pending) {
        for (YMWPlacement *old in self.placements.copy)
            if (old.windowID == placement.windowID && old.application.processIdentifier == placement.application.processIdentifier)
                [self.placements removeObject:old];
        [self.placements addObject:placement];
    }
    [self refreshInventory];
    return YES;
}
- (BOOL)restoreAll:(NSError **)error {
    for (NSNumber *ID in self.ownedIDs.copy) if (![self restoreDisplayID:ID.unsignedIntValue error:error]) return NO;
    return YES;
}
- (void)refreshWithVirtualDisplayID:(CGDirectDisplayID)ID displaySnapshot:(NSArray<NSDictionary *> *)snapshot {
    [self refreshWithVirtualDisplayIDs:ID ? @[@(ID)] : @[] displaySnapshot:snapshot];
}
- (BOOL)moveApplicationAtURL:(NSURL *)URL error:(NSError **)error {
    return [self moveApplicationAtURL:URL toDisplayID:self.ownedIDs.firstObject.unsignedIntValue error:error];
}
- (BOOL)restoreApplicationWithBundleIdentifier:(NSString *)bundle error:(NSError **)error {
    return [self restoreApplicationWithBundleIdentifier:bundle fromDisplayID:0 error:error];
}
@end
