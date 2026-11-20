#import "UpdateWorkspaceRecovery.h"
#import "AppWorkspacePolicy.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

NSErrorDomain const YMUpdateWorkspaceRecoveryErrorDomain = @"dev.chekusu.yomado.update-workspace";
static BOOL UFail(NSError **error, NSInteger code, NSString *text) {
    if (error) *error = [NSError errorWithDomain:YMUpdateWorkspaceRecoveryErrorDomain code:code
                                      userInfo:@{NSLocalizedDescriptionKey:text}];
    return NO;
}
static id URead(id element, CFStringRef key) {
    if (!element || CFGetTypeID((__bridge CFTypeRef)element) != AXUIElementGetTypeID()) return nil;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static NSDictionary *UFrame(id element) {
    id p = URead(element, kAXPositionAttribute), s = URead(element, kAXSizeAttribute);
    if (!p || !s || CFGetTypeID((__bridge CFTypeRef)p) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)s) != AXValueGetTypeID()) return nil;
    CGPoint point; CGSize size;
    if (!AXValueGetValue((__bridge AXValueRef)p, kAXValueCGPointType, &point) ||
        !AXValueGetValue((__bridge AXValueRef)s, kAXValueCGSizeType, &size)) return nil;
    return YMWorkspaceGeometry(@{@"x":@(point.x), @"y":@(point.y), @"width":@(size.width), @"height":@(size.height)});
}
static BOOL USameFrame(NSDictionary *a, NSDictionary *b) {
    if (!YMWorkspaceGeometry(a) || !YMWorkspaceGeometry(b)) return NO;
    for (NSString *key in @[@"x",@"y",@"width",@"height"])
        if (fabs([a[key] doubleValue] - [b[key] doubleValue]) > 1) return NO;
    return YES;
}
YMUpdateOwnedWindowRelation YMUpdateWindowRelationToOwnedDisplays(NSDictionary *frame, NSArray<NSDictionary *> *displays) {
    if (!YMWorkspaceGeometry(frame) || ![displays isKindOfClass:NSArray.class]) return YMUpdateWindowCrossesOwnedBoundary;
    double area=[frame[@"width"] doubleValue]*[frame[@"height"] doubleValue];
    NSUInteger intersected=0, contained=0;
    for (id display in displays) {
        if (![display isKindOfClass:NSDictionary.class] || !YMWorkspaceGeometry(display[@"bounds"])) return YMUpdateWindowCrossesOwnedBoundary;
        double intersection=YMWorkspaceIntersection(frame,display[@"bounds"]);
        if (intersection>0) intersected++;
        if (intersection>=area-.001) contained++;
    }
    if (!intersected) return YMUpdateWindowOutsideOwned;
    return intersected==1 && contained==1 ? YMUpdateWindowContainedInOwned : YMUpdateWindowCrossesOwnedBoundary;
}
static BOOL UInteger(id value, uint64_t minimum, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double n = [value doubleValue];
    return isfinite(n) && n >= minimum && n <= maximum && floor(n) == n;
}
static BOOL UIdentityValid(NSDictionary *identity) {
    return [identity isKindOfClass:NSDictionary.class] && identity.count == 5 &&
        UInteger(identity[@"pid"], 1, INT_MAX) && UInteger(identity[@"windowID"], 1, UINT32_MAX) &&
        UInteger(identity[@"startSeconds"], 1, UINT64_C(9999999999)) &&
        UInteger(identity[@"startMicroseconds"], 0, 999999) &&
        [identity[@"bundleID"] isKindOfClass:NSString.class] && [identity[@"bundleID"] length] > 0 &&
        [identity[@"bundleID"] length] <= 255 &&
        [identity[@"bundleID"] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet]].location == NSNotFound;
}
static NSDictionary *UProcess(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || !info.pbi_start_tvsec) return nil;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.terminated || !app.bundleIdentifier.length) return nil;
    return @{@"pid":@(pid), @"startSeconds":@(info.pbi_start_tvsec),
             @"startMicroseconds":@(info.pbi_start_tvusec), @"bundleID":app.bundleIdentifier};
}
static CGWindowID UWindowID(id element) {
    typedef AXError (*WindowIDFunction)(AXUIElementRef, CGWindowID *);
    static WindowIDFunction function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = (WindowIDFunction)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); });
    CGWindowID ID = 0;
    if (!function || !element || CFGetTypeID((__bridge CFTypeRef)element) != AXUIElementGetTypeID() ||
        function((__bridge AXUIElementRef)element, &ID) != kAXErrorSuccess) return 0;
    return ID;
}
NSDictionary *YMUpdateIdentityForWindowElement(id element) {
    CGWindowID ID = UWindowID(element); pid_t pid = 0;
    if (!ID || AXUIElementGetPid((__bridge AXUIElementRef)element, &pid) != kAXErrorSuccess) return nil;
    NSDictionary *process = UProcess(pid); if (!process) return nil;
    NSMutableDictionary *identity = process.mutableCopy; identity[@"windowID"] = @(ID);
    return identity.copy;
}
static BOOL UHasDialog(id element) {
    if ([URead(element, kAXModalAttribute) boolValue]) return YES;
    id sheets = URead(element, CFSTR("AXSheets"));
    if (sheets && (![sheets isKindOfClass:NSArray.class] || [sheets count])) return YES;
    id children = URead(element, kAXChildrenAttribute);
    if (children && ![children isKindOfClass:NSArray.class]) return YES;
    for (id child in children) {
        id role = URead(child, kAXRoleAttribute), subrole = URead(child, kAXSubroleAttribute);
        if ([role isEqual:(__bridge NSString *)kAXSheetRole] || [URead(child, kAXModalAttribute) boolValue] ||
            [subrole isEqual:(__bridge NSString *)kAXDialogSubrole] ||
            [subrole isEqual:(__bridge NSString *)kAXSystemDialogSubrole]) return YES;
    }
    return NO;
}
static BOOL UWindowSafe(id element) {
    if (![URead(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole] ||
        ![URead(element, kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole] ||
        [URead(element, kAXMinimizedAttribute) boolValue] || [URead(element, CFSTR("AXFullScreen")) boolValue] ||
        UHasDialog(element)) return NO;
    id sheets = URead(element, CFSTR("AXSheets"));
    if (sheets && (![sheets isKindOfClass:NSArray.class] || [sheets count])) return NO;
    Boolean settable = false;
    return UFrame(element) && AXUIElementIsAttributeSettable((__bridge AXUIElementRef)element,
        kAXPositionAttribute, &settable) == kAXErrorSuccess && settable;
}
static BOOL USystemMenuMatchesDisplay(NSDictionary *systemMenu, NSDictionary *displayBounds,
    double topInset, NSInteger mainMenuLevel) {
    if (![systemMenu isKindOfClass:NSDictionary.class] || !YMWorkspaceGeometry(displayBounds) ||
        !YMWorkspaceGeometry(systemMenu[@"frame"]) || !isfinite(topInset) || topInset <= 1 ||
        topInset >= [displayBounds[@"height"] doubleValue] / 4 || mainMenuLevel <= 0 ||
        ![systemMenu[@"trustedWindowServer"] isEqual:@YES] || ![systemMenu[@"onscreen"] isEqual:@YES] ||
        ![systemMenu[@"layer"] isEqual:@(mainMenuLevel)] ||
        !UInteger(systemMenu[@"pid"],1,INT_MAX) || !UInteger(systemMenu[@"windowID"],1,UINT32_MAX)) return NO;
    NSDictionary *band=@{@"x":displayBounds[@"x"],@"y":displayBounds[@"y"],
        @"width":displayBounds[@"width"],@"height":@(topInset)};
    // AppKit reserves an additional edge pixel on some systems (31 vs 30).
    // Use the actual full-width system surface, with only rounding tolerance.
    return USameFrame(systemMenu[@"frame"],band);
}
// Pure classification, with the system cursor level supplied by the caller.
// These small WindowServer surfaces hold no application workspace to restore.
// The mouse pointer: WindowServer's own small square surface at the cursor level. It holds no work, moves on its
// own and is never restored, so it may sit anywhere, even across an owned display's edge, without pausing an update.
// Only WindowServer's surfaces at exactly the cursor level and at most 64 points square qualify; anything else at a
// high level still blocks.
BOOL YMUpdateIsPointerSurface(NSDictionary *candidate, NSInteger cursorLevel, BOOL windowServer) {
    if (!windowServer || ![candidate isKindOfClass:NSDictionary.class] || cursorLevel<=0 ||
        !YMWorkspaceGeometry(candidate[@"frame"]) || ![candidate[@"layer"] isEqual:@(cursorLevel)]) return NO;
    double width=[candidate[@"frame"][@"width"] doubleValue], height=[candidate[@"frame"][@"height"] doubleValue];
    return width>=1 && height>=1 && width<=64 && height<=64 && fabs(width-height)<=1;
}
BOOL YMUpdateIsVerifiedMenuCursorChrome(NSDictionary *candidate, NSDictionary *displayBounds,
    double topInset, NSInteger mainMenuLevel, NSDictionary *systemMenu, NSInteger cursorLevel) {
    if (![candidate isKindOfClass:NSDictionary.class] || !YMWorkspaceGeometry(candidate[@"frame"]) ||
        !UInteger(candidate[@"windowID"],1,UINT32_MAX) || cursorLevel<=mainMenuLevel ||
        !USystemMenuMatchesDisplay(systemMenu,displayBounds,topInset,mainMenuLevel) ||
        ![candidate[@"pid"] isEqual:systemMenu[@"pid"]] || ![candidate[@"onscreen"] isEqual:@YES] ||
        ![candidate[@"layer"] isEqual:@(cursorLevel)]) return NO;
    NSDictionary *frame=candidate[@"frame"], *band=systemMenu[@"frame"];
    double x=[frame[@"x"] doubleValue], y=[frame[@"y"] doubleValue];
    double width=[frame[@"width"] doubleValue], height=[frame[@"height"] doubleValue];
    double bandX=[band[@"x"] doubleValue], bandY=[band[@"y"] doubleValue];
    double bandWidth=[band[@"width"] doubleValue], bandHeight=[band[@"height"] doubleValue];
    // Deliberately no rounding allowance for containment or maximum size.
    return width<=bandHeight && height<=bandHeight && fabs(width-height)<=1 &&
        x>=bandX && y>=bandY && x+width<=bandX+bandWidth && y+height<=bandY+bandHeight;
}
BOOL YMUpdateIsVerifiedMenuChrome(NSDictionary *candidate, NSDictionary *displayBounds,
    double topInset, NSInteger mainMenuLevel, NSDictionary *systemMenu, NSDictionary *ownerAX,
    NSArray<NSDictionary *> *currentMenuRegions) {
    if (![candidate isKindOfClass:NSDictionary.class] || !YMWorkspaceGeometry(candidate[@"frame"]) ||
        !UInteger(candidate[@"pid"],1,INT_MAX) || !UInteger(candidate[@"windowID"],1,UINT32_MAX) ||
        !USystemMenuMatchesDisplay(systemMenu,displayBounds,topInset,mainMenuLevel) ||
        !USameFrame(candidate[@"frame"],systemMenu[@"frame"])) return NO;
    if ([candidate[@"pid"] isEqual:systemMenu[@"pid"]] &&
        [candidate[@"windowID"] isEqual:systemMenu[@"windowID"]])
        return [candidate[@"onscreen"] isEqual:@YES] && [candidate[@"layer"] isEqual:@(mainMenuLevel)];
    if (![candidate[@"onscreen"] isEqual:@NO] || ![candidate[@"layer"] isEqual:@0] ||
        ![ownerAX isKindOfClass:NSDictionary.class] || ![ownerAX[@"pid"] isEqual:candidate[@"pid"]] ||
        ![ownerAX[@"menuRole"] isEqual:(__bridge NSString *)kAXMenuBarRole] ||
        ![ownerAX[@"windows"] isKindOfClass:NSArray.class]) return NO;
    // AXMenuBar can describe the primary menu while its backing copies occupy
    // other screens. Exposed geometry must still match a current system menu;
    // the candidate above must match the menu on its own display.
    if (ownerAX[@"menuFrame"] && !USameFrame(ownerAX[@"menuFrame"],systemMenu[@"frame"])) {
        if (![currentMenuRegions isKindOfClass:NSArray.class]) return NO;
        BOOL corroborated=NO;
        for (id region in currentMenuRegions) {
            if (![region isKindOfClass:NSDictionary.class] ||
                ![region[@"topInset"] isKindOfClass:NSNumber.class] ||
                !USystemMenuMatchesDisplay(region[@"surface"],region[@"bounds"],
                    [region[@"topInset"] doubleValue],mainMenuLevel)) continue;
            if (USameFrame(ownerAX[@"menuFrame"],region[@"surface"][@"frame"])) { corroborated=YES; break; }
        }
        if (!corroborated) return NO;
    }
    for (id window in ownerAX[@"windows"]) {
        if (![window isKindOfClass:NSDictionary.class]) return NO;
        if ([ownerAX[@"bundleID"] isEqual:@"com.apple.finder"] &&
            [window[@"role"] isEqual:(__bridge NSString *)kAXScrollAreaRole] &&
            [window[@"windowID"] isEqual:@0] && [window[@"hasDialog"] isEqual:@NO]) continue;
        if (![window[@"role"] isEqual:(__bridge NSString *)kAXWindowRole] ||
            ![window[@"safe"] isEqual:@YES] || ![window[@"hasDialog"] isEqual:@NO] ||
            !UInteger(window[@"windowID"],1,UINT32_MAX) || !YMWorkspaceGeometry(window[@"frame"]) ||
            [window[@"windowID"] isEqual:candidate[@"windowID"]] ||
            USameFrame(window[@"frame"],candidate[@"frame"])) return NO;
    }
    return YES;
}
static NSDictionary *UMenuOwnerSnapshot(pid_t pid) {
    NSDictionary *identity=UProcess(pid); if (!identity || !AXIsProcessTrusted()) return nil;
    AXUIElementRef application=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(application,.8);
    id app=CFBridgingRelease(application), windows=URead(app,kAXWindowsAttribute), menu=URead(app,kAXMenuBarAttribute);
    if (![windows isKindOfClass:NSArray.class] || ![URead(menu,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuBarRole]) return nil;
    NSMutableArray *items=[NSMutableArray array];
    for (id window in windows) {
        id role=URead(window,kAXRoleAttribute); if (![role isKindOfClass:NSString.class]) return nil;
        NSMutableDictionary *item=[@{@"role":role,@"windowID":@(UWindowID(window)),
            @"safe":@(UWindowSafe(window)),@"hasDialog":@(UHasDialog(window))} mutableCopy];
        NSDictionary *frame=UFrame(window); if (frame) item[@"frame"]=frame;
        [items addObject:item.copy];
    }
    if (![identity isEqual:UProcess(pid)]) return nil;
    NSMutableDictionary *result=[@{@"pid":@(pid),@"bundleID":identity[@"bundleID"],
        @"menuRole":(__bridge NSString *)kAXMenuBarRole,@"windows":items.copy} mutableCopy];
    NSDictionary *frame=UFrame(menu); if (frame) result[@"menuFrame"]=frame;
    return result.copy;
}
static BOOL UIsSystemWindowServer(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    return proc_pidpath(pid,path,sizeof(path))>0 &&
        strcmp(path,"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer")==0;
}
static NSDictionary *UMenuScreenInsets(NSArray *displays) {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    double primaryHeight=CGDisplayBounds(CGMainDisplayID()).size.height;
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *ID=screen.deviceDescription[@"NSScreenNumber"];
        for (NSDictionary *display in displays) {
            if (![display[@"displayID"] isEqual:ID]) continue;
            NSRect frame=screen.frame, visible=screen.visibleFrame;
            NSDictionary *converted=@{@"x":@(frame.origin.x),@"y":@(primaryHeight-NSMaxY(frame)),
                @"width":@(frame.size.width),@"height":@(frame.size.height)};
            double inset=NSMaxY(frame)-NSMaxY(visible);
            if (USameFrame(converted,display[@"bounds"]) && NSContainsRect(frame,visible) && isfinite(inset) && inset>1)
                result[ID]=@(inset);
        }
    }
    return result.copy;
}
id YMUpdateResolveWindowIdentity(NSDictionary *identity, NSError **error) {
    if (!UIdentityValid(identity) || !AXIsProcessTrusted()) {
        UFail(error, 1, @"Window control permission or exact window identity is unavailable."); return nil;
    }
    NSMutableDictionary *expected = identity.mutableCopy; [expected removeObjectForKey:@"windowID"];
    if (![UProcess([identity[@"pid"] intValue]) isEqual:expected]) {
        UFail(error, 2, @"The saved application process changed; no replacement window will be moved."); return nil;
    }
    AXUIElementRef app = AXUIElementCreateApplication([identity[@"pid"] intValue]);
    AXUIElementSetMessagingTimeout(app, .8);
    id application = CFBridgingRelease(app), windows = URead(application, kAXWindowsAttribute);
    if (![windows isKindOfClass:NSArray.class]) { UFail(error, 3, @"The saved application cannot enumerate its windows safely."); return nil; }
    id match = nil;
    for (id window in windows) {
        NSString *role = URead(window, kAXSubroleAttribute);
        id sheets = URead(window, CFSTR("AXSheets"));
        if ([role isEqual:(__bridge NSString *)kAXDialogSubrole] ||
            [role isEqual:(__bridge NSString *)kAXSystemDialogSubrole] ||
            UHasDialog(window) ||
            (sheets && (![sheets isKindOfClass:NSArray.class] || [sheets count]))) {
            UFail(error, 4, @"An application has a dialog or sheet; close it before updating."); return nil;
        }
        if (UWindowID(window) != [identity[@"windowID"] unsignedIntValue]) continue;
        if (match) { UFail(error, 5, @"The saved window identity is ambiguous."); return nil; }
        match = window;
    }
    if (!match || ![YMUpdateIdentityForWindowElement(match) isEqual:identity] || !UWindowSafe(match)) {
        UFail(error, 6, @"The saved ordinary window is unavailable, full-screen, minimized or not movable."); return nil;
    }
    return match;
}
static NSDictionary *UCGWindowMetadata(NSDictionary *raw) {
    CGRect rect;
    if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)raw[(__bridge NSString *)kCGWindowBounds], &rect)) return nil;
    NSDictionary *frame = YMWorkspaceGeometry(@{@"x":@(rect.origin.x),@"y":@(rect.origin.y),
        @"width":@(rect.size.width),@"height":@(rect.size.height)});
    if (!frame) return nil;
    return @{@"windowID":raw[(__bridge NSString *)kCGWindowNumber], @"pid":raw[(__bridge NSString *)kCGWindowOwnerPID],
             @"frame":frame, @"onscreen":raw[(__bridge NSString *)kCGWindowIsOnscreen] ?: @NO,
             @"layer":raw[(__bridge NSString *)kCGWindowLayer] ?: @0};
}
static NSDictionary *UCGWindow(CGWindowID ID) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, ID));
    return windows.count==1 ? UCGWindowMetadata(windows.firstObject) : nil;
}
static NSArray *UDisplays(NSError **error) {
    CGDirectDisplayID ids[256]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(256, ids, &count) || !count || count >= 256) {
        UFail(error, 10, @"The complete display topology is unavailable."); return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID ID = ids[i]; CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(ID);
        if (!uuid) { UFail(error, 10, @"A display has no stable identity."); return nil; }
        NSString *identity = CFBridgingRelease(CFUUIDCreateString(NULL, uuid)); CFRelease(uuid);
        CGRect rect = CGDisplayBounds(ID); CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ID);
        if (!mode && CGDisplayIsActive(ID)) { UFail(error, 10, @"A display mode is still changing."); return nil; }
        NSDictionary *modeInfo = mode ? @{@"width":@(CGDisplayModeGetWidth(mode)), @"height":@(CGDisplayModeGetHeight(mode)),
            @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode)),
            @"refresh":@(CGDisplayModeGetRefreshRate(mode)), @"flags":@(CGDisplayModeGetIOFlags(mode)),
            @"desktopUsable":@(CGDisplayModeIsUsableForDesktopGUI(mode))} : @{};
        if (mode) CGDisplayModeRelease(mode);
        [result addObject:@{@"displayID":@(ID), @"identity":identity, @"main":@(CGDisplayIsMain(ID)),
            @"active":@(CGDisplayIsActive(ID)), @"rotation":@(CGDisplayRotation(ID)),
            @"mirrorOf":@(CGDisplayMirrorsDisplay(ID)), @"inMirrorSet":@(CGDisplayIsInMirrorSet(ID)),
            @"bounds":@{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)},
            @"mode":modeInfo}];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"displayID"] compare:b[@"displayID"]]; }];
    return result.copy;
}

