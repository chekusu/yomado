#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <stdio.h>
#import "AppWorkspace.h"
#import "AppWorkspaceAccess.h"
#import "AppWorkspacePolicy.h"

static NSUInteger checks, failures;
static void Check(BOOL condition, NSString *description) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", description.UTF8String);
    }
}

static NSDictionary *Frame(double x, double y, double width, double height) {
    return @{@"x": @(x), @"y": @(y), @"width": @(width), @"height": @(height)};
}

static NSDictionary *RuntimeDisplay(unsigned int ID, double x, BOOL isVirtual, NSString *uuid) {
    return @{@"displayID": @(ID), @"displayUUID": uuid,
        @"bounds": Frame(x, 0, 2560, 1440), @"isMain": @(ID == 5),
        @"isActive": @YES, @"isOnline": @YES, @"isVirtual": @(isVirtual)};
}

static NSArray *RuntimeDisplays(void) {
    return @[RuntimeDisplay(5, 0, NO, @"physical"),
             RuntimeDisplay(8, 2560, YES, @"agent-a"),
             RuntimeDisplay(9, 5120, YES, @"agent-b")];
}

static NSDictionary *Identity(pid_t pid, CGWindowID windowID) {
    return @{@"pid": @(pid), @"windowID": @(windowID), @"startSeconds": @1000,
             @"startMicroseconds": @7, @"bundleID": @"test.calculator"};
}

#pragma mark - Fake application / access

@class YMFakeRunningApp;

@interface YMFakeWindowAccess : NSObject <YMWorkspaceWindowAccess>
@property(nonatomic) BOOL trusted;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *cgWindows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray *> *axByPID;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YMFakeRunningApp *> *appsByPID;
@property(nonatomic, strong) NSMutableDictionary *elementFrames;
@property(nonatomic, strong) NSMutableDictionary *elementIdentities;
@property(nonatomic, strong) NSMutableDictionary *elementStates;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *positionWrites;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *sizeWrites;
@property(nonatomic, copy) NSDictionary *currentFrame;
@property(nonatomic) NSUInteger activationRequests;
@property(nonatomic) NSUInteger readCount;
@property(nonatomic) NSUInteger writeCount;
@property(nonatomic) NSUInteger observeCount;
@property(nonatomic) NSUInteger observeElementCount;
@property(nonatomic) BOOL failVisibleWindows;
@property(nonatomic) BOOL forceIncompleteObserve;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *forceIncompletePIDs;
@property(nonatomic, copy) NSString *incompleteReason;
@property(nonatomic) NSTimeInterval observeDelay;
@property(nonatomic) NSUInteger failNextPositionWrites;
@property(nonatomic) BOOL syncCGOnWrite;
@property(nonatomic) BOOL flipIdentityOnNextObserveElement;
/// 1-based: when observeElementCount reaches this value, apply observeElementMutation once.
@property(nonatomic) NSUInteger mutateOnObserveElementCount;
@property(nonatomic, copy) NSDictionary *observeElementMutation;
@property(nonatomic, copy) void (^observeElementSideEffect)(NSUInteger count);
@property(nonatomic, copy) void (^observeApplicationSideEffect)(pid_t pid, NSTimeInterval deadline);
@property(nonatomic, strong) NSMutableArray<NSNumber *> *observedPIDs;
/// When YES, applicationForPID returns a fresh equal wrapper (not pointer-identical).
@property(nonatomic) BOOL reboxApplicationWrappers;
@end

@interface YMFakeRunningApp : NSObject
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, strong) NSURL *bundleURL;
@property(nonatomic, copy) NSString *localizedName;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, weak) YMFakeWindowAccess *access;
/// Stable across equal wrappers of one process lifetime; replaced on same-PID relaunch.
@property(nonatomic, strong) id lifecycleToken;
@end
@implementation YMFakeRunningApp
- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options {
    (void)options;
    self.access.activationRequests += 1;
    return NO;
}
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:YMFakeRunningApp.class]) return NO;
    YMFakeRunningApp *app = other;
    return self.lifecycleToken != nil && self.lifecycleToken == app.lifecycleToken;
}
- (NSUInteger)hash {
    return self.lifecycleToken ? (NSUInteger)self.lifecycleToken : (NSUInteger)self;
}
@end

@implementation YMFakeWindowAccess
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _trusted = YES;
    _cgWindows = [NSMutableArray array];
    _axByPID = [NSMutableDictionary dictionary];
    _appsByPID = [NSMutableDictionary dictionary];
    _elementFrames = [NSMutableDictionary dictionary];
    _elementIdentities = [NSMutableDictionary dictionary];
    _elementStates = [NSMutableDictionary dictionary];
    _positionWrites = [NSMutableArray array];
    _sizeWrites = [NSMutableArray array];
    _forceIncompletePIDs = [NSMutableSet set];
    _observedPIDs = [NSMutableArray array];
    _incompleteReason = @"timeout";
    _syncCGOnWrite = YES;
    return self;
}

- (YMFakeRunningApp *)installApp:(pid_t)pid name:(NSString *)name bundle:(NSString *)bundle {
    return [self installApp:pid name:name bundle:bundle bundleURL:nil];
}

