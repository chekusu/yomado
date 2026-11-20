#import "UpdateRuntimeWorkspace.h"
#import "VDVirtualDisplay.h"
#import "YMDisplayTopology.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <libproc.h>

static BOOL FFail(NSError **error, NSInteger code, NSString *description) {
    if (error) *error=[NSError errorWithDomain:@"fixture.occupied-workspace" code:code
        userInfo:@{NSLocalizedDescriptionKey:description}];
    return NO;
}
static BOOL FFrameEqual(NSDictionary *a, NSDictionary *b) {
    if (!a || !b) return NO;
    for (NSString *key in @[@"x",@"y",@"width",@"height"])
        if (!a[key] || !b[key] || fabs([a[key] doubleValue]-[b[key] doubleValue])>1) return NO;
    return YES;
}
static NSDictionary *FIdentity(pid_t pid, NSError **error) {
    AXUIElementRef app=AXUIElementCreateApplication(pid); CFTypeRef raw=NULL;
    AXError status=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&raw); CFRelease(app);
    id windows=CFBridgingRelease(raw);
    if (status!=kAXErrorSuccess || ![windows isKindOfClass:NSArray.class] || [windows count]!=1) {
        FFail(error,1,@"Expected exactly one ordinary fixture window."); return nil;
    }
    NSDictionary *identity=YMUpdateIdentityForWindowElement([windows firstObject]);
    if (!identity) FFail(error,2,@"Could not resolve the exact fixture process and window.");
    return identity;
}
// The window apps are started by the script, not by this process: their NSRunningApplication entry (and so their
// bundle identity) can reach this process a moment after their window exists (seen in a fresh Hayabuild VM). Give the
// run loop up to 3 s to deliver it before failing.
static NSDictionary *FIdentityWaiting(pid_t pid, NSError **error) {
    for (NSUInteger attempt=0;;attempt++) {
        NSError *failure=nil; NSDictionary *identity=FIdentity(pid,&failure);
        if (identity || attempt>=30) { if (!identity && error) *error=failure; return identity; }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}
static NSDictionary *FWindowDiagnostic(NSDictionary *window) {
    if (!window) return @{};
    NSDictionary *identity=window[@"identity"] ?: @{};
    return @{@"pid":identity[@"pid"] ?: @0,@"windowID":identity[@"windowID"] ?: @0,
        @"frame":window[@"frame"] ?: @{},@"displayID":window[@"displayID"] ?: @0};
}
static NSDictionary *FErrorDiagnostic(NSError *error) {
    return error ? @{@"domain":error.domain,@"code":@(error.code),
        @"description":error.localizedDescription} : @{};
}
static id FAXRead(AXUIElementRef element,CFStringRef attribute,AXError *status) {
    CFTypeRef value=NULL; *status=AXUIElementCopyAttributeValue(element,attribute,&value);
    return CFBridgingRelease(value);
}
static NSDictionary *FAXElementDiagnostic(id element) {
    if (!element || CFGetTypeID((__bridge CFTypeRef)element)!=AXUIElementGetTypeID()) return @{};
    AXUIElementRef ref=(__bridge AXUIElementRef)element;
    typedef AXError (*WindowIDFunction)(AXUIElementRef,CGWindowID *);
    WindowIDFunction function=(WindowIDFunction)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    CGWindowID ID=0; AXError idStatus=function ? function(ref,&ID) : kAXErrorNotImplemented;
    AXError roleStatus,subroleStatus,positionStatus,sizeStatus;
    id role=FAXRead(ref,kAXRoleAttribute,&roleStatus),subrole=FAXRead(ref,kAXSubroleAttribute,&subroleStatus);
    id position=FAXRead(ref,kAXPositionAttribute,&positionStatus),size=FAXRead(ref,kAXSizeAttribute,&sizeStatus);
    CGPoint point=CGPointZero; CGSize dimensions=CGSizeZero; NSDictionary *frame=@{};
    if (position && size && CFGetTypeID((__bridge CFTypeRef)position)==AXValueGetTypeID() &&
        CFGetTypeID((__bridge CFTypeRef)size)==AXValueGetTypeID() &&
        AXValueGetValue((__bridge AXValueRef)position,kAXValueCGPointType,&point) &&
        AXValueGetValue((__bridge AXValueRef)size,kAXValueCGSizeType,&dimensions) &&
        isfinite(point.x) && isfinite(point.y) && isfinite(dimensions.width) && isfinite(dimensions.height))
        frame=@{@"x":@(point.x),@"y":@(point.y),@"width":@(dimensions.width),@"height":@(dimensions.height)};
    return @{@"windowID":@(ID),@"windowIDStatus":@(idStatus),@"role":role ?: @"",@"roleStatus":@(roleStatus),
        @"subrole":subrole ?: @"",@"subroleStatus":@(subroleStatus),
        @"frame":frame,@"positionStatus":@(positionStatus),@"sizeStatus":@(sizeStatus)};
}
static NSDictionary *FAXApplicationDiagnostic(pid_t pid) {
    AXUIElementRef application=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(application,.2);
    AXError windowsStatus,menuStatus,extrasStatus;
    id windows=FAXRead(application,kAXWindowsAttribute,&windowsStatus);
    id menu=FAXRead(application,kAXMenuBarAttribute,&menuStatus);
    id extras=FAXRead(application,CFSTR("AXExtrasMenuBar"),&extrasStatus);
    NSMutableArray *items=[NSMutableArray array];
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) [items addObject:FAXElementDiagnostic(window)];
    CFRelease(application);
    char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
    int pathLength=proc_pidpath(pid,executable,sizeof(executable));
    NSString *path=pathLength>0 ? [NSString stringWithUTF8String:executable] : nil;
    BOOL systemExecutable=[path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/libexec/"];
    return @{@"pid":@(pid),@"windowsStatus":@(windowsStatus),@"windows":items,
        @"menuBarStatus":@(menuStatus),@"menuBar":FAXElementDiagnostic(menu),
        @"extrasMenuBarStatus":@(extrasStatus),@"extrasMenuBar":FAXElementDiagnostic(extras),
        @"processPathAvailable":@(pathLength>0),@"isSystemExecutable":@(systemExecutable),
        @"systemExecutablePath":systemExecutable ? path : @""};
}
@interface YMUpdateRuntimeWorkspace ()
@property(nonatomic, copy) NSString *directory;
@property(nonatomic) pid_t workPID;
@property(nonatomic) pid_t probePID;
@property(nonatomic, strong) id<YMUpdateWorkspaceRecoveryBackend> backend;
@property(nonatomic, copy) void (^record)(NSString *, NSDictionary *);
@property(nonatomic, strong) VDVirtualDisplay *display;
@property(nonatomic, strong) YMDisplayTopology *topology;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSDictionary *baseline;
@property(nonatomic) BOOL loggedSurfaceInventory;
@end
@implementation YMUpdateRuntimeWorkspace
- (instancetype)initWithDirectory:(NSString *)directory workPID:(pid_t)workPID probePID:(pid_t)probePID
    backend:(id<YMUpdateWorkspaceRecoveryBackend>)backend record:(void (^)(NSString *, NSDictionary *))record {
    self=[super init]; if (self) {
        _directory=directory; _workPID=workPID; _probePID=probePID; _backend=backend; _record=[record copy];
        _topology=[YMDisplayTopology new]; _queue=dispatch_queue_create("fixture.occupied-topology",DISPATCH_QUEUE_SERIAL);
        _display=[[VDVirtualDisplay alloc] initWithSerialNumber:829401];
    } return self;
}
- (NSArray<NSDictionary *> *)profiles {
    if (!self.display.isCreated) return @[];
    return @[@{@"ordinal":@1,@"displayID":@(self.display.displayID),@"width":@1280,@"height":@800,@"hiDPI":@NO}];
}
- (BOOL)captureNamed:(NSString *)name error:(NSError **)error {
    CGDirectDisplayID displays[64]; uint32_t count=0; NSUInteger index=NSNotFound;
    if (CGGetActiveDisplayList(64,displays,&count)!=kCGErrorSuccess || count>=64)
        return FFail(error,8,@"Cannot identify the fixture screen for pixel evidence.");
    for (uint32_t i=0;i<count;i++) if (displays[i]==self.display.displayID) index=i+1;
    if (index==NSNotFound) return FFail(error,8,@"The fixture screen disappeared before capture.");
    NSTask *capture=[NSTask new]; capture.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    capture.arguments=@[@"-x",@"-D",[@(index) stringValue],[self.directory stringByAppendingPathComponent:name]];
    if (![capture launchAndReturnError:error]) return NO;
    [capture waitUntilExit];
    self.record(@"occupied-pixel-capture",@{@"name":name,@"status":@(capture.terminationStatus),@"displayID":@(self.display.displayID),@"displayIndex":@(index)});
    return capture.terminationStatus==0 || FFail(error,8,@"The real virtual-screen screenshot was not captured.");
}
- (NSString *)baselinePath { return [self.directory stringByAppendingPathComponent:@"workspace-baseline.json"]; }
- (void)createWithSavedBounds:(NSDictionary *)savedBounds completion:(void (^)(BOOL,NSError *))completion {
    // Production requires AppKit to keep processing display notifications while
    // its bounded CoreGraphics transactions execute on a serial worker queue.
    dispatch_async(self.queue, ^{
        NSError *error=nil;
        YMDisplayTopologySnapshot *before=[self.topology captureSnapshotWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *creationError=error;
            if (!before || ![self.display createWithWidth:1280 height:800 hiDPI:NO name:@"Update acceptance workspace" error:&creationError]) {
                completion(NO,creationError); return;
            }
            CGDirectDisplayID ID=self.display.displayID;
            dispatch_async(self.queue, ^{
                NSError *configureError=nil;
                BOOL ready=[self.topology configureAndVerifyNewDisplay:ID width:1280 height:800 hiDPI:NO baseline:before error:&configureError];
                if (ready && savedBounds) {
                    YMDisplayTopologySnapshot *layout=[self.topology captureSnapshotWithError:&configureError];
                    ready=layout && [self.topology positionOwnedDisplays:@{@(ID):savedBounds} baseline:layout error:&configureError];
                }
                dispatch_async(dispatch_get_main_queue(), ^{ completion(ready,configureError); });
            });
        });
    });
}
- (void)recordSurfaceInventoryDiagnostic {
    CGRect owned=CGDisplayBounds(self.display.displayID);
    NSMutableArray *candidates=[NSMutableArray array];
    NSMutableSet<NSNumber *> *owners=[NSMutableSet set];
    NSArray *raw=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,0));
    for (NSDictionary *entry in raw) {
        CGRect frame;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds],&frame) ||
            CGRectIsEmpty(CGRectIntersection(frame,owned))) continue;
        NSNumber *pid=entry[(__bridge NSString *)kCGWindowOwnerPID] ?: @0;
        [owners addObject:pid];
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
        [candidates addObject:@{@"pid":pid,@"windowID":entry[(__bridge NSString *)kCGWindowNumber] ?: @0,
            @"bundleID":app.bundleIdentifier ?: @"",@"ownerName":entry[(__bridge NSString *)kCGWindowOwnerName] ?: @"",
            @"layer":entry[(__bridge NSString *)kCGWindowLayer] ?: @0,
            @"onScreen":entry[(__bridge NSString *)kCGWindowIsOnscreen] ?: @NO,
            @"alpha":entry[(__bridge NSString *)kCGWindowAlpha] ?: @0,
            @"frame":@{@"x":@(frame.origin.x),@"y":@(frame.origin.y),@"width":@(frame.size.width),@"height":@(frame.size.height)}}];
    }
    // Disposable guest diagnostics only. Do not read window titles or
    // alter the production inventory classifier to admit these entries.
    NSMutableArray *AXOwners=[NSMutableArray array];
    for (NSNumber *pid in [owners.allObjects sortedArrayUsingSelector:@selector(compare:)])
        [AXOwners addObject:FAXApplicationDiagnostic(pid.intValue)];
    NSMutableArray *screenFrames=[NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *ID=screen.deviceDescription[@"NSScreenNumber"];
        if (![ID isEqual:@(self.display.displayID)]) continue;
        NSRect frame=screen.frame,visible=screen.visibleFrame;
        [screenFrames addObject:@{@"displayID":ID,@"cocoaFrame":@{@"x":@(frame.origin.x),@"y":@(frame.origin.y),
            @"width":@(frame.size.width),@"height":@(frame.size.height)},
            @"cocoaVisibleFrame":@{@"x":@(visible.origin.x),@"y":@(visible.origin.y),
            @"width":@(visible.size.width),@"height":@(visible.size.height)},
            @"topInset":@(NSMaxY(frame)-NSMaxY(visible))}];
    }
    self.record(@"occupied-cg-inventory",@{@"displayID":@(self.display.displayID),
        @"bounds":@{@"x":@(owned.origin.x),@"y":@(owned.origin.y),@"width":@(owned.size.width),@"height":@(owned.size.height)},
        @"candidates":candidates,@"AXOwners":AXOwners,@"screenFrames":screenFrames});
}
- (void)observeInitialMove:(NSDictionary *)workIdentity destination:(NSDictionary *)destination
    probe:(NSDictionary *)probe deadline:(NSTimeInterval)deadline stableSamples:(NSUInteger)stableSamples
    completion:(void (^)(NSDictionary *,NSError *))completion {
    NSError *captureError=nil,*workError=nil,*probeError=nil;
    NSDictionary *after=[self.backend captureWithProfiles:self.profiles error:&captureError];
    NSDictionary *workAfter=[self.backend readWindow:workIdentity error:&workError];
    NSDictionary *probeAfter=[self.backend readWindow:probe[@"identity"] error:&probeError];
    if (!self.loggedSurfaceInventory || (captureError.code==13 &&
        [captureError.domain isEqual:@"dev.chekusu.yomado.update-workspace"] && NSProcessInfo.processInfo.systemUptime>=deadline)) {
        self.loggedSurfaceInventory=YES;
        [self recordSurfaceInventoryDiagnostic];
    }
    NSArray *windows=after[@"windows"] ?: @[];
    BOOL inventoryMatches=windows.count==1 && [windows[0][@"identity"] isEqual:workIdentity] &&
        FFrameEqual(windows[0][@"frame"],destination);
    BOOL workMatches=[workAfter[@"identity"] isEqual:workIdentity] && FFrameEqual(workAfter[@"frame"],destination);
    BOOL probeMatches=[probeAfter[@"identity"] isEqual:probe[@"identity"]] && FFrameEqual(probeAfter[@"frame"],probe[@"frame"]);
    BOOL matches=after && inventoryMatches && workMatches && probeMatches;
    NSUInteger consecutive=matches ? stableSamples+1 : 0;
    NSMutableArray *inventory=[NSMutableArray array];
    for (NSDictionary *window in windows) [inventory addObject:FWindowDiagnostic(window)];
    self.record(@"occupied-settle-sample",@{@"captureAvailable":@(after!=nil),@"inventory":inventory,
        @"displays":after[@"displays"] ?: @[],@"expectedWork":FWindowDiagnostic(@{@"identity":workIdentity,@"frame":destination}),
        @"currentWork":FWindowDiagnostic(workAfter),@"expectedProbe":FWindowDiagnostic(probe),
        @"currentProbe":FWindowDiagnostic(probeAfter),@"captureError":FErrorDiagnostic(captureError),
        @"workError":FErrorDiagnostic(workError),@"probeError":FErrorDiagnostic(probeError),
        @"inventoryMatches":@(inventoryMatches),@"workMatches":@(workMatches),@"probeMatches":@(probeMatches),
        @"stableSamples":@(consecutive)});
    if (consecutive>=3) { completion(after,nil); return; }
    if (NSProcessInfo.processInfo.systemUptime>=deadline) {
        NSError *failure=captureError ?: workError ?: probeError;
        if (!failure) FFail(&failure,4,@"The exact initial workspace inventory and probe did not settle within three seconds.");
        completion(nil,failure); return;
    }
    // AX writes can reach CoreGraphics after the write returns. Wait only while
    // constructing this fixture; production checkpoint admission stays unchanged.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self observeInitialMove:workIdentity destination:destination probe:probe deadline:deadline
            stableSamples:consecutive completion:completion];
    });
}
- (void)prepareOccupiedWorkspace:(void (^)(BOOL,NSError *))completion {
    NSError *error=nil;
    self.record(@"occupied-preflight",@{@"accessibilityTrusted":@((BOOL)AXIsProcessTrusted()),@"virtualAPIAvailable":@(VDVirtualDisplay.isAPIAvailable)});
    if (!AXIsProcessTrusted() || !VDVirtualDisplay.isAPIAvailable) {
        FFail(&error,3,@"Guest Accessibility or virtual-display support is unavailable."); completion(NO,error); return;
    }
    NSDictionary *workIdentity=FIdentityWaiting(self.workPID,&error), *probeIdentity=FIdentityWaiting(self.probePID,&error);
    NSDictionary *work=workIdentity ? [self.backend readWindow:workIdentity error:&error] : nil;
    NSDictionary *probe=probeIdentity ? [self.backend readWindow:probeIdentity error:&error] : nil;
    NSDictionary *state=[self.backend captureWithProfiles:@[] error:&error];
    if (!work || !probe || !state) { completion(NO,error); return; }
    [self createWithSavedBounds:nil completion:^(BOOL ready,NSError *creationError) {
        NSError *failure=creationError;
        if (!ready) { completion(NO,failure); return; }
        CGRect bounds=CGDisplayBounds(self.display.displayID);
        NSMutableDictionary *destination=[work[@"frame"] mutableCopy];
        destination[@"x"]=@(bounds.origin.x+100); destination[@"y"]=@(bounds.origin.y+120);
        if (![self.backend moveWindow:workIdentity fromFrame:work[@"frame"] toFrame:destination error:&failure]) {
            completion(NO,failure); return;
        }
        [self observeInitialMove:workIdentity destination:destination probe:probe
            deadline:NSProcessInfo.processInfo.systemUptime+3 stableSamples:0
            completion:^(NSDictionary *after,NSError *settleError) {
        NSError *failure=settleError;
        if (!after) { completion(NO,failure); return; }
        NSMutableArray *unowned=[after[@"displays"] mutableCopy];
        [unowned filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings) {
            (void)bindings; return ![item[@"displayID"] isEqual:@(self.display.displayID)];
        }]];
        if (![unowned isEqual:state[@"displays"]]) {
            FFail(&failure,5,@"Creating the workspace changed an unowned display."); completion(NO,failure); return;
        }
        self.baseline=@{@"work":after[@"windows"][0],@"probe":probe,@"unownedDisplays":state[@"displays"],@"profiles":self.profiles};
        NSData *data=[NSJSONSerialization dataWithJSONObject:self.baseline options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&failure];
        if (!data || ![data writeToFile:self.baselinePath options:NSDataWritingAtomic error:&failure]) { completion(NO,failure); return; }
        self.record(@"occupied-ready",self.baseline);
        BOOL captured=[self captureNamed:@"occupied-before.png" error:&failure]; completion(captured,failure);
        }];
    }];
}
- (void)recreateProfiles:(NSArray<NSDictionary *> *)profiles completion:(void (^)(BOOL,NSError *))completion {
    NSError *error=nil; NSData *data=[NSData dataWithContentsOfFile:self.baselinePath options:0 error:&error];
    self.baseline=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    NSDictionary *saved=profiles.count==1 ? profiles.firstObject : nil;
    if (!self.baseline || ![saved[@"ordinal"] isEqual:@1] || ![saved[@"width"] isEqual:@1280] ||
        ![saved[@"height"] isEqual:@800] || [saved[@"hiDPI"] boolValue] || !saved[@"bounds"]) {
        FFail(&error,6,@"The occupied restart fixture did not receive its exact saved profile."); completion(NO,error); return;
    }
    self.record(@"occupied-recreate",@{@"savedProfiles":profiles,@"accessibilityTrusted":@((BOOL)AXIsProcessTrusted())});
    [self createWithSavedBounds:saved[@"bounds"] completion:completion];
}
- (BOOL)verifyRestoredWorkspace:(NSError **)error {
    NSDictionary *state=[self.backend captureWithProfiles:self.profiles error:error];
    NSDictionary *probe=[self.backend readWindow:self.baseline[@"probe"][@"identity"] error:error];
    NSDictionary *work=[self.backend readWindow:self.baseline[@"work"][@"identity"] error:error];
    if (!state || !probe || !work) return NO;
    NSMutableArray *unowned=[state[@"displays"] mutableCopy];
    [unowned filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings) {
        (void)bindings; return ![item[@"displayID"] isEqual:@(self.display.displayID)];
    }]];
    BOOL matches=[state[@"windows"] count]==1 &&
        [state[@"windows"][0][@"identity"] isEqual:self.baseline[@"work"][@"identity"]] &&
        [probe[@"identity"] isEqual:self.baseline[@"probe"][@"identity"]] &&
        FFrameEqual(work[@"frame"],self.baseline[@"work"][@"frame"]) &&
        FFrameEqual(probe[@"frame"],self.baseline[@"probe"][@"frame"]) &&
        [unowned isEqual:self.baseline[@"unownedDisplays"]];
    self.record(@"occupied-verified",@{@"matches":@(matches),@"currentWork":work,@"currentProbe":probe,
        @"currentState":state,@"currentProfiles":self.profiles});
    if (!matches) return FFail(error,7,@"Exact surviving window identity, geometry or physical probe changed.");
    return [self captureNamed:@"occupied-after.png" error:error];
}
- (void)recordRecoveryFailureDiagnostic {
    // Observe the exact surviving fixture identities after the failed production
    // call. This does not retry restoration, move windows, or grant permission.
    BOOL trusted=AXIsProcessTrusted();
    NSMutableDictionary *observations=[NSMutableDictionary dictionary];
    for (NSString *role in @[@"work",@"probe"]) {
        NSDictionary *identity=self.baseline[role][@"identity"];
        NSError *error=nil;
        NSDictionary *window=identity ? [self.backend readWindow:identity error:&error] : nil;
        NSMutableArray *cg=[NSMutableArray array];
        NSArray *raw=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
            [identity[@"windowID"] unsignedIntValue]));
        for (NSDictionary *entry in raw) {
            CGRect frame;
            if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds],&frame)) continue;
            [cg addObject:@{@"pid":entry[(__bridge NSString *)kCGWindowOwnerPID] ?: @0,
                @"windowID":entry[(__bridge NSString *)kCGWindowNumber] ?: @0,
                @"layer":entry[(__bridge NSString *)kCGWindowLayer] ?: @0,
                @"onScreen":entry[(__bridge NSString *)kCGWindowIsOnscreen] ?: @NO,
                @"frame":@{@"x":@(frame.origin.x),@"y":@(frame.origin.y),
                    @"width":@(frame.size.width),@"height":@(frame.size.height)}}];
        }
        observations[role]=@{@"expectedIdentity":identity ?: @{},@"nativeWindow":FWindowDiagnostic(window),
            @"nativeError":FErrorDiagnostic(error),@"CGWindows":cg,
            @"AXApplication":identity ? FAXApplicationDiagnostic([identity[@"pid"] intValue]) : @{}};
    }
    self.record(@"occupied-recovery-failure-diagnostic",@{@"accessibilityTrusted":@(trusted),
        @"observations":observations});
}
@end
