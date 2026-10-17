#import "AppWorkspace.h"
#import "AppWorkspaceAccess.h"
#import "AppWorkspacePolicy.h"
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

NSString * const YMAppWorkspaceErrorDomain = @"dev.chekusu.yomado.app-workspace";

static const NSTimeInterval kYMInventoryBudget = 1.0;
static const NSTimeInterval kYMInventoryPIDBudget = 0.2;
static const NSTimeInterval kYMInventoryCacheTTL = 1.0;
static const NSUInteger kYMInventoryMaxPIDs = 64;
static const NSUInteger kYMInventoryMaxCGCandidates = 512;

@interface YMWPlacement : NSObject
@property(nonatomic, strong) id element;
@property(nonatomic, strong) NSRunningApplication *application;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSDictionary *origin;
@property(nonatomic, copy) NSDictionary *identity;
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
@property(nonatomic, readwrite) BOOL inventoryReady;
@property(nonatomic) BOOL inventoryReadyPublished;
@property(nonatomic) BOOL operationInProgress;
@property(nonatomic, strong) id<YMWorkspaceWindowAccess> windowAccess;
@property(nonatomic, strong) dispatch_queue_t inventoryQueue;
@property(nonatomic) NSUInteger inventoryGeneration;
@property(nonatomic, copy) NSString *inventoryInflightKey;
@property(nonatomic) NSUInteger inventoryInflightGeneration;
@property(nonatomic, copy) NSString *inventoryLatestKey;
@property(nonatomic) NSUInteger inventoryLatestGeneration;
@property(nonatomic, copy) NSString *inventoryPublishedKey;
@property(nonatomic) NSUInteger inventoryPublishedGeneration;
@property(nonatomic) NSTimeInterval inventoryPublishedAt;
@property(nonatomic, copy) NSArray<NSDictionary *> *inventoryCachedCG;
@property(nonatomic) BOOL inventoryJobScheduled;
@property(nonatomic) BOOL inventoryHasObservedTrust;
@property(nonatomic) BOOL inventoryObservedTrusted;
@property(nonatomic) BOOL inventoryHasObservedCG;
@property(nonatomic, copy) NSString *inventoryObservedCGSignature;
@property(nonatomic, copy) NSSet<NSString *> *inventoryConfirmedExcludedKeys;
@property(nonatomic) NSUInteger inventoryPIDCursor;
@end