@interface YMNativeUpdateWorkspaceBackend : NSObject <YMUpdateWorkspaceRecoveryBackend>
@end
@implementation YMNativeUpdateWorkspaceBackend
- (NSTimeInterval)now { return NSDate.date.timeIntervalSince1970; }
- (NSString *)bootSessionIdentifier {
    char value[128] = {0}; size_t length = sizeof(value);
    return sysctlbyname("kern.bootsessionuuid", value, &length, NULL, 0) == 0 ? [NSString stringWithUTF8String:value] : @"";
}
- (NSString *)runningVersion { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""; }
- (NSString *)runningBuild { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @""; }
- (NSDictionary *)readWindow:(NSDictionary *)identity error:(NSError **)error {
    id element = YMUpdateResolveWindowIdentity(identity, error); if (!element) return nil;
    NSDictionary *cg = UCGWindow([identity[@"windowID"] unsignedIntValue]), *frame = UFrame(element);
    if (!cg || ![cg[@"pid"] isEqual:identity[@"pid"]] || [cg[@"layer"] integerValue] != 0 ||
        ![cg[@"onscreen"] boolValue] || !USameFrame(frame, cg[@"frame"])) {
        UFail(error, 7, @"The saved window's independent observations disagree or it is not visible."); return nil;
    }
    return @{@"identity":identity, @"frame":frame};
}
- (NSDictionary *)captureWithProfiles:(NSArray<NSDictionary *> *)profiles error:(NSError **)error {
    NSArray *displays = UDisplays(error); if (!displays) return nil;
    NSMutableArray *owned = [NSMutableArray array];
    for (NSDictionary *profile in profiles) {
        NSDictionary *found = nil;
        for (NSDictionary *display in displays) if ([display[@"displayID"] isEqual:profile[@"displayID"]]) found = display;
        if (!found) { UFail(error, 11, @"An owned display disappeared before the update checkpoint."); return nil; }
        [owned addObject:found];
    }
    if (!owned.count) return @{@"displays":displays, @"windows":@[]};
    NSArray *raw = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, 0));
    if (!raw) { UFail(error, 12, @"The complete window inventory is unavailable."); return nil; }
    NSDictionary *menuInsets=UMenuScreenInsets(displays);
    NSInteger menuLevel=CGWindowLevelForKey(kCGMainMenuWindowLevelKey);
    NSInteger cursorLevel=CGWindowLevelForKey(kCGCursorWindowLevelKey);
    NSMutableDictionary<NSNumber *,NSMutableArray *> *systemMenus=[NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *currentMenuRegions=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,id> *menuOwners=[NSMutableDictionary dictionary];
    for (NSDictionary *entry in raw) {
        if ([entry[(__bridge NSString *)kCGWindowLayer] integerValue]!=menuLevel ||
            ![entry[(__bridge NSString *)kCGWindowIsOnscreen] boolValue] ||
            !UIsSystemWindowServer([entry[(__bridge NSString *)kCGWindowOwnerPID] intValue])) continue;
        NSMutableDictionary *menu=[UCGWindowMetadata(entry) mutableCopy]; if (!menu) continue;
        menu[@"trustedWindowServer"]=@YES;
        for (NSDictionary *display in displays) {
            NSNumber *ID=display[@"displayID"];
            if (!USystemMenuMatchesDisplay(menu,display[@"bounds"],[menuInsets[ID] doubleValue],menuLevel)) continue;
            if (!systemMenus[ID]) systemMenus[ID]=[NSMutableArray array];
            [systemMenus[ID] addObject:menu.copy];
            [currentMenuRegions addObject:@{@"surface":menu.copy,@"bounds":display[@"bounds"],@"topInset":menuInsets[ID]}];
        }
    }
    NSMutableArray *windows = [NSMutableArray array];
    for (NSDictionary *entry in raw) {
        CGRect rect;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds], &rect)) continue;
        NSDictionary *frame = YMWorkspaceGeometry(@{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)});
        if (!frame || rect.size.width < 1 || rect.size.height < 1) continue;
        pid_t pid = [entry[(__bridge NSString *)kCGWindowOwnerPID] intValue];
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *bundle = app.bundleIdentifier;
        if ([@[@"com.apple.dock",@"com.apple.SystemUIServer",@"com.apple.WindowManager",@"com.apple.controlcenter",@"com.apple.loginwindow"] containsObject:bundle ?: @""]) continue;
        // The new application restores its own panel from a separate checkpoint.
        if (pid == getpid()) continue;
        // Off-screen, non-document backing windows do not hold visible work.
        // Hidden layer-zero windows remain uncertain and therefore block.
        if (![entry[(__bridge NSString *)kCGWindowIsOnscreen] boolValue] &&
            [entry[(__bridge NSString *)kCGWindowLayer] integerValue] != 0) continue;
        if (YMUpdateIsPointerSurface(UCGWindowMetadata(entry),cursorLevel,UIsSystemWindowServer(pid))) continue;
        YMUpdateOwnedWindowRelation relation=YMUpdateWindowRelationToOwnedDisplays(frame,owned);
        if (relation==YMUpdateWindowOutsideOwned) continue;
        if (relation==YMUpdateWindowCrossesOwnedBoundary) {
            UFail(error,13,@"A window crosses an owned display boundary; move it fully onto one display before updating."); return nil;
        }
        NSDictionary *owner=nil;
        for (NSDictionary *display in owned) if (YMWorkspaceIntersection(frame,display[@"bounds"])>0) owner=display;
        BOOL menuChrome=NO;
        for (NSDictionary *menu in systemMenus[owner[@"displayID"]]) {
            NSDictionary *candidate=UCGWindowMetadata(entry), *ownerAX=nil;
            if (YMUpdateIsVerifiedMenuCursorChrome(candidate,owner[@"bounds"],
                [menuInsets[owner[@"displayID"]] doubleValue],menuLevel,menu,cursorLevel)) { menuChrome=YES; break; }
            if (!USameFrame(frame,menu[@"frame"])) continue;
            if ([candidate[@"layer"] isEqual:@0] && [candidate[@"onscreen"] isEqual:@NO]) {
                NSNumber *PID=@(pid);
                if (!menuOwners[PID]) menuOwners[PID]=UMenuOwnerSnapshot(pid) ?: NSNull.null;
                if ([menuOwners[PID] isKindOfClass:NSDictionary.class]) ownerAX=menuOwners[PID];
            }
            if (YMUpdateIsVerifiedMenuChrome(candidate,owner[@"bounds"],
                [menuInsets[owner[@"displayID"]] doubleValue],menuLevel,menu,ownerAX,currentMenuRegions)) { menuChrome=YES; break; }
        }
        if (menuChrome) continue;
        if (!bundle || [entry[(__bridge NSString *)kCGWindowLayer] integerValue] != 0 ||
            ![entry[(__bridge NSString *)kCGWindowIsOnscreen] boolValue] ||
            YMWorkspaceIntersection(frame, owner[@"bounds"]) < rect.size.width * rect.size.height - 1) {
            UFail(error, 13, @"An owned display has an unsupported, hidden or overlapping window; update is paused."); return nil;
        }
        NSMutableDictionary *identity = [UProcess(pid) mutableCopy];
        if (!identity) { UFail(error, 2, @"An application process identity is unavailable."); return nil; }
        identity[@"windowID"] = entry[(__bridge NSString *)kCGWindowNumber];
        NSDictionary *window = [self readWindow:identity error:error]; if (!window) return nil;
        if (!USameFrame(window[@"frame"], frame)) { UFail(error, 7, @"Window geometry changed during checkpoint capture."); return nil; }
        NSMutableDictionary *candidate = window.mutableCopy; candidate[@"displayID"] = owner[@"displayID"];
        [windows addObject:candidate.copy];
    }
    [windows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"identity"][@"windowID"] compare:b[@"identity"][@"windowID"]]; }];
    return @{@"displays":displays, @"windows":windows.copy};
}
- (BOOL)moveWindow:(NSDictionary *)identity fromFrame:(NSDictionary *)before toFrame:(NSDictionary *)after error:(NSError **)error {
    NSDictionary *live = [self readWindow:identity error:error];
    if (!live || !USameFrame(live[@"frame"], before) || !YMWorkspaceGeometry(after))
        return UFail(error, 14, @"Window geometry changed before restoration; no substitute window will be moved.");
    id element = YMUpdateResolveWindowIdentity(identity, error); if (!element) return NO;
    AXUIElementRef ref = (__bridge AXUIElementRef)element;
    CGSize size = CGSizeMake([after[@"width"] doubleValue], [after[@"height"] doubleValue]);
    if (fabs([before[@"width"] doubleValue] - size.width) > 1 || fabs([before[@"height"] doubleValue] - size.height) > 1) {
        Boolean settable = false;
        if (AXUIElementIsAttributeSettable(ref, kAXSizeAttribute, &settable) != kAXErrorSuccess || !settable)
            return UFail(error, 15, @"A saved window cannot restore its original size.");
        AXValueRef value = AXValueCreate(kAXValueCGSizeType, &size);
        AXError result = value ? AXUIElementSetAttributeValue(ref, kAXSizeAttribute, value) : kAXErrorFailure;
        if (value) CFRelease(value);
        if (result != kAXErrorSuccess) return UFail(error, 15, @"The saved window rejected size restoration.");
    }
    if (![YMUpdateIdentityForWindowElement(element) isEqual:identity]) return UFail(error, 2, @"The saved window identity changed.");
    CGPoint point = CGPointMake([after[@"x"] doubleValue], [after[@"y"] doubleValue]);
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &point);
    AXError result = value ? AXUIElementSetAttributeValue(ref, kAXPositionAttribute, value) : kAXErrorFailure;
    if (value) CFRelease(value);
    if (result != kAXErrorSuccess || !USameFrame(UFrame(element), after))
        return UFail(error, 16, @"Exact saved window placement has not been verified; recovery remains pending.");
    return YES;
}
@end