- (YMFakeRunningApp *)installApp:(pid_t)pid name:(NSString *)name bundle:(NSString *)bundle
                       bundleURL:(NSURL *)bundleURL {
    YMFakeRunningApp *app = [YMFakeRunningApp new];
    app.processIdentifier = pid;
    app.bundleIdentifier = bundle;
    app.localizedName = name;
    app.bundleURL = bundleURL ?: [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/fake-%@.app", bundle]];
    app.terminated = NO;
    app.access = self;
    // New install = new lifecycle, even when PID is reused after termination.
    app.lifecycleToken = app;
    self.appsByPID[@(pid)] = app;
    return app;
}

- (void)installWindowPID:(pid_t)pid windowID:(CGWindowID)windowID
                cgFrame:(NSDictionary *)cgFrame axFrame:(NSDictionary *)axFrame {
    NSDictionary *identity = Identity(pid, windowID);
    id element = [NSString stringWithFormat:@"el-%d-%u", pid, windowID];
    [self.cgWindows addObject:@{@"pid": @(pid), @"windowID": @(windowID),
        @"frame": cgFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
    NSDictionary *ax = @{@"identity": identity, @"frame": axFrame, @"ordinary": @YES,
        @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element};
    NSMutableArray *list = [self.axByPID[@(pid)] mutableCopy] ?: [NSMutableArray array];
    [list addObject:ax];
    self.axByPID[@(pid)] = list;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    self.elementFrames[key] = axFrame;
    self.elementIdentities[key] = identity;
    self.elementStates[key] = @{@"ordinary": @YES, @"minimized": @NO, @"positionSettable": @YES};
    self.currentFrame = axFrame;
}

- (NSString *)elementKey:(id)element {
    return [NSString stringWithFormat:@"%p", element];
}

- (void)applyObserveElementMutationForElement:(id)element {
    NSString *key = [self elementKey:element];
    NSDictionary *mutation = self.observeElementMutation;
    if (!mutation.count) return;
    NSDictionary *prior = self.elementIdentities[key];
    if (prior) {
        NSMutableDictionary *changed = [prior mutableCopy];
        if (mutation[@"startSecondsDelta"])
            changed[@"startSeconds"] = @([prior[@"startSeconds"] unsignedLongLongValue]
                + [mutation[@"startSecondsDelta"] unsignedLongLongValue]);
        if (mutation[@"windowID"]) changed[@"windowID"] = mutation[@"windowID"];
        if (mutation[@"pid"]) changed[@"pid"] = mutation[@"pid"];
        if (mutation[@"bundleID"]) changed[@"bundleID"] = mutation[@"bundleID"];
        self.elementIdentities[key] = changed;
        pid_t listPID = [prior[@"pid"] intValue];
        NSMutableArray *list = [self.axByPID[@(listPID)] mutableCopy] ?: [NSMutableArray array];
        for (NSUInteger i = 0; i < list.count; i++) {
            NSMutableDictionary *ax = [list[i] mutableCopy];
            if ([ax[@"element"] isEqual:element]) {
                ax[@"identity"] = changed;
                if (mutation[@"frame"]) ax[@"frame"] = mutation[@"frame"];
                if (mutation[@"ordinary"]) ax[@"ordinary"] = mutation[@"ordinary"];
                if (mutation[@"minimized"]) ax[@"minimized"] = mutation[@"minimized"];
                if (mutation[@"positionSettable"]) ax[@"positionSettable"] = mutation[@"positionSettable"];
                list[i] = ax;
            }
        }
        self.axByPID[@(listPID)] = list;
        if (mutation[@"pid"] && [mutation[@"pid"] intValue] != listPID) {
            self.axByPID[mutation[@"pid"]] = list;
            [self.axByPID removeObjectForKey:@(listPID)];
        }
        if (mutation[@"windowID"] || mutation[@"pid"]) {
            for (NSUInteger i = 0; i < self.cgWindows.count; i++) {
                NSDictionary *cg = self.cgWindows[i];
                if ([cg[@"pid"] intValue] == listPID &&
                    [cg[@"windowID"] unsignedIntValue] == [prior[@"windowID"] unsignedIntValue]) {
                    NSMutableDictionary *updated = [cg mutableCopy];
                    if (mutation[@"windowID"]) updated[@"windowID"] = mutation[@"windowID"];
                    if (mutation[@"pid"]) updated[@"pid"] = mutation[@"pid"];
                    if (mutation[@"frame"]) updated[@"frame"] = mutation[@"frame"];
                    self.cgWindows[i] = updated;
                    break;
                }
            }
        }
    }
    if (mutation[@"frame"]) self.elementFrames[key] = mutation[@"frame"];
    if (mutation[@"ordinary"] || mutation[@"minimized"] || mutation[@"positionSettable"]) {
        NSMutableDictionary *state = [self.elementStates[key] mutableCopy]
            ?: [@{@"ordinary": @YES, @"minimized": @NO, @"positionSettable": @YES} mutableCopy];
        if (mutation[@"ordinary"]) state[@"ordinary"] = mutation[@"ordinary"];
        if (mutation[@"minimized"]) state[@"minimized"] = mutation[@"minimized"];
        if (mutation[@"positionSettable"]) state[@"positionSettable"] = mutation[@"positionSettable"];
        self.elementStates[key] = state;
    }
    self.observeElementMutation = nil;
}

- (void)updateAXFrame:(NSDictionary *)frame forElement:(id)element {
    NSString *key = [self elementKey:element];
    self.elementFrames[key] = frame;
    self.currentFrame = frame;
    NSDictionary *identity = self.elementIdentities[key];
    if (!identity) return;
    pid_t pid = [identity[@"pid"] intValue];
    NSMutableArray *list = [self.axByPID[@(pid)] mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < list.count; i++) {
        NSMutableDictionary *ax = [list[i] mutableCopy];
        if ([ax[@"element"] isEqual:element] || [ax[@"identity"] isEqual:identity]) {
            ax[@"frame"] = frame;
            list[i] = ax;
        }
    }
    self.axByPID[@(pid)] = list;
    if (!self.syncCGOnWrite) return;
    CGWindowID windowID = [identity[@"windowID"] unsignedIntValue];
    for (NSUInteger i = 0; i < self.cgWindows.count; i++) {
        NSDictionary *cg = self.cgWindows[i];
        if ([cg[@"pid"] intValue] == pid && [cg[@"windowID"] unsignedIntValue] == windowID) {
            NSMutableDictionary *updated = [cg mutableCopy];
            updated[@"frame"] = frame;
            self.cgWindows[i] = updated;
            break;
        }
    }
}

- (BOOL)accessibilityTrusted { return self.trusted; }

- (nullable NSArray<NSDictionary *> *)visibleWindows {
    self.readCount++;
    if (self.failVisibleWindows) return nil;
    return self.cgWindows.copy;
}

- (nullable NSRunningApplication *)applicationForPID:(pid_t)pid {
    YMFakeRunningApp *stored = self.appsByPID[@(pid)];
    if (!stored) return nil;
    if (!self.reboxApplicationWrappers) return (NSRunningApplication *)stored;
    YMFakeRunningApp *wrapper = [YMFakeRunningApp new];
    wrapper.processIdentifier = stored.processIdentifier;
    wrapper.terminated = stored.terminated;
    wrapper.bundleIdentifier = stored.bundleIdentifier;
    wrapper.bundleURL = stored.bundleURL;
    wrapper.localizedName = stored.localizedName;
    wrapper.access = stored.access;
    wrapper.lifecycleToken = stored.lifecycleToken;
    return (NSRunningApplication *)wrapper;
}

- (NSArray<NSRunningApplication *> *)applicationsForBundleIdentifier:(NSString *)bundleID {
    NSMutableArray *result = [NSMutableArray array];
    for (YMFakeRunningApp *app in self.appsByPID.allValues)
        if ([app.bundleIdentifier isEqual:bundleID]) [result addObject:(id)app];
    // Stable PID order so multi-process restore regressions hit process A before B.
    [result sortUsingComparator:^NSComparisonResult(YMFakeRunningApp *a, YMFakeRunningApp *b) {
        if (a.processIdentifier < b.processIdentifier) return NSOrderedAscending;
        if (a.processIdentifier > b.processIdentifier) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return result;
}

- (NSDictionary *)observeApplication:(NSRunningApplication *)application
                             deadline:(NSTimeInterval)deadline {
    self.observeCount++;
    pid_t pid = application.processIdentifier;
    [self.observedPIDs addObject:@(pid)];
    if (self.observeApplicationSideEffect) self.observeApplicationSideEffect(pid, deadline);
    if (self.forceIncompleteObserve || [self.forceIncompletePIDs containsObject:@(pid)])
        return @{@"windows": self.axByPID[@(pid)] ?: @[], @"complete": @NO,
                 @"reason": self.incompleteReason ?: @"timeout"};
    YMFakeRunningApp *app = self.appsByPID[@(pid)];
    if (!app || app.terminated)
        return @{@"windows": @[], @"complete": @NO, @"reason": @"processTerminated"};
    return @{@"windows": self.axByPID[@(pid)] ?: @[], @"complete": @YES, @"reason": @""};
}

- (nullable NSDictionary *)observeElement:(id)element {
    self.observeElementCount++;
    NSString *key = [self elementKey:element];
    if (self.flipIdentityOnNextObserveElement) {
        self.flipIdentityOnNextObserveElement = NO;
        self.mutateOnObserveElementCount = self.observeElementCount;
        self.observeElementMutation = @{@"startSecondsDelta": @1};
    }
    if (self.mutateOnObserveElementCount &&
        self.observeElementCount == self.mutateOnObserveElementCount) {
        [self applyObserveElementMutationForElement:element];
        self.mutateOnObserveElementCount = 0;
    }
    if (self.observeElementSideEffect) self.observeElementSideEffect(self.observeElementCount);
    NSDictionary *frame = self.elementFrames[key];
    NSDictionary *identity = self.elementIdentities[key];
    NSDictionary *state = self.elementStates[key];
    if (!frame || !identity) return nil;
    return @{@"identity": identity, @"frame": frame,
             @"ordinary": state[@"ordinary"] ?: @YES,
             @"minimized": state[@"minimized"] ?: @NO,
             @"readable": @YES,
             @"positionSettable": state[@"positionSettable"] ?: @YES,
             @"element": element};
}

- (nullable id)resolveIdentity:(NSDictionary *)identity error:(NSError **)error {
    for (NSString *key in self.elementIdentities) {
        if ([self.elementIdentities[key] isEqual:identity]) {
            for (NSArray *list in self.axByPID.allValues)
                for (NSDictionary *ax in list)
                    if ([ax[@"identity"] isEqual:identity]) return ax[@"element"];
        }
    }
    if (error) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    return nil;
}

- (BOOL)setPosition:(CGPoint)position element:(id)element
   expectedIdentity:(NSDictionary *)identity {
    NSString *key = [self elementKey:element];
    if (!YMWorkspaceSameWindowIdentity(self.elementIdentities[key], identity)) return NO;
    [self.positionWrites addObject:@{@"identity": identity, @"x": @(position.x), @"y": @(position.y),
        @"element": element ?: [NSNull null]}];
    self.writeCount++;
    if (self.failNextPositionWrites) {
        self.failNextPositionWrites -= 1;
        return NO;
    }
    NSDictionary *prior = self.elementFrames[key] ?: Frame(position.x, position.y, 100, 100);
    [self updateAXFrame:Frame(position.x, position.y,
                              [prior[@"width"] doubleValue], [prior[@"height"] doubleValue])
             forElement:element];
    return YES;
}

- (BOOL)setSize:(CGSize)size element:(id)element expectedIdentity:(NSDictionary *)identity {
    NSString *key = [self elementKey:element];
    if (!YMWorkspaceSameWindowIdentity(self.elementIdentities[key], identity)) return NO;
    [self.sizeWrites addObject:@{@"identity": identity, @"width": @(size.width), @"height": @(size.height),
        @"element": element ?: [NSNull null]}];
    self.writeCount++;
    NSDictionary *prior = self.elementFrames[key] ?: Frame(0, 0, size.width, size.height);
    [self updateAXFrame:Frame([prior[@"x"] doubleValue], [prior[@"y"] doubleValue], size.width, size.height)
             forElement:element];
    return YES;
}
@end

static NSURL *WriteTempFixtureApp(NSString *bundleID) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"yomado-mgr-%@", NSUUID.UUID.UUIDString]];
    NSString *appPath = [root stringByAppendingPathComponent:@"Calculator.app"];
    NSString *contents = [appPath stringByAppendingPathComponent:@"Contents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:contents withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSDictionary *plist = @{@"CFBundleIdentifier": bundleID,
                            @"CFBundleName": @"Calculator",
                            @"CFBundleExecutable": @"Calculator",
                            @"CFBundlePackageType": @"APPL"};
    [plist writeToURL:[NSURL fileURLWithPath:[contents stringByAppendingPathComponent:@"Info.plist"]]
              atomically:YES];
    return [NSURL fileURLWithPath:appPath];
}

#pragma mark - Workspace fixture

@interface YMAppWorkspace (RuntimePrivate)
@property(nonatomic, strong) id<YMWorkspaceWindowAccess> windowAccess;
@property(nonatomic, strong) NSMutableArray *placements;
@property(nonatomic, copy) NSArray *windows;
@property(nonatomic) BOOL inventoryValid;
@property(nonatomic) BOOL operationInProgress;
@property(nonatomic) NSUInteger inventoryGeneration;
- (void)scheduleInventoryRead:(dispatch_block_t)read;
- (void)publishInventoryRead:(dispatch_block_t)publish;
- (NSTimeInterval)inventoryTime;
- (NSArray<NSScreen *> *)workspaceScreens;
- (void)invalidateInventoryForMutation;
- (BOOL)displayStillCurrent:(NSDictionary *)display;
- (NSDictionary *)liveDisplayStateForID:(CGDirectDisplayID)ID;
- (BOOL)displayMatchesLiveTopology:(NSDictionary *)display;
- (BOOL)placeElement:(id)element frame:(NSDictionary *)frame display:(NSDictionary *)display
         application:(NSRunningApplication *)app expectedIdentity:(NSDictionary *)identity;
- (void)finishInventoryJobKey:(NSString *)jobKey generation:(NSUInteger)jobGeneration
                   cgSnapshot:(NSArray *)cgSnapshot trusted:(BOOL)trusted
                     complete:(BOOL)complete reason:(NSString *)reason
                     snapshot:(NSDictionary *)snapshot axRecords:(NSArray *)axRecords
                 observedApps:(NSDictionary *)observedApps;
- (void)scheduleInventoryIfNeeded;
- (void)publishWindows:(NSArray<NSDictionary *> *)windows ready:(BOOL)ready key:(NSString *)key
             generation:(NSUInteger)generation excludedKeys:(NSSet<NSString *> *)excludedKeys;
@end

@interface YMWorkspaceFixture : YMAppWorkspace
@property(nonatomic, strong) NSMutableArray *pendingReads;
@property(nonatomic, strong) NSMutableArray *pendingPublishes;
@property(nonatomic) NSTimeInterval clock;
@property(nonatomic) NSUInteger scheduleCount;
@property(nonatomic, strong) NSArray *fakeScreens;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *liveDisplayStates;
@end

@implementation YMWorkspaceFixture
- (instancetype)initWithWindowAccess:(id<YMWorkspaceWindowAccess>)access {
    self = [super initWithWindowAccess:access];
    if (!self) return nil;
    _pendingReads = [NSMutableArray array];
    _pendingPublishes = [NSMutableArray array];
    _clock = 1000;
    _fakeScreens = @[];
    _liveDisplayStates = [NSMutableDictionary dictionary];
    return self;
}

- (void)scheduleInventoryRead:(dispatch_block_t)read {
    self.scheduleCount++;
    [self.pendingReads addObject:[read copy]];
}

- (void)publishInventoryRead:(dispatch_block_t)publish {
    [self.pendingPublishes addObject:[publish copy]];
}

- (NSTimeInterval)inventoryTime { return self.clock; }

- (NSArray<NSScreen *> *)workspaceScreens { return self.fakeScreens ?: @[]; }

- (NSDictionary *)liveDisplayStateForID:(CGDirectDisplayID)ID {
    NSDictionary *override = self.liveDisplayStates[@(ID)];
    if (override) return override;
    // Default: mirror cached snapshot so inventory/move guards run production
    // comparison without touching CG/NSScreen.
    for (NSDictionary *display in [self valueForKey:@"displays"]) {
        if ([display[@"displayID"] unsignedIntValue] != ID) continue;
        return @{
            @"isActive": display[@"isActive"] ?: @NO,
            @"isOnline": display[@"isOnline"] ?: @NO,
            @"isInMirrorSet": @NO,
            @"mirrorsDisplay": @(kCGNullDirectDisplay),
            @"bounds": display[@"bounds"]
        };
    }
    return nil;
}

- (void)advanceClock:(NSTimeInterval)delta { self.clock += delta; }

- (void)finishNextRead {
    if (self.pendingReads.count) {
        dispatch_block_t read = self.pendingReads.firstObject;
        [self.pendingReads removeObjectAtIndex:0];
        read();
    }
    if (self.pendingPublishes.count) {
        dispatch_block_t publish = self.pendingPublishes.firstObject;
        [self.pendingPublishes removeObjectAtIndex:0];
        publish();
    }
}

- (void)drainReads {
    NSUInteger guard = 128;
    while ((self.pendingReads.count || self.pendingPublishes.count) && guard--)
        [self finishNextRead];
}

- (void)installPlacementElement:(id)element application:(YMFakeRunningApp *)app
                       windowID:(CGWindowID)windowID origin:(NSDictionary *)origin
                  lastDisplayID:(CGDirectDisplayID)lastDisplayID {
    [self installPlacementElement:element application:app windowID:windowID
                           origin:origin lastDisplayID:lastDisplayID identity:nil];
}

- (void)installPlacementElement:(id)element application:(YMFakeRunningApp *)app
                       windowID:(CGWindowID)windowID origin:(NSDictionary *)origin
                  lastDisplayID:(CGDirectDisplayID)lastDisplayID identity:(NSDictionary *)identity {
    Class cls = NSClassFromString(@"YMWPlacement");
    Check(cls != Nil, @"YMWPlacement class must be linked");
    id placement = [cls new];
    [placement setValue:element forKey:@"element"];
    [placement setValue:app forKey:@"application"];
    [placement setValue:app.bundleIdentifier forKey:@"bundleID"];
    [placement setValue:@(windowID) forKey:@"windowID"];
    [placement setValue:origin forKey:@"origin"];
    [placement setValue:@(lastDisplayID) forKey:@"lastDisplayID"];
    if (identity) [placement setValue:identity forKey:@"identity"];
    [[self valueForKey:@"placements"] addObject:placement];
}
@end

static YMWorkspaceFixture *FixtureWithThumbnail(YMFakeWindowAccess **outAccess) {
    YMFakeWindowAccess *access = [YMFakeWindowAccess new];
    [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
    // Task 2 small Stage Manager thumbnail on physical; real AX frame also physical.
    [access installWindowPID:42 windowID:1490
                     cgFrame:Frame(15, 982, 37, 102)
                     axFrame:Frame(830, 719, 230, 408)];
    YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
    if (outAccess) *outAccess = access;
    return workspace;
}

static YMWorkspaceFixture *ManagerFixture(YMFakeWindowAccess **outAccess, NSURL **outURL,
                                          NSDictionary *cgFrame, NSDictionary *axFrame) {
    NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
    YMFakeWindowAccess *access = [YMFakeWindowAccess new];
    [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
    [access installWindowPID:42 windowID:1490 cgFrame:cgFrame axFrame:axFrame];
    YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
    if (outAccess) *outAccess = access;
    if (outURL) *outURL = fixtureURL;
    return workspace;
}

int main(void) {
    @autoreleasepool {
        NSArray *displays = RuntimeDisplays();

        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSArray *physicalWindows = workspace.windows;
            __block NSUInteger callbacks = 0;
            workspace.inventoryDidChange = ^{ callbacks++; };
            [workspace publishWindows:physicalWindows ready:NO key:@"partial-physical"
                           generation:workspace.inventoryGeneration excludedKeys:nil];
            callbacks = 0;
            [workspace publishWindows:@[] ready:NO key:@"partial-empty"
                           generation:workspace.inventoryGeneration excludedKeys:nil];
            Check(callbacks == 1, @"physical-only row removal notifies while inventory stays incomplete");
            [workspace publishWindows:physicalWindows ready:NO key:@"partial-physical"
                           generation:workspace.inventoryGeneration excludedKeys:nil];
            Check(callbacks == 2, @"physical-only row arrival notifies without virtual rows changing");
            [workspace publishWindows:physicalWindows ready:NO key:@"partial-physical"
                           generation:workspace.inventoryGeneration excludedKeys:nil];
            Check(callbacks == 2, @"unchanged physical inventory does not loop callbacks");
            Check(!workspace.inventoryReady, @"physical row notifications do not authorize close");
            Check(access.writeCount == 0, @"physical row notification regression performs no window writes");
        }

        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(2700, 100, 230, 408)
                             axFrame:Frame(2700, 100, 230, 408)];
            [access installApp:77 name:@"Unresponsive" bundle:@"test.unresponsive"];
            [access installWindowPID:77 windowID:1770
                             cgFrame:Frame(100, 100, 400, 300)
                             axFrame:Frame(100, 100, 400, 300)];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"multi-app baseline is complete");
            [access.forceIncompletePIDs addObject:@77];
            // Even duplicate records from the failed PID must not poison a fully
            // observed app's presentation or become authority for any write.
            access.axByPID[@77] = @[access.axByPID[@77][0], access.axByPID[@77][0]];
            id element = access.axByPID[@42][0][@"element"];
            [access updateAXFrame:Frame(830, 719, 230, 408) forElement:element];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[workspace rowsForDisplayID:8] count] == 0,
                  @"unrelated PID failure does not leave returned Calculator on virtual screen");
            Check([[[workspace rowsForDisplayID:5] valueForKey:@"bundleIdentifier"]
                   containsObject:@"test.calculator"],
                  @"fully observed Calculator publishes physical return despite unrelated failure");
            Check(!workspace.inventoryReady, @"partial app presentation never becomes ready");
            Check([workspace needsRestoreForDisplayID:8], @"partial presentation retains close gate");
            NSError *error = nil;
            Check(![workspace restoreDisplayID:8 error:&error], @"partial display rows cannot authorize close");
            Check([workspace restartOriginCheckpointsWithError:&error] == nil,
                  @"partial display rows cannot authorize update export");
            Check(access.writeCount == 0, @"partial inventory and blocked gates perform no writes");
        }

        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [access installApp:77 name:@"Unresponsive" bundle:@"test.unresponsive"];
            [access installWindowPID:77 windowID:1770
                             cgFrame:Frame(100, 100, 400, 300)
                             axFrame:Frame(100, 100, 400, 300)];
            [access.forceIncompletePIDs addObject:@77];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[[workspace rowsForDisplayID:5] valueForKey:@"bundleIdentifier"]
                   containsObject:@"test.calculator"],
                  @"initial partial inventory still shows fully observed physical app");
            Check(!workspace.inventoryReady, @"initial partial inventory remains fail-closed");
        }

        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (pid_t pid = 100; pid <= 106; pid++) {
                [access installApp:pid name:@"Budget fixture"
                            bundle:[NSString stringWithFormat:@"test.budget.%d", pid]];
                [access installWindowPID:pid windowID:(CGWindowID)(2000 + pid)
                                 cgFrame:Frame(100, 100, 400, 300)
                                 axFrame:Frame(100, 100, 400, 300)];
                if (pid != 106) [access.forceIncompletePIDs addObject:@(pid)];
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            __weak YMWorkspaceFixture *weakWorkspace = workspace;
            access.observeApplicationSideEffect = ^(pid_t pid, NSTimeInterval deadline) {
                YMWorkspaceFixture *current = weakWorkspace;
                Check(deadline - current.clock <= 0.200001, @"each PID gets a bounded share of inventory budget");
                if (pid != 106) current.clock = deadline;
            };
            BOOL healthyAppPublished = NO;
            NSDictionary *healthyCG = access.cgWindows.lastObject;
            for (NSUInteger round = 0; round < 3; round++) {
                NSMutableArray *reordered = [access.cgWindows mutableCopy];
                [reordered removeObject:healthyCG];
                NSUInteger cursor = [[workspace valueForKey:@"inventoryPIDCursor"] unsignedIntegerValue];
                [reordered insertObject:healthyCG atIndex:(cursor + 6) % 7];
                [access.cgWindows setArray:reordered];
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
                [workspace drainReads];
                if ([[[workspace rowsForDisplayID:5] valueForKey:@"bundleIdentifier"]
                     containsObject:@"test.budget.106"]) healthyAppPublished = YES;
                Check(!workspace.inventoryReady, @"budget-exhausted rounds remain incomplete");
                [workspace advanceClock:1.1];
            }
            Check([access.observedPIDs containsObject:@106], @"slow leading PIDs cannot starve trailing app forever");
            Check(healthyAppPublished, @"healthy app publishes despite adversarial CG Z-order changes");
            Check(access.writeCount == 0, @"budget fairness never writes or activates apps");
        }

        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            YMFakeRunningApp *system = [access installApp:999 name:@"System surface" bundle:@""];
            system.bundleURL = nil;
            [access.cgWindows addObject:@{@"pid": @999, @"windowID": @9990,
                @"frame": Frame(100, 100, 200, 200), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @9991,
                @"frame": Frame(100, 100, 200, 200), @"layer": @101, @"onScreen": @YES, @"alpha": @1}];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger generation = workspace.inventoryGeneration;
            NSUInteger schedules = workspace.scheduleCount;
            for (NSUInteger index = 1; index < access.cgWindows.count; index++) {
                NSMutableDictionary *changed = [access.cgWindows[index] mutableCopy];
                changed[@"frame"] = Frame(200, 200, 300, 300);
                access.cgWindows[index] = changed;
            }
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryGeneration == generation,
                  @"classified system and non-candidate surfaces do not churn generation");
            Check(workspace.scheduleCount == schedules, @"irrelevant CG churn does not discard and restart AX job");
            Check(workspace.inventoryReady, @"current app evidence publishes despite irrelevant CG movement");
            Check([[workspace rowsForDisplayID:5] count] == 1, @"system churn cannot hide Calculator row");
        }

        for (NSNumber *trusted in @[@YES, @NO]) {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            access.trusted = trusted.boolValue;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"empty baseline ready before unresolved process appears");
            [access.cgWindows addObject:@{@"pid": @999, @"windowID": @77,
                @"frame": Frame(2800, 200, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(!workspace.inventoryReady, @"unresolved visible process cannot reuse empty ready TTL");
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"unresolved visible process stays pending after observation");
            Check([workspace needsRestoreForDisplayID:8], @"unresolved process retains virtual display");
            NSError *error = nil;
            Check(![workspace restoreDisplayID:8 error:&error], @"unresolved process refuses empty close");
            Check([workspace restartOriginCheckpointsWithError:&error] == nil,
                  @"unresolved process refuses empty export");
            Check(access.writeCount == 0, @"unresolved-process guard performs no window writes");
            [access.cgWindows removeAllObjects];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"empty inventory can recover after unresolved surface disappears");
        }

        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSUInteger schedules = workspace.scheduleCount;
            [access updateAXFrame:Frame(2700, 100, 230, 408)
                      forElement:access.axByPID[@42][0][@"element"]];
            [workspace invalidateInventoryForMutation];
            [workspace drainReads];
            Check(workspace.scheduleCount == schedules + 1,
                  @"post-mutation inventory captures fresh CG before scheduling, without stale first pass");
            Check([[workspace rowsForDisplayID:8] count] == 1, @"fresh post-mutation pass publishes destination");
        }

        {
            YMFakeWindowAccess *access = nil;
            NSURL *url = nil;
            NSDictionary *origin = Frame(830, 719, 230, 408);
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &url, origin, origin);
            [access installApp:1014 name:@"WindowManager" bundle:@"com.apple.WindowManager"
                     bundleURL:[NSURL fileURLWithPath:@"/System/Library/CoreServices/WindowManager.app"]];
            [access.cgWindows addObjectsFromArray:@[
                @{@"pid": @1014, @"windowID": @705, @"frame": Frame(15, 982, 37, 102),
                  @"layer": @0, @"onScreen": @YES, @"alpha": @1},
                @{@"pid": @1014, @"windowID": @5430, @"frame": Frame(2700, 100, 1800, 1000),
                  @"layer": @0, @"onScreen": @YES, @"alpha": @1}
            ]];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"real-path Stage Manager surfaces without AX windows do not block inventory");
            Check(![access.observedPIDs containsObject:@1014], @"system presentation process is not enumerated as ordinary app");
            Check([[workspace rowsForDisplayID:5] count] == 1, @"physical rows include Calculator but not WindowManager");
            Check([[workspace rowsForDisplayID:8] count] == 0, @"large virtual system surface is not an app window");
            NSError *error = nil;
            BOOL moved = [workspace moveApplicationAtURL:url fromDisplayID:5 toDisplayID:8 error:&error];
            [workspace drainReads];
            Check(moved && workspace.inventoryReady, @"ordinary window move remains ready alongside system surfaces");
            BOOL restored = [workspace restoreDisplayID:8 error:&error];
            Check(restored, @"close restore can return Calculator despite Stage Manager surfaces");
            Check(YMWorkspaceSameFrame(access.currentFrame, origin), @"close restore retains original Calculator geometry");
            for (NSDictionary *write in access.positionWrites)
                Check([write[@"identity"][@"pid"] intValue] == 42, @"close never writes system presentation windows");
            [[NSFileManager defaultManager] removeItemAtURL:[url URLByDeletingLastPathComponent] error:nil];
        }

        for (NSNumber *trusted in @[@YES, @NO]) {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            access.trusted = trusted.boolValue;
            [access installApp:1014 name:@"WindowManager" bundle:@"com.apple.WindowManager"
                     bundleURL:[NSURL fileURLWithPath:@"/System/Library/CoreServices/WindowManager.app"]];
            [access.cgWindows addObject:@{@"pid": @1014, @"windowID": @5430,
                @"frame": Frame(2700, 100, 1800, 1000), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"known system-only surface is empty ordinary inventory with or without AX");
            Check([[workspace rowsForDisplayID:8] count] == 0, @"no-AX fallback also excludes system presentation surface");
            NSMutableDictionary *malformed = [access.cgWindows[0] mutableCopy];
            [malformed removeObjectForKey:@"alpha"];
            access.cgWindows[0] = malformed;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"malformed system-owner metadata still fails closed");
        }

        for (NSDictionary *spoof in @[
            @{@"bundle": @"com.apple.WindowManager", @"path": @"/Applications/WindowManager.app"},
            @{@"bundle": @"test.other-app", @"path": @"/System/Library/CoreServices/WindowManager.app"}
        ]) {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:1014 name:@"Not verified system process" bundle:spoof[@"bundle"]
                     bundleURL:[NSURL fileURLWithPath:spoof[@"path"]]];
            [access.cgWindows addObject:@{@"pid": @1014, @"windowID": @5430,
                @"frame": Frame(2700, 100, 1800, 1000), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"matching only system name or path cannot bypass unmatched AX blocker");
            Check([workspace needsRestoreForDisplayID:8], @"unverified system lookalike retains close gate");
            Check([access.observedPIDs containsObject:@1014], @"system lookalike is still observed as an ordinary app");
        }

        // --- Group 0 / Step 1 smoke: pending then publish small thumbnail ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(!workspace.inventoryReady, @"pending metadata is not a verified empty display");
            Check([workspace needsRestoreForDisplayID:8], @"pending read keeps display alive");
            [workspace drainReads];
            Check([[workspace rowsForDisplayID:5] count] == 1,
                  @"small thumbnail publishes its real app row");
            Check(workspace.inventoryReady, @"complete current metadata publishes ready state");
            NSDictionary *row = [workspace rowsForDisplayID:5].firstObject;
            Check([row[@"appName"] isEqual:@"Calculator"], @"main thread assembles fake appName");
            Check([row[@"bundleIdentifier"] isEqual:@"test.calculator"], @"bundle comes from fake app");
            Check(access.observeCount == 1, @"one observeApplication per PID");
        }

        // --- Group 1: coalesce 30 refreshes; stale generation discarded ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger firstSchedules = workspace.scheduleCount;
            for (NSUInteger i = 0; i < 30; i++)
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == firstSchedules,
                  @"same key refresh 30 times schedules only one job");
            Check(workspace.pendingReads.count == 1, @"at most one in-flight read block");

            // Change owned IDs while the first job is still pending; coalescing keeps
            // a single in-flight slot and remembers the latest request.
            [workspace refreshWithVirtualDisplayIDs:@[@9] displaySnapshot:displays];
            Check(workspace.scheduleCount == firstSchedules,
                  @"owned ID change while in-flight does not start a second concurrent job");
            Check(workspace.pendingReads.count == 1, @"still one in-flight read block");
            [workspace finishNextRead];
            Check(!workspace.inventoryReady, @"stale generation must not publish ready");
            Check([[workspace rowsForDisplayID:8] count] == 0,
                  @"cancelled screen cannot be reassigned by stale result");
            // Discard schedules the latest generation job.
            Check(workspace.scheduleCount == firstSchedules + 1,
                  @"discarded stale result merges the latest topology request");
            [workspace drainReads];
            Check(workspace.inventoryReady, @"fresh generation publishes after drain");
            Check([[workspace rowsForDisplayID:8] count] == 0,
                  @"screen 8 stays unowned after switching to screen 9");
        }

        // --- Group 2: timeout / PID failure / CG failure / trust revoke / true empty ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.forceIncompleteObserve = YES;
            access.incompleteReason = @"timeout";
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"round timeout is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"timeout keeps needsRestore");
            NSError *error = nil;
            Check(![workspace restoreDisplayID:8 error:&error], @"timeout refuses restoreDisplayID");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.forceIncompleteObserve = YES;
            access.incompleteReason = @"incompleteMetadata";
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"PID observe failure is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"PID failure keeps needsRestore");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.failVisibleWindows = YES;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(!workspace.inventoryReady, @"CG failure is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"CG failure keeps needsRestore");
            NSError *error = nil;
            Check(![workspace restoreDisplayID:8 error:&error], @"CG failure refuses restoreDisplayID");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"trusted complete inventory is ready before revoke");
            access.trusted = NO;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            // No AX: pure CG path. Small thumbnail fails old size gate → not shown,
            // but unresolved small candidate must not prove any owned virtual empty.
            Check(!workspace.inventoryReady,
                  @"unknown no-AX thumbnail does not publish ready empty proof");
            Check([workspace needsRestoreForDisplayID:8],
                  @"unknown no-AX thumbnail keeps needsRestore on owned virtual");
            NSError *revokeError = nil;
            Check(![workspace restoreDisplayID:8 error:&revokeError],
                  @"unknown no-AX thumbnail refuses restoreDisplayID");
            // Large CG on virtual without AX should show and allow classification.
            [access.cgWindows removeAllObjects];
            [access.axByPID removeAllObjects];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[workspace rowsForDisplayID:8] count] == 1, @"no-AX large CG still displays");
            Check([workspace needsRestoreForDisplayID:8], @"no-AX window on virtual keeps restore need");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"true empty inventory can be ready");
            Check(![workspace needsRestoreForDisplayID:8], @"true empty without placements may close");
            NSError *error = nil;
            Check([workspace restoreDisplayID:8 error:&error], @"true empty restoreDisplayID succeeds");
        }

        // --- Group 3: mutation invalidates old job; UI rows may linger; close/export blocked ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"baseline ready before mutation");
            NSUInteger rowsBefore = [workspace rowsForDisplayID:5].count;
            [workspace invalidateInventoryForMutation];
            Check(!workspace.inventoryReady, @"mutation invalidates ready immediately");
            Check([workspace rowsForDisplayID:5].count == rowsBefore, @"UI rows may linger after invalidate");
            Check([workspace needsRestoreForDisplayID:8], @"close gate blocked after mutation");
            NSError *error = nil;
            Check(![workspace restartOriginCheckpointsWithError:&error],
                  @"update export blocked while inventory unconfirmed");
            [workspace drainReads];
        }

        // --- Group 4: CG order change does not starve; cache expires after 1s ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [access installApp:77 name:@"Notes" bundle:@"test.notes"];
            [access installWindowPID:77 windowID:2001
                             cgFrame:Frame(100, 100, 200, 200)
                             axFrame:Frame(100, 100, 200, 200)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSUInteger schedules = workspace.scheduleCount;
            NSUInteger observes = access.observeCount;
            // Reverse CG order, same set.
            NSArray *reversed = [[access.cgWindows reverseObjectEnumerator] allObjects];
            [access.cgWindows removeAllObjects];
            [access.cgWindows addObjectsFromArray:reversed];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedules,
                  @"CG order change with same set does not schedule a new job");
            Check(access.observeCount == observes, @"same normalized key reuses observation");
            Check(workspace.inventoryReady, @"cache still authorizes close within 1s");
            [workspace advanceClock:1.01];
            Check(!workspace.inventoryReady, @"cache older than 1s no longer authorizes close");
            Check([workspace needsRestoreForDisplayID:8], @"expired cache keeps needsRestore");
        }

        // --- Group 6: checkpoint retirement uses independent cgFrame + job AX ---
        {
            // Delayed physical CG A + different physical AX B: keep. Using frame as
            // cgFrame would wrongly confirm (SameFrame(ax,ax) on physical).
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *physicalCG = Frame(100, 100, 230, 408);
            NSDictionary *physicalAX = Frame(500, 200, 230, 408);
            id element = @"el-checkpoint-disagree";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = physicalAX;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": physicalCG, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": physicalAX, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(physicalCG, RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            NSUInteger elementObservesBefore = access.observeElementCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSArray *placements = [workspace valueForKey:@"placements"];
            Check(placements.count == 1,
                  @"disagreeing physical CG+AX must not retire checkpoint");
            NSDictionary *published = nil;
            for (NSDictionary *window in workspace.windows)
                if ([window[@"windowID"] unsignedIntValue] == 1490) published = window;
            Check(published[@"cgFrame"] != nil, @"published window retains cgFrame");
            Check([published[@"cgFrame"] isEqual:physicalCG],
                  @"cgFrame must stay independent raw CG, not normalizer.frame");
            Check([published[@"frame"] isEqual:physicalAX], @"frame uses AX geometry");
            Check(!YMWorkspacePhysicalReturnConfirmed(published[@"cgFrame"], published[@"frame"],
                                                      displays, NO),
                  @"independent disagreeing cgFrame+AX keep checkpoint");
            Check(YMWorkspacePhysicalReturnConfirmed(published[@"frame"], published[@"frame"],
                                                     displays, NO),
                  @"using normalizer.frame as cgFrame would wrongly confirm physical return");
            Check(access.observeElementCount == elementObservesBefore,
                  @"checkpoint retirement must not sync observeElement on publish");
        }
        {
            // Agreeing physical CG+AX enters physical-return branch and clears.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *physical = Frame(830, 675, 230, 408);
            id element = @"el-checkpoint-agree";
            NSDictionary *identity = Identity(42, 1491);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = physical;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1491,
                @"frame": physical, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": physical, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(physical, RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1491
                                        origin:origin lastDisplayID:8];
            NSUInteger elementObservesBefore = access.observeElementCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSArray *placements = [workspace valueForKey:@"placements"];
            Check(placements.count == 0,
                  @"agreeing physical CG+AX retires checkpoint via physical-return branch");
            Check(access.observeElementCount == elementObservesBefore,
                  @"physical-return retirement uses job AX evidence, not sync observeElement");
        }

        // --- Group 7: callback on main; incomplete failure path terminates ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            __block NSUInteger callbacks = 0;
            __block BOOL sawOffMain = NO;
            __weak YMWorkspaceFixture *weakWorkspace = workspace;
            workspace.inventoryDidChange = ^{
                if (![NSThread isMainThread]) sawOffMain = YES;
                callbacks++;
                YMWorkspaceFixture *strong = weakWorkspace;
                if (strong)
                    [strong refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            };
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(callbacks == 1, @"callback fires once on first publish");
            Check(!sawOffMain, @"callback runs on main thread");
            NSUInteger schedules = workspace.scheduleCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedules, @"callback-driven same-key refresh does not loop");
            Check(callbacks == 1, @"same-key reuse does not reenter callback");
            workspace = nil;
            Check(weakWorkspace == nil || callbacks >= 1, @"callback captures workspace weakly");
        }
        {
            // Incomplete same-key: notify only on real change; bounded reuse; no close;
            // callback-driven refresh must terminate without a new job.
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.forceIncompleteObserve = YES;
            access.incompleteReason = @"timeout";
            __block NSUInteger callbacks = 0;
            __weak YMWorkspaceFixture *weakWorkspace = workspace;
            workspace.inventoryDidChange = ^{
                callbacks++;
                YMWorkspaceFixture *strong = weakWorkspace;
                if (strong)
                    [strong refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            };
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSUInteger schedulesAfterFail = workspace.scheduleCount;
            NSUInteger callbacksAfterFail = callbacks;
            Check(!workspace.inventoryReady, @"incomplete observation is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"incomplete never authorizes close");
            Check(workspace.pendingReads.count == 0, @"failure path has no leftover in-flight job");
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedulesAfterFail,
                  @"same-key incomplete result reuses observation without new job");
            Check(workspace.pendingReads.count == 0,
                  @"callback-driven refresh on failure path does not restart a job");
            [workspace drainReads];
            Check(callbacks == callbacksAfterFail,
                  @"same-key incomplete reuse does not reenter callback");
            Check(callbacks <= 2, @"incomplete failure path does not spin callbacks");
        }

        // --- Fix2 / Important 1: write-in-flight must not rewrite placement ownership ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *virtualFrame = Frame(2700, 100, 230, 408);
            id element = @"el-write-ownership";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = virtualFrame;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": virtualFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": virtualFrame, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(Frame(100, 100, 230, 408),
                                                     RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            // Schedule observation, then enter a write before it publishes — mirrors
            // placeElement runloop allowing an in-flight job to finish mid-move.
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            Check(workspace.pendingReads.count == 1, @"write probe starts with one pending job");
            id placement = [[workspace valueForKey:@"placements"] firstObject];
            // A→B move already recorded; stale observation still shows screen A (8).
            [placement setValue:@9 forKey:@"lastDisplayID"];
            workspace.operationInProgress = YES;
            [workspace invalidateInventoryForMutation];
            Check(workspace.pendingReads.count == 1,
                  @"invalidate during write does not schedule an additional job");
            [workspace finishNextRead]; // in-flight job completes during write
            Check([[placement valueForKey:@"lastDisplayID"] unsignedIntValue] == 9,
                  @"write-in-flight publish must not revert placement ownership to stale screen");
            Check(!workspace.inventoryReady,
                  @"write-in-flight inventory must not publish ready");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"target-screen placement record must survive stale publish during write");
            workspace.operationInProgress = NO;
            [workspace invalidateInventoryForMutation];
            [workspace drainReads];
            Check(workspace.pendingReads.count == 0,
                  @"bounded reads resume after write ends");
        }

        // --- Fix2 / Important 2: publish revalidates live topology ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            YMFakeRunningApp *app = access.appsByPID[@42];
            id element = access.axByPID[@42].firstObject[@"element"];
            NSDictionary *origin = YMWorkspaceOrigin(Frame(830, 719, 230, 408),
                                                     RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.pendingReads.count == 1, @"topology probe schedules one job");
            // Inject a real bounds drift on the physical screen — production
            // comparison must reject without a blunt displayStillCurrent override.
            workspace.liveDisplayStates[@5] = @{
                @"isActive": @YES, @"isOnline": @YES,
                @"isInMirrorSet": @NO, @"mirrorsDisplay": @(kCGNullDirectDisplay),
                @"bounds": Frame(99, 0, 2560, 1440)
            };
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"stale topology must not publish ready without manager refresh");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"stale topology must not retire checkpoints");
        }

        // --- Fix4 / P2: stable inactive-online must not block inventory ready ---
        {
            NSArray *withInactive = @[
                RuntimeDisplay(5, 0, NO, @"physical"),
                @{@"displayID": @7, @"displayUUID": @"sidecar-inactive",
                  @"bounds": Frame(7680, 0, 1920, 1080), @"isMain": @NO,
                  @"isActive": @NO, @"isOnline": @YES, @"isVirtual": @NO},
                RuntimeDisplay(8, 2560, YES, @"agent-a"),
                RuntimeDisplay(9, 5120, YES, @"agent-b")
            ];
            {
                YMFakeWindowAccess *access = nil;
                YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:withInactive];
                [workspace drainReads];
                Check(workspace.inventoryReady,
                      @"stable inactive online display must not block inventory ready");
                Check([[workspace rowsForDisplayID:5] count] == 1,
                      @"active virtual inventory still publishes with inactive sidecar");
                NSDictionary *inactive = nil;
                for (NSDictionary *display in [workspace valueForKey:@"displays"]) {
                    if ([display[@"displayID"] unsignedIntValue] == 7) { inactive = display; break; }
                }
                Check(inactive != nil, @"inactive sidecar remains in cached displays");
                Check(![workspace displayStillCurrent:inactive],
                      @"displayStillCurrent must still reject inactive move targets");
                Check([workspace displayMatchesLiveTopology:inactive],
                      @"inventory topology match allows stable inactive online");
            }
            // Inject drift before publish so production comparison rejects (same-key
            // TTL reuse would skip a post-ready refresh).
            {
                YMFakeWindowAccess *access = nil;
                YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:withInactive];
                workspace.liveDisplayStates[@7] = @{
                    @"isActive": @YES, @"isOnline": @YES,
                    @"isInMirrorSet": @NO, @"mirrorsDisplay": @(kCGNullDirectDisplay),
                    @"bounds": Frame(7680, 0, 1920, 1080)
                };
                [workspace drainReads];
                Check(!workspace.inventoryReady,
                      @"inactive→active live drift must refuse inventory publish");
                Check([workspace needsRestoreForDisplayID:8],
                      @"topology drift keeps needsRestore / blocks empty close");
            }
            {
                YMFakeWindowAccess *access = nil;
                YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:withInactive];
                workspace.liveDisplayStates[@8] = @{
                    @"isActive": @YES, @"isOnline": @NO,
                    @"isInMirrorSet": @NO, @"mirrorsDisplay": @(kCGNullDirectDisplay),
                    @"bounds": Frame(2560, 0, 2560, 1440)
                };
                [workspace drainReads];
                Check(!workspace.inventoryReady,
                      @"owned display online→offline drift must refuse inventory publish");
            }
            {
                YMFakeWindowAccess *access = nil;
                YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:withInactive];
                workspace.liveDisplayStates[@8] = @{
                    @"isActive": @YES, @"isOnline": @YES,
                    @"isInMirrorSet": @YES, @"mirrorsDisplay": @(5),
                    @"bounds": Frame(2560, 0, 2560, 1440)
                };
                [workspace drainReads];
                Check(!workspace.inventoryReady,
                      @"owned display mirror drift must refuse inventory publish");
            }
            {
                YMFakeWindowAccess *access = nil;
                YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:withInactive];
                workspace.liveDisplayStates[@5] = @{
                    @"isActive": @YES, @"isOnline": @YES,
                    @"isInMirrorSet": @NO, @"mirrorsDisplay": @(kCGNullDirectDisplay),
                    @"bounds": Frame(10, 0, 2560, 1440)
                };
                [workspace drainReads];
                Check(!workspace.inventoryReady,
                      @"bounds drift must refuse inventory publish");
            }
        }

        // --- Fix2 / Important 3: normalizer uses admitted app set ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(2700, 100, 400, 300)
                             axFrame:Frame(2700, 100, 400, 300)];
            // Layer-zero system surface without bundle admission.
            YMFakeRunningApp *system = [access installApp:999 name:@"System surface" bundle:@""];
            system.bundleURL = nil;
            [access.cgWindows addObject:@{@"pid": @999, @"windowID": @77,
                @"frame": Frame(2800, 200, 120, 90), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"non-admitted system surface must not create unmatched blockers");
            Check([[workspace rowsForDisplayID:8] count] == 1,
                  @"admitted app still publishes");

            // Admitted app with CG but missing AX remains unknown — not silently skipped.
            YMFakeWindowAccess *unknownAccess = [YMFakeWindowAccess new];
            [unknownAccess installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [unknownAccess.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *unknownWS = [[YMWorkspaceFixture alloc] initWithWindowAccess:unknownAccess];
            [unknownWS refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [unknownWS drainReads];
            Check(!unknownWS.inventoryReady,
                  @"admitted app with unknown AX metadata still refuses ready");
        }

        // --- Fix2 / Important 4: retained checkpoint must not silent-export empty ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            // Independent evidence disagree: CG still virtual, AX already physical.
            NSDictionary *cgVirtual = Frame(2700, 100, 230, 408);
            NSDictionary *axPhysical = Frame(830, 675, 230, 408);
            id element = @"el-retained-checkpoint";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = axPhysical;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": cgVirtual, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": axPhysical, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(axPhysical, RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"disagreeing CG/AX inventory can still be ready");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"disagreeing evidence retains checkpoint");
            NSError *exportError = nil;
            NSArray *exported = [workspace restartOriginCheckpointsWithError:&exportError];
            Check(exported == nil && exportError != nil,
                  @"retained checkpoint absent from owned windows must export error, not empty success");
        }

        // --- Fix2 / Important 5: observed trust/CG source transitions bump generation ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger gen0 = workspace.inventoryGeneration;
            Check(workspace.pendingReads.count == 1, @"trust probe starts with one job");
            // YES → NO → YES while first job still in-flight.
            access.trusted = NO;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterNO = workspace.inventoryGeneration;
            Check(genAfterNO > gen0, @"observed trust YES→NO advances generation");
            access.trusted = YES;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterYES = workspace.inventoryGeneration;
            Check(genAfterYES > genAfterNO, @"observed trust NO→YES advances generation again");
            [workspace finishNextRead]; // completes the original in-flight job
            Check(!workspace.inventoryReady,
                  @"old job must not revive on final equal key after trust flap");
            [workspace drainReads];
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger gen0 = workspace.inventoryGeneration;
            // Source A → B → A while first job in-flight.
            NSDictionary *altFrame = Frame(100, 100, 200, 200);
            [access.cgWindows removeAllObjects];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": altFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterB = workspace.inventoryGeneration;
            Check(genAfterB > gen0, @"observed CG source A→B advances generation");
            [access.cgWindows removeAllObjects];
            [access.axByPID removeAllObjects];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(15, 982, 37, 102)
                             axFrame:Frame(830, 719, 230, 408)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterA = workspace.inventoryGeneration;
            Check(genAfterA > genAfterB, @"observed CG source B→A advances generation again");
            [workspace finishNextRead];
            Check(!workspace.inventoryReady,
                  @"old job must not revive on final equal CG key after source flap");
            [workspace drainReads];
        }

        // --- Fix2 / Important 6: exact budget ceilings remain complete ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (NSUInteger i = 0; i < 64; i++) {
                pid_t pid = (pid_t)(1000 + i);
                [access installApp:pid name:[NSString stringWithFormat:@"App%lu", (unsigned long)i]
                            bundle:[NSString stringWithFormat:@"test.app%lu", (unsigned long)i]];
                [access installWindowPID:pid windowID:(CGWindowID)(2000 + i)
                                 cgFrame:Frame(2700, 100, 200, 200)
                                 axFrame:Frame(2700, 100, 200, 200)];
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 64 PIDs remains a complete observation");
            Check(access.observedPIDs.count == 64, @"exactly 64 PIDs are all observed");

            pid_t extra = 1064;
            [access installApp:extra name:@"Extra" bundle:@"test.extra"];
            [access installWindowPID:extra windowID:2064
                             cgFrame:Frame(2700, 100, 200, 200)
                             axFrame:Frame(2700, 100, 200, 200)];
            [access.observedPIDs removeAllObjects];
            access.observeCount = 0;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"65 PIDs is truncated and incomplete");
            Check(access.observedPIDs.count == 64,
                  @"exactly 64 of 65 PIDs are observed; the extra is truncated");
            Check(![access.observedPIDs containsObject:@(extra)],
                  @"65th PID is not observed after the ceiling");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (NSUInteger i = 0; i < 512; i++) {
                // Same PID so PID cap does not trip; exercise CG candidate ceiling.
                if (i == 0) [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
                CGWindowID wid = (CGWindowID)(3000 + i);
                NSDictionary *frame = Frame(2700 + (i % 10), 100 + (i % 20), 200, 200);
                [access.cgWindows addObject:@{@"pid": @42, @"windowID": @(wid),
                    @"frame": frame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
                NSMutableArray *list = [access.axByPID[@42] mutableCopy] ?: [NSMutableArray array];
                id element = [NSString stringWithFormat:@"el-cg-%u", wid];
                NSDictionary *identity = Identity(42, wid);
                [list addObject:@{@"identity": identity, @"frame": frame, @"ordinary": @YES,
                    @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
                access.axByPID[@42] = list;
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 512 CG candidates remains complete");

            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @9999,
                @"frame": Frame(2710, 110, 200, 200), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            NSMutableArray *list = [access.axByPID[@42] mutableCopy];
            [list addObject:@{@"identity": Identity(42, 9999),
                @"frame": Frame(2710, 110, 200, 200), @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                @"element": @"el-cg-9999"}];
            access.axByPID[@42] = list;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"513 CG candidates is incomplete");
        }
        {
            // Boundary neighbors: 63 PIDs complete; 511 candidates complete.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (NSUInteger i = 0; i < 63; i++) {
                pid_t pid = (pid_t)(2000 + i);
                [access installApp:pid name:[NSString stringWithFormat:@"P%lu", (unsigned long)i]
                            bundle:[NSString stringWithFormat:@"test.p%lu", (unsigned long)i]];
                [access installWindowPID:pid windowID:(CGWindowID)(4000 + i)
                                 cgFrame:Frame(2700, 100, 200, 200)
                                 axFrame:Frame(2700, 100, 200, 200)];
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 63 PIDs remains complete");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            for (NSUInteger i = 0; i < 511; i++) {
                CGWindowID wid = (CGWindowID)(5000 + i);
                NSDictionary *frame = Frame(2700, 100, 200, 200);
                [access.cgWindows addObject:@{@"pid": @42, @"windowID": @(wid),
                    @"frame": frame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
                NSMutableArray *list = [access.axByPID[@42] mutableCopy] ?: [NSMutableArray array];
                [list addObject:@{@"identity": Identity(42, wid), @"frame": frame, @"ordinary": @YES,
                    @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                    @"element": [NSString stringWithFormat:@"el-511-%u", wid]}];
                access.axByPID[@42] = list;
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 511 CG candidates remains complete");
        }

        // --- Fix2 / no-AX acceptance remnant: illegal CG and over-cap tail ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            // Missing layer/onScreen/alpha: dropped by both Visible and ClearlyInvisible.
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300)}];
            access.trusted = NO;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"illegal/missing CG fields must not publish empty no-AX ready");
            Check([workspace needsRestoreForDisplayID:8],
                  @"illegal/missing CG keeps needsRestore");
        }

        // --- Fix3: trusted AX path must keep unclassifiable CG fail-closed ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            // Missing layer/onScreen/alpha — admission Visible drops it before normalizer.
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300)}];
            access.trusted = YES;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"trusted illegal/missing CG fields must not publish ready");
            Check([workspace needsRestoreForDisplayID:8],
                  @"trusted illegal/missing CG keeps needsRestore");
            NSError *restoreError = nil;
            Check(![workspace restoreDisplayID:8 error:&restoreError],
                  @"trusted illegal CG refuses restoreDisplayID empty close");
        }
        {
            // Missing identity must also block trusted ready (not only visibility fields).
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access.cgWindows addObject:@{@"pid": @42,
                @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.trusted = YES;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"trusted CG missing identity must not publish ready");
            Check([workspace needsRestoreForDisplayID:8],
                  @"trusted CG missing identity keeps needsRestore");
        }
        {
            // Mixed: one legal AX-matched window + one unclassifiable sibling.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(2700, 100, 400, 300)
                             axFrame:Frame(2700, 100, 400, 300)];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1491,
                @"frame": Frame(2800, 200, 400, 300)}];
            access.trusted = YES;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"trusted mixed legal+illegal CG must not publish ready");
            Check([workspace needsRestoreForDisplayID:8],
                  @"trusted mixed legal+illegal CG keeps needsRestore");
            Check([[workspace rowsForDisplayID:8] count] == 1,
                  @"trusted mixed case still publishes the legal window row");
        }
        {
            // Over-cap tail unknown must not be missed after truncation.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            for (NSUInteger i = 0; i < 512; i++) {
                [access.cgWindows addObject:@{@"pid": @42, @"windowID": @(6000 + i),
                    @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            }
            // 513th: small unknown thumbnail beyond the admitted truncation set.
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @9998,
                @"frame": Frame(15, 982, 37, 102), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.trusted = NO;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"over-cap unknown tail must not authorize empty no-AX close");
        }

        // --- Task 5: real manager entry + exact identity move/restore ---
        {
            // Step 1 smoke: Stage Manager thumbnail through public move/restore.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            NSDictionary *originalFrame = Frame(830, 719, 230, 408);
            NSDictionary *identity = Identity(42, 1490);
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(15, 982, 37, 102), originalFrame);
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            // Do not drain: selected-app move must not require global UI ready.
            Check(!workspace.inventoryReady, @"move probe starts without inventory ready");
            NSError *error = nil;
            NSUInteger activationsBefore = access.activationRequests;
            BOOL moved = [workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8
                                                   error:&error];
            Check(moved, @"Stage Manager thumbnail moves through the real manager entry point");
            Check(access.positionWrites.count == 1, @"only the selected window is written");
            if (access.positionWrites.count)
                Check([access.positionWrites[0][@"identity"] isEqual:identity],
                      @"write targets exact identity");
            else
                Check(NO, @"write targets exact identity");
            Check(access.activationRequests == activationsBefore,
                  @"no target application activation");
            // Seed activation counter can rise only when activateWithOptions: is messaged.
            [(id)access.appsByPID[@42] activateWithOptions:0];
            Check(access.activationRequests == activationsBefore + 1,
                  @"activationRequests records real activate attempts");
            BOOL restored = moved && [workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error];
            Check(restored && YMWorkspaceSameFrame(access.currentFrame, originalFrame),
                  @"return uses real origin instead of thumbnail geometry");
        }
        {
            // Small and large thumbnails; same size different IDs stay distinct.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(20, 900, 120, 140), Frame(100, 100, 400, 300));
            [access installWindowPID:42 windowID:1491
                             cgFrame:Frame(40, 900, 120, 140)
                             axFrame:Frame(500, 100, 400, 300)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSError *error = nil;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"large-enough Stage Manager thumbnails move by identity");
            Check(access.positionWrites.count == 2, @"both same-size windows written once each");
            NSSet *written = [NSSet setWithArray:@[access.positionWrites[0][@"identity"],
                                                   access.positionWrites[1][@"identity"]]];
            Check([written containsObject:Identity(42, 1490)] &&
                  [written containsObject:Identity(42, 1491)],
                  @"same-size different IDs are not confused");
        }
        {
            // Source isolation across physical5 / virtual8 / virtual9.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:100
                             cgFrame:Frame(100, 100, 230, 408) axFrame:Frame(100, 100, 230, 408)];
            [access installWindowPID:42 windowID:200
                             cgFrame:Frame(2700, 100, 230, 408) axFrame:Frame(2700, 100, 230, 408)];
            [access installWindowPID:42 windowID:300
                             cgFrame:Frame(5300, 100, 230, 408) axFrame:Frame(5300, 100, 230, 408)];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            NSError *error = nil;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"physical card move succeeds");
            Check(access.positionWrites.count == 1 &&
                  [access.positionWrites[0][@"identity"] isEqual:Identity(42, 100)],
                  @"from5→8 only writes physical window");
            [access.positionWrites removeAllObjects];
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:8 toDisplayID:9 error:&error],
                  @"virtual→virtual transfer succeeds");
            NSMutableSet *ids = [NSMutableSet set];
            for (NSDictionary *write in access.positionWrites) [ids addObject:write[@"identity"]];
            Check(access.positionWrites.count == 2 &&
                  [ids containsObject:Identity(42, 100)] &&
                  [ids containsObject:Identity(42, 200)] &&
                  ![ids containsObject:Identity(42, 300)],
                  @"from8→9 writes only windows on 8, never screen 9");
            // Finder whole-app (source=nil) keeps explicit cross-source semantics.
            access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:100
                             cgFrame:Frame(100, 100, 230, 408) axFrame:Frame(100, 100, 230, 408)];
            [access installWindowPID:42 windowID:200
                             cgFrame:Frame(2700, 100, 230, 408) axFrame:Frame(2700, 100, 230, 408)];
            [access installWindowPID:42 windowID:300
                             cgFrame:Frame(5300, 100, 230, 408) axFrame:Frame(5300, 100, 230, 408)];
            workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            [access.positionWrites removeAllObjects];
            Check([workspace moveApplicationAtURL:fixtureURL toDisplayID:8 error:&error],
                  @"Finder whole-app drop moves every non-target source window");
            Check(access.positionWrites.count == 2, @"nil source moves physical and other-virtual only");
        }
        {
            // Hidden / minimized / non-ordinary / AX-not-in-CG are not moved; dialog blocks.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(100, 100, 230, 408) axFrame:Frame(100, 100, 230, 408)];
            // AX-only (not in CG): must not be collected.
            id ghost = @"el-ghost";
            NSMutableArray *ax = [access.axByPID[@42] mutableCopy];
            [ax addObject:@{@"identity": Identity(42, 9999), @"frame": Frame(120, 120, 230, 408),
                @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                @"element": ghost}];
            access.axByPID[@42] = ax;
            access.elementFrames[[NSString stringWithFormat:@"%p", ghost]] = Frame(120, 120, 230, 408);
            access.elementIdentities[[NSString stringWithFormat:@"%p", ghost]] = Identity(42, 9999);
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSError *error = nil;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"AX-not-in-CG ghost does not block or move");
            Check(access.positionWrites.count == 1 &&
                  [access.positionWrites[0][@"identity"] isEqual:Identity(42, 1490)],
                  @"only CG-visible ordinary window is written");

            // Dialog blocker on source refuses move.
            access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(100, 100, 230, 408) axFrame:Frame(100, 100, 230, 408)];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1500,
                @"frame": Frame(150, 150, 200, 200), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            ax = [access.axByPID[@42] mutableCopy];
            id dialog = @"el-dialog";
            [ax addObject:@{@"identity": Identity(42, 1500), @"frame": Frame(150, 150, 200, 200),
                @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                @"element": dialog}];
            access.axByPID[@42] = ax;
            access.elementFrames[[NSString stringWithFormat:@"%p", dialog]] = Frame(150, 150, 200, 200);
            access.elementIdentities[[NSString stringWithFormat:@"%p", dialog]] = Identity(42, 1500);
            workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [access.positionWrites removeAllObjects];
            error = nil;
            Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"dialog blocker refuses source move");
            Check(access.positionWrites.count == 0, @"dialog blocker writes nothing");
        }
        {
            // Identity change between candidates and first write stops; no unsafe write.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            access.flipIdentityOnNextObserveElement = YES;
            NSError *error = nil;
            Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"identity change before write fails closed");
            Check(error.code == 11, @"identity change uses code 11");
            Check(access.positionWrites.count == 0, @"identity change writes nothing");
        }
        {
            // Fix1 / Important 2: candidate→write mutations stop before first unsafe write.
            NSArray *mutations = @[
                @{@"name": @"windowID", @"mutation": @{@"windowID": @9991}},
                @{@"name": @"pid", @"mutation": @{@"pid": @99}},
                @{@"name": @"frame", @"mutation": @{@"frame": Frame(120, 120, 230, 408)}},
                @{@"name": @"ordinary", @"mutation": @{@"ordinary": @NO}},
                @{@"name": @"minimized", @"mutation": @{@"minimized": @YES}},
                @{@"name": @"settable", @"mutation": @{@"positionSettable": @NO}},
                @{@"name": @"source", @"mutation": @{@"frame": Frame(2700, 100, 230, 408)}},
            ];
            for (NSDictionary *caseInfo in mutations) {
                YMFakeWindowAccess *access = nil;
                NSURL *fixtureURL = nil;
                YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                    Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
                access.mutateOnObserveElementCount = 1;
                access.observeElementMutation = caseInfo[@"mutation"];
                NSError *error = nil;
                NSString *label = [NSString stringWithFormat:
                    @"%@ change after candidates stops before first write", caseInfo[@"name"]];
                Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8
                                                 error:&error], label);
                Check(error.code == 11, [NSString stringWithFormat:@"%@ uses code 11", caseInfo[@"name"]]);
                Check(access.positionWrites.count == 0,
                      [NSString stringWithFormat:@"%@ writes nothing", caseInfo[@"name"]]);
            }
            // Target display invalidated on the pre-write observe — also stops with zero writes.
            {
                YMFakeWindowAccess *access = nil;
                NSURL *fixtureURL = nil;
                YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                    Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
                __weak YMWorkspaceFixture *weakWS = workspace;
                access.observeElementSideEffect = ^(NSUInteger count) {
                    if (count == 1) {
                        weakWS.liveDisplayStates[@8] = @{
                            @"isActive": @NO, @"isOnline": @NO,
                            @"isInMirrorSet": @NO, @"mirrorsDisplay": @(kCGNullDirectDisplay),
                            @"bounds": Frame(2560, 0, 2560, 1440)
                        };
                    }
                };
                NSError *error = nil;
                Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8
                                                 error:&error],
                      @"target display invalidation after candidates stops before write");
                Check(error.code == 11, @"target invalidation uses code 11");
                Check(access.positionWrites.count == 0, @"target invalidation writes nothing");
            }
        }
        {
            // Fix1 / Important 3: identity change after destination write → rollback writes zero.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            // observe#1 pre-write, #2 placeElement start, setPosition records then fails,
            // observe#3 rollback placeElement start → flip identity so rollback must not write.
            access.failNextPositionWrites = 1;
            access.mutateOnObserveElementCount = 3;
            access.observeElementMutation = @{@"startSecondsDelta": @1};
            NSDictionary *originalIdentity = Identity(42, 1490);
            NSError *error = nil;
            Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"identity change after failed destination write refuses move");
            Check(error.code == 12, @"failed write with identity-changed rollback uses code 12");
            Check(access.positionWrites.count == 1,
                  @"only the destination write attempt is recorded; rollback writes zero");
            if (access.positionWrites.count) {
                Check([access.positionWrites[0][@"identity"] isEqual:originalIdentity],
                      @"recorded write targets original identity, never replacement");
                Check(access.positionWrites[0][@"x"] != nil && access.positionWrites[0][@"y"] != nil,
                      @"fake records write position not only BOOL");
            }
        }
        {
            // Replacement window ID must not inherit a prior origin checkpoint.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
            id element = access.axByPID[@42].firstObject[@"element"];
            YMFakeRunningApp *app = access.appsByPID[@42];
            NSDictionary *oldOrigin = YMWorkspaceOrigin(Frame(50, 50, 230, 408),
                                                        RuntimeDisplay(5, 0, NO, @"physical"));
            NSDictionary *oldIdentity = @{@"pid": @42, @"windowID": @1490, @"startSeconds": @1,
                @"startMicroseconds": @1, @"bundleID": @"test.calculator"};
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:oldOrigin lastDisplayID:5 identity:oldIdentity];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSError *error = nil;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"replacement with new lifecycle identity can still move");
            id placement = [[workspace valueForKey:@"placements"] firstObject];
            Check(!YMWorkspaceSameWindowIdentity([placement valueForKey:@"identity"], oldIdentity),
                  @"live placement stores the new identity");
            Check(![[placement valueForKey:@"origin"] isEqual:oldOrigin],
                  @"replacement never inherits prior origin checkpoint");
        }
        {
            // Write fails then rollback succeeds → checkpoint cleaned when created this move.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            access.failNextPositionWrites = 1; // destination fails; rollback succeeds
            NSError *error = nil;
            Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"failed destination with successful rollback reports failure");
            Check(error.code == 12, @"rollback success uses code 12");
            Check([[workspace valueForKey:@"placements"] count] == 0,
                  @"successful rollback clears newly created checkpoint");
            Check(YMWorkspaceSameFrame(access.currentFrame, Frame(100, 100, 230, 408)),
                  @"successful rollback restores prior frame");
        }
        {
            // Write fails and rollback fails → keep target ownership record.
            YMFakeWindowAccess *access = nil;
            NSURL *fixtureURL = nil;
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &fixtureURL,
                Frame(100, 100, 230, 408), Frame(100, 100, 230, 408));
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            access.failNextPositionWrites = 2;
            NSError *error = nil;
            Check(![workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"failed destination and rollback keeps records");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"failed rollback retains placement on target screen");
            id placement = [[workspace valueForKey:@"placements"] firstObject];
            Check([[placement valueForKey:@"lastDisplayID"] unsignedIntValue] == 8,
                  @"failed rollback leaves lastDisplayID on target");
        }
        {
            // Manual entry without checkpoint → explicit physical return centers.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            NSDictionary *virtualFrame = Frame(2700, 100, 230, 408);
            [access installWindowPID:42 windowID:1490 cgFrame:virtualFrame axFrame:virtualFrame];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSError *error = nil;
            Check([workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error],
                  @"manual entry without checkpoint restores to requested physical");
            // Centered on physical usable area: x=(2560-230)/2=1165, y=32+(1408-408)/2=532
            Check(YMWorkspaceSameFrame(access.currentFrame, Frame(1165, 532, 230, 408)),
                  @"manual return centers on requested physical screen");
        }
        {
            // Return to a different physical screen does not reuse old offsets.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            NSDictionary *virtualFrame = Frame(2700, 100, 230, 408);
            [access installWindowPID:42 windowID:1490 cgFrame:virtualFrame axFrame:virtualFrame];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(Frame(100, 100, 230, 408),
                                                     RuntimeDisplay(5, 0, NO, @"physical"));
            id element = access.axByPID[@42].firstObject[@"element"];
            [workspace installPlacementElement:element application:access.appsByPID[@42]
                                      windowID:1490 origin:origin lastDisplayID:8
                                      identity:Identity(42, 1490)];
            // Add a second physical display as explicit target.
            NSArray *twoPhysical = @[RuntimeDisplay(5, 0, NO, @"physical"),
                @{@"displayID": @6, @"displayUUID": @"other-physical",
                  @"bounds": Frame(-2560, 0, 2560, 1440), @"isMain": @NO,
                  @"isActive": @YES, @"isOnline": @YES, @"isVirtual": @NO},
                RuntimeDisplay(8, 2560, YES, @"agent-a"),
                RuntimeDisplay(9, 5120, YES, @"agent-b")];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:twoPhysical];
            NSError *error = nil;
            Check([workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:6 error:&error],
                  @"explicit other physical target restores");
            // Centered on display 6 usable area, not old (100,100) offsets.
            Check(YMWorkspaceSameFrame(access.currentFrame, Frame(-2560 + 1165, 532, 230, 408)),
                  @"other physical target centers rather than reusing old offsets");
        }
        {
            // Delayed CG: CG physical thumbnail while AX already on virtual8 — keep origin,
            // restore through manager uses preserved origin; independent CG/AX must agree to retire.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            access.syncCGOnWrite = NO;
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            NSDictionary *cgPhysical = Frame(15, 982, 37, 102);
            NSDictionary *axVirtual = Frame(2700, 100, 230, 408);
            NSDictionary *remembered = Frame(830, 719, 230, 408);
            [access installWindowPID:42 windowID:1490 cgFrame:cgPhysical axFrame:axVirtual];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(remembered, RuntimeDisplay(5, 0, NO, @"physical"));
            id element = access.axByPID[@42].firstObject[@"element"];
            [workspace installPlacementElement:element application:access.appsByPID[@42]
                                      windowID:1490 origin:origin lastDisplayID:8
                                      identity:Identity(42, 1490)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"delayed physical CG keeps origin while AX owns virtual");
            Check([[workspace rowsForDisplayID:8] count] == 1,
                  @"AX virtual geometry owns the window for inventory rows");
            id placementBefore = [[workspace valueForKey:@"placements"] firstObject];
            Check([[placementBefore valueForKey:@"origin"] isEqual:origin],
                  @"delayed CG restore path still holds the remembered physical origin");
            NSError *error = nil;
            Check([workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error],
                  @"delayed CG state still restores through the real manager entry");
            Check(YMWorkspaceSameFrame(access.currentFrame, remembered),
                  @"delayed CG restore uses preserved origin, not thumbnail geometry");

            // Retirement: AX already physical but CG still thumbnail → keep checkpoint.
            access = [YMFakeWindowAccess new];
            access.syncCGOnWrite = NO;
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490 cgFrame:cgPhysical axFrame:remembered];
            workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            element = access.axByPID[@42].firstObject[@"element"];
            [workspace installPlacementElement:element application:access.appsByPID[@42]
                                      windowID:1490 origin:origin lastDisplayID:8
                                      identity:Identity(42, 1490)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"independent disagreeing CG thumbnail + physical AX does not retire");
            // Agreeing independent CG+AX evidence finally retires.
            for (NSUInteger i = 0; i < access.cgWindows.count; i++) {
                NSMutableDictionary *cg = [access.cgWindows[i] mutableCopy];
                cg[@"frame"] = remembered;
                access.cgWindows[i] = cg;
            }
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[workspace valueForKey:@"placements"] count] == 0,
                  @"independent agreeing CG+AX physical evidence retires checkpoint");
        }
        {
            // Fix1 / Important 1: close gate verified before move — independent of post-move pending.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(100, 100, 230, 408) axFrame:Frame(100, 100, 230, 408)];
            [access installApp:77 name:@"Other" bundle:@"test.other"];
            [access installWindowPID:77 windowID:7700
                             cgFrame:Frame(200, 200, 300, 300) axFrame:Frame(200, 200, 300, 300)];
            [access.forceIncompletePIDs addObject:@77];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"unrelated app timeout leaves inventory not ready");
            NSError *closeError = nil;
            Check(![workspace restoreDisplayID:8 error:&closeError],
                  @"close refuses before move while unrelated app timeout leaves inventory not ready");
            Check(closeError.code == 3, @"pre-move close refusal uses inventory evidence code");
            NSError *error = nil;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"unrelated app timeout does not block selected-app move");
            Check(access.positionWrites.count == 1, @"selected app still writes once");
            Check([access.positionWrites[0][@"identity"] isEqual:Identity(42, 1490)],
                  @"selected-app write records exact identity");
        }
        {
            // Fix1 / Important 5: physical→virtual8→virtual9→physical keeps physical origin.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            NSDictionary *physicalFrame = Frame(830, 719, 230, 408);
            [access installWindowPID:42 windowID:1490
                             cgFrame:physicalFrame axFrame:physicalFrame];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            NSError *error = nil;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:5 toDisplayID:8 error:&error],
                  @"physical→virtual8 move succeeds");
            id placement = [[workspace valueForKey:@"placements"] firstObject];
            NSDictionary *originAfter8 = [placement valueForKey:@"origin"];
            Check(originAfter8 != nil, @"physical→8 stores a physical origin");
            Check([originAfter8[@"displayUUID"] isEqual:@"physical"],
                  @"physical→8 origin UUID is the physical screen");
            Check(YMWorkspaceSameFrame(originAfter8[@"relative"], physicalFrame),
                  @"physical→8 origin relative matches the real physical frame");
            NSUInteger writesAfter8 = access.positionWrites.count;
            Check([workspace moveApplicationAtURL:fixtureURL fromDisplayID:8 toDisplayID:9 error:&error],
                  @"virtual8→virtual9 move succeeds");
            placement = [[workspace valueForKey:@"placements"] firstObject];
            NSDictionary *originAfter9 = [placement valueForKey:@"origin"];
            Check([originAfter9 isEqual:originAfter8],
                  @"virtual→virtual does not overwrite the physical origin");
            Check(access.positionWrites.count > writesAfter8,
                  @"virtual→virtual still performs real writes");
            for (NSDictionary *write in access.positionWrites)
                Check([write[@"identity"] isEqual:Identity(42, 1490)],
                      @"origin-chain writes always target the same identity");
            Check([workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:9 toPhysicalDisplayID:5 error:&error],
                  @"virtual9→physical restore succeeds");
            Check(YMWorkspaceSameFrame(access.currentFrame, physicalFrame),
                  @"full chain returns to the original physical origin frame");
        }
        {
            // Adopt then restore uses checkpoint origin; closed/unresolvable rejects export.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            NSDictionary *virtualFrame = Frame(2700, 100, 230, 408);
            [access installWindowPID:42 windowID:1490 cgFrame:virtualFrame axFrame:virtualFrame];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSDictionary *identity = Identity(42, 1490);
            NSDictionary *origin = @{@"displayUUID": @"physical",
                @"relative": Frame(100, 100, 230, 408)};
            NSError *error = nil;
            Check([workspace adoptRestartOriginCheckpoints:@[@{@"identity": identity, @"origin": origin}]
                                                     error:&error],
                  @"adopt accepts live resolvable checkpoint");
            Check([workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error],
                  @"adopted origin restores correctly");
            Check(YMWorkspaceSameFrame(access.currentFrame, Frame(100, 100, 230, 408)),
                  @"adopted origin returns exact remembered frame");

            // Unresolvable identity refuses adopt (no bogus empty origin).
            access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator" bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490 cgFrame:virtualFrame axFrame:virtualFrame];
            workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSDictionary *missing = @{@"pid": @42, @"windowID": @1490, @"startSeconds": @9999,
                @"startMicroseconds": @1, @"bundleID": @"test.calculator"};
            error = nil;
            Check(![workspace adoptRestartOriginCheckpoints:@[@{@"identity": missing, @"origin": origin}]
                                                      error:&error],
                  @"unresolvable identity refuses adopt");
        }
        {
            // Fix2 / P2: same-bundle multi-process restore must finish every process
            // candidate check before the first position/size write.
            NSURL *fixtureURL = WriteTempFixtureApp(@"test.calculator");
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *appA = [access installApp:42 name:@"Calculator"
                                                bundle:@"test.calculator" bundleURL:fixtureURL];
            YMFakeRunningApp *appB = [access installApp:43 name:@"Calculator"
                                                bundle:@"test.calculator" bundleURL:fixtureURL];
            NSDictionary *frameA = Frame(2700, 100, 230, 408);
            NSDictionary *frameB = Frame(2800, 200, 230, 408);
            NSDictionary *originA = @{@"displayUUID": @"physical",
                @"relative": Frame(830, 719, 230, 408)};
            NSDictionary *originB = @{@"displayUUID": @"physical",
                @"relative": Frame(900, 700, 230, 408)};
            [access installWindowPID:42 windowID:1490 cgFrame:frameA axFrame:frameA];
            [access installWindowPID:43 windowID:1491 cgFrame:frameB axFrame:frameB];
            [access.forceIncompletePIDs addObject:@43];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            id elementA = access.axByPID[@42].firstObject[@"element"];
            id elementB = access.axByPID[@43].firstObject[@"element"];
            [workspace installPlacementElement:elementA application:appA windowID:1490
                                       origin:originA lastDisplayID:8 identity:Identity(42, 1490)];
            [workspace installPlacementElement:elementB application:appB windowID:1491
                                       origin:originB lastDisplayID:8 identity:Identity(43, 1491)];
            NSError *error = nil;
            Check(![workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error],
                  @"same-bundle process B timeout fails restore before any write");
            Check(error.code == 6, @"process B timeout uses incomplete observation code");
            Check(access.positionWrites.count == 0,
                  @"same-bundle timeout restore writes no positions");
            Check(access.sizeWrites.count == 0,
                  @"same-bundle timeout restore writes no sizes");
            NSDictionary *frameAAfter =
                access.elementFrames[[NSString stringWithFormat:@"%p", elementA]];
            Check(YMWorkspaceSameFrame(frameAAfter, frameA),
                  @"process A frame stays on virtual source after sibling timeout");
            NSArray *placements = [workspace valueForKey:@"placements"];
            Check(placements.count == 2, @"process A checkpoint retained after sibling timeout");
            id keptA = nil;
            for (id placement in placements) {
                if ([[placement valueForKey:@"windowID"] unsignedIntValue] == 1490)
                    keptA = placement;
            }
            Check(keptA != nil, @"process A placement still present");
            Check([[keptA valueForKey:@"origin"] isEqual:originA],
                  @"process A origin checkpoint is not deleted on sibling failure");

            // Blocker on process B also refuses before any write.
            access = [YMFakeWindowAccess new];
            appA = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"
                            bundleURL:fixtureURL];
            appB = [access installApp:43 name:@"Calculator" bundle:@"test.calculator"
                            bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490 cgFrame:frameA axFrame:frameA];
            [access installWindowPID:43 windowID:1491 cgFrame:frameB axFrame:frameB];
            elementA = access.axByPID[@42].firstObject[@"element"];
            elementB = access.axByPID[@43].firstObject[@"element"];
            [access.cgWindows addObject:@{@"pid": @43, @"windowID": @1500,
                @"frame": Frame(2900, 150, 200, 200), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            NSMutableArray *axB = [access.axByPID[@43] mutableCopy];
            id dialog = @"el-43-dialog";
            [axB addObject:@{@"identity": Identity(43, 1500), @"frame": Frame(2900, 150, 200, 200),
                @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                @"element": dialog}];
            access.axByPID[@43] = axB;
            access.elementFrames[[NSString stringWithFormat:@"%p", dialog]] = Frame(2900, 150, 200, 200);
            access.elementIdentities[[NSString stringWithFormat:@"%p", dialog]] = Identity(43, 1500);
            workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace installPlacementElement:elementA application:appA windowID:1490
                                       origin:originA lastDisplayID:8 identity:Identity(42, 1490)];
            [workspace installPlacementElement:elementB application:appB windowID:1491
                                       origin:originB lastDisplayID:8 identity:Identity(43, 1491)];
            error = nil;
            Check(![workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error],
                  @"same-bundle process B dialog blocker fails restore before any write");
            Check(error.code == 7, @"process B blocker uses source integrity code");
            Check(access.positionWrites.count == 0,
                  @"same-bundle blocker restore writes no positions");
            Check(access.sizeWrites.count == 0,
                  @"same-bundle blocker restore writes no sizes");
            Check([[workspace valueForKey:@"placements"] count] == 2,
                  @"process A checkpoint retained after sibling blocker");

            // Both processes reliable: restore still succeeds with exact identities.
            access = [YMFakeWindowAccess new];
            appA = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"
                            bundleURL:fixtureURL];
            appB = [access installApp:43 name:@"Calculator" bundle:@"test.calculator"
                            bundleURL:fixtureURL];
            [access installWindowPID:42 windowID:1490 cgFrame:frameA axFrame:frameA];
            [access installWindowPID:43 windowID:1491 cgFrame:frameB axFrame:frameB];
            elementA = access.axByPID[@42].firstObject[@"element"];
            elementB = access.axByPID[@43].firstObject[@"element"];
            workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace installPlacementElement:elementA application:appA windowID:1490
                                       origin:originA lastDisplayID:8 identity:Identity(42, 1490)];
            [workspace installPlacementElement:elementB application:appB windowID:1491
                                       origin:originB lastDisplayID:8 identity:Identity(43, 1491)];
            error = nil;
            Check([workspace restoreApplicationWithBundleIdentifier:@"test.calculator"
                fromDisplayID:8 toPhysicalDisplayID:5 error:&error],
                  @"same-bundle two reliable processes restore successfully");
            NSMutableSet *written = [NSMutableSet set];
            for (NSDictionary *write in access.positionWrites)
                [written addObject:write[@"identity"]];
            Check(access.positionWrites.count == 2 &&
                  [written containsObject:Identity(42, 1490)] &&
                  [written containsObject:Identity(43, 1491)],
                  @"reliable multi-process restore writes both exact identities");
            Check([[workspace valueForKey:@"placements"] count] == 0,
                  @"reliable multi-process restore retires both checkpoints");
            Check(YMWorkspaceSameFrame(
                      access.elementFrames[[NSString stringWithFormat:@"%p", elementA]],
                      originA[@"relative"]),
                  @"process A restores its remembered physical origin");
            Check(YMWorkspaceSameFrame(
                      access.elementFrames[[NSString stringWithFormat:@"%p", elementB]],
                      originB[@"relative"]),
                  @"process B restores its remembered physical origin");
        }

        // --- Global fix: MUST_FIX #1 missing layer after ready must not TTL-reuse ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"#1 baseline ready before layer drop");
            NSUInteger gen = workspace.inventoryGeneration;
            NSMutableDictionary *cg = [access.cgWindows[0] mutableCopy];
            [cg removeObjectForKey:@"layer"];
            access.cgWindows[0] = cg;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(!workspace.inventoryReady,
                  @"#1 dropping layer after ready immediately clears ready");
            Check(workspace.inventoryGeneration != gen,
                  @"#1 missing layer advances inventory generation");
            NSError *restoreError = nil;
            Check(![workspace restoreDisplayID:8 error:&restoreError],
                  @"#1 missing layer refuses empty close via restoreDisplayID");
            Check([workspace needsRestoreForDisplayID:8],
                  @"#1 missing layer keeps needsRestore");
        }

        // --- Global fix: MUST_FIX #2 CG nil permanently invalidates prior job ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.pendingReads.count == 1, @"#2 schedules one read");
            dispatch_block_t read = workspace.pendingReads.firstObject;
            [workspace.pendingReads removeObjectAtIndex:0];
            read();
            Check(workspace.pendingPublishes.count == 1, @"#2 read queues publish");
            NSUInteger gen = workspace.inventoryGeneration;
            access.failVisibleWindows = YES;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.inventoryGeneration != gen,
                  @"#2 CG nil advances generation");
            Check(!workspace.inventoryReady, @"#2 CG nil clears ready");
            access.failVisibleWindows = NO;
            dispatch_block_t publish = workspace.pendingPublishes.firstObject;
            [workspace.pendingPublishes removeObjectAtIndex:0];
            publish();
            Check(!workspace.inventoryReady,
                  @"#2 stale publish after CG failure cannot revive ready");
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"#2 fresh observation after recovery can become ready");
        }

        // --- Global fix: MUST_FIX #3 publish binds observed process lifecycle ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            dispatch_block_t read = workspace.pendingReads.firstObject;
            [workspace.pendingReads removeObjectAtIndex:0];
            read();
            YMFakeRunningApp *original = access.appsByPID[@42];
            original.terminated = YES;
            YMFakeRunningApp *replacement = [access installApp:42 name:@"Replacement"
                                                       bundle:@"test.calculator"];
            NSMutableDictionary *ax = [access.axByPID[@42].firstObject mutableCopy];
            NSMutableDictionary *identity = [ax[@"identity"] mutableCopy];
            identity[@"startSeconds"] = @1001;
            ax[@"identity"] = identity;
            ax[@"frame"] = Frame(2700, 100, 230, 408);
            access.axByPID[@42] = @[ax];
            access.elementFrames[[access elementKey:ax[@"element"]]] = ax[@"frame"];
            access.elementIdentities[[access elementKey:ax[@"element"]]] = identity;
            Check(![replacement isEqual:original],
                  @"#3 same-PID replacement must not be lifecycle-equal to prior process");
            dispatch_block_t publish = workspace.pendingPublishes.firstObject;
            [workspace.pendingPublishes removeObjectAtIndex:0];
            publish();
            Check(!workspace.inventoryReady,
                  @"#3 replacement process cannot publish ready with stale AX");
            Check([[workspace rowsForDisplayID:5] count] == 0,
                  @"#3 replacement must not publish old physical geometry as current");
        }
        {
            // Equal wrappers of the same lifetime must publish; pointer singleton is not required.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(15, 982, 37, 102)
                             axFrame:Frame(830, 719, 230, 408)];
            YMFakeRunningApp *stored = access.appsByPID[@42];
            access.reboxApplicationWrappers = YES;
            id first = [access applicationForPID:42];
            id second = [access applicationForPID:42];
            Check(first != second, @"#3 reboxed wrappers are distinct objects");
            Check([first isEqual:second], @"#3 reboxed wrappers share process lifecycle equality");
            Check([first isEqual:stored], @"#3 reboxed wrapper equals stored lifecycle token");
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"#3 same-lifecycle reboxed wrappers must still publish ready");
            Check([[workspace rowsForDisplayID:5] count] == 1,
                  @"#3 same-lifecycle reboxed wrappers keep physical rows");
            Check(![workspace needsRestoreForDisplayID:8],
                  @"#3 same-lifecycle reboxed wrappers must not force restore");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            dispatch_block_t read = workspace.pendingReads.firstObject;
            [workspace.pendingReads removeObjectAtIndex:0];
            read();
            YMFakeRunningApp *original = access.appsByPID[@42];
            original.terminated = YES;
            // Live lookup still returns the terminated object (no replacement installed).
            dispatch_block_t publish = workspace.pendingPublishes.firstObject;
            [workspace.pendingPublishes removeObjectAtIndex:0];
            publish();
            Check(!workspace.inventoryReady,
                  @"#3 terminated observed process cannot publish ready");
        }

        // --- Global fix: MUST_FIX #4/#5 confirmed aux exclusion vs non-admitted ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [access installWindowPID:42 windowID:1491
                             cgFrame:Frame(200, 200, 30, 30)
                             axFrame:Frame(200, 200, 30, 30)];
            NSMutableArray *ax = [access.axByPID[@42] mutableCopy];
            NSMutableDictionary *aux = [ax[1] mutableCopy];
            aux[@"ordinary"] = @NO;
            ax[1] = aux;
            access.axByPID[@42] = ax;
            NSDictionary *snapshot = YMWorkspaceNormalizeWindowSnapshot(access.cgWindows, ax, YES, displays);
            Check([snapshot[@"complete"] boolValue] && [snapshot[@"blockers"] count] == 0,
                  @"#4 normalizer confirms small aux without blockers");
            Check(snapshot[@"excluded"] == nil,
                  @"#4 normalizer must not expose excluded schema field");
            Check([snapshot[@"windows"] count] == 1,
                  @"#4 ordinary window remains while aux is privately excluded");
            BOOL auxPublished = NO;
            for (NSDictionary *window in snapshot[@"windows"]) {
                if ([window[@"windowID"] isEqual:@1491]) auxPublished = YES;
            }
            Check(!auxPublished, @"#4 confirmed aux must not appear in published windows");
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"#4 confirmed aux exclusion must not block inventory ready");
            Check(![workspace needsRestoreForDisplayID:8],
                  @"#4 confirmed aux exclusion must not keep needsRestore");
        }
        {
            // Unknown/unmatched admitted CG must still fail closed without excluded schema.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(830, 719, 230, 408), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            // No AX record → unmatched, not confirmed exclusion.
            access.axByPID[@42] = @[];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"#4 unmatched admitted CG must fail closed without excluded schema");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *system = [access installApp:999 name:@"System surface" bundle:@""];
            system.bundleURL = nil;
            [access.cgWindows addObject:@{@"pid": @999, @"windowID": @77,
                @"frame": Frame(2800, 200, 120, 90), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"#5 non-admitted-only virtual may be ready empty");
            Check([[workspace rowsForDisplayID:8] count] == 0, @"#5 non-admitted creates no rows");
            NSError *restoreError = nil;
            Check([workspace restoreDisplayID:8 error:&restoreError],
                  @"#5 empty admitted inventory may close");
            Check(![workspace needsRestoreForDisplayID:8],
                  @"#5 non-admitted system surface must not keep needsRestore");
        }

        // --- Global fix: MUST_FIX #6 post-size state revalidation ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            access.mutateOnObserveElementCount = 2;
            access.observeElementMutation = @{@"minimized": @YES};
            id element = access.axByPID[@42].firstObject[@"element"];
            BOOL placed = [workspace placeElement:element frame:Frame(2700, 100, 200, 300)
                                          display:displays[1]
                                      application:(id)access.appsByPID[@42]
                                 expectedIdentity:Identity(42, 1490)];
            Check(!placed, @"#6 minimized after setSize must fail placeElement");
            Check(access.sizeWrites.count == 1, @"#6 still attempted size when needed");
            Check(access.positionWrites.count == 0,
                  @"#6 must not position after post-size minimized");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            access.mutateOnObserveElementCount = 2;
            access.observeElementMutation = @{@"ordinary": @NO};
            id element = access.axByPID[@42].firstObject[@"element"];
            BOOL placed = [workspace placeElement:element frame:Frame(2700, 100, 200, 300)
                                          display:displays[1]
                                      application:(id)access.appsByPID[@42]
                                 expectedIdentity:Identity(42, 1490)];
            Check(!placed, @"#6 non-ordinary after setSize must fail placeElement");
            Check(access.positionWrites.count == 0,
                  @"#6 must not position after post-size non-ordinary");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            access.mutateOnObserveElementCount = 2;
            access.observeElementMutation = @{@"positionSettable": @NO};
            id element = access.axByPID[@42].firstObject[@"element"];
            BOOL placed = [workspace placeElement:element frame:Frame(2700, 100, 200, 300)
                                          display:displays[1]
                                      application:(id)access.appsByPID[@42]
                                 expectedIdentity:Identity(42, 1490)];
            Check(!placed, @"#6 unsettable after setSize must fail placeElement");
            Check(access.positionWrites.count == 0,
                  @"#6 must not position after post-size unsettable");
        }

        // --- Global fix: MUST_FIX #7 source topology before origin/write ---
        {
            YMFakeWindowAccess *access = nil;
            NSURL *url = nil;
            NSDictionary *original = Frame(830, 719, 230, 408);
            YMWorkspaceFixture *workspace = ManagerFixture(&access, &url,
                Frame(15, 982, 37, 102), original);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            workspace.liveDisplayStates[@5] = @{
                @"isActive": @YES, @"isOnline": @YES,
                @"isInMirrorSet": @NO, @"mirrorsDisplay": @(kCGNullDirectDisplay),
                @"bounds": Frame(100, 0, 2560, 1440)
            };
            NSError *moveError = nil;
            BOOL moved = [workspace moveApplicationAtURL:url fromDisplayID:5 toDisplayID:8
                                                   error:&moveError];
            Check(!moved, @"#7 source bounds drift refuses move");
            Check(access.positionWrites.count == 0 && access.sizeWrites.count == 0,
                  @"#7 source drift performs zero position/size writes");
            Check([[workspace valueForKey:@"placements"] count] == 0,
                  @"#7 source drift must not save a wrong origin checkpoint");
            [[NSFileManager defaultManager] removeItemAtURL:[url URLByDeletingLastPathComponent]
                                                      error:nil];
        }

        // --- Global fix: MUST_FIX #10 write-period current-generation operation guard ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *virtualFrame = Frame(2700, 100, 230, 408);
            id element = @"el-write-guard";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = virtualFrame;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": virtualFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": virtualFrame, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(Frame(100, 100, 230, 408),
                                                     RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            Check(workspace.pendingReads.count == 1, @"#10 starts with one pending job");
            // Finish observation into publish queue, then enter write WITHOUT bumping
            // generation so the pending publish is still current-generation.
            dispatch_block_t read = workspace.pendingReads.firstObject;
            [workspace.pendingReads removeObjectAtIndex:0];
            read();
            id placement = [[workspace valueForKey:@"placements"] firstObject];
            [placement setValue:@9 forKey:@"lastDisplayID"];
            workspace.operationInProgress = YES;
            NSUInteger schedulesBefore = workspace.scheduleCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedulesBefore,
                  @"#10 write blocks scheduling a new inventory job");
            Check(workspace.pendingReads.count == 0,
                  @"#10 write must not enqueue a replacement read");
            dispatch_block_t publish = workspace.pendingPublishes.firstObject;
            [workspace.pendingPublishes removeObjectAtIndex:0];
            publish();
            Check([[placement valueForKey:@"lastDisplayID"] unsignedIntValue] == 9,
                  @"#10 current-gen publish during write must not revert ownership");
            Check(!workspace.inventoryReady,
                  @"#10 current-gen publish during write must not become ready");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"#10 placement survives current-gen publish during write");
            workspace.operationInProgress = NO;
            [workspace invalidateInventoryForMutation];
            [workspace drainReads];
            Check(workspace.pendingReads.count == 0,
                  @"#10 bounded reads resume after write ends");
        }

        printf("App workspace runtime tests: %lu passed, %lu failed; no GUI or display calls executed.\n",
               (unsigned long)(checks - failures), (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