@implementation YMAppWorkspace
- (instancetype)init {
    return [self initWithWindowAccess:[YMSystemWorkspaceWindowAccess new]];
}
- (instancetype)initWithWindowAccess:(id<YMWorkspaceWindowAccess>)access {
    self = [super init];
    if (!self) return nil;
    _windowAccess = access;
    _rows = @[]; _ownedIDs = @[]; _displays = @[]; _windows = @[];
    _placements = [NSMutableArray array];
    _inventoryCachedCG = @[];
    _statusText = @"拖入已打开的 App，或手动把窗口拖到虚拟屏。原位置只保留到退出 yomado。";
    _inventoryQueue = dispatch_queue_create("dev.chekusu.yomado.app-workspace.inventory", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (BOOL)accessibilityTrusted { return [self.windowAccess accessibilityTrusted]; }
- (BOOL)isSystemPresentationApplication:(NSRunningApplication *)application {
    // Stage Manager's system-owned surfaces have no ordinary AX counterpart.
    // A bundle identifier alone must not let a third-party app evade close guards.
    return application && !application.terminated &&
        [application.bundleIdentifier isEqualToString:@"com.apple.WindowManager"] &&
        [[application.bundleURL URLByResolvingSymlinksInPath].path
            isEqualToString:@"/System/Library/CoreServices/WindowManager.app"];
}
- (BOOL)inventoryReady {
    return self.inventoryReadyPublished && [self inventoryCacheFresh];
}
- (void)setInventoryReady:(BOOL)inventoryReady {
    self.inventoryReadyPublished = inventoryReady;
}
- (void)scheduleInventoryRead:(dispatch_block_t)read {
    dispatch_async(self.inventoryQueue, read);
}
- (void)publishInventoryRead:(dispatch_block_t)publish {
    dispatch_async(dispatch_get_main_queue(), publish);
}
- (NSTimeInterval)inventoryTime {
    return NSProcessInfo.processInfo.systemUptime;
}
- (NSArray<NSScreen *> *)workspaceScreens {
    return NSScreen.screens;
}
- (void)invalidateInventoryForMutation {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    self.inventoryGeneration += 1;
    self.inventoryReady = NO;
    self.inventoryValid = NO;
    self.inventoryPublishedKey = nil;
    self.inventoryPublishedAt = 0;
    self.inventoryConfirmedExcludedKeys = nil;
    self.inventoryLatestKey = [self inventoryRequestKeyForCG:self.inventoryCachedCG
                                                    trusted:self.accessibilityTrusted];
    self.inventoryLatestGeneration = self.inventoryGeneration;
    // Never schedule/publish inventory that can rewrite placements while a write
    // is still settling on the run loop. The write's @finally re-invalidates.
    if (!self.operationInProgress) [self refreshInventory];
}
- (void)notifyInventoryDidChange {
    void (^callback)(void) = self.inventoryDidChange;
    if (callback) callback();
}
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
    NSArray *previousOwned = self.ownedIDs;
    BOOL previousTrusted = self.accessibilityTrusted;
    self.ownedIDs = IDs.array;
    NSMutableArray *normalized = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSScreen *> *screens = [NSMutableDictionary dictionary];
    for (NSScreen *screen in [self workspaceScreens]) {
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
    BOOL topologyChanged = ![previousOwned isEqualToArray:self.ownedIDs] ||
        ![self.displays isEqualToArray:normalized];
    self.displays = normalized;
    if (topologyChanged) self.inventoryGeneration += 1;
    (void)previousTrusted; // trust flaps are tracked irreversibly in refreshInventory
    [self refreshInventory];
}
- (NSString *)normalizedCGSignature:(NSArray<NSDictionary *> *)cgWindows {
    NSMutableArray *parts = [NSMutableArray array];
    NSMutableArray *relevant = [NSMutableArray array];
    for (NSDictionary *cg in cgWindows) {
        if (![cg isKindOfClass:NSDictionary.class]) {
            [parts addObject:@"invalidCG"];
            continue;
        }
        // Classified non-candidates cannot change the application inventory. Keep
        // malformed evidence in the key so it can never revive a ready snapshot.
        if (YMWorkspaceCGCandidateIdentity(cg) && YMWorkspaceGeometry(cg[@"frame"])) {
            if (YMWorkspaceCGCandidateClearlyInvisible(cg)) continue;
            if (YMWorkspaceCGCandidateVisible(cg)) {
                NSRunningApplication *app = [self.windowAccess applicationForPID:[cg[@"pid"] intValue]];
                if ([self isSystemPresentationApplication:app]) continue;
                if (app && !app.terminated && (!app.bundleIdentifier.length || !app.bundleURL)) continue;
            }
        }
        [relevant addObject:cg];
    }
    NSArray *sorted = [relevant sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult pid = [a[@"pid"] compare:b[@"pid"]];
        return pid != NSOrderedSame ? pid : [a[@"windowID"] compare:b[@"windowID"]];
    }];
    for (NSDictionary *cg in sorted) {
        NSDictionary *frame = YMWorkspaceGeometry(cg[@"frame"]);
        // Preserve presence/validity: missing or non-number fields must not encode
        // as legal defaults (layer=0 / onScreen=NO / alpha=0), or TTL reuse can
        // treat unclassifiable CG as a prior ready observation.
        NSString *fx = frame ? [NSString stringWithFormat:@"%@", frame[@"x"]] : @"?";
        NSString *fy = frame ? [NSString stringWithFormat:@"%@", frame[@"y"]] : @"?";
        NSString *fw = frame ? [NSString stringWithFormat:@"%@", frame[@"width"]] : @"?";
        NSString *fh = frame ? [NSString stringWithFormat:@"%@", frame[@"height"]] : @"?";
        NSString *layer = [cg[@"layer"] isKindOfClass:NSNumber.class]
            ? [NSString stringWithFormat:@"%@", cg[@"layer"]] : @"?";
        NSString *onScreen = [cg[@"onScreen"] isKindOfClass:NSNumber.class]
            ? [NSString stringWithFormat:@"%@", cg[@"onScreen"]] : @"?";
        NSString *alpha = [cg[@"alpha"] isKindOfClass:NSNumber.class] &&
            isfinite([cg[@"alpha"] doubleValue])
            ? [NSString stringWithFormat:@"%@", cg[@"alpha"]] : @"?";
        [parts addObject:[NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@:%@:%@:%@",
            cg[@"pid"] ?: @"?", cg[@"windowID"] ?: @"?",
            fx, fy, fw, fh, layer, onScreen, alpha]];
    }
    return [parts componentsJoinedByString:@"|"];
}
- (NSString *)inventoryRequestKeyForCG:(NSArray<NSDictionary *> *)cgWindows trusted:(BOOL)trusted {
    NSMutableArray *displayParts = [NSMutableArray array];
    for (NSDictionary *display in self.displays) {
        NSDictionary *bounds = display[@"bounds"];
        [displayParts addObject:[NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@:%@",
            display[@"displayID"], display[@"displayUUID"],
            bounds[@"x"], bounds[@"y"], bounds[@"width"], bounds[@"height"],
            display[@"isVirtual"]]];
    }
    NSArray *owned = [self.ownedIDs sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"cg=%@;disp=%@;owned=%@;trust=%d;gen=%lu",
        [self normalizedCGSignature:cgWindows ?: @[]],
        [displayParts componentsJoinedByString:@","],
        [owned componentsJoinedByString:@","],
        trusted ? 1 : 0,
        (unsigned long)self.inventoryGeneration];
}
- (BOOL)inventoryCacheFresh {
    return self.inventoryPublishedKey.length &&
        self.inventoryPublishedGeneration == self.inventoryGeneration &&
        ([self inventoryTime] - self.inventoryPublishedAt) <= kYMInventoryCacheTTL;
}
- (void)markInventoryNotReady:(NSString *)status {
    BOOL wasReady = self.inventoryReady;
    self.inventoryReady = NO;
    self.inventoryValid = NO;
    self.inventoryConfirmedExcludedKeys = nil;
    if (status.length) self.statusText = status;
    if (wasReady) [self notifyInventoryDidChange];
}
- (void)invalidateInventoryReuseForCGFailure {
    // CG read failure is irreversible for in-flight/published reuse: advance
    // generation and drop the published key so a later equal observation cannot
    // revive a job collected before the failure.
    self.inventoryGeneration += 1;
    self.inventoryPublishedKey = nil;
    self.inventoryPublishedAt = 0;
    self.inventoryConfirmedExcludedKeys = nil;
}
- (NSArray<NSDictionary *> *)admittedCGCandidates:(NSArray<NSDictionary *> *)cgWindows
                                       truncated:(BOOL *)truncated {
    NSMutableArray *candidates = [NSMutableArray array];
    BOOL overflow = NO;
    for (NSDictionary *cg in cgWindows) {
        if (!YMWorkspaceCGCandidateVisible(cg)) continue;
        pid_t pid = [cg[@"pid"] intValue];
        NSRunningApplication *app = [self.windowAccess applicationForPID:pid];
        if (!app || app.terminated || !app.bundleIdentifier.length || !app.bundleURL) continue;
        if ([self isSystemPresentationApplication:app]) continue;
        if (candidates.count >= kYMInventoryMaxCGCandidates) {
            overflow = YES;
            break;
        }
        [candidates addObject:cg];
    }
    if (truncated) *truncated = overflow;
    return candidates;
}
- (NSArray<NSDictionary *> *)admittedCGCandidates:(NSArray<NSDictionary *> *)cgWindows {
    return [self admittedCGCandidates:cgWindows truncated:NULL];
}
- (BOOL)cgHasUnclassifiableEvidence:(NSArray<NSDictionary *> *)cgWindows {
    for (NSDictionary *cg in cgWindows) {
        if (![cg isKindOfClass:NSDictionary.class]) return YES;
        if (!YMWorkspaceCGCandidateIdentity(cg)) return YES;
        if (!YMWorkspaceGeometry(cg[@"frame"])) return YES;
        if (YMWorkspaceCGCandidateClearlyInvisible(cg)) continue;
        if (YMWorkspaceCGCandidateVisible(cg)) {
            NSRunningApplication *app = [self.windowAccess applicationForPID:[cg[@"pid"] intValue]];
            if (!app || app.terminated) return YES;
            continue;
        }
        // Identity+frame present but visibility fields missing/invalid: both
        // Visible and ClearlyInvisible filters drop it — must not prove empty.
        return YES;
    }
    return NO;
}
- (void)scheduleInventoryIfNeeded {
    if (self.operationInProgress) return;
    if (self.inventoryJobScheduled) return;
    NSString *key = self.inventoryLatestKey;
    NSUInteger generation = self.inventoryLatestGeneration;
    if (!key.length) return;
    if (self.inventoryInflightKey.length) {
        // One in-flight + one latest slot; identical key waits for completion.
        return;
    }
    // Same-key reuse within TTL covers complete and incomplete observations.
    // Incomplete reuse never sets inventoryReady, so it cannot authorize close.
    if ([key isEqual:self.inventoryPublishedKey] && generation == self.inventoryPublishedGeneration &&
        [self inventoryCacheFresh]) {
        self.inventoryLatestKey = nil;
        return;
    }
    self.inventoryInflightKey = key;
    self.inventoryInflightGeneration = generation;
    self.inventoryLatestKey = nil;
    self.inventoryJobScheduled = YES;
    self.inventoryReady = NO;
    self.inventoryValid = NO;

    NSArray *cgSnapshot = [self.inventoryCachedCG copy] ?: @[];
    NSArray *displays = [self.displays copy] ?: @[];
    NSUInteger pidCursor = self.inventoryPIDCursor;
    BOOL trusted = self.accessibilityTrusted;
    NSUInteger jobGeneration = generation;
    NSString *jobKey = [key copy];
    __weak YMAppWorkspace *weakSelf = self;
    [self scheduleInventoryRead:^{
        YMAppWorkspace *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableArray *axRecords = [NSMutableArray array];
        NSMutableDictionary *observedApps = [NSMutableDictionary dictionary];
        NSUInteger nextPIDCursor = 0;
        BOOL complete = YES;
        NSString *reason = @"";
        NSArray *normalizeCG = cgSnapshot;
        if (trusted) {
            BOOL cgTruncated = NO;
            NSArray *candidates = [strongSelf admittedCGCandidates:cgSnapshot truncated:&cgTruncated];
            BOOL hitCGCap = cgTruncated;
            NSMutableOrderedSet *allPIDs = [NSMutableOrderedSet orderedSet];
            for (NSDictionary *cg in candidates) [allPIDs addObject:cg[@"pid"]];
            BOOL hitPIDCap = allPIDs.count > kYMInventoryMaxPIDs;
            NSArray *sortedPIDs = [allPIDs.array sortedArrayUsingSelector:@selector(compare:)];
            NSArray *observePIDs = hitPIDCap
                ? [sortedPIDs subarrayWithRange:NSMakeRange(0, kYMInventoryMaxPIDs)]
                : sortedPIDs;
            // Normalizer must share the AX admission set so non-admitted system
            // surfaces do not become unmatched; admitted unknowns still fail closed.
            normalizeCG = candidates;
            NSTimeInterval deadline = [strongSelf inventoryTime] + kYMInventoryBudget;
            for (NSUInteger index = 0; index < observePIDs.count; index++) {
                NSUInteger pidIndex = (pidCursor + index) % observePIDs.count;
                NSNumber *pidValue = observePIDs[pidIndex];
                if ([strongSelf inventoryTime] >= deadline) {
                    complete = NO; reason = @"timeout";
                    nextPIDCursor = pidIndex;
                    break;
                }
                NSRunningApplication *app = [strongSelf.windowAccess applicationForPID:pidValue.intValue];
                if (!app || app.terminated || !app.bundleIdentifier.length || !app.bundleURL) {
                    complete = NO;
                    if (!reason.length) reason = @"missingApplication";
                    continue;
                }
                // Bind the concrete process object observed for this job. Publish
                // must refuse if that process exits or a same-PID replacement appears.
                observedApps[pidValue] = app;
                NSTimeInterval pidDeadline = fmin(deadline, [strongSelf inventoryTime] + kYMInventoryPIDBudget);
                NSDictionary *observation = [strongSelf.windowAccess observeApplication:app deadline:pidDeadline];
                BOOL pidComplete = [observation[@"complete"] boolValue];
                if (!pidComplete) {
                    complete = NO;
                    if (!reason.length) reason = observation[@"reason"] ?: @"incomplete";
                }
                NSArray *windows = observation[@"windows"];
                // An incomplete PID cannot prove that its remaining AX windows
                // are unambiguous. Other fully observed apps can still update UI.
                if (pidComplete && [windows isKindOfClass:NSArray.class]) [axRecords addObjectsFromArray:windows];
            }
            if (hitCGCap) { complete = NO; if (!reason.length) reason = @"cgLimit"; }
            if (hitPIDCap) { complete = NO; if (!reason.length) reason = @"pidLimit"; }
        }
        NSDictionary *snapshot = trusted
            ? YMWorkspaceNormalizeWindowSnapshot(normalizeCG, axRecords, YES, displays)
            : nil;
        NSDictionary *observedAppsCopy = [observedApps copy];
        [strongSelf publishInventoryRead:^{
            YMAppWorkspace *publisher = weakSelf;
            if (!publisher) return;
            publisher.inventoryJobScheduled = NO;
            publisher.inventoryInflightKey = nil;
            publisher.inventoryPIDCursor = nextPIDCursor;
            [publisher finishInventoryJobKey:jobKey generation:jobGeneration
                                  cgSnapshot:cgSnapshot trusted:trusted
                                    complete:complete reason:reason
                                   snapshot:snapshot axRecords:axRecords
                               observedApps:observedAppsCopy];
        }];
    }];
}
- (NSArray<NSDictionary *> *)windowsFromNoAXCG:(NSArray<NSDictionary *> *)cgWindows {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSDictionary *cg in cgWindows) {
        if (!YMWorkspaceCGCandidateVisible(cg)) continue;
        NSDictionary *frame = YMWorkspaceGeometry(cg[@"frame"]);
        if (!YMWorkspaceVisibleOrdinaryGeometry(frame, [cg[@"layer"] integerValue],
            [cg[@"onScreen"] boolValue], [cg[@"alpha"] doubleValue])) continue;
        pid_t pid = [cg[@"pid"] intValue];
        NSRunningApplication *app = [self.windowAccess applicationForPID:pid];
        if (!app || app.terminated || !app.bundleIdentifier.length || !app.bundleURL) continue;
        if ([self isSystemPresentationApplication:app]) continue;
        NSDictionary *display = YMWorkspaceDisplayForFrame(frame, self.displays);
        if (!display) continue;
        [windows addObject:@{@"windowID": cg[@"windowID"], @"pid": @(pid),
            @"bundleIdentifier": app.bundleIdentifier,
            @"appName": app.localizedName ?: app.bundleIdentifier,
            @"appURL": app.bundleURL, @"frame": frame, @"cgFrame": frame,
            @"displayID": display[@"displayID"], @"isVirtual": display[@"isVirtual"]}];
    }
    return windows;
}
- (BOOL)observedAppsStillCurrent:(NSDictionary *)observedApps {
    if (![observedApps isKindOfClass:NSDictionary.class]) return NO;
    for (NSNumber *pidValue in observedApps) {
        NSRunningApplication *observed = observedApps[pidValue];
        if (![observed isKindOfClass:NSRunningApplication.class] &&
            ![observed respondsToSelector:@selector(isTerminated)]) return NO;
        if (observed.terminated) return NO;
        NSRunningApplication *live = [self.windowAccess applicationForPID:pidValue.intValue];
        if (!live || live.terminated) return NO;
        // Lifecycle equality, not pointer identity — equal wrappers of one process are OK.
        // Same-PID replacement must not reuse AX collected against the prior process.
        if (![live isEqual:observed]) return NO;
        if (!live.bundleIdentifier.length || !live.bundleURL) return NO;
    }
    return YES;
}
- (NSArray<NSDictionary *> *)assembledWindowsFromSnapshot:(NSDictionary *)snapshot
                                             observedApps:(NSDictionary *)observedApps {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSDictionary *entry in snapshot[@"windows"]) {
        pid_t pid = [entry[@"pid"] intValue];
        NSRunningApplication *observed = observedApps[@(pid)];
        NSRunningApplication *app = observed ?: [self.windowAccess applicationForPID:pid];
        if (!app || app.terminated || !app.bundleIdentifier.length || !app.bundleURL) continue;
        NSRunningApplication *live = [self.windowAccess applicationForPID:pid];
        if (observed && (observed.terminated || !live || live.terminated || ![live isEqual:observed]))
            continue;
        NSMutableDictionary *window = [entry mutableCopy];
        window[@"bundleIdentifier"] = app.bundleIdentifier;
        window[@"appName"] = app.localizedName ?: app.bundleIdentifier;
        window[@"appURL"] = app.bundleURL;
        [windows addObject:window];
    }
    return windows;
}
// Private confirmed-exclusion evidence bound to this job's already-classified CG/AX.
// Reuses normalizer on single-record subsets; does not extend the public snapshot schema.
- (NSSet<NSString *> *)confirmedExcludedKeysFromCG:(NSArray *)cgWindows
                                        axRecords:(NSArray *)axRecords
                                         displays:(NSArray *)displays {
    if (![cgWindows isKindOfClass:NSArray.class] || ![axRecords isKindOfClass:NSArray.class] ||
        ![displays isKindOfClass:NSArray.class]) return [NSSet set];
    NSMutableDictionary *axByKey = [NSMutableDictionary dictionary];
    for (NSDictionary *ax in axRecords) {
        if (![ax isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *identity = ax[@"identity"];
        if (![identity isKindOfClass:NSDictionary.class] ||
            !YMWorkspaceIdentityInteger(identity[@"pid"], 1, INT_MAX) ||
            !YMWorkspaceIdentityInteger(identity[@"windowID"], 1, UINT32_MAX)) continue;
        NSString *key = YMWorkspaceWindowKey(identity[@"pid"], identity[@"windowID"]);
        if (axByKey[key]) {
            axByKey[key] = [NSNull null]; // duplicate AX → never confirm exclusion
            continue;
        }
        axByKey[key] = ax;
    }
    BOOL truncated = NO;
    NSArray *admitted = [self admittedCGCandidates:cgWindows truncated:&truncated];
    if (truncated) return [NSSet set];
    NSMutableSet *excluded = [NSMutableSet set];
    for (NSDictionary *cg in admitted) {
        NSString *key = YMWorkspaceWindowKey(cg[@"pid"], cg[@"windowID"]);
        id ax = axByKey[key];
        if (![ax isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *subset = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[ax], YES, displays);
        if (![subset[@"complete"] boolValue]) continue;
        if ([subset[@"blockers"] count]) continue;
        if ([subset[@"windows"] count]) continue;
        [excluded addObject:key];
    }
    return excluded;
}
- (BOOL)snapshotHasUnresolvedEvidence:(NSDictionary *)snapshot cg:(NSArray *)cgWindows
                         excludedKeys:(NSSet<NSString *> *)excludedKeys {
    if (![snapshot[@"complete"] boolValue]) return YES;
    if ([snapshot[@"blockers"] count]) return YES;
    BOOL truncated = NO;
    NSArray *admitted = [self admittedCGCandidates:cgWindows truncated:&truncated];
    if (truncated) return YES;
    // Any visible CG candidate that did not become a published window remains unknown,
    // unless this job privately confirmed exact exclusion against current CG/AX.
    NSMutableSet *published = [NSMutableSet set];
    for (NSDictionary *window in snapshot[@"windows"])
        [published addObject:YMWorkspaceWindowKey(window[@"pid"], window[@"windowID"])];
    NSSet *excluded = excludedKeys ?: [NSSet set];
    for (NSDictionary *cg in admitted) {
        NSString *key = YMWorkspaceWindowKey(cg[@"pid"], cg[@"windowID"]);
        if ([published containsObject:key]) continue;
        if ([excluded containsObject:key]) continue;
        return YES;
    }
    return NO;
}
- (void)retirePlacementsAgainstWindows:(NSArray<NSDictionary *> *)windows {
    if (self.operationInProgress) return;
    for (YMWPlacement *placement in self.placements.copy) {
        if (placement.application.terminated) { [self.placements removeObject:placement]; continue; }
        for (NSDictionary *window in windows) {
            if ([window[@"windowID"] unsignedIntValue] != placement.windowID ||
                [window[@"pid"] intValue] != placement.application.processIdentifier) continue;
            if ([window[@"isVirtual"] boolValue])
                placement.lastDisplayID = [window[@"displayID"] unsignedIntValue];
            else if (self.accessibilityTrusted) {
                // Use AX geometry already gathered by this generation's inventory job.
                // Insufficient/missing frame keeps the checkpoint — never sync AX here.
                NSDictionary *axFrame = YMWorkspaceGeometry(window[@"frame"]);
                if (!axFrame) break;
                // Independent raw CG evidence only — never normalized AX as cgFrame.
                if (YMWorkspacePhysicalReturnConfirmed(window[@"cgFrame"], axFrame, self.displays, NO))
                    [self.placements removeObject:placement];
            }
            break;
        }
    }
}
- (void)publishWindows:(NSArray<NSDictionary *> *)windows ready:(BOOL)ready key:(NSString *)key
             generation:(NSUInteger)generation excludedKeys:(NSSet<NSString *> *)excludedKeys {
    NSArray *previousWindows = self.windows;
    NSArray *previousRows = self.rows;
    BOOL previousReady = self.inventoryReady;
    [self retirePlacementsAgainstWindows:windows];
    self.windows = windows;
    self.rows = [self groupedRowsForDisplay:0 ownedOnly:YES];
    // Record the observation key for both ready and incomplete results so the
    // same key can reuse within TTL. Only ready=YES authorizes close/export.
    if (key.length) {
        self.inventoryPublishedKey = key;
        self.inventoryPublishedGeneration = generation;
        self.inventoryPublishedAt = [self inventoryTime];
    } else {
        self.inventoryPublishedKey = nil;
        self.inventoryPublishedAt = 0;
    }
    self.inventoryReady = ready;
    self.inventoryValid = ready;
    self.inventoryConfirmedExcludedKeys = ready ? [excludedKeys copy] : nil;
    BOOL rowsChanged = ![previousRows isEqual:self.rows];
    BOOL windowsChanged = ![previousWindows isEqual:self.windows];
    if (rowsChanged || windowsChanged || previousReady != self.inventoryReady)
        [self notifyInventoryDidChange];
}
- (void)finishInventoryJobKey:(NSString *)jobKey generation:(NSUInteger)jobGeneration
                   cgSnapshot:(NSArray *)cgSnapshot trusted:(BOOL)trusted
                     complete:(BOOL)complete reason:(NSString *)reason
                     snapshot:(NSDictionary *)snapshot axRecords:(NSArray *)axRecords
                 observedApps:(NSDictionary *)observedApps {
    if (self.operationInProgress) {
        // Write still settling: keep latest request but do not publish/retire.
        self.inventoryReady = NO;
        self.inventoryValid = NO;
        self.inventoryConfirmedExcludedKeys = nil;
        self.inventoryLatestKey = [self inventoryRequestKeyForCG:self.inventoryCachedCG
                                                        trusted:self.accessibilityTrusted];
        self.inventoryLatestGeneration = self.inventoryGeneration;
        return;
    }
    NSArray *liveCG = [self.windowAccess visibleWindows];
    if (!liveCG) {
        [self invalidateInventoryReuseForCGFailure];
        [self markInventoryNotReady:@"暂时无法读取窗口清单；保留显示器，稍后刷新。"];
        [self drainLatestInventoryRequest];
        return;
    }
    self.inventoryCachedCG = liveCG;
    BOOL liveTrusted = self.accessibilityTrusted;
    NSString *liveKey = [self inventoryRequestKeyForCG:liveCG trusted:liveTrusted];
    NSString *jobCGSignature = [self normalizedCGSignature:cgSnapshot];
    NSString *liveCGSignature = [self normalizedCGSignature:liveCG];
    BOOL topologyCurrent = YES;
    for (NSDictionary *display in self.displays) {
        // Inventory requires live topology to match the cached snapshot, including
        // stable inactive-online entries. Move targets still use displayStillCurrent:.
        if (![self displayMatchesLiveTopology:display]) { topologyCurrent = NO; break; }
    }
    if (!topologyCurrent) {
        // Cached self.displays no longer match live topology. Do not publish,
        // retire, or busy-reschedule — wait for refreshWithVirtualDisplayIDs.
        self.inventoryReady = NO;
        self.inventoryValid = NO;
        self.inventoryConfirmedExcludedKeys = nil;
        self.inventoryLatestKey = nil;
        return;
    }
    if (jobGeneration != self.inventoryGeneration || ![jobKey isEqual:liveKey] ||
        trusted != liveTrusted || ![jobCGSignature isEqual:liveCGSignature]) {
        // World moved: discard stale result and merge the latest request.
        self.inventoryLatestKey = liveKey;
        self.inventoryLatestGeneration = self.inventoryGeneration;
        self.inventoryReady = NO;
        self.inventoryValid = NO;
        self.inventoryConfirmedExcludedKeys = nil;
        [self drainLatestInventoryRequest];
        return;
    }
    if (!trusted) {
        NSArray *windows = [self windowsFromNoAXCG:liveCG];
        // Pure CG may still display/lock classified windows, but unresolved
        // visible candidates (e.g. Stage Manager thumbnails), unclassifiable
        // missing fields, and over-cap tails must not prove an owned virtual empty.
        BOOL unresolved = [self cgHasUnclassifiableEvidence:liveCG] ||
            [self snapshotHasUnresolvedEvidence:
                @{@"windows": windows, @"blockers": @[], @"complete": @YES}
                                                   cg:liveCG
                                        excludedKeys:nil];
        [self publishWindows:windows ready:!unresolved key:liveKey generation:jobGeneration
                excludedKeys:nil];
        [self drainLatestInventoryRequest];
        return;
    }
    // Private evidence from this job's axRecords + current CG — not snapshot schema.
    NSSet *excludedKeys = [self confirmedExcludedKeysFromCG:liveCG
                                                  axRecords:axRecords
                                                   displays:self.displays];
    // Observed process must still match by lifecycle equality; same-PID relaunch discards.
    if (observedApps.count && ![self observedAppsStillCurrent:observedApps]) {
        self.inventoryPublishedKey = liveKey;
        self.inventoryPublishedGeneration = jobGeneration;
        self.inventoryPublishedAt = [self inventoryTime];
        self.inventoryReady = NO;
        self.inventoryValid = NO;
        self.inventoryConfirmedExcludedKeys = nil;
        self.statusText = @"暂时无法完整核对窗口清单；保留显示器，稍后刷新。";
        [self notifyInventoryDidChange];
        [self drainLatestInventoryRequest];
        return;
    }
    // Admission Visible filtering must not erase unclassifiable CG (missing
    // identity/frame/layer/onScreen/alpha); those still block ready/empty close.
    if (!complete || !snapshot || ![snapshot[@"complete"] boolValue] ||
        [self cgHasUnclassifiableEvidence:liveCG] ||
        [self snapshotHasUnresolvedEvidence:snapshot cg:liveCG excludedKeys:excludedKeys]) {
        NSArray *partial = snapshot
            ? [self assembledWindowsFromSnapshot:snapshot observedApps:observedApps]
            : self.windows;
        // Keep prior display rows when partial; never claim ready/empty.
        // Bound incomplete results to liveKey so same-key refresh reuses TTL.
        NSString *previousStatus = self.statusText;
        BOOL previousReady = self.inventoryReady;
        NSArray *previousRows = self.rows;
        if (snapshot && [snapshot[@"windows"] count])
            [self publishWindows:partial ready:NO key:liveKey generation:jobGeneration
                    excludedKeys:nil];
        else {
            self.inventoryPublishedKey = liveKey;
            self.inventoryPublishedGeneration = jobGeneration;
            self.inventoryPublishedAt = [self inventoryTime];
            self.inventoryReady = NO;
            self.inventoryValid = NO;
            self.inventoryConfirmedExcludedKeys = nil;
            if ([reason isEqual:@"timeout"])
                self.statusText = @"窗口清单核对超时；保留显示器，稍后刷新。";
            else
                self.statusText = @"暂时无法完整核对窗口清单；保留显示器，稍后刷新。";
            BOOL statusChanged = previousStatus.length == 0 || ![previousStatus isEqual:self.statusText];
            BOOL rowsChanged = ![previousRows isEqual:self.rows];
            if (statusChanged || rowsChanged || previousReady != self.inventoryReady)
                [self notifyInventoryDidChange];
        }
        [self drainLatestInventoryRequest];
        return;
    }
    NSArray *windows = [self assembledWindowsFromSnapshot:snapshot observedApps:observedApps];
    [self publishWindows:windows ready:YES key:liveKey generation:jobGeneration
            excludedKeys:excludedKeys];
    [self drainLatestInventoryRequest];
}
- (void)drainLatestInventoryRequest {
    if (!self.inventoryLatestKey.length) return;
    [self scheduleInventoryIfNeeded];
}
- (void)refreshInventory {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    NSArray *cg = [self.windowAccess visibleWindows];
    if (!cg) {
        [self invalidateInventoryReuseForCGFailure];
        [self markInventoryNotReady:@"暂时无法读取窗口清单；保留显示器，稍后刷新。"];
        return;
    }
    self.inventoryCachedCG = cg;
    BOOL trusted = self.accessibilityTrusted;
    NSString *cgSignature = [self normalizedCGSignature:cg];
    // Remember observed trust/CG source. Intermediate flaps advance generation
    // irreversibly so a later equal key cannot revive an older in-flight job.
    if (self.inventoryHasObservedTrust) {
        if (self.inventoryObservedTrusted != trusted) self.inventoryGeneration += 1;
    } else {
        self.inventoryHasObservedTrust = YES;
    }
    self.inventoryObservedTrusted = trusted;
    if (self.inventoryHasObservedCG) {
        if (![cgSignature isEqual:self.inventoryObservedCGSignature])
            self.inventoryGeneration += 1;
    } else {
        self.inventoryHasObservedCG = YES;
    }
    self.inventoryObservedCGSignature = cgSignature;
    NSString *key = [self inventoryRequestKeyForCG:cg trusted:trusted];
    // Reuse same-key observation within TTL (ready or incomplete). Incomplete
    // never sets inventoryReady, so close/export stay blocked. Unclassifiable
    // CG must never reuse a prior ready observation even if the key matched.
    if ([key isEqual:self.inventoryPublishedKey] &&
        self.inventoryPublishedGeneration == self.inventoryGeneration &&
        [self inventoryCacheFresh] &&
        ![self cgHasUnclassifiableEvidence:cg]) {
        return;
    }
    // Pending until a matching generation publishes.
    self.inventoryReady = NO;
    self.inventoryValid = NO;
    self.inventoryLatestKey = key;
    self.inventoryLatestGeneration = self.inventoryGeneration;
    [self scheduleInventoryIfNeeded];
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
            NSImage *icon = [self.windowAccess applicationForPID:[window[@"pid"] intValue]].icon;
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
    if (!self.inventoryReady || ![self inventoryCacheFresh]) return YES;
    if ([self rowsForDisplayID:ID].count) return YES;
    for (YMWPlacement *placement in self.placements) if (placement.lastDisplayID == ID) return YES;
    // Close uses the same admission/exclusion evidence as inventory ready.
    // Non-admitted system surfaces and confirmed exclusions must not block empty close.
    if ([self cgHasUnclassifiableEvidence:self.inventoryCachedCG]) return YES;
    BOOL truncated = NO;
    NSArray *admitted = [self admittedCGCandidates:self.inventoryCachedCG truncated:&truncated];
    if (truncated) return YES;
    NSSet *excluded = self.inventoryConfirmedExcludedKeys ?: [NSSet set];
    for (NSDictionary *cg in admitted) {
        NSDictionary *frame = YMWorkspaceGeometry(cg[@"frame"]);
        NSDictionary *display = frame ? YMWorkspaceDisplayForFrame(frame, self.displays) : nil;
        if ([display[@"displayID"] unsignedIntValue] != ID) continue;
        NSString *key = YMWorkspaceWindowKey(cg[@"pid"], cg[@"windowID"]);
        if ([excluded containsObject:key]) continue;
        BOOL published = NO;
        for (NSDictionary *window in self.windows) {
            if ([window[@"pid"] isEqual:cg[@"pid"]] && [window[@"windowID"] isEqual:cg[@"windowID"]]) {
                published = YES; break;
            }
        }
        if (!published) return YES;
    }
    return NO;
}
- (BOOL)needsRestoreBeforeRemovingVirtualDisplay {
    for (NSNumber *ID in self.ownedIDs) if ([self needsRestoreForDisplayID:ID.unsignedIntValue]) return YES;
    return NO;
}
- (BOOL)preflight:(NSError **)error {
    if (self.operationInProgress) return [self fail:error code:1 text:@"正在核对窗口位置，请稍候。"];
    if (!self.accessibilityTrusted) return [self fail:error code:2 text:@"移动窗口需要控制权限；请先打开控制权限设置。"];
    NSArray *cg = [self.windowAccess visibleWindows];
    if (!cg) return [self fail:error code:3 text:@"无法读取窗口清单，尚未移动任何窗口。"];
    [self refreshInventory];
    // Selected-app move/restore uses a live per-app observe. Do not wait for
    // unrelated App background AX cache. Close/export keep inventoryReady gates.
    return YES;
}
- (BOOL)genericBundleAllowed:(NSString *)bundle error:(NSError **)error {
    if (YMWorkspaceGenericMutationAllowed(bundle)) return YES;
    return [self fail:error code:4 text:[bundle isEqualToString:@"com.tencent.xinWeChat"] ?
        @"微信由专用安全恢复器处理，请通过控制面板的微信条目操作。" : @"此应用的窗口由系统或 yomado 自身管理，不能移入。"];
}
- (YMWPlacement *)placementForElement:(id)element application:(NSRunningApplication *)application
                             windowID:(CGWindowID)windowID identity:(NSDictionary *)identity {
    (void)element;
    for (YMWPlacement *p in self.placements.copy) {
        if (p.application.processIdentifier != application.processIdentifier || p.application.terminated)
            continue;
        if (YMWorkspaceSameWindowIdentity(p.identity, identity)) {
            if (p.windowID == windowID) return p;
            // Lifecycle reuse of the same AX element must not inherit an old frame.
            [self.placements removeObject:p];
            return nil;
        }
        // Same window ID with a different five-field identity is a replacement.
        if (p.windowID == windowID) [self.placements removeObject:p];
    }
    return nil;
}
- (NSArray<NSDictionary *> *)candidatesForApplication:(NSRunningApplication *)app sourceFilter:(NSNumber *)filter error:(NSError **)error {
    if (!app || app.terminated) {
        [self fail:error code:5 text:@"无法访问应用窗口；请先打开应用主窗口。"]; return nil;
    }
    NSArray *cgAll = [self.windowAccess visibleWindows];
    if (!cgAll) {
        [self fail:error code:3 text:@"无法读取窗口清单，尚未移动任何窗口。"]; return nil;
    }
    NSMutableArray *cgForApp = [NSMutableArray array];
    for (NSDictionary *cg in cgAll)
        if ([cg[@"pid"] intValue] == app.processIdentifier) [cgForApp addObject:cg];

    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.8;
    NSDictionary *observation = [self.windowAccess observeApplication:app deadline:deadline];
    if (app.terminated) {
        [self fail:error code:5 text:@"无法访问应用窗口；请先打开应用主窗口。"]; return nil;
    }
    if (![observation isKindOfClass:NSDictionary.class] ||
        ![observation[@"complete"] isKindOfClass:NSNumber.class] || ![observation[@"complete"] boolValue]) {
        NSString *reason = [observation[@"reason"] isKindOfClass:NSString.class] ? observation[@"reason"] : @"";
        if ([reason isEqual:@"incompleteMetadata"] || [reason isEqual:@"duplicateIdentity"]) {
            [self fail:error code:20 text:@"无法确认窗口身份；请保持应用打开后重试，尚未移动任何窗口。"];
            return nil;
        }
        [self fail:error code:6 text:@"应用暂时没有响应窗口查询；已保留原位置记录。"]; return nil;
    }
    NSArray *axWindows = [observation[@"windows"] isKindOfClass:NSArray.class] ? observation[@"windows"] : @[];
    BOOL anyValidIdentity = NO;
    for (NSDictionary *ax in axWindows)
        if (YMWorkspaceIdentityValid(ax[@"identity"])) { anyValidIdentity = YES; break; }
    // Identity private API unavailable: AX rows exist but none carry a valid identity.
    if (cgForApp.count && axWindows.count && !anyValidIdentity) {
        [self fail:error code:20 text:@"无法确认窗口身份；请保持应用打开后重试，尚未移动任何窗口。"];
        return nil;
    }

    NSDictionary *snapshot = YMWorkspaceNormalizeWindowSnapshot(cgForApp, axWindows, YES, self.displays);
    if (!YMWorkspaceSnapshotAllowsSource(snapshot, filter)) {
        [self fail:error code:7 text:@"部分窗口无法可靠匹配或移动。请关闭弹窗、展开普通窗口后重试；尚未继续移屏。"];
        return nil;
    }

    // Only a complete, identity-trusted enumeration may retire closed placements.
    NSMutableSet *liveKeys = [NSMutableSet set];
    for (NSDictionary *ax in axWindows) {
        NSDictionary *identity = ax[@"identity"];
        if (YMWorkspaceIdentityValid(identity))
            [liveKeys addObject:YMWorkspaceWindowKey(identity[@"pid"], identity[@"windowID"])];
    }
    for (YMWPlacement *placement in self.placements.copy) {
        if (placement.application.processIdentifier != app.processIdentifier) continue;
        NSString *key = YMWorkspaceIdentityValid(placement.identity)
            ? YMWorkspaceWindowKey(placement.identity[@"pid"], placement.identity[@"windowID"])
            : YMWorkspaceWindowKey(@(placement.application.processIdentifier), @(placement.windowID));
        if (![liveKeys containsObject:key]) [self.placements removeObject:placement];
    }

    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *window in snapshot[@"windows"]) {
        if (!YMWorkspaceMatchesSource(window, filter)) continue;
        if (![window[@"positionSettable"] boolValue] || !window[@"element"] ||
            !YMWorkspaceIdentityValid(window[@"identity"]) || !YMWorkspaceGeometry(window[@"frame"])) {
            [self fail:error code:7 text:@"部分窗口无法可靠匹配或移动。请关闭弹窗、展开普通窗口后重试；尚未继续移屏。"];
            return nil;
        }
        [result addObject:@{
            @"element": window[@"element"],
            @"frame": window[@"frame"],
            @"cgFrame": window[@"cgFrame"] ?: window[@"frame"],
            @"windowID": window[@"windowID"],
            @"displayID": window[@"displayID"],
            @"isVirtual": window[@"isVirtual"] ?: @NO,
            @"identity": window[@"identity"]
        }];
    }
    return result;
}
- (NSDictionary *)liveDisplayStateForID:(CGDirectDisplayID)ID {
    if (!ID) return nil;
    CGRect rect = CGDisplayBounds(ID);
    return @{
        @"isActive": @(CGDisplayIsActive(ID)),
        @"isOnline": @(CGDisplayIsOnline(ID)),
        @"isInMirrorSet": @(CGDisplayIsInMirrorSet(ID)),
        @"mirrorsDisplay": @(CGDisplayMirrorsDisplay(ID)),
        @"bounds": @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
                     @"width": @(rect.size.width), @"height": @(rect.size.height)}
    };
}
- (BOOL)displayMatchesLiveTopology:(NSDictionary *)display {
    if (![display isKindOfClass:NSDictionary.class]) return NO;
    CGDirectDisplayID ID = [display[@"displayID"] unsignedIntValue];
    NSDictionary *bounds = YMWorkspaceGeometry(display[@"bounds"]);
    if (!ID || !bounds ||
        ![display[@"isActive"] isKindOfClass:NSNumber.class] ||
        ![display[@"isOnline"] isKindOfClass:NSNumber.class]) return NO;
    NSDictionary *live = [self liveDisplayStateForID:ID];
    if (!live) return NO;
    if ([display[@"isActive"] boolValue] != [live[@"isActive"] boolValue]) return NO;
    if ([display[@"isOnline"] boolValue] != [live[@"isOnline"] boolValue]) return NO;
    if ([self.ownedIDs containsObject:@(ID)]) {
        CGDirectDisplayID mirrors = [live[@"mirrorsDisplay"] unsignedIntValue];
        if ([live[@"isInMirrorSet"] boolValue] || mirrors != kCGNullDirectDisplay) return NO;
    }
    return YMWorkspaceSameFrame(bounds, live[@"bounds"]);
}
- (BOOL)displayStillCurrent:(NSDictionary *)display {
    // Strict write-target guard: snapshot entry must already be usable (active+online).
    if (!YMWorkspaceUsableDisplay(display)) return NO;
    NSDictionary *live = [self liveDisplayStateForID:[display[@"displayID"] unsignedIntValue]];
    if (!live || ![live[@"isActive"] boolValue] || ![live[@"isOnline"] boolValue]) return NO;
    CGDirectDisplayID ID = [display[@"displayID"] unsignedIntValue];
    if ([self.ownedIDs containsObject:@(ID)]) {
        CGDirectDisplayID mirrors = [live[@"mirrorsDisplay"] unsignedIntValue];
        if ([live[@"isInMirrorSet"] boolValue] || mirrors != kCGNullDirectDisplay) return NO;
    }
    return YMWorkspaceSameFrame(display[@"bounds"], live[@"bounds"]);
}
- (BOOL)placeElement:(id)element frame:(NSDictionary *)frame display:(NSDictionary *)display
         application:(NSRunningApplication *)app expectedIdentity:(NSDictionary *)identity {
    if (app.terminated || !YMWorkspaceIdentityValid(identity) || !YMWorkspaceGeometry(frame) ||
        ![self displayStillCurrent:display]) return NO;
    NSDictionary *live = [self.windowAccess observeElement:element];
    if (!live || !YMWorkspaceSameWindowIdentity(live[@"identity"], identity) ||
        ![live[@"ordinary"] boolValue] || [live[@"minimized"] boolValue] ||
        ![live[@"positionSettable"] boolValue] || !YMWorkspaceGeometry(live[@"frame"])) return NO;
    NSDictionary *before = live[@"frame"];
    CGSize size = CGSizeMake([frame[@"width"] doubleValue], [frame[@"height"] doubleValue]);
    if (fabs([before[@"width"] doubleValue] - size.width) > 1 ||
        fabs([before[@"height"] doubleValue] - size.height) > 1) {
        (void)[self.windowAccess setSize:size element:element expectedIdentity:identity];
        live = [self.windowAccess observeElement:element];
        // Re-validate full movable state after resize — minimized/non-ordinary/
        // unsettable windows must not continue into position writes.
        if (!live || !YMWorkspaceSameWindowIdentity(live[@"identity"], identity) ||
            ![live[@"ordinary"] boolValue] || [live[@"minimized"] boolValue] ||
            ![live[@"positionSettable"] boolValue] || !YMWorkspaceGeometry(live[@"frame"]))
            return NO;
    }
    if (![self displayStillCurrent:display]) return NO;
    CGPoint point = CGPointMake([frame[@"x"] doubleValue], [frame[@"y"] doubleValue]);
    if (![self.windowAccess setPosition:point element:element expectedIdentity:identity]) return NO;
    for (NSUInteger observation = 0; observation < 4; observation++) {
        // The run loop permits external screen changes while settling. Never
        // accept a frame against stale bounds after a display moves/disappears.
        if (![self displayStillCurrent:display]) return NO;
        live = [self.windowAccess observeElement:element];
        if (!live || !YMWorkspaceSameWindowIdentity(live[@"identity"], identity) ||
            ![live[@"ordinary"] boolValue] || [live[@"minimized"] boolValue] ||
            ![live[@"positionSettable"] boolValue] || !YMWorkspaceGeometry(live[@"frame"]))
            return NO;
        if (YMWorkspaceFrameFits(live[@"frame"], display)) return YES;
        if (observation < 3)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                   beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
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
    for (NSRunningApplication *app in [self.windowAccess applicationsForBundleIdentifier:bundle.bundleIdentifier]) {
        NSURL *appURL = app.bundleURL.isFileURL
            ? app.bundleURL.URLByResolvingSymlinksInPath.URLByStandardizingPath : nil;
        if (app.terminated || ![appURL isEqual:canonical]) continue;
        running = YES;
        NSArray *candidates = [self candidatesForApplication:app sourceFilter:filter error:error]; if (!candidates) return NO;
        for (NSDictionary *candidate in candidates) if ([candidate[@"displayID"] unsignedIntValue] != ID)
            [operations addObject:@{@"application": app, @"candidate": candidate}];
    }
    if (!running) return [self fail:error code:10 text:@"请先打开这个 App 的窗口，再将 App 拖入虚拟屏。"];
    if (!operations.count) return [self fail:error code:18 text:@"没有需要移动的可见普通窗口；窗口可能已在目标屏，或仍处于隐藏、最小化状态。请先显示要移动的窗口。"];
    self.operationInProgress = YES;
    [self invalidateInventoryForMutation];
    NSUInteger moved = 0;
    @try {
        for (NSDictionary *operation in operations) {
            NSRunningApplication *app = operation[@"application"]; NSDictionary *candidate = operation[@"candidate"];
            id element = candidate[@"element"];
            NSDictionary *expectedIdentity = candidate[@"identity"];
            NSDictionary *live = [self.windowAccess observeElement:element];
            if (!live || !YMWorkspaceSameWindowIdentity(live[@"identity"], expectedIdentity) ||
                !YMWorkspaceSameFrame(live[@"frame"], candidate[@"frame"]) ||
                ![live[@"ordinary"] boolValue] || [live[@"minimized"] boolValue] ||
                ![live[@"positionSettable"] boolValue])
                return [self fail:error code:11 text:@"窗口身份或位置已变化，已停止后续移动；可以返回已移动的窗口。"];
            NSDictionary *liveDisplay = YMWorkspaceDisplayForFrame(live[@"frame"], self.displays);
            NSDictionary *source = [self display:[candidate[@"displayID"] unsignedIntValue]];
            // Source topology must still match before saving origin or writing.
            // Target-only checks leave relative origins wrong when the physical
            // source drifts while the cached snapshot stays stale.
            if (!liveDisplay || !source ||
                [liveDisplay[@"displayID"] unsignedIntValue] != [candidate[@"displayID"] unsignedIntValue] ||
                !YMWorkspaceMatchesSource(@{@"displayID": liveDisplay[@"displayID"],
                    @"isVirtual": liveDisplay[@"isVirtual"]}, filter) ||
                ![self displayStillCurrent:source] ||
                ![self displayStillCurrent:target])
                return [self fail:error code:11 text:@"窗口身份或位置已变化，已停止后续移动；可以返回已移动的窗口。"];
            NSDictionary *before = live[@"frame"];
            YMWPlacement *placement = [self placementForElement:element application:app
                                                       windowID:[candidate[@"windowID"] unsignedIntValue]
                                                       identity:expectedIdentity];
            BOOL created = !placement;
            if (!placement) {
                placement = [YMWPlacement new]; placement.element = element; placement.application = app;
                placement.bundleID = app.bundleIdentifier;
                placement.windowID = [candidate[@"windowID"] unsignedIntValue];
                placement.identity = expectedIdentity;
                // Physical AX origin only — virtual→virtual must not invent/overwrite it.
                placement.origin = YMWorkspaceOrigin(before, source);
                [self.placements addObject:placement];
            }
            CGDirectDisplayID priorID = placement.lastDisplayID;
            placement.lastDisplayID = ID;
            placement.element = element;
            placement.identity = expectedIdentity;
            NSDictionary *destination = YMWorkspaceFrameOnDisplay(before, nil, target);
            if (![self placeElement:element frame:destination display:target application:app
                   expectedIdentity:expectedIdentity]) {
                // Never roll back onto a replacement that no longer matches identity.
                BOOL returned = [self placeElement:element frame:before display:source application:app
                                  expectedIdentity:expectedIdentity];
                if (returned && created && placement.origin) [self.placements removeObject:placement];
                else if (returned) placement.lastDisplayID = priorID ?: [source[@"displayID"] unsignedIntValue];
                return [self fail:error code:12 text:returned ? @"移屏未获验证，当前窗口已退回；已停止后续移动。" :
                    @"尚未确认窗口位置；保留显示器和原位置记录，请使用返回操作。"];
            }
            moved++;
        }
        self.statusText = [NSString stringWithFormat:@"已移入 %lu 个窗口。原位置在本次 yomado 运行期间保留。", (unsigned long)moved];
        return YES;
    } @finally {
        self.operationInProgress = NO;
        [self invalidateInventoryForMutation];
        [self refreshInventory];
    }
}
- (BOOL)moveApplicationAtURL:(NSURL *)URL toDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    return [self performMoveApplicationAtURL:URL sourceFilter:nil toDisplayID:ID error:error];
}
- (BOOL)moveApplicationAtURL:(NSURL *)URL fromDisplayID:(CGDirectDisplayID)sourceID toDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    return [self performMoveApplicationAtURL:URL sourceFilter:@(sourceID) toDisplayID:ID error:error];
}
- (BOOL)performRestoreBundle:(NSString *)bundle sourceID:(CGDirectDisplayID)sourceID physicalTarget:(NSDictionary *)physicalTarget error:(NSError **)error {
    if (!YMWorkspaceGenericRestoreAllowed(bundle)) return [self fail:error code:4 text:@"请先把 yomado 控制面板移回实体屏，再关闭此虚拟屏。"];
    // Collect every same-bundle process candidate before the first restore write —
    // a sibling timeout/blocker must not leave earlier processes already moved.
    NSMutableArray *operations = [NSMutableArray array];
    NSNumber *sourceFilter = sourceID ? @(sourceID) : nil;
    for (NSRunningApplication *app in [self.windowAccess applicationsForBundleIdentifier:bundle]) {
        if (app.terminated) continue;
        NSArray *candidates = [self candidatesForApplication:app sourceFilter:sourceFilter error:error];
        if (!candidates) return NO;
        for (NSDictionary *candidate in candidates) {
            NSDictionary *source = [self display:[candidate[@"displayID"] unsignedIntValue]];
            if (![self.ownedIDs containsObject:source[@"displayID"]]) continue;
            [operations addObject:@{@"application": app, @"candidate": candidate}];
        }
    }
    NSUInteger restored = 0, fallback = 0;
    for (NSDictionary *operation in operations) {
        NSRunningApplication *app = operation[@"application"];
        NSDictionary *candidate = operation[@"candidate"];
        id element = candidate[@"element"];
        NSDictionary *expectedIdentity = candidate[@"identity"];
        YMWPlacement *placement = [self placementForElement:element application:app
                                                   windowID:[candidate[@"windowID"] unsignedIntValue]
                                                   identity:expectedIdentity];
        NSDictionary *live = [self.windowAccess observeElement:element];
        if (!live || !YMWorkspaceSameWindowIdentity(live[@"identity"], expectedIdentity) ||
            !YMWorkspaceSameFrame(live[@"frame"], candidate[@"frame"]) ||
            ![live[@"ordinary"] boolValue] || [live[@"minimized"] boolValue] ||
            ![live[@"positionSettable"] boolValue])
            return [self fail:error code:13 text:@"窗口身份或位置已变化，已停止恢复；请刷新后再试。"];
        NSDictionary *origin = placement.origin, *before = live[@"frame"];
        NSDictionary *source = [self display:[candidate[@"displayID"] unsignedIntValue]];
        // Restore source (owned virtual) must still match live topology before writes.
        if (!source || ![self displayStillCurrent:source])
            return [self fail:error code:13 text:@"窗口身份或位置已变化，已停止恢复；请刷新后再试。"];
        NSDictionary *target = physicalTarget ?: YMWorkspacePhysicalDisplay(origin[@"displayUUID"], self.displays);
        NSDictionary *destination = physicalTarget ? YMWorkspaceFrameForExplicitPhysicalReturn(origin, before, target) :
            YMWorkspaceFrameOnDisplay(origin[@"relative"] ?: before, origin[@"relative"], target);
        if (!target || !destination || ![self displayStillCurrent:target])
            return [self fail:error code:14 text:@"没有可用的实体显示器；保留虚拟屏和窗口记录。"];
        if (![self placeElement:element frame:destination display:target application:app
               expectedIdentity:expectedIdentity])
            return [self fail:error code:15 text:@"尚未确认窗口已返回实体屏；保留虚拟屏和原位置记录。"];
        if (!origin || (physicalTarget && !YMWorkspaceOriginBelongsToDisplay(origin, target))) fallback++;
        if (placement) [self.placements removeObject:placement];
        restored++;
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
    [self invalidateInventoryForMutation];
    @try { return [self performRestoreBundle:bundle sourceID:ID physicalTarget:nil error:error]; }
    @finally {
        self.operationInProgress = NO;
        [self invalidateInventoryForMutation];
        [self refreshInventory];
    }
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
    [self invalidateInventoryForMutation];
    @try { return [self performRestoreBundle:bundle sourceID:sourceID physicalTarget:target error:error]; }
    @finally {
        self.operationInProgress = NO;
        [self invalidateInventoryForMutation];
        [self refreshInventory];
    }
}
- (BOOL)restoreDisplayID:(CGDirectDisplayID)ID error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (self.operationInProgress) return [self fail:error code:1 text:@"正在核对窗口位置，请稍候。"];
    [self refreshInventory];
    if (!self.inventoryReady || ![self inventoryCacheFresh])
        return [self fail:error code:3 text:@"无法读取窗口清单；保留虚拟屏，稍后再试。"];
    if (![self.ownedIDs containsObject:@(ID)]) return [self fail:error code:17 text:@"只能返回 yomado 虚拟屏中的窗口。"];
    NSMutableOrderedSet *bundles = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *row in [self rowsForDisplayID:ID]) [bundles addObject:row[@"bundleIdentifier"]];
    for (YMWPlacement *placement in self.placements) if (placement.lastDisplayID == ID) [bundles addObject:placement.bundleID];
    // Read-only inventory is enough to close an empty workspace. Do not trap
    // users in an empty virtual display just because AX permission is absent.
    if (!bundles.count) { self.statusText = @"此虚拟屏没有需要返回的窗口。"; return YES; }
    if (!self.accessibilityTrusted) return [self fail:error code:2 text:@"返回窗口需要控制权限；请先打开控制权限设置，或手动移回窗口。"];
    self.operationInProgress = YES;
    [self invalidateInventoryForMutation];
    @try {
        for (NSString *bundle in bundles) {
            // The controller first handles any pending WeChat safety checkpoint
            // with YMWindowRecovery. A manually dragged ordinary WeChat window
            // without a checkpoint can then return to physical main here.
            if (![self performRestoreBundle:bundle sourceID:ID physicalTarget:nil error:error]) return NO;
        }
        return YES;
    } @finally {
        self.operationInProgress = NO;
        [self invalidateInventoryForMutation];
        [self refreshInventory];
    }
}
- (NSArray<NSDictionary *> *)restartOriginCheckpointsWithError:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"App workspace is main-thread only.");
    if (self.operationInProgress) { [self fail:error code:30 text:@"窗口操作尚未结束，稍后再更新。"]; return nil; }
    [self refreshInventory];
    if (!self.inventoryReady || ![self inventoryCacheFresh]) {
        [self fail:error code:30 text:@"无法核对窗口清单，保留当前工作区。"];
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (YMWPlacement *placement in self.placements) {
        if (!placement.origin) continue;
        // Retained checkpoints not present in current owned windows are unresolved
        // (e.g. independent CG/AX disagree). Never silent-skip into empty success.
        NSDictionary *owned = YMWorkspaceCheckpointWindow(placement.application.processIdentifier,
            placement.windowID, self.windows, self.ownedIDs);
        if (!owned) {
            [self fail:error code:31 text:@"已有窗口的原位置无法精确交接，已暂停更新。"];
            return nil;
        }
        NSDictionary *live = [self.windowAccess observeElement:placement.element];
        NSDictionary *identity = live[@"identity"];
        NSDictionary *frame = live[@"frame"];
        if (YMWorkspaceIdentityValid(placement.identity) &&
            !YMWorkspaceSameWindowIdentity(identity, placement.identity)) {
            [self fail:error code:31 text:@"已有窗口的原位置无法精确交接，已暂停更新。"]; return nil;
        }
        NSDictionary *display = YMWorkspaceDisplayForFrame(frame, self.displays);
        NSDictionary *relative = YMWorkspaceGeometry(placement.origin[@"relative"]);
        NSString *uuid = placement.origin[@"displayUUID"];
        if (!YMWorkspaceIdentityValid(identity) ||
            [identity[@"pid"] intValue] != placement.application.processIdentifier ||
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
        if (!YMWorkspaceIdentityValid(identity))
            return [self fail:error code:31 text:@"窗口原位置接管未完成，保留恢复记录供重试。"];
        id element = [self.windowAccess resolveIdentity:identity error:error];
        NSDictionary *live = element ? [self.windowAccess observeElement:element] : nil;
        NSDictionary *frame = live[@"frame"];
        if (!YMWorkspaceSameWindowIdentity(live[@"identity"], identity))
            return [self fail:error code:31 text:@"窗口原位置接管未完成，保留恢复记录供重试。"];
        NSDictionary *display = YMWorkspaceDisplayForFrame(frame, self.displays);
        if (!element || !frame || ![self.ownedIDs containsObject:display[@"displayID"]] || !relative ||
            ![uuid isKindOfClass:NSString.class] || !uuid.length || [seen containsObject:identity])
            return [self fail:error code:31 text:@"窗口原位置接管未完成，保留恢复记录供重试。"];
        [seen addObject:identity];
        YMWPlacement *placement = [YMWPlacement new];
        placement.element = element;
        placement.application = [self.windowAccess applicationForPID:[identity[@"pid"] intValue]];
        placement.bundleID = identity[@"bundleID"];
        placement.windowID = [identity[@"windowID"] unsignedIntValue];
        placement.identity = identity;
        placement.lastDisplayID = [display[@"displayID"] unsignedIntValue];
        placement.origin = @{@"displayUUID": uuid, @"relative": relative};
        if (!placement.application || placement.application.terminated)
            return [self fail:error code:31 text:@"窗口原位置接管未完成，保留恢复记录供重试。"];
        [pending addObject:placement];
    }
    // All exact lookups complete before changing any in-memory ownership.
    for (YMWPlacement *placement in pending) {
        for (YMWPlacement *old in self.placements.copy)
            if (old.windowID == placement.windowID &&
                old.application.processIdentifier == placement.application.processIdentifier)
                [self.placements removeObject:old];
        [self.placements addObject:placement];
    }
    [self invalidateInventoryForMutation];
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