static NSString *UString(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > limit ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return value;
}
static NSDictionary *USelect(NSDictionary *value, NSArray<NSString *> *keys) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in keys) { if (!value[key]) return nil; result[key] = value[key]; }
    return result.copy;
}
static NSDictionary *UDisplay(NSDictionary *raw) {
    NSDictionary *result = USelect(raw, @[@"displayID",@"identity",@"main",@"active",@"rotation",@"mirrorOf",@"inMirrorSet",@"bounds",@"mode"]);
    if (!result || !UInteger(result[@"displayID"],1,UINT32_MAX) || !UString(result[@"identity"],128) ||
        !UInteger(result[@"main"],0,1) || !UInteger(result[@"active"],0,1) || !UInteger(result[@"inMirrorSet"],0,1) ||
        !UInteger(result[@"mirrorOf"],0,UINT32_MAX) || ![result[@"rotation"] isKindOfClass:NSNumber.class] ||
        !isfinite([result[@"rotation"] doubleValue]) || !YMWorkspaceGeometry(result[@"bounds"])) return nil;
    id mode = result[@"mode"];
    if (![mode isKindOfClass:NSDictionary.class]) return nil;
    if ([mode count]) {
        mode = USelect(mode,@[@"width",@"height",@"pixelWidth",@"pixelHeight",@"refresh",@"flags",@"desktopUsable"]);
        if (!mode) return nil;
        for (NSString *key in @[@"width",@"height",@"pixelWidth",@"pixelHeight"])
            if (!UInteger(mode[key],1,100000)) return nil;
        if (!UInteger(mode[@"flags"],0,UINT32_MAX) || !UInteger(mode[@"desktopUsable"],0,1) ||
            ![mode[@"refresh"] isKindOfClass:NSNumber.class] || !isfinite([mode[@"refresh"] doubleValue]) ||
            [mode[@"refresh"] doubleValue] < 0 || [mode[@"refresh"] doubleValue] > 1000) return nil;
    } else if ([result[@"active"] boolValue]) return nil;
    NSMutableDictionary *clean = result.mutableCopy;
    clean[@"bounds"] = YMWorkspaceGeometry(result[@"bounds"]); clean[@"mode"] = mode;
    return clean.copy;
}
static NSDictionary *UState(NSDictionary *raw) {
    if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"displays"] isKindOfClass:NSArray.class] ||
        ![raw[@"windows"] isKindOfClass:NSArray.class] || ![raw[@"displays"] count] ||
        [raw[@"displays"] count] > 256 || [raw[@"windows"] count] > 2048) return nil;
    NSMutableArray *displays=[NSMutableArray array], *windows=[NSMutableArray array];
    NSMutableSet *ids=[NSMutableSet set], *uuids=[NSMutableSet set], *windowIDs=[NSMutableSet set];
    NSUInteger mainCount=0;
    for (NSDictionary *entry in raw[@"displays"]) {
        NSDictionary *display=UDisplay(entry); if (!display || [ids containsObject:display[@"displayID"]] ||
            [uuids containsObject:display[@"identity"]]) return nil;
        [ids addObject:display[@"displayID"]]; [uuids addObject:display[@"identity"]];
        mainCount += [display[@"main"] boolValue]; [displays addObject:display];
    }
    if (mainCount != 1) return nil;
    for (NSDictionary *entry in raw[@"windows"]) {
        if (![entry isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *identity=entry[@"identity"], *frame=YMWorkspaceGeometry(entry[@"frame"]);
        if (!UIdentityValid(identity) || !frame || ![ids containsObject:entry[@"displayID"]] ||
            [windowIDs containsObject:identity[@"windowID"]]) return nil;
        NSDictionary *owner=nil;
        for (NSDictionary *display in displays) if ([display[@"displayID"] isEqual:entry[@"displayID"]]) owner=display;
        if (YMWorkspaceIntersection(frame,owner[@"bounds"]) < [frame[@"width"] doubleValue]*[frame[@"height"] doubleValue]-1) return nil;
        [windowIDs addObject:identity[@"windowID"]];
        [windows addObject:@{@"identity":identity,@"frame":frame,@"displayID":entry[@"displayID"]}];
    }
    [displays sortUsingComparator:^NSComparisonResult(id a,id b) { return [a[@"displayID"] compare:b[@"displayID"]]; }];
    [windows sortUsingComparator:^NSComparisonResult(id a,id b) { return [a[@"identity"][@"windowID"] compare:b[@"identity"][@"windowID"]]; }];
    return @{@"displays":displays.copy,@"windows":windows.copy};
}
static NSDictionary *UFindDisplay(NSArray *displays, NSNumber *ID) {
    for (NSDictionary *display in displays) if ([display[@"displayID"] isEqual:ID]) return display;
    return nil;
}
static NSArray *UProfiles(NSArray *profiles, NSDictionary *state) {
    if (![profiles isKindOfClass:NSArray.class] || profiles.count > 16) return nil;
    NSMutableArray *clean=[NSMutableArray array]; NSMutableSet *ids=[NSMutableSet set], *ordinals=[NSMutableSet set];
    for (id p in profiles) {
        NSDictionary *profile=USelect(p,@[@"ordinal",@"displayID",@"width",@"height",@"hiDPI"]);
        if (!profile || !UInteger(profile[@"ordinal"],1,1000000) || !UInteger(profile[@"displayID"],1,UINT32_MAX) ||
            !UInteger(profile[@"width"],640,16384) || !UInteger(profile[@"height"],480,16384) ||
            !UInteger(profile[@"hiDPI"],0,1) || [ids containsObject:profile[@"displayID"]] ||
            [ordinals containsObject:profile[@"ordinal"]]) return nil;
        NSDictionary *d=UFindDisplay(state[@"displays"],profile[@"displayID"]), *mode=d[@"mode"];
        NSUInteger scale=[profile[@"hiDPI"] boolValue] ? 2 : 1;
        if (!d || [d[@"main"] boolValue] || ![d[@"active"] boolValue] || [d[@"mirrorOf"] unsignedIntValue] ||
            [d[@"inMirrorSet"] boolValue] || [d[@"rotation"] doubleValue] != 0 ||
            [mode[@"width"] unsignedIntegerValue] != [profile[@"width"] unsignedIntegerValue] ||
            [mode[@"height"] unsignedIntegerValue] != [profile[@"height"] unsignedIntegerValue] ||
            [mode[@"pixelWidth"] unsignedIntegerValue] != [profile[@"width"] unsignedIntegerValue]*scale ||
            [mode[@"pixelHeight"] unsignedIntegerValue] != [profile[@"height"] unsignedIntegerValue]*scale ||
            [d[@"bounds"][@"width"] unsignedIntegerValue] != [profile[@"width"] unsignedIntegerValue] ||
            [d[@"bounds"][@"height"] unsignedIntegerValue] != [profile[@"height"] unsignedIntegerValue]) return nil;
        NSMutableDictionary *saved=profile.mutableCopy; saved[@"bounds"]=d[@"bounds"];
        [clean addObject:saved.copy]; [ids addObject:profile[@"displayID"]]; [ordinals addObject:profile[@"ordinal"]];
    }
    for (NSDictionary *window in state[@"windows"]) if (![ids containsObject:window[@"displayID"]]) return nil;
    [clean sortUsingComparator:^NSComparisonResult(id a,id b) { return [a[@"ordinal"] compare:b[@"ordinal"]]; }];
    return clean.copy;
}
static NSArray *UOrigins(NSArray *origins, NSDictionary *state) {
    if (![origins isKindOfClass:NSArray.class] || origins.count > 2048) return nil;
    NSMutableArray *result=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for (id item in origins) {
        if (![item isKindOfClass:NSDictionary.class] || !UIdentityValid(item[@"identity"])) return nil;
        NSDictionary *origin=item[@"origin"];
        if (![origin isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *relative=YMWorkspaceGeometry(origin[@"relative"]);
        if (!UString(origin[@"displayUUID"],128) || !relative ||
            [seen containsObject:item[@"identity"]]) return nil;
        BOOL found=NO;
        for (NSDictionary *window in state[@"windows"]) if ([window[@"identity"] isEqual:item[@"identity"]]) found=YES;
        if (!found) return nil;
        [seen addObject:item[@"identity"]];
        [result addObject:@{@"identity":item[@"identity"],@"origin":@{@"displayUUID":origin[@"displayUUID"],@"relative":relative}}];
    }
    return result.copy;
}

@interface YMUpdateWorkspaceRecovery ()
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) id<YMUpdateWorkspaceRecoveryBackend> backend;
@property(nonatomic, copy) NSDictionary *journal;
@property(nonatomic, copy) NSString *transaction;
@property(nonatomic) BOOL preparedByThisInstance;
@property(nonatomic) BOOL claimed;
@property(nonatomic) BOOL restored;
@property(nonatomic, copy) NSArray *restoredProfiles;
@property(nonatomic, strong) NSMutableDictionary *observedOwnedIdentities;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *restoredOriginCheckpoints;
@end
@implementation YMUpdateWorkspaceRecovery
- (instancetype)init {
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [self initWithDirectoryURL:[support URLByAppendingPathComponent:@"dev.chekusu.yomado/UpdateRecovery" isDirectory:YES]
                             backend:[YMNativeUpdateWorkspaceBackend new]];
}
- (instancetype)initWithDirectoryURL:(NSURL *)directory backend:(id<YMUpdateWorkspaceRecoveryBackend>)backend {
    self=[super init]; if (self) { _directory=directory; _backend=backend; _restoredOriginCheckpoints=@[]; _observedOwnedIdentities=[NSMutableDictionary dictionary]; } return self;
}
- (int)openDirectory:(NSError **)error {
    if (!self.directory.isFileURL || !self.directory.path.isAbsolutePath) { UFail(error,20,@"The private recovery directory is invalid."); return -1; }
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    NSArray *parts=self.directory.path.pathComponents;
    for (NSString *part in parts) {
        if ([part isEqual:@"/"]) continue;
        if ([part isEqual:@".."] || [part isEqual:@"."] || !part.length) { close(fd); UFail(error,20,@"The private recovery directory is invalid."); return -1; }
        if (mkdirat(fd,part.fileSystemRepresentation,0700) && errno != EEXIST) { close(fd); UFail(error,20,@"Cannot create the private recovery directory."); return -1; }
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); close(fd); fd=next;
        if (fd<0) { UFail(error,20,@"The recovery path is not a safe directory."); return -1; }
    }
    struct stat info;
    if (fstat(fd,&info) || info.st_uid != getuid() || (info.st_mode & 0777) != 0700) {
        close(fd); UFail(error,20,@"The recovery directory must be private to the current user."); return -1;
    }
    return fd;
}
- (NSDictionary *)readJournal:(NSError **)error {
    int dir=[self openDirectory:error]; if (dir<0) return nil;
    int fd=openat(dir,"restart.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC); int reason=errno; close(dir);
    if (fd<0) { if (reason != ENOENT) UFail(error,21,@"The recovery record cannot be read safely."); return nil; }
    struct stat info;
    if (fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || (info.st_mode&0777)!=0600 ||
        info.st_nlink!=1 || info.st_size<2 || info.st_size>1024*1024) {
        close(fd); UFail(error,21,@"The recovery record has unsafe ownership, permissions or size."); return nil;
    }
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)info.st_size]; size_t count=0;
    while (count<data.length) { ssize_t got=read(fd,(char *)data.mutableBytes+count,data.length-count); if (got<=0) { close(fd); UFail(error,21,@"The recovery record is incomplete."); return nil; } count+=(size_t)got; }
    close(fd);
    id record=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![self validJournal:record]) { UFail(error,22,@"The recovery record is invalid or uses an unsupported format."); return nil; }
    return record;
}
- (BOOL)validJournal:(NSDictionary *)j {
    if (![j isKindOfClass:NSDictionary.class] || j.count!=13 || ![j[@"schema"] isEqual:@1] ||
        ![j[@"intent"] isEqual:@"sparkle-install"] || !UString(j[@"transaction"],36) || ![NSUUID.alloc initWithUUIDString:j[@"transaction"]] ||
        ![@[@"prepared",@"armed",@"claimed"] containsObject:j[@"phase"]] ||
        ![j[@"createdAt"] isKindOfClass:NSNumber.class] || !isfinite([j[@"createdAt"] doubleValue]) ||
        !UString(j[@"bootSession"],128) || !UString(j[@"sourceVersion"],64) || !UString(j[@"sourceBuild"],64) ||
        !UString(j[@"targetVersion"],64) || !UString(j[@"targetBuild"],64)) return NO;
    NSDictionary *state=UState(j[@"state"]); NSArray *profiles=state ? UProfiles(j[@"profiles"],state) : nil;
    NSArray *origins=state ? UOrigins(j[@"origins"],state) : nil;
    return state && profiles && origins && [state isEqual:j[@"state"]] &&
        [profiles isEqual:j[@"profiles"]] && [origins isEqual:j[@"origins"]];
}
- (BOOL)writeJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self validJournal:journal]) return UFail(error,22,@"The recovery record failed validation.");
    NSData *data=[NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingSortedKeys error:NULL];
    if (!data || data.length>1024*1024) return UFail(error,22,@"The recovery record is too large.");
    int dir=[self openDirectory:error]; if (dir<0) return NO;
    NSString *temporary=[NSString stringWithFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
    int fd=openat(dir,temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) { close(dir); return UFail(error,23,@"Cannot write the private recovery record."); }
    size_t count=0; BOOL okay=YES;
    while (count<data.length) { ssize_t n=write(fd,(const char *)data.bytes+count,data.length-count); if (n<=0) { okay=NO; break; } count+=(size_t)n; }
    if (okay) okay=fsync(fd)==0; close(fd);
    if (okay) okay=renameat(dir,temporary.fileSystemRepresentation,dir,"restart.json")==0;
    if (okay) okay=fsync(dir)==0;
    if (!okay) unlinkat(dir,temporary.fileSystemRepresentation,0);
    close(dir);
    if (!okay) return UFail(error,23,@"Cannot commit the private recovery record.");
    self.journal=journal.copy; return YES;
}
- (NSDictionary *)capture:(NSArray *)profiles error:(NSError **)error {
    NSDictionary *raw=[self.backend captureWithProfiles:profiles error:error]; if (!raw) return nil;
    NSDictionary *state=UState(raw);
    if (!state) UFail(error,24,@"The workspace inventory is incomplete or inconsistent.");
    return state;
}
- (BOOL)fresh:(NSDictionary *)journal target:(BOOL)target error:(NSError **)error {
    NSTimeInterval age=[self.backend now]-[journal[@"createdAt"] doubleValue];
    if (age<0 || age>300 || ![journal[@"bootSession"] isEqual:[self.backend bootSessionIdentifier]])
        return UFail(error,25,@"The update checkpoint expired or belongs to another login boot; it will not be replayed.");
    NSString *version=journal[target ? @"targetVersion" : @"sourceVersion"], *build=journal[target ? @"targetBuild" : @"sourceBuild"];
    if (![version isEqual:[self.backend runningVersion]] || ![build isEqual:[self.backend runningBuild]])
        return UFail(error,26,@"The recovery checkpoint does not belong to this application version.");
    return YES;
}
- (BOOL)prepareRestartWithProfiles:(NSArray<NSDictionary *> *)profiles targetVersion:(NSString *)version targetBuild:(NSString *)build originCheckpoints:(NSArray<NSDictionary *> *)origins error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Update recovery is main-thread only.");
    NSError *readError=nil; NSDictionary *existing=[self readJournal:&readError];
    if (readError) { if (error) *error=readError; return NO; }
    if (existing) return UFail(error,27,@"An earlier recovery record needs attention before another update.");
    NSDictionary *state=[self capture:profiles error:error]; if (!state) return NO;
    NSArray *saved=UProfiles(profiles,state), *savedOrigins=UOrigins(origins,state);
    if (!saved || !savedOrigins || !UString(version,64) || !UString(build,64) ||
        !UString([self.backend bootSessionIdentifier],128) || !UString([self.backend runningVersion],64) ||
        !UString([self.backend runningBuild],64) || [build isEqual:[self.backend runningBuild]])
        return UFail(error,28,@"The update cannot preserve the current display configuration or target identity.");
    NSDictionary *again=[self capture:profiles error:error];
    if (!again || ![again isEqual:state]) return UFail(error,29,@"The workspace changed during update preparation. Retry when it is stable.");
    NSString *transaction=NSUUID.UUID.UUIDString;
    NSDictionary *j=@{@"schema":@1,@"intent":@"sparkle-install",@"transaction":transaction,@"phase":@"prepared",
        @"createdAt":@([self.backend now]),@"bootSession":[self.backend bootSessionIdentifier],
        @"sourceVersion":[self.backend runningVersion],@"sourceBuild":[self.backend runningBuild],
        @"targetVersion":version,@"targetBuild":build,@"profiles":saved,@"state":state,@"origins":savedOrigins};
    if (![self writeJournal:j error:error]) return NO;
    self.transaction=transaction; self.preparedByThisInstance=YES; self.claimed=NO; self.restored=NO; return YES;
}
- (BOOL)ownJournal:(NSError **)error {
    NSDictionary *live=[self readJournal:error];
    if (!live || !self.transaction || ![live[@"transaction"] isEqual:self.transaction] || ![live isEqual:self.journal])
        return UFail(error,30,@"The recovery transaction changed; no other record will be overwritten.");
    return YES;
}
- (BOOL)commitPreparedRestart:(NSError **)error {
    if (![self ownJournal:error]) return NO;
    if (![self.journal[@"phase"] isEqual:@"prepared"]) return UFail(error,30,@"The update checkpoint is not prepared for restart.");
    if (![self fresh:self.journal target:NO error:error]) return NO;
    NSDictionary *state=[self capture:self.journal[@"profiles"] error:error];
    if (!state || ![state isEqual:self.journal[@"state"]]) return UFail(error,29,@"Windows or displays changed before restart; the update was postponed.");
    NSMutableDictionary *armed=self.journal.mutableCopy; armed[@"phase"]=@"armed";
    return [self writeJournal:armed error:error];
}
- (BOOL)environment:(NSArray *)profiles requireBounds:(BOOL)requireBounds error:(NSError **)error {
    NSDictionary *current=[self capture:@[] error:error]; if (!current) return NO;
    NSArray *actual=UProfiles(profiles,current); if (!actual) return UFail(error,31,@"A recreated workspace does not have a verified extended display.");
    NSMutableArray *expectedUnowned=[self.journal[@"state"][@"displays"] mutableCopy], *actualUnowned=[current[@"displays"] mutableCopy];
    NSArray *saved=self.journal[@"profiles"];
    for (NSDictionary *p in saved) [expectedUnowned removeObject:UFindDisplay(expectedUnowned,p[@"displayID"])];
    NSMutableSet *ordinals=[NSMutableSet set];
    for (NSDictionary *p in actual) {
        NSDictionary *match=nil;
        for (NSDictionary *old in saved) if ([old[@"ordinal"] isEqual:p[@"ordinal"]]) match=old;
        if (!match) return UFail(error,31,@"An unrelated owned display appeared during recovery.");
        NSDictionary *oldDisplay=UFindDisplay(self.journal[@"state"][@"displays"],match[@"displayID"]);
        NSDictionary *newDisplay=UFindDisplay(current[@"displays"],p[@"displayID"]);
        if (![oldDisplay[@"mode"] isEqual:newDisplay[@"mode"]]) return UFail(error,31,@"A recreated display has different checked mode properties.");
        NSDictionary *identity=@{@"displayID":p[@"displayID"],@"identity":newDisplay[@"identity"]};
        NSDictionary *seen=self.observedOwnedIdentities[p[@"ordinal"]];
        if (seen && ![seen isEqual:identity]) return UFail(error,31,@"A recreated display identity changed during recovery.");
        for (NSString *key in @[@"width",@"height",@"hiDPI"]) if (![match[key] isEqual:p[key]])
            return UFail(error,31,@"A saved display mode changed during recovery.");
        if (requireBounds && ![p[@"bounds"] isEqual:match[@"bounds"]]) return UFail(error,31,@"A saved workspace has not returned to its original position.");
        [actualUnowned removeObject:UFindDisplay(actualUnowned,p[@"displayID"])]; [ordinals addObject:p[@"ordinal"]];
    }
    if (requireBounds && ordinals.count!=saved.count) return UFail(error,31,@"Not all saved workspaces have been recreated.");
    if (![actualUnowned isEqual:expectedUnowned]) return UFail(error,32,@"A physical or unrelated display changed; recovery will not alter it.");
    for (NSDictionary *p in actual) {
        NSDictionary *d=UFindDisplay(current[@"displays"],p[@"displayID"]);
        self.observedOwnedIdentities[p[@"ordinal"]]=@{@"displayID":p[@"displayID"],@"identity":d[@"identity"]};
    }
    return YES;
}
- (NSArray *)claim:(BOOL)retry error:(NSError **)error {
    NSDictionary *j=[self readJournal:error]; if (!j) return nil;
    if (![self fresh:j target:YES error:error]) return nil;
    if (![j[@"phase"] isEqual:@"armed"] && !(retry && [j[@"phase"] isEqual:@"claimed"])) {
        UFail(error,33,@"This checkpoint is not eligible for automatic replay. An interrupted recovery requires an explicit retry."); return nil;
    }
    self.journal=j; self.transaction=j[@"transaction"];
    if (![self environment:@[] requireBounds:NO error:error]) return nil;
    NSMutableDictionary *claimed=j.mutableCopy; claimed[@"phase"]=@"claimed";
    if (![self writeJournal:claimed error:error]) return nil;
    self.claimed=YES; self.restored=NO; return self.journal[@"profiles"];
}
- (NSArray *)pendingProfilesWithError:(NSError **)error { return [self claim:NO error:error]; }
- (NSArray *)retryPendingProfilesWithError:(NSError **)error { return [self claim:YES error:error]; }
- (BOOL)verifyRestorationEnvironmentWithProfiles:(NSArray<NSDictionary *> *)profiles error:(NSError **)error {
    if (!self.claimed) return UFail(error,33,@"No update recovery has been claimed by this instance.");
    return [self ownJournal:error] && [self fresh:self.journal target:YES error:error] && [self environment:profiles requireBounds:NO error:error];
}
- (BOOL)restoreWithProfiles:(NSArray<NSDictionary *> *)profiles error:(NSError **)error {
    if (!self.claimed) return UFail(error,33,@"No update recovery has been claimed by this instance.");
    if (![self ownJournal:error] || ![self fresh:self.journal target:YES error:error] ||
        ![self environment:profiles requireBounds:YES error:error]) return NO;
    NSMutableArray *moves=[NSMutableArray array];
    for (NSDictionary *saved in self.journal[@"state"][@"windows"]) {
        NSDictionary *oldProfile=nil, *newProfile=nil;
        for (NSDictionary *p in self.journal[@"profiles"]) if ([p[@"displayID"] isEqual:saved[@"displayID"]]) oldProfile=p;
        for (NSDictionary *p in profiles) if ([p[@"ordinal"] isEqual:oldProfile[@"ordinal"]]) newProfile=p;
        if (!oldProfile || !newProfile) return UFail(error,31,@"A saved window has no verified workspace.");
        NSError *readError=nil;
        NSDictionary *current=[self.backend readWindow:saved[@"identity"] error:&readError];
        if (!current && readError) { if (error) *error=readError; return NO; }
        if (!current || ![current[@"identity"] isEqual:saved[@"identity"]] || !YMWorkspaceGeometry(current[@"frame"])) return UFail(error,34,@"A saved window is unavailable or changed; no substitute will be moved.");
        // The saved and recreated bounds must agree, so the original absolute
        // frame is also exactly the original virtual-relative placement.
        [moves addObject:@{@"identity":saved[@"identity"],@"before":current[@"frame"],@"after":saved[@"frame"]}];
    }
    for (NSDictionary *move in moves) {
        if (![self environment:profiles requireBounds:YES error:error]) return NO;
        if (!USameFrame(move[@"before"],move[@"after"]) && ![self.backend moveWindow:move[@"identity"]
            fromFrame:move[@"before"] toFrame:move[@"after"] error:error]) return NO;
    }
    for (NSDictionary *move in moves) {
        NSError *readError=nil;
        NSDictionary *current=[self.backend readWindow:move[@"identity"] error:&readError];
        if (!current && readError) { if (error) *error=readError; return NO; }
        if (!current || ![current[@"identity"] isEqual:move[@"identity"]] || !USameFrame(current[@"frame"],move[@"after"]))
            return UFail(error,34,@"A restored window changed before verification; recovery remains pending.");
    }
    if (![self environment:profiles requireBounds:YES error:error]) return NO;
    self.restoredOriginCheckpoints=self.journal[@"origins"]; self.restoredProfiles=profiles.copy; self.restored=YES; return YES;
}
- (BOOL)removeOwnJournal:(NSError **)error {
    if (![self ownJournal:error]) return NO;
    int dir=[self openDirectory:error]; if (dir<0) return NO;
    BOOL okay=unlinkat(dir,"restart.json",0)==0;
    if (okay) okay=fsync(dir)==0; close(dir);
    if (!okay) return UFail(error,35,@"The recovery record could not be removed safely.");
    self.journal=nil; self.transaction=nil; self.preparedByThisInstance=NO; self.claimed=NO; return YES;
}
- (BOOL)completeRestoration:(NSError **)error {
    if (!self.claimed || !self.restored) return UFail(error,36,@"Restoration has not been verified yet.");
    if (![self environment:self.restoredProfiles requireBounds:YES error:error]) return NO;
    for (NSDictionary *saved in self.journal[@"state"][@"windows"]) {
        NSError *readError=nil;
        NSDictionary *current=[self.backend readWindow:saved[@"identity"] error:&readError];
        if (!current && readError) { if (error) *error=readError; return NO; }
        if (!current || ![current[@"identity"] isEqual:saved[@"identity"]] || !USameFrame(current[@"frame"],saved[@"frame"]))
            return UFail(error,34,@"A window changed during origin handoff; recovery remains pending.");
    }
    return [self removeOwnJournal:error];
}
- (BOOL)cancelPreparedRestart:(NSError **)error {
    if (!self.transaction) return YES;
    // Reading a startup journal does not confer cancellation ownership. A
    // failed claim must remain available for explicit retry or discard.
    if (!self.preparedByThisInstance) return UFail(error,36,@"A recovery record from another instance must be retained for retry.");
    if (self.claimed || [self.journal[@"phase"] isEqual:@"claimed"]) return UFail(error,36,@"A pending recovery must be retained for retry.");
    return [self removeOwnJournal:error];
}
- (BOOL)discardRecoveryAfterUserRequest:(NSError **)error {
    NSDictionary *record=[self readJournal:error];
    if (!record) return error == NULL || *error == nil;
    self.journal=record; self.transaction=record[@"transaction"];
    return [self removeOwnJournal:error];
}

@end
