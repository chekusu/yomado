// Executes production controller logic with fake display/topology boundaries.
// No NSApplication, CoreGraphics operations, window creation, defaults or IOPM.
#define main YMIgnoredApplicationMain
#import "Yomado.m"
#undef main

@interface YMFakeDisplay : VDVirtualDisplay
@property BOOL live;
@property BOOL createResult;
@property NSUInteger creates;
@property NSUInteger destroys;
@property CGDirectDisplayID fixtureID;
@property NSUInteger lastWidth;
@property NSUInteger lastHeight;
@property BOOL lastHiDPI;
@property(copy) NSString *lastName;
@end
@implementation YMFakeDisplay
- (instancetype)init { if ((self = [super init])) _createResult = YES; return self; }
- (BOOL)isCreated { return self.live; }
- (CGDirectDisplayID)displayID { return self.live ? self.fixtureID : 0; }
- (BOOL)createWithWidth:(NSUInteger)w height:(NSUInteger)h hiDPI:(BOOL)hiDPI name:(NSString *)name error:(NSError **)error {
    self.lastWidth = w; self.lastHeight = h; self.lastHiDPI = hiDPI; self.lastName = [name copy];
    self.creates++;
    self.live = self.createResult;
    if (!self.createResult && error) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    return self.createResult;
}
- (void)destroy { self.destroys++; self.live = NO; }
@end

@interface YMFakeTopology : NSObject
@property BOOL captureResult;
@property BOOL configureResult;
@property BOOL restoreResult;
@property BOOL extended;
@property NSUInteger captures;
@property NSUInteger configurations;
@property NSUInteger restorations;
@property CGDirectDisplayID lastRemoved;
@property CGDirectDisplayID lastConfigured;
@property YMDisplayTopologySnapshot *snapshot;
@property(copy) void (^duringCapture)(void);
@property(copy) void (^duringConfigure)(void);
@property(copy) void (^duringRestore)(void);
@end
@implementation YMFakeTopology
- (instancetype)init {
    if ((self = [super init])) { _captureResult = YES; _configureResult = YES; _restoreResult = YES; _extended = YES; _snapshot = [YMDisplayTopologySnapshot new]; }
    return self;
}
- (YMDisplayTopologySnapshot *)captureSnapshotWithError:(NSError **)error {
    self.captures++; if (self.duringCapture) self.duringCapture();
    if (!self.captureResult && error) *error = [NSError errorWithDomain:@"fixture" code:2 userInfo:nil];
    return self.captureResult ? self.snapshot : nil;
}
- (BOOL)configureAndVerifyNewDisplay:(CGDirectDisplayID)d width:(NSUInteger)w height:(NSUInteger)h hiDPI:(BOOL)hi baseline:(YMDisplayTopologySnapshot *)s error:(NSError **)error {
    (void)w; (void)h; (void)hi; (void)s; self.configurations++; self.lastConfigured=d;
    if (self.duringConfigure) self.duringConfigure();
    if (!self.configureResult && error) *error = [NSError errorWithDomain:@"fixture" code:3 userInfo:nil];
    return self.configureResult;
}
- (BOOL)restoreAndVerifySnapshot:(YMDisplayTopologySnapshot *)s excludingDisplayID:(CGDirectDisplayID)d error:(NSError **)error {
    (void)s; self.restorations++; self.lastRemoved = d;
    if (self.duringRestore) self.duringRestore();
    if (!self.restoreResult && error) *error = [NSError errorWithDomain:@"fixture" code:4 userInfo:nil];
    return self.restoreResult;
}
- (BOOL)isExtendedTarget:(CGDirectDisplayID)d width:(NSUInteger)w height:(NSUInteger)h hiDPI:(BOOL)hi {
    (void)d; (void)w; (void)h; (void)hi; return self.extended;
}
@end

@interface YMFakeController : ADController
@property NSUInteger inventoryUpdates;
@property NSUInteger panelCheckpoints;
@property NSUInteger saves;
@property NSUInteger reports;
@property BOOL powerFails;
@property BOOL simulateFinalRemovalRecoveryFailure;
@property NSUInteger stopCalls;
@property NSUInteger showCalls;
@property NSUInteger resumedTerminations;
@property BOOL deferTopologyOperations;
@property BOOL useRealPanelPresentation;
@property BOOL useProductionAppRestore;
@property BOOL useProductionUnmovableConfirmation;
@property NSMutableArray<NSDictionary *> *pendingTopologyOperations;
- (void)runNextTopologyOperation;
@end
@implementation YMFakeController
- (void)performTopologyOperation:(BOOL (^)(NSError **))operation completion:(void (^)(BOOL, NSError *))completion {
    if (self.deferTopologyOperations) {
        if (!self.pendingTopologyOperations) self.pendingTopologyOperations=[NSMutableArray array];
        [self.pendingTopologyOperations addObject:@{@"operation":[operation copy], @"completion":[completion copy]}];
        return;
    }
    NSError *error=nil; BOOL succeeded=operation(&error); completion(succeeded,error);
}
- (void)runNextTopologyOperation {
    NSDictionary *next=self.pendingTopologyOperations.firstObject;
    NSAssert(next, @"A queued operation must exist");
    [self.pendingTopologyOperations removeObjectAtIndex:0];
    BOOL (^operation)(NSError **)=next[@"operation"];
    void (^completion)(BOOL,NSError *)=next[@"completion"];
    NSError *error=nil; BOOL succeeded=operation(&error); completion(succeeded,error);
}
- (void)updateInventory { self.inventoryUpdates++; }
- (void)storeUpdatePanelState { self.panelCheckpoints++; }
- (void)saveDisplayProfiles { self.saves++; }
- (void)reportTopologyError:(NSError *)error { (void)error; self.reports++; }
- (void)powerAssertions:(BOOL)on { self.systemAssertion = self.displayAssertion = on && !self.powerFails ? 1 : 0; }
- (BOOL)restoreApplicationsForDisplayID:(CGDirectDisplayID)displayID {
    if (self.useProductionAppRestore) return [super restoreApplicationsForDisplayID:displayID];
    (void)displayID;
    return YES;
}
- (BOOL)confirmUnmovableWindowsOnDisplayIDs:(NSArray<NSNumber *> *)displayIDs {
    if (self.useProductionUnmovableConfirmation) return [super confirmUnmovableWindowsOnDisplayIDs:displayIDs];
    (void)displayIDs;
    return YES;
}
- (void)showWindow:(id)sender {
    self.showCalls++;
    if (self.useRealPanelPresentation) [super showWindow:sender];
}
- (void)resumeTerminationAfterTopologyRecovery:(BOOL)recovered {
    if (self.terminationAfterTopologyRecovery && recovered) self.resumedTerminations++;
    self.terminationAfterTopologyRecovery=NO;
}
- (BOOL)writeStateEnding:(BOOL)end { (void)end; return YES; }
- (YMManagedDisplay *)newProfileWithOrdinal:(NSUInteger)ordinal name:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI {
    YMManagedDisplay *profile = [super newProfileWithOrdinal:ordinal name:name width:width height:height hiDPI:hiDPI];
    YMFakeDisplay *fake = [YMFakeDisplay new];
    fake.fixtureID = (CGDirectDisplayID)(300 + ordinal);
    profile.display = fake;
    return profile;
}
- (void)stop:(id)sender {
    (void)sender; self.stopCalls++;
    // The termination decision is production logic. This boundary models the
    // actual stop outcome: the last owned output is gone, recovery still fails.
    // It deliberately avoids the real stop method's WindowServer calls.
    if (self.simulateFinalRemovalRecoveryFailure) {
        CGDirectDisplayID removed = self.virtualDisplay.displayID;
        self.selectedProfile.topologyVerified = NO;
        [self.virtualDisplay destroy];
        YMDisplayTopologySnapshot *snapshot = [(YMFakeTopology *)self.displayTopology snapshot];
        self.displayOperationInProgress=YES;
        [self recoverTopology:snapshot removedID:removed completion:^(BOOL recovered,NSError *error) {
            (void)error; self.displayOperationInProgress=NO;
            [self resumeTerminationAfterTopologyRecovery:recovered];
        }];
    }
}
@end

@interface YMUnmovableWorkspace : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<NSDictionary *> *> *windowsByDisplayID;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *pendingReadsByDisplayID;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *neverReadyDisplayIDs;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *queriedDisplayIDs;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *allowedDisplayIDs;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *restoreDisplayIDs;
@property(nonatomic) CGDirectDisplayID restoreFailureDisplayID;
@property(nonatomic) NSUInteger cancelAllowanceCalls;
- (NSArray<NSDictionary *> *)unmovableWindowsForDisplayID:(CGDirectDisplayID)displayID;
- (void)allowUnmovableWindowsOnDisplayID:(CGDirectDisplayID)displayID;
- (void)cancelUnmovableWindowAllowances;
- (BOOL)inventoryReadyForClosingDisplayID:(CGDirectDisplayID)displayID;
- (BOOL)restoreDisplayID:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)needsRestoreForDisplayID:(CGDirectDisplayID)displayID;
@end
@implementation YMUnmovableWorkspace
- (instancetype)init {
    if ((self = [super init])) {
        _windowsByDisplayID = [NSMutableDictionary dictionary];
        _pendingReadsByDisplayID = [NSMutableDictionary dictionary];
        _neverReadyDisplayIDs = [NSMutableSet set];
        _queriedDisplayIDs = [NSMutableArray array];
        _allowedDisplayIDs = [NSMutableArray array];
        _restoreDisplayIDs = [NSMutableArray array];
    }
    return self;
}
- (NSArray<NSDictionary *> *)unmovableWindowsForDisplayID:(CGDirectDisplayID)displayID {
    NSNumber *key = @(displayID);
    [self.queriedDisplayIDs addObject:key];
    if ([self.neverReadyDisplayIDs containsObject:key]) return nil;
    NSUInteger pendingReads = self.pendingReadsByDisplayID[key].unsignedIntegerValue;
    if (pendingReads) {
        self.pendingReadsByDisplayID[key] = @(pendingReads - 1);
        return nil;
    }
    return self.windowsByDisplayID[key] ?: @[];
}
- (void)allowUnmovableWindowsOnDisplayID:(CGDirectDisplayID)displayID {
    [self.allowedDisplayIDs addObject:@(displayID)];
}
- (void)cancelUnmovableWindowAllowances {
    self.cancelAllowanceCalls++;
    [self.allowedDisplayIDs removeAllObjects];
}
- (BOOL)inventoryReadyForClosingDisplayID:(CGDirectDisplayID)displayID {
    (void)displayID;
    return YES;
}
- (BOOL)restoreDisplayID:(CGDirectDisplayID)displayID error:(NSError **)error {
    [self.restoreDisplayIDs addObject:@(displayID)];
    if (displayID == self.restoreFailureDisplayID) {
        if (error) *error = [NSError errorWithDomain:@"fixture" code:8 userInfo:nil];
        return NO;
    }
    return YES;
}
- (BOOL)needsRestoreForDisplayID:(CGDirectDisplayID)displayID { (void)displayID; return NO; }
- (BOOL)accessibilityTrusted { return YES; }
@end

@interface YMUnmovableController : YMFakeController
@property(nonatomic, copy) NSString *confirmationSummary;
@property(nonatomic) BOOL confirmationResponse;
@property(nonatomic) NSUInteger confirmationCalls;
@property(nonatomic) NSUInteger applicationErrors;
@end
@implementation YMUnmovableController
- (BOOL)confirmLeavingUnmovableWindows:(NSString *)summary {
    self.confirmationCalls++;
    self.confirmationSummary = summary;
    return self.confirmationResponse;
}
- (void)reportApplicationError:(NSError *)error fallback:(NSString *)fallback {
    (void)error; (void)fallback;
    self.applicationErrors++;
}
@end

@interface YMSpyPanelPresenter : NSObject
@property NSUInteger opens;
@property NSUInteger closes;
@property NSUInteger invalidations;
@property BOOL acceptClose;
@property NSWindow *lastClosedWindow;
@end
@implementation YMSpyPanelPresenter
- (void)open { self.opens++; }
- (BOOL)closeWindow:(NSWindow *)window {
    self.closes++; self.lastClosedWindow = window; return self.acceptClose;
}
- (void)invalidate { self.invalidations++; }
@end

@interface YMSpyPanelWindow : NSObject
@property NSUInteger ordersOut;
@end
@implementation YMSpyPanelWindow
- (void)orderOut:(id)sender { (void)sender; self.ordersOut++; }
@end

@interface YMSpyHeartbeat : NSObject
@property NSUInteger invalidations;
@end
@implementation YMSpyHeartbeat
- (void)invalidate { self.invalidations++; }
@end

@interface YMControllerUpdateEngine : NSObject
@property BOOL installationPending;
@property BOOL installationAuthorized;
@property BOOL automaticUpdatesEnabled;
@property BOOL busy;
@property BOOL canCancel;
@property YMAutomaticUpdateStatus status;
@property double progress;
@property NSError *lastError;
@property BOOL canCheck;
@property NSString *latestVersion;
@property NSString *latestBuild;
@property NSUInteger deferrals;
@end
@implementation YMControllerUpdateEngine
- (void)installationWasDeferredWithError:(NSError *)error { (void)error; self.deferrals++; self.installationAuthorized=NO; }
@end
@interface YMControllerUpdateRecovery : NSObject
@property BOOL commitResult;
@property NSUInteger commits;
@property NSUInteger preparations;
@property NSUInteger cancellations;
@property BOOL restoreResult;
@property NSArray *restoredOriginCheckpoints;
@property NSMutableArray *events;
@end
@implementation YMControllerUpdateRecovery
- (BOOL)prepareRestartWithProfiles:(NSArray *)profiles targetVersion:(NSString *)version targetBuild:(NSString *)build originCheckpoints:(NSArray *)origins error:(NSError **)error {
    (void)profiles; (void)version; (void)build; (void)origins; (void)error; self.preparations++; return YES;
}
- (BOOL)restoreWithProfiles:(NSArray *)profiles error:(NSError **)error { (void)profiles; (void)error; [self.events addObject:@"restore"]; return self.restoreResult; }
- (BOOL)completeRestoration:(NSError **)error { (void)error; [self.events addObject:@"complete"]; return YES; }
- (BOOL)cancelPreparedRestart:(NSError **)error { (void)error; self.cancellations++; return YES; }
- (BOOL)commitPreparedRestart:(NSError **)error {
    self.commits++;
    if (!self.commitResult && error) *error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    return self.commitResult;
}
@end
@interface YMControllerUpdateWorkspace : NSObject
@property NSMutableArray *events;
@property BOOL adoptedNonemptyOrigins;
@end
@implementation YMControllerUpdateWorkspace
- (NSArray *)restartOriginCheckpointsWithError:(NSError **)error { (void)error; return @[]; }
- (BOOL)adoptRestartOriginCheckpoints:(NSArray *)points error:(NSError **)error {
    (void)error;
    self.adoptedNonemptyOrigins=points.count>0 && [self.events.lastObject isEqual:@"inventory"];
    [self.events addObject:@"adopt"];
    return self.adoptedNonemptyOrigins;
}
@end

// Close-gate fixture: inventory readiness and a single restore write.
@interface YMCloseGateWorkspace : NSObject {
    BOOL _gateReady;
}
@property(nonatomic) BOOL inventoryReady;
@property(nonatomic) BOOL needsRestoreFlag;
@property(nonatomic) BOOL restoreResult;
@property(nonatomic) NSUInteger restoreCalls;
@property(nonatomic) NSUInteger readyPolls;
@property(nonatomic) NSUInteger needsRestorePolls;
@property(nonatomic) NSUInteger refreshesBeforeReady;
@property(nonatomic) NSUInteger closingReadyPolls;
@property(nonatomic) CGDirectDisplayID lastClosingDisplayID;
@property(nonatomic) BOOL closingReadinessOverrideEnabled;
@property(nonatomic) BOOL closingReadinessOverride;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end
@implementation YMCloseGateWorkspace
- (instancetype)init {
    if ((self = [super init])) {
        _gateReady = YES;
        _restoreResult = YES;
        _events = [NSMutableArray array];
    }
    return self;
}
- (void)refreshWithVirtualDisplayIDs:(NSArray *)ids displaySnapshot:(NSArray *)snapshot {
    (void)ids; (void)snapshot;
    [self.events addObject:@"refresh"];
    if (self.refreshesBeforeReady > 0) {
        self.refreshesBeforeReady--;
        _gateReady = self.refreshesBeforeReady == 0;
    }
}
- (BOOL)inventoryReady {
    self.readyPolls++;
    [self.events addObject:_gateReady ? @"readyYES" : @"readyNO"];
    return _gateReady;
}
- (void)setInventoryReady:(BOOL)inventoryReady {
    _gateReady = inventoryReady;
}
- (BOOL)inventoryReadyForClosingDisplayID:(CGDirectDisplayID)displayID {
    self.closingReadyPolls++;
    self.lastClosingDisplayID = displayID;
    return self.closingReadinessOverrideEnabled ? self.closingReadinessOverride : self.inventoryReady;
}
- (BOOL)needsRestoreForDisplayID:(CGDirectDisplayID)displayID {
    (void)displayID;
    self.needsRestorePolls++;
    return self.needsRestoreFlag;
}
- (BOOL)restoreDisplayID:(CGDirectDisplayID)displayID error:(NSError **)error {
    (void)displayID; (void)error;
    self.restoreCalls++;
    [self.events addObject:@"restore"];
    // restoreDisplayID itself requires ready evidence (mirrors production gate).
    if (!_gateReady) {
        if (error) *error = [NSError errorWithDomain:@"fixture" code:3 userInfo:nil];
        return NO;
    }
    return self.restoreResult;
}
- (void)cancelUnmovableWindowAllowances {}
- (BOOL)accessibilityTrusted { return YES; }
- (NSArray *)rowsForDisplayID:(CGDirectDisplayID)displayID { (void)displayID; return @[]; }
@end

@interface YMCloseGateController : YMFakeController
@end
@implementation YMCloseGateController
- (void)updateInventory {
    self.inventoryUpdates++;
    NSArray *ids = self.virtualDisplay.isCreated ? @[@(self.virtualDisplay.displayID)] : @[];
    [(id)self.appWorkspace refreshWithVirtualDisplayIDs:ids displaySnapshot:@[]];
}
- (void)reportApplicationError:(NSError *)error fallback:(NSString *)fallback {
    (void)error; (void)fallback; self.reports++;
}
@end
@interface YMControllerLegacyRecovery : NSObject
@property BOOL needsRestoreBeforeRemovingVirtualDisplay;
@property(nonatomic, weak) YMCloseGateWorkspace *workspaceToInvalidate;
@property(nonatomic) NSUInteger restoreWeChatCalls;
@property(nonatomic) NSUInteger refreshSnapshotCount;
@property(nonatomic, strong) NSArray *lastRefreshSnapshot;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end
@implementation YMControllerLegacyRecovery
- (instancetype)init {
    if ((self = [super init])) _events = [NSMutableArray array];
    return self;
}
- (void)refreshWithVirtualDisplayID:(CGDirectDisplayID)displayID displaySnapshot:(NSArray *)snapshot {
    (void)displayID;
    self.refreshSnapshotCount++;
    self.lastRefreshSnapshot = snapshot;
    [self.events addObject:@"wechatRefresh"];
}
- (BOOL)restoreWeChat:(NSError **)error {
    (void)error;
    self.restoreWeChatCalls++;
    [self.events addObject:@"wechatRestore"];
    // World change after WeChat: inventory key/TTL no longer authorizes close.
    YMCloseGateWorkspace *gate = self.workspaceToInvalidate;
    if (gate) {
        gate.inventoryReady = NO;
        gate.refreshesBeforeReady = 2;
    }
    return YES;
}
@end

@interface YMIsolatedWeChatController : YMCloseGateController
@property(nonatomic) NSUInteger displaySnapshotCalls;
@property(nonatomic, strong) NSArray *fakeDisplaySnapshot;
@end
@implementation YMIsolatedWeChatController
- (NSArray *)controllerDisplaySnapshot {
    self.displaySnapshotCalls++;
    return self.fakeDisplaySnapshot ?: @[];
}
@end
@interface YMUpdateCompletionController : YMFakeController
@property NSMutableArray *events;
@property NSError *completionError;
@end
@implementation YMUpdateCompletionController
- (void)updateInventory { [self.events addObject:@"inventory"]; }
- (void)finishUpdateRecoveryWithError:(NSError *)error { self.completionError=error; [self.events addObject:@"finished"]; }
@end

@interface ADController (YMProfileEditorTestDeclaration)
- (YMDisplayProfileEditor *)makeDisplayProfileEditorWithMode:(YMDisplayProfileEditorMode)mode
                                                       draft:(YMDisplayProfileDraft *)draft;
- (void)presentProfileEditorForOrdinal:(NSUInteger)ordinal mode:(YMDisplayProfileEditorMode)mode;
- (void)updateSavedProfilesPresentation;
@property(nonatomic, strong) YMSavedDisplayProfilesView *savedProfilesView;
@property(nonatomic, strong) NSTextField *profileActivityLabel;
@end

@interface YMHeadlessProfileWindow : NSObject
@property(nonatomic, strong) id attachedSheet;
@end
@implementation YMHeadlessProfileWindow
@end

@interface YMHeadlessProfileEditor : NSObject
@property(nonatomic, strong) id window;
@property(nonatomic, copy) BOOL (^submitHandler)(YMDisplayProfileDraft *draft, NSError **error);
@property(nonatomic, copy) void (^endHandler)(BOOL accepted);
@property(nonatomic) YMDisplayProfileEditorMode mode;
- (void)beginSheetForWindow:(NSWindow *)parent;
- (void)cancel:(id)sender;
@end
@implementation YMHeadlessProfileEditor
- (void)beginSheetForWindow:(NSWindow *)parent { (void)parent; }
- (void)cancel:(id)sender { (void)sender; if (self.endHandler) self.endHandler(NO); }
@end

@interface YMRenameText : NSObject
@property(nonatomic, copy) NSString *stringValue;
@end
@implementation YMRenameText
@end

@interface YMRenameWindow : NSObject
@property(nonatomic) BOOL visible;
@property(nonatomic, strong) id attachedSheet;
@property(nonatomic, weak) id firstResponder;
- (BOOL)makeFirstResponder:(id)responder;
@end
@implementation YMRenameWindow
- (BOOL)makeFirstResponder:(id)responder { self.firstResponder = responder; return YES; }
@end

@interface YMRenameEditorStandIn : NSObject
@property(nonatomic) YMDisplayProfileEditorMode mode;
@property(nonatomic, strong) YMDisplayProfileDraft *draft;
@property(nonatomic, strong) id window;
@property(nonatomic, weak) YMRenameWindow *parent;
@property(nonatomic, copy) BOOL (^submitHandler)(YMDisplayProfileDraft *draft, NSError **error);
@property(nonatomic, copy) void (^endHandler)(BOOL accepted);
@property(nonatomic) NSUInteger begins;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL acceptedResult;
@property(nonatomic, strong) NSError *lastError;
- (void)beginSheetForWindow:(NSWindow *)window;
- (void)submitName:(NSString *)name;
- (void)cancel:(id)sender;
@end
@implementation YMRenameEditorStandIn
- (instancetype)init {
    if ((self = [super init])) _window = [NSObject new];
    return self;
}
- (void)beginSheetForWindow:(NSWindow *)window {
    self.parent = (YMRenameWindow *)(id)window;
    self.parent.attachedSheet = self.window;
    self.parent.visible = YES;
    self.begins++;
}
- (void)submitName:(NSString *)name {
    if (self.finished) return;
    YMDisplayProfileDraft *value = [[YMDisplayProfileDraft alloc] initWithName:name
                                                                          width:self.draft.width
                                                                          hiDPI:self.draft.hiDPI];
    NSError *error = nil;
    BOOL ok = self.submitHandler ? self.submitHandler(value, &error) : NO;
    self.lastError = error;
    if (!ok) return;
    self.finished = YES;
    self.acceptedResult = YES;
    self.parent.attachedSheet = nil;
    void (^end)(BOOL) = self.endHandler;
    self.endHandler = nil;
    self.submitHandler = nil;
    if (end) end(YES);
}
- (void)cancel:(id)sender {
    (void)sender;
    if (self.finished) return;
    self.finished = YES;
    self.acceptedResult = NO;
    self.parent.attachedSheet = nil;
    void (^end)(BOOL) = self.endHandler;
    self.endHandler = nil;
    self.submitHandler = nil;
    if (end) end(NO);
}
@end

@interface YMRenameMenuItem : NSObject
@property(nonatomic, strong) id representedObject;
@end
@implementation YMRenameMenuItem
@end

@interface YMFakeStatusItem : NSObject
@property(nonatomic, strong) NSMenu *menu;
@end
@implementation YMFakeStatusItem
@end

@interface YMRenameEnvironment : NSObject <YMPanelPresentationEnvironment>
@property(nonatomic) NSApplicationActivationPolicy activationPolicy;
@property(nonatomic) BOOL rejectAccessory;
@property(nonatomic) NSUInteger hides;
@property(nonatomic) NSUInteger presentations;
@property(nonatomic) NSUInteger policyRequests;
@property(nonatomic, strong) NSMutableArray *pending;
@property(nonatomic, strong) NSMutableArray *settling;
- (void)drain;
- (void)drainSettling;
@end
@implementation YMRenameEnvironment
- (instancetype)init {
    if ((self = [super init])) {
        _activationPolicy = NSApplicationActivationPolicyAccessory;
        _pending = [NSMutableArray array];
        _settling = [NSMutableArray array];
    }
    return self;
}
- (BOOL)requestActivationPolicy:(NSApplicationActivationPolicy)policy {
    self.policyRequests++;
    if (self.rejectAccessory && policy == NSApplicationActivationPolicyAccessory) return NO;
    self.activationPolicy = policy;
    return YES;
}
- (void)activateApplication {}
- (void)deferUntilAfterMenuTracking:(dispatch_block_t)block {
    [self.pending addObject:[block copy]];
}
- (void)deferUntilPolicySettles:(dispatch_block_t)block {
    [self.settling addObject:[block copy]];
}
- (BOOL)isWindowVisible:(NSWindow *)window {
    return ((YMRenameWindow *)(id)window).visible;
}
- (BOOL)hasAttachedSheetForWindow:(NSWindow *)window {
    return ((YMRenameWindow *)(id)window).attachedSheet != nil;
}
- (void)presentWindow:(NSWindow *)window {
    self.presentations++;
    ((YMRenameWindow *)(id)window).visible = YES;
}
- (void)hideWindow:(NSWindow *)window {
    self.hides++;
    ((YMRenameWindow *)(id)window).visible = NO;
}
- (void)reportActivationPolicyFailure:(NSApplicationActivationPolicy)requested
                        actualPolicy:(NSApplicationActivationPolicy)actual {
    (void)requested; (void)actual;
}
- (void)drain {
    while (self.pending.count) {
        dispatch_block_t block = self.pending.firstObject;
        [self.pending removeObjectAtIndex:0];
        block();
    }
}
- (void)drainSettling {
    while (self.settling.count) {
        dispatch_block_t block = self.settling.firstObject;
        [self.settling removeObjectAtIndex:0];
        block();
    }
}
@end

@interface YMFocusControl : NSObject
@property(nonatomic, weak) id window;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL acceptsFirstResponder;
@end
@implementation YMFocusControl
- (BOOL)isEnabled { return self.enabled; }
@end

@interface ADController (YMProfileEditorFocusTestAccess)
@property(nonatomic, weak) id profileEditorOrigin;
@property(nonatomic) BOOL profileEditorFocusPending;
@end

@interface YMRenameController : YMFakeController
@property(nonatomic) NSUInteger editorCreations;
@property(nonatomic, strong) YMRenameEditorStandIn *lastEditor;
@property(nonatomic) YMDisplayProfileEditorMode lastPresentMode;
@property(nonatomic) NSUInteger lastPresentOrdinal;
@property(nonatomic) NSUInteger presentCalls;
@property(nonatomic) NSUInteger restoreFocusCalls;
@property(nonatomic) BOOL inventoryDrivesPendingRestore;
@end
@implementation YMRenameController
- (YMDisplayProfileEditor *)makeDisplayProfileEditorWithMode:(YMDisplayProfileEditorMode)mode
                                                       draft:(YMDisplayProfileDraft *)draft {
    self.editorCreations++;
    YMRenameEditorStandIn *editor = [YMRenameEditorStandIn new];
    editor.mode = mode;
    editor.draft = draft;
    self.lastEditor = editor;
    return (YMDisplayProfileEditor *)(id)editor;
}
- (void)presentProfileEditorForOrdinal:(NSUInteger)ordinal mode:(YMDisplayProfileEditorMode)mode {
    self.presentCalls++;
    self.lastPresentOrdinal = ordinal;
    self.lastPresentMode = mode;
    [super presentProfileEditorForOrdinal:ordinal mode:mode];
}
- (void)restoreProfileEditorFocus {
    self.restoreFocusCalls++;
    [super restoreProfileEditorFocus];
}
- (void)updateInventory {
    self.inventoryUpdates++;
    // Headless stand-in for the production updateInventory pending-restore handoff.
    // Real AppKit inventory coverage lives in DisplayProfilePanelTests.
    if (self.inventoryDrivesPendingRestore
        && self.profileEditorFocusPending && !self.profileEditor && self.window.attachedSheet == nil) {
        [self restoreProfileEditorFocus];
    }
}
@end

static YMRenameController *RenameController(YMRenameWindow **window, YMRenameEnvironment **environment, YMManagedDisplay **profile) {
    YMRenameController *c = [YMRenameController new];
    YMRenameWindow *w = [YMRenameWindow new];
    YMRenameEnvironment *e = [YMRenameEnvironment new];
    YMFakeDisplay *display = [YMFakeDisplay new];
    YMManagedDisplay *p = [YMManagedDisplay new];
    p.width = 1920; p.height = 1080; p.ordinal = 1;
    p.friendlyName = @"Original";
    p.display = display;
    c.displayProfiles = [NSMutableArray arrayWithObject:p];
    c.selectedProfile = p;
    c.virtualDisplay = display;
    c.statusLabel = (NSTextField *)(id)[YMRenameText new];
    c.detailLabel = (NSTextField *)(id)[YMRenameText new];
    c.window = (NSWindow *)(id)w;
    c.useRealPanelPresentation = YES;
    c.panelPresenter = [[YMControlPanelPresenter alloc] initWithWindow:(NSWindow *)(id)w environment:e];
    if (window) *window = w;
    if (environment) *environment = e;
    if (profile) *profile = p;
    return c;
}

static NSUInteger Tests, Failures;
static void Expect(BOOL value, const char *name) { Tests++; if (!value) { Failures++; fprintf(stderr,"FAIL %s\n",name); } }
static YMFakeController *Controller(YMFakeTopology **t, YMFakeDisplay **d, YMManagedDisplay **p, YMManagedDisplay **s) {
    YMFakeController *c = [YMFakeController new];
    *t = [YMFakeTopology new]; c.displayTopology = (YMDisplayTopology *)*t;
    *d = [YMFakeDisplay new]; (*d).fixtureID = 202;
    *p = [YMManagedDisplay new]; (*p).width=800; (*p).height=600; (*p).ordinal=2; (*p).friendlyName=@"fixture"; (*p).display=*d;
    YMFakeDisplay *older = [YMFakeDisplay new]; older.live = YES; older.fixtureID=101;
    *s = [YMManagedDisplay new]; (*s).width=800; (*s).height=600; (*s).display=older; (*s).topologyVerified=YES;
    c.displayProfiles=[NSMutableArray arrayWithArray:@[*s,*p]]; c.selectedProfile=*p; c.virtualDisplay=*d;
    return c;
}
int main(void) {
    @autoreleasepool {
        Expect(NSApp == nil,"tests begin without NSApplication");
        YMFakeTopology *t; YMFakeDisplay *d; YMManagedDisplay *p,*s;
        YMFakeController *c = Controller(&t,&d,&p,&s);
        __weak YMFakeController *weakC=c; __weak YMManagedDisplay *weakP=p;
        t.duringCapture=^{Expect(weakC.displayOperationInProgress,"busy begins before capture");};
        t.duringConfigure=^{Expect(weakC.displayOperationInProgress,"busy during configure"); Expect(![weakC canMoveIntoProfile:weakP],"no admission during configure");};
        [c create:nil];
        Expect(d.creates==1&&d.destroys==0,"success creates once, retains target");
        Expect(p.topologyVerified&&[c canMoveIntoProfile:p],"success opens real admission gate");
        Expect(c.saves==1&&!c.displayOperationInProgress,"success saved and busy released");
        Expect(s.display.isCreated&&[(YMFakeDisplay *)s.display destroys]==0,"success preserves older object");
        t.extended=NO; Expect(![c canMoveIntoProfile:p],"later mirror/mode mismatch closes admission");

        c=Controller(&t,&d,&p,&s); t.configureResult=NO;
        weakC=c; weakP=p;
        t.duringRestore=^{Expect(weakC.displayOperationInProgress,"busy through rollback");Expect(![weakC canMoveIntoProfile:weakP],"no admission during rollback");};
        [c create:nil];
        Expect(d.creates==1&&d.destroys==1&&!d.live,"configuration failure destroys only new target");
        Expect(t.restorations==1&&t.lastRemoved==202,"rollback receives exact removed ID");
        Expect(!p.topologyVerified&&!c.topologyRecoverySnapshot&&!c.displayOperationInProgress,"verified rollback clears busy without admitting target");
        Expect(c.saves==0&&c.reports==1,"failed target not persisted as success");
        Expect(s.display.isCreated&&[(YMFakeDisplay *)s.display destroys]==0,"rollback preserves older object");

        c=Controller(&t,&d,&p,&s); t.configureResult=NO; t.restoreResult=NO; [c create:nil];
        Expect(c.topologyRecoverySnapshot==t.snapshot&&c.topologyRecoveryRemovedID==202,"failed recovery retains snapshot and target ID");
        Expect(![c canMoveIntoProfile:s],"recovery failure gates sibling admission too");
        NSUInteger priorCreates=d.creates; [c create:nil]; Expect(d.creates==priorCreates,"pending recovery blocks subsequent creation");
        t.restoreResult=YES; [c retryTopologyRecovery:nil];
        Expect(!c.topologyRecoverySnapshot&&!c.topologyRecoveryRemovedID,"successful retry clears pending state");
        Expect([c canMoveIntoProfile:s],"recovery retry restores verified sibling admission");
        Expect(![c canMoveIntoProfile:p],"recovery retry does not admit removed target");

        // A held operation exercises the real async boundary without starting
        // AppKit, dispatching to a background queue, or invoking CoreGraphics.
        c=Controller(&t,&d,&p,&s); c.deferTopologyOperations=YES;
        [c create:nil];
        Expect(d.live&&t.configurations==0&&c.pendingTopologyOperations.count==1,"creation returns while topology verification remains queued");
        Expect(c.displayOperationInProgress&&!p.topologyVerified,"pending creation remains busy and unverified");
        [c selectProfile:s];
        Expect(c.selectedProfile==p&&c.virtualDisplay==d,"pending configuration prevents selection changes");
        BOOL droppedSafely=YES;
        @try { [c dropApplication:(NSDictionary *)(id)[NSObject new] targetDisplayID:202]; } @catch(NSException *e) { (void)e; droppedSafely=NO; }
        Expect(droppedSafely&&!c.appOperationInProgress,"pending configuration rejects drop before reading invalid payload");
        Expect([c applicationShouldTerminate:(NSApplication *)(id)[NSObject new]]==NSTerminateCancel&&d.destroys==0&&c.stopCalls==0,"pending configuration rejects quit without destroying output");
        Expect(![c canMoveIntoProfile:p]&&![c canMoveIntoProfile:s],"all incoming admission blocked while configuration pending");
        NSUInteger queuedCreates=d.creates;
        [c create:nil]; Expect(d.creates==queuedCreates&&c.pendingTopologyOperations.count==1,"pending creation cannot start a second operation");
        c.selectedProfile=s; c.virtualDisplay=s.display;
        [c runNextTopologyOperation];
        Expect(t.lastConfigured==202&&p.topologyVerified,"queued creation operates on its frozen original profile");
        Expect(c.selectedProfile==s&&s.topologyVerified&&[(YMFakeDisplay *)s.display destroys]==0,"completion preserves later selection and sibling object");
        Expect(!c.displayOperationInProgress&&[c canMoveIntoProfile:p],"successful async completion releases busy and admission");

        c=Controller(&t,&d,&p,&s); c.deferTopologyOperations=YES; t.configureResult=NO;
        [c create:nil]; c.selectedProfile=s; c.virtualDisplay=s.display;
        [c runNextTopologyOperation];
        Expect(d.destroys==1&&!d.live&&[(YMFakeDisplay *)s.display destroys]==0,"failed async creation destroys only captured original target");
        Expect(c.displayOperationInProgress&&c.pendingTopologyOperations.count==1,"rollback stays busy until its own queued verification");
        Expect(![c canMoveIntoProfile:s],"sibling admission remains blocked while rollback is pending");
        [c selectProfile:p];
        Expect(c.selectedProfile==s,"pending rollback prevents selection changes");
        droppedSafely=YES;
        @try { [c dropApplication:(NSDictionary *)(id)[NSObject new] targetDisplayID:101]; } @catch(NSException *e) { (void)e; droppedSafely=NO; }
        Expect(droppedSafely&&!c.appOperationInProgress,"pending rollback rejects drop before reading invalid payload");
        Expect([c applicationShouldTerminate:(NSApplication *)(id)[NSObject new]]==NSTerminateCancel&&[(YMFakeDisplay *)s.display destroys]==0,"pending rollback rejects quit without destroying survivor");
        [c runNextTopologyOperation];
        Expect(t.lastRemoved==202&&!c.displayOperationInProgress&&!c.topologyRecoverySnapshot,"queued rollback completes against exact removed ID");
        Expect([c canMoveIntoProfile:s]&&!p.topologyVerified,"successful rollback reopens survivor gate only");

        c=Controller(&t,&d,&p,&s); c.deferTopologyOperations=YES; t.configureResult=NO; t.restoreResult=NO;
        [c create:nil]; [c runNextTopologyOperation]; [c runNextTopologyOperation];
        Expect(c.topologyRecoverySnapshot==t.snapshot&&!c.displayOperationInProgress,"failed queued recovery retains original snapshot after busy clears");
        t.restoreResult=YES; [c retryTopologyRecovery:nil];
        Expect(c.displayOperationInProgress&&c.topologyRecoverySnapshot==t.snapshot&&c.pendingTopologyOperations.count==1,"queued recovery retry retains snapshot and busy until verified");
        [c runNextTopologyOperation];
        Expect(!c.topologyRecoverySnapshot&&!c.displayOperationInProgress&&[c canMoveIntoProfile:s],"queued recovery completion clears pending and restores admission");

        c=Controller(&t,&d,&p,&s); t.captureResult=NO; [c create:nil];
        Expect(d.creates==0&&t.configurations==0&&t.restorations==0,"incomplete baseline causes no creation or mutation");
        Expect(!p.topologyVerified&&!c.displayOperationInProgress,"capture failure leaves target denied and idle");
        c=Controller(&t,&d,&p,&s); d.createResult=NO; [c create:nil];
        Expect(d.creates==1&&t.configurations==0&&t.restorations==1,"private API create failure still verifies original baseline");
        Expect(d.destroys==0&&s.display.isCreated,"create failure never destroys older display");
        c=Controller(&t,&d,&p,&s); c.powerFails=YES; [c create:nil];
        Expect(d.destroys==1&&t.restorations==1&&!p.topologyVerified,"power assertion failure rolls new output back");
        Expect(s.display.isCreated,"power failure preserves sibling");
        c=Controller(&t,&d,&p,&s);
        c.displayProfiles=[NSMutableArray arrayWithObject:s]; c.selectedProfile=s; c.virtualDisplay=s.display;
        c.simulateFinalRemovalRecoveryFailure=YES; t.restoreResult=NO;
        // The production method explicitly ignores sender; no app singleton is created.
        NSApplication *unusedSender=(NSApplication *)(id)[NSObject new];
        NSApplicationTerminateReply reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel,"last-output recovery failure cancels termination");
        Expect(!s.display.isCreated&&c.stopCalls==1,"termination observes removed final output");
        Expect(c.topologyRecoverySnapshot==t.snapshot,"termination retains failed recovery snapshot");
        Expect(c.showCalls==1,"failed final recovery exposes recovery controls");
        reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel&&c.stopCalls==1,"repeated quit retries recovery without another destroy");
        t.restoreResult=YES; reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel&&!c.topologyRecoverySnapshot&&c.resumedTerminations==1,"verified recovery schedules a new termination pass");
        reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateNow,"subsequent quit proceeds after verified recovery");

        c=Controller(&t,&d,&p,&s); c.deferTopologyOperations=YES;
        c.displayProfiles=[NSMutableArray arrayWithObject:s]; c.selectedProfile=s; c.virtualDisplay=s.display;
        c.simulateFinalRemovalRecoveryFailure=YES; t.restoreResult=NO;
        reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel&&c.displayOperationInProgress&&!s.display.isCreated,"async final-output removal keeps termination pending");
        Expect(c.topologyRecoverySnapshot==t.snapshot&&c.resumedTerminations==0,"quit retains rollback snapshot until worker completes");
        [c runNextTopologyOperation];
        Expect(c.topologyRecoverySnapshot==t.snapshot&&!c.displayOperationInProgress&&c.resumedTerminations==0,"failed async rollback cannot resume termination");
        t.restoreResult=YES; reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel&&c.displayOperationInProgress&&c.stopCalls==1,"later quit retries recovery without removing again");
        [c runNextTopologyOperation];
        Expect(c.resumedTerminations==1&&!c.topologyRecoverySnapshot&&!c.displayOperationInProgress,"successful async recovery resumes termination exactly once");
        c=Controller(&t,&d,&p,&s); c.deferTopologyOperations=YES; d.live=YES; p.topologyVerified=YES;
        c.simulateFinalRemovalRecoveryFailure=YES;
        reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel&&!s.display.isCreated&&d.live&&c.stopCalls==1,"multi-output quit removes only first screen before verification");
        Expect(c.pendingTopologyOperations.count==1&&c.resumedTerminations==0,"multi-output quit waits for first restoration");
        [c runNextTopologyOperation];
        Expect(c.resumedTerminations==1&&d.live,"first verified removal schedules continuation and preserves second output");
        reply=[c applicationShouldTerminate:unusedSender];
        Expect(reply==NSTerminateCancel&&!d.live&&c.stopCalls==2,"continuation closes second output in sequence");
        [c runNextTopologyOperation];
        Expect(c.resumedTerminations==2&&c.pendingTopologyOperations.count==0,"second verified removal schedules final termination exactly once");
        Expect([c applicationShouldTerminate:unusedSender]==NSTerminateNow,"multi-output quit completes only after both restorations");

        YMFakeController *panelController = [YMFakeController new];
        YMSpyPanelWindow *panel = [YMSpyPanelWindow new];
        panelController.window = (NSWindow *)(id)panel;
        [panelController preparePanelPresenter];
        Expect(panelController.panelPresenter != nil && NSApp == nil,
               "binding creates no application or window");
        YMSpyPanelPresenter *spy = [YMSpyPanelPresenter new];
        spy.acceptClose = YES;
        panelController.panelPresenter = (YMControlPanelPresenter *)(id)spy;
        panelController.useRealPanelPresentation = YES;
        YMSpyHeartbeat *heartbeat = [YMSpyHeartbeat new];
        panelController.heartbeatTimer = (NSTimer *)(id)heartbeat;
        [panelController showWindow:nil];
        Expect(spy.opens == 1, "showWindow uses the retained presenter");
        Expect(![panelController applicationShouldHandleReopen:(NSApplication *)(id)[NSObject new] hasVisibleWindows:NO] && spy.opens == 2,
               "application reopen uses the same presenter");
        Expect(![panelController windowShouldClose:panelController.window] && spy.closes == 1,
               "panel close is delegated but never destroys the NSWindow");
        Expect(spy.lastClosedWindow == panelController.window && panel.ordersOut == 0,
               "controller does not bypass the presenter's sheet and identity guard");
        Expect(heartbeat.invalidations == 0 && panelController.stopCalls == 0,
               "closing panel neither invalidates heartbeat nor stops workspaces");
        spy.acceptClose = NO;
        Expect(![panelController windowShouldClose:panelController.window] && panel.ordersOut == 0,
               "refused close leaves the panel untouched");
        YMSpyPanelWindow *other = [YMSpyPanelWindow new];
        NSUInteger closes = spy.closes;
        [panelController windowShouldClose:(NSWindow *)(id)other];
        Expect(spy.closes == closes && other.ordersOut == 1,
               "other-window close preserves old hide behavior without application demotion");
        panelController.previewMode = YES;
        NSUInteger opens = spy.opens;
        [panelController showWindow:nil];
        Expect(spy.opens == opens, "preview cannot activate the interactive presenter");
        [panelController preparePanelPresenter];
        Expect(!panelController.panelPresenter && spy.invalidations == 1,
               "preview binding drops the interactive presenter");
        panelController.previewMode = NO;
        panelController.panelPresenter = (YMControlPanelPresenter *)(id)spy;
        [panelController applicationWillTerminate:(NSNotification *)(id)[NSObject new]];
        Expect(spy.invalidations == 2 && heartbeat.invalidations == 1,
               "actual termination invalidates lifecycle before cleanup completes");

        c = Controller(&t, &d, &p, &s);
        YMSpyPanelPresenter *recoverySpy = [YMSpyPanelPresenter new];
        recoverySpy.acceptClose = YES;
        c.window = (NSWindow *)(id)[YMSpyPanelWindow new];
        c.panelPresenter = (YMControlPanelPresenter *)(id)recoverySpy;
        c.useRealPanelPresentation = YES;
        [c windowShouldClose:c.window];
        Expect(s.display.isCreated && [(YMFakeDisplay *)s.display destroys] == 0 && c.stopCalls == 0,
               "closing panel preserves an existing virtual display object");
        c.displayProfiles = [NSMutableArray arrayWithObject:s];
        c.selectedProfile = s; c.virtualDisplay = s.display;
        c.simulateFinalRemovalRecoveryFailure = YES; t.restoreResult = NO;
        Expect([c applicationShouldTerminate:unusedSender] == NSTerminateCancel,
               "existing topology failure still cancels quit");
        Expect(recoverySpy.opens == 1,
               "safety recovery can reopen a previously closed panel through the actual showWindow path");

        // Exact production updater termination branch, with no defaults writes,
        // WindowServer calls, process termination or third-party app access.
        c=Controller(&t,&d,&p,&s);
        YMControllerUpdateEngine *updater=[YMControllerUpdateEngine new];
        updater.installationPending=YES; updater.installationAuthorized=YES;
        updater.latestVersion=@"0.3.7"; updater.latestBuild=@"13";
        c.automaticUpdater=(YMAutomaticUpdater *)(id)updater;
        YMControllerUpdateRecovery *journal=[YMControllerUpdateRecovery new]; journal.commitResult=YES;
        c.updateRecovery=(YMUpdateWorkspaceRecovery *)(id)journal;
        c.appWorkspace=(YMAppWorkspace *)(id)[YMControllerUpdateWorkspace new];
        Expect([c prepareUpdateRestart:NULL] && journal.preparations==1 && c.updateWorkspaceBusy,
            "preparation checkpoints and freezes yomado workspace controls");
        Expect(![c canMoveIntoProfile:s], "prepared update prevents moving more apps into owned screens");
        NSUInteger saved=c.saves;
        [c create:nil]; [c stop:nil];
        // Fake stop itself does not include production action guard; create must.
        Expect(d.creates==0 && c.saves==saved, "prepared update prevents a new screen operation");
        c.stopCalls=0;
        Expect([c applicationShouldTerminate:unusedSender]==NSTerminateNow && journal.commits==1,
            "authorized update rechecks checkpoint immediately at termination");
        Expect(c.stopCalls==0 && [(YMFakeDisplay *)s.display destroys]==0 && c.panelCheckpoints==1,
            "update quit does not sweep apps back to physical screens or remove sibling displays early");
        journal.commitResult=NO; c.updateWorkspaceBusy=YES;
        Expect([c applicationShouldTerminate:unusedSender]==NSTerminateCancel && updater.deferrals==1,
            "late window change vetoes installer termination");
        Expect(!c.updateWorkspaceBusy && !updater.installationAuthorized && updater.installationPending,
            "late veto unlocks app controls while keeping installer pending and gated");
        NSUInteger commits=journal.commits;
        Expect([c applicationShouldTerminate:unusedSender]==NSTerminateCancel && journal.commits==commits,
            "later ordinary quit cannot bypass a deferred update's preparation gate");
        c.displayOperationInProgress=YES;
        NSUInteger preparations=journal.preparations;
        Expect(![c prepareUpdateRestart:NULL] && journal.preparations==preparations,
            "in-flight display operation prevents preparing an updater restart");
        c.displayOperationInProgress=NO; c.updateRecoveryFailed=YES;
        Expect(![c prepareUpdateRestart:NULL] && journal.preparations==preparations,
            "failed recovery cannot be overwritten by another update checkpoint");
        c.updateRecoveryFailed=NO;
        YMControllerLegacyRecovery *legacyRecovery=[YMControllerLegacyRecovery new];
        legacyRecovery.needsRestoreBeforeRemovingVirtualDisplay=YES;
        c.windowRecovery=(YMWindowRecovery *)(id)legacyRecovery;
        NSError *legacyError=nil;
        Expect(![c prepareUpdateRestart:&legacyError] && legacyError.code==106 && journal.preparations==preparations,
            "pending dedicated WeChat recovery defers update before replacing its exact tracked window state");
        Expect(legacyRecovery.needsRestoreBeforeRemovingVirtualDisplay,
            "update gate leaves the dedicated recovery record untouched");

        c=Controller(&t,&d,&p,&s);
        updater=[YMControllerUpdateEngine new];
        c.automaticUpdater=(YMAutomaticUpdater *)(id)updater;
        journal=[YMControllerUpdateRecovery new];
        c.updateRecovery=(YMUpdateWorkspaceRecovery *)(id)journal;
        c.updateRecoveryFailed=YES; c.updateRecoveryMessage=@"pending recovery";
        [c automaticUpdateStateDidChange];
        Expect(journal.cancellations==0 && [c.updateRecoveryMessage isEqual:@"pending recovery"],
            "idle updater retains failed startup recovery even without claimed profiles");
        updater.status=YMAutomaticUpdateChecking;
        [c automaticUpdateStateDidChange];
        Expect(journal.cancellations==0 && [c.updateRecoveryMessage isEqual:@"pending recovery"],
            "scheduled checking cannot clear a failed recovery record or explanation");
        c.updateRecoveryFailed=NO; c.pendingUpdateProfiles=@[];
        [c automaticUpdateStateDidChange];
        Expect(journal.cancellations==0,"claimed recovery remains protected from updater cleanup");
        c.pendingUpdateProfiles=nil; updater.status=YMAutomaticUpdateCancelled;
        c.updateWorkspaceBusy=YES;
        [c automaticUpdateStateDidChange];
        Expect(journal.cancellations==1 && !c.updateWorkspaceBusy,
            "ordinary cancelled preparation still releases its own checkpoint and controls");

        YMUpdateCompletionController *completionController=[YMUpdateCompletionController new];
        NSMutableArray *events=[NSMutableArray array]; completionController.events=events;
        completionController.pendingUpdateProfiles=@[];
        YMControllerUpdateRecovery *restoreJournal=[YMControllerUpdateRecovery new];
        restoreJournal.events=events; restoreJournal.restoreResult=YES;
        restoreJournal.restoredOriginCheckpoints=@[@{@"fixture":@"nonempty-return-point"}];
        completionController.updateRecovery=(YMUpdateWorkspaceRecovery *)(id)restoreJournal;
        YMControllerUpdateWorkspace *restoreWorkspace=[YMControllerUpdateWorkspace new];
        restoreWorkspace.events=events;
        completionController.appWorkspace=(YMAppWorkspace *)(id)restoreWorkspace;
        [completionController restoreUpdateProfileAtIndex:0];
        Expect(restoreWorkspace.adoptedNonemptyOrigins && [events isEqual:@[@"restore",@"inventory",@"adopt",@"complete",@"finished"]],
            "nonempty return points are adopted only after refreshing recreated display inventory");
        Expect(completionController.completionError==nil,"verified complete recovery succeeds");
        [events removeAllObjects]; restoreJournal.restoreResult=NO;
        [completionController restoreUpdateProfileAtIndex:0];
        Expect(completionController.completionError!=nil && [events isEqual:@[@"restore",@"finished"]],
            "backend failure without NSError cannot be announced as a successful recovery");

        // Production confirmation logic with only inventory and prompt-boundary fakes.
        {
            YMUnmovableWorkspace *workspace = [YMUnmovableWorkspace new];
            workspace.windowsByDisplayID[@101] = @[
                @{@"appName": @"Editor", @"count": @1},
                @{@"appName": @"Tool", @"count": @1}
            ];
            workspace.windowsByDisplayID[@202] = @[@{@"appName": @"Editor", @"count": @2}];
            YMUnmovableController *controller = [YMUnmovableController new];
            controller.appWorkspace = (YMAppWorkspace *)(id)workspace;
            controller.useProductionUnmovableConfirmation = YES;
            controller.confirmationResponse = YES;
            BOOL confirmed = [controller confirmUnmovableWindowsOnDisplayIDs:@[@101, @202]];
            Expect(confirmed && controller.confirmationCalls == 1,
                   "production confirmation prompts once for unmovable windows across screens");
            Expect([controller.confirmationSummary isEqualToString:@"「Editor」3 个窗口、「Tool」1 个窗口"],
                   "multi-screen confirmation aggregates counts by application");
            Expect([workspace.allowedDisplayIDs isEqualToArray:@[@101, @202]],
                   "continuing authorizes the exact displayed screen IDs");
            Expect(NSApp == nil, "unmovable confirmation tests do not create NSApplication");

            workspace = [YMUnmovableWorkspace new];
            workspace.windowsByDisplayID[@202] = @[@{@"appName": @"Dialog", @"count": @1}];
            controller = [YMUnmovableController new];
            controller.appWorkspace = (YMAppWorkspace *)(id)workspace;
            controller.useProductionUnmovableConfirmation = YES;
            controller.confirmationResponse = NO;
            confirmed = [controller confirmUnmovableWindowsOnDisplayIDs:@[@202]];
            Expect(!confirmed && controller.confirmationCalls == 1 && workspace.allowedDisplayIDs.count == 0,
                   "canceling the production confirmation grants no allowance");
            Expect(workspace.cancelAllowanceCalls == 1,
                   "canceling clears offered unmovable-window allowances");

            workspace = [YMUnmovableWorkspace new];
            controller = [YMUnmovableController new];
            controller.appWorkspace = (YMAppWorkspace *)(id)workspace;
            controller.useProductionUnmovableConfirmation = YES;
            controller.confirmationResponse = NO;
            confirmed = [controller confirmUnmovableWindowsOnDisplayIDs:@[@202]];
            Expect(confirmed && controller.confirmationCalls == 0 && workspace.allowedDisplayIDs.count == 0,
                   "an empty unmovable-window list succeeds without prompting or authorizing");

            workspace = [YMUnmovableWorkspace new];
            workspace.pendingReadsByDisplayID[@202] = @1;
            workspace.windowsByDisplayID[@202] = @[@{@"appName": @"Dialog", @"count": @1}];
            controller = [YMUnmovableController new];
            controller.appWorkspace = (YMAppWorkspace *)(id)workspace;
            controller.useProductionUnmovableConfirmation = YES;
            controller.confirmationResponse = YES;
            confirmed = [controller confirmUnmovableWindowsOnDisplayIDs:@[@202]];
            Expect(confirmed && workspace.queriedDisplayIDs.count >= 2 && controller.inventoryUpdates >= 2,
                   "pending inventory is retried until it becomes ready");
            Expect(controller.confirmationCalls == 1 && [workspace.allowedDisplayIDs isEqualToArray:@[@202]],
                   "ready inventory is summarized and authorized only after confirmation");

            workspace = [YMUnmovableWorkspace new];
            [workspace.neverReadyDisplayIDs addObject:@202];
            controller = [YMUnmovableController new];
            controller.appWorkspace = (YMAppWorkspace *)(id)workspace;
            controller.useProductionUnmovableConfirmation = YES;
            controller.confirmationResponse = YES;
            NSDate *started = [NSDate date];
            confirmed = [controller confirmUnmovableWindowsOnDisplayIDs:@[@202]];
            NSTimeInterval waited = -[started timeIntervalSinceNow];
            Expect(!confirmed && controller.confirmationCalls == 0 && workspace.allowedDisplayIDs.count == 0,
                   "inventory timeout retains the screen without prompting or authorizing");
            Expect(workspace.cancelAllowanceCalls == 1 && controller.applicationErrors == 1,
                   "inventory timeout clears allowances and reports the blocked close");
            Expect(waited >= 1.4 && waited < 3.0,
                   "unmovable inventory readiness wait is bounded near 1.5 seconds");

            YMUnmovableWorkspace *quitWorkspace = [YMUnmovableWorkspace new];
            quitWorkspace.windowsByDisplayID[@202] = @[@{@"appName": @"Dialog", @"count": @1}];
            quitWorkspace.restoreFailureDisplayID = 202;
            YMUnmovableController *quitController = [YMUnmovableController new];
            YMFakeDisplay *firstDisplay = [YMFakeDisplay new];
            firstDisplay.live = YES; firstDisplay.fixtureID = 101;
            YMFakeDisplay *secondDisplay = [YMFakeDisplay new];
            secondDisplay.live = YES; secondDisplay.fixtureID = 202;
            YMManagedDisplay *firstProfile = [YMManagedDisplay new]; firstProfile.display = firstDisplay;
            YMManagedDisplay *secondProfile = [YMManagedDisplay new]; secondProfile.display = secondDisplay;
            quitController.displayProfiles = [NSMutableArray arrayWithArray:@[firstProfile, secondProfile]];
            quitController.selectedProfile = firstProfile;
            quitController.virtualDisplay = firstDisplay;
            quitController.appWorkspace = (YMAppWorkspace *)(id)quitWorkspace;
            quitController.useProductionUnmovableConfirmation = YES;
            quitController.useProductionAppRestore = YES;
            quitController.confirmationResponse = YES;
            NSApplicationTerminateReply reply =
                [quitController applicationShouldTerminate:(NSApplication *)(id)[NSObject new]];
            Expect(reply == NSTerminateCancel && quitController.stopCalls == 0,
                   "failure restoring any screen cancels quit before stopping one");
            Expect(firstDisplay.live && secondDisplay.live &&
                   [quitWorkspace.restoreDisplayIDs isEqualToArray:@[@101, @202]],
                   "quit restores every workspace before removing any screen");
            Expect(quitWorkspace.allowedDisplayIDs.count == 0 && quitWorkspace.cancelAllowanceCalls == 1,
                   "failed multi-screen quit clears temporary unmovable-window allowances");
        }

        // Group 5: ready wait + single restore write; timeout retains virtual display.
        {
            YMFakeTopology *closeT = [YMFakeTopology new];
            YMFakeDisplay *closeD = [YMFakeDisplay new];
            closeD.live = YES; closeD.fixtureID = 202;
            YMManagedDisplay *closeP = [YMManagedDisplay new];
            closeP.width = 800; closeP.height = 600; closeP.display = closeD; closeP.topologyVerified = YES;
            YMCloseGateController *closeController = [YMCloseGateController new];
            closeController.displayTopology = (YMDisplayTopology *)closeT;
            closeController.displayProfiles = [NSMutableArray arrayWithObject:closeP];
            closeController.selectedProfile = closeP;
            closeController.virtualDisplay = closeD;
            closeController.useProductionAppRestore = YES;
            YMCloseGateWorkspace *gate = [YMCloseGateWorkspace new];
            gate.inventoryReady = YES;
            gate.needsRestoreFlag = NO;
            gate.restoreResult = YES;
            closeController.appWorkspace = (YMAppWorkspace *)(id)gate;
            closeController.windowRecovery = (YMWindowRecovery *)(id)[YMControllerLegacyRecovery new];
            BOOL restored = [closeController restoreApplicationsForDisplayID:202];
            Expect(restored && gate.restoreCalls == 1,
                   "ready inventory restores the display exactly once");
            Expect(gate.closingReadyPolls > 0 && gate.lastClosingDisplayID == 202,
                   "production close checks inventory readiness for the target display");
            Expect(gate.needsRestorePolls >= 1,
                   "convergence polling observes needsRestore without a second write");
            Expect(closeD.live && closeD.destroys == 0, "successful restore does not destroy the display");

            gate.restoreCalls = 0; gate.readyPolls = 0; gate.needsRestorePolls = 0; gate.closingReadyPolls = 0;
            gate.inventoryReady = YES;
            gate.closingReadinessOverrideEnabled = YES;
            gate.closingReadinessOverride = NO;
            gate.refreshesBeforeReady = 0; // never becomes ready
            NSDate *started = [NSDate date];
            restored = [closeController restoreApplicationsForDisplayID:202];
            NSTimeInterval waited = -[started timeIntervalSinceNow];
            Expect(!restored && gate.restoreCalls == 0 && gate.closingReadyPolls > 0 && gate.readyPolls == 0,
                   "per-display readiness timeout blocks writes even when global inventory is ready");
            Expect(waited >= 1.4 && waited < 3.0, "ready wait bounds near 1.5 seconds");
            Expect(closeD.live && closeD.destroys == 0,
                   "timeout does not remove the virtual display");
            Expect(closeController.reports >= 1, "timeout reports and retains the screen");

            // Ready after several refreshes, then a single restore write.
            gate.restoreCalls = 0; gate.readyPolls = 0; gate.needsRestorePolls = 0; gate.closingReadyPolls = 0;
            gate.closingReadinessOverrideEnabled = NO;
            gate.needsRestoreFlag = NO;
            gate.restoreResult = YES;
            gate.inventoryReady = NO;
            gate.refreshesBeforeReady = 3;
            [gate.events removeAllObjects];
            restored = [closeController restoreApplicationsForDisplayID:202];
            Expect(restored && gate.restoreCalls == 1,
                   "ready after several refreshes restores the display exactly once");
            Expect(gate.closingReadyPolls >= 3 && gate.readyPolls >= 3,
                   "controller waits through per-display readiness refreshesBeforeReady");

            // WeChat world-change must happen before the ready wait that authorizes restore.
            // If wait runs first, WeChat invalidates ready and restoreDisplayID refuses.
            // Display reads go through controllerDisplaySnapshot — never real CG/NSScreen.
            YMIsolatedWeChatController *wechatController = [YMIsolatedWeChatController new];
            wechatController.displayTopology = (YMDisplayTopology *)closeT;
            wechatController.displayProfiles = [NSMutableArray arrayWithObject:closeP];
            wechatController.selectedProfile = closeP;
            wechatController.virtualDisplay = closeD;
            wechatController.useProductionAppRestore = YES;
            wechatController.appWorkspace = (YMAppWorkspace *)(id)gate;
            wechatController.fakeDisplaySnapshot =
                @[@{@"displayID": @5, @"displayUUID": @"physical",
                    @"bounds": @{@"x": @0, @"y": @0, @"width": @2560, @"height": @1440},
                    @"isMain": @YES, @"isActive": @YES, @"isOnline": @YES, @"isVirtual": @NO},
                  @{@"displayID": @202, @"displayUUID": @"agent",
                    @"bounds": @{@"x": @2560, @"y": @0, @"width": @2560, @"height": @1440},
                    @"isMain": @NO, @"isActive": @YES, @"isOnline": @YES, @"isVirtual": @YES}];
            YMControllerLegacyRecovery *wechatRecovery = [YMControllerLegacyRecovery new];
            wechatRecovery.needsRestoreBeforeRemovingVirtualDisplay = YES;
            wechatRecovery.workspaceToInvalidate = gate;
            wechatController.windowRecovery = (YMWindowRecovery *)(id)wechatRecovery;
            wechatController.wechatDisplayID = 202;
            gate.restoreCalls = 0; gate.readyPolls = 0; gate.needsRestorePolls = 0;
            gate.needsRestoreFlag = NO;
            gate.restoreResult = YES;
            gate.inventoryReady = YES;
            gate.refreshesBeforeReady = 0;
            [gate.events removeAllObjects];
            [wechatRecovery.events removeAllObjects];
            restored = [wechatController restoreApplicationsForDisplayID:202];
            Expect(wechatRecovery.restoreWeChatCalls == 1, "pending WeChat restore runs during close");
            Expect(restored && gate.restoreCalls == 1,
                   "ready wait after WeChat world-change still restores once");
            Expect(wechatController.displaySnapshotCalls >= 1,
                   "WeChat close path uses overridable controllerDisplaySnapshot");
            Expect(wechatRecovery.refreshSnapshotCount == 1 &&
                   [wechatRecovery.lastRefreshSnapshot isEqual:wechatController.fakeDisplaySnapshot],
                   "WeChat refresh receives fake snapshot, not live DisplaySnapshot");
            Expect([wechatRecovery.events indexOfObject:@"wechatRestore"] != NSNotFound &&
                   [gate.events indexOfObject:@"restore"] != NSNotFound,
                   "WeChat restore and app restore both recorded");
            Expect(restored, "WeChat-then-ready-then-restore close path succeeds");
        }

        {
            BOOL seamAvailable = [ADController instancesRespondToSelector:
                @selector(makeDisplayProfileEditorWithMode:draft:)];
            Expect(seamAvailable, "profile editor factory has a headless boundary");
            BOOL presentAvailable = [ADController instancesRespondToSelector:
                @selector(presentProfileEditorForOrdinal:mode:)];
            Expect(presentAvailable, "profile editor present entry exists");
            if (!seamAvailable || !presentAvailable) goto rename_tests_done;

            YMRenameWindow *w;
            YMRenameEnvironment *e;
            YMManagedDisplay *profile;
            YMRenameController *c = RenameController(&w, &e, &profile);
            [c showWindow:nil]; [e drain];
            [c windowShouldClose:c.window]; [e drain];
            NSUInteger hides = e.hides, opens = c.showCalls;
            YMRenameMenuItem *item = [YMRenameMenuItem new];
            item.representedObject = profile;
            [c renameManagedDisplayFromMenu:(NSMenuItem *)(id)item];
            Expect(c.showCalls == opens + 1, "menu rename uses the normal open entry");
            Expect(c.presentCalls == 1 && c.lastPresentMode == YMDisplayProfileEditorModeRename
                   && c.lastPresentOrdinal == profile.ordinal,
                   "menu rename presents rename mode with stable ordinal");
            Expect(c.editorCreations == 1 && c.lastEditor.mode == YMDisplayProfileEditorModeRename,
                   "menu rename uses editor factory");
            Expect(c.panelPresenter.panelOpen, "rename restores logical open state");
            [e drain];
            Expect(e.activationPolicy == NSApplicationActivationPolicyRegular,
                   "rename restores regular lifecycle");
            [c.lastEditor cancel:nil];
            Expect(c.panelPresenter.panelOpen && w.visible && c.saves == 0 && !c.lastEditor.acceptedResult,
                   "cancel keeps the panel open without saving");
            [c windowShouldClose:c.window]; [e drain];
            Expect(!w.visible && !c.panelPresenter.panelOpen && e.hides == hides + 1,
                   "explicit close after rename hides the same panel");
            NSWindow *originalWindow = c.window;
            [c showWindow:nil]; [e drain];
            Expect(w.visible && c.panelPresenter.panelOpen && c.window == originalWindow,
                   "normal reopen reuses the panel");
            [c windowShouldClose:c.window]; [e drain];
            Expect(!w.visible && e.hides == hides + 2, "reopened panel closes again");
            Expect(NSApp == nil, "rename regression never initializes the application");
            [c.panelPresenter invalidate];
            [e.pending removeAllObjects];
            [e.settling removeAllObjects];

            {
                YMRenameWindow *cw; YMRenameEnvironment *ce; YMManagedDisplay *cp;
                YMRenameController *cc = RenameController(&cw, &ce, &cp);
                NSUInteger profilesBefore = cc.displayProfiles.count;
                NSUInteger savesBefore = cc.saves;
                [cc addDisplay:nil];
                Expect(cc.presentCalls == 1 && cc.lastPresentMode == YMDisplayProfileEditorModeCreate
                       && cc.lastPresentOrdinal == 0,
                       "addDisplay presents create mode at ordinal zero");
                Expect(cc.displayProfiles.count == profilesBefore && cc.saves == savesBefore,
                       "addDisplay does not allocate a default profile");
                [cc.lastEditor cancel:nil];
                [cc.panelPresenter invalidate];
                [ce.pending removeAllObjects];
                [ce.settling removeAllObjects];
            }

            {
                YMRenameWindow *ew; YMRenameEnvironment *ee; YMManagedDisplay *ep;
                YMRenameController *ec = RenameController(&ew, &ee, &ep);
                [ec presentProfileEditorForOrdinal:ep.ordinal mode:YMDisplayProfileEditorModeEdit];
                Expect(ec.presentCalls == 1 && ec.lastPresentMode == YMDisplayProfileEditorModeEdit
                       && ec.lastPresentOrdinal == ep.ordinal && ec.editorCreations == 1,
                       "edit entry presents edit mode with ordinal");
                [ec.lastEditor cancel:nil];
                [ec.panelPresenter invalidate];
                [ee.pending removeAllObjects];
                [ee.settling removeAllObjects];
            }

            {
                YMRenameWindow *mw; YMRenameEnvironment *me; YMManagedDisplay *mp;
                YMRenameController *mc = RenameController(&mw, &me, &mp);
                YMFakeStatusItem *status = [YMFakeStatusItem new];
                NSMenu *menu = [[NSMenu alloc] initWithTitle:@"yomado"];
                status.menu = menu;
                mc.statusItem = (NSStatusItem *)(id)status;
                [mc menuNeedsUpdate:menu];
                NSMenuItem *addItem = nil;
                for (NSMenuItem *candidate in menu.itemArray) {
                    if ([candidate.title isEqualToString:@"添加或启动虚拟屏…"]) { addItem = candidate; break; }
                }
                Expect(addItem != nil, "menu bar keeps add-or-start item");
                Expect(addItem.action == @selector(showWindow:) && addItem.submenu == nil,
                       "menu bar add-or-start opens the control panel");
                NSUInteger presentsBefore = mc.presentCalls;
                NSUInteger profilesBefore = mc.displayProfiles.count;
                [mc addDisplay:nil];
                Expect(mc.presentCalls == presentsBefore + 1 && mc.lastPresentMode == YMDisplayProfileEditorModeCreate,
                       "create still goes through the form entry");
                Expect(mc.displayProfiles.count == profilesBefore, "menu path never default-creates");
                [mc.lastEditor cancel:nil];
                [mc.panelPresenter invalidate];
                [me.pending removeAllObjects];
                [me.settling removeAllObjects];
            }

            NSArray<NSString *> *blockedFlags = @[
                @"previewMode", @"updateWorkspaceBusy", @"appOperationInProgress",
                @"displayOperationInProgress", @"armed", @"preparing", @"restoring",
                @"layoutChangedForTrial", @"recoveryRequested"
            ];
            for (NSString *flag in blockedFlags) {
                YMRenameWindow *bw; YMRenameEnvironment *be; YMManagedDisplay *bp;
                YMRenameController *bc = RenameController(&bw, &be, &bp);
                NSUInteger showBefore = bc.showCalls, editorsBefore = bc.editorCreations, savesBefore = bc.saves;
                [bc setValue:@YES forKey:flag];
                YMRenameMenuItem *blockedItem = [YMRenameMenuItem new];
                blockedItem.representedObject = bp;
                [bc renameManagedDisplayFromMenu:(NSMenuItem *)(id)blockedItem];
                Expect(bc.showCalls == showBefore && bc.editorCreations == editorsBefore && bc.saves == savesBefore,
                       [[NSString stringWithFormat:@"blocked flag %@ rejects rename", flag] UTF8String]);
                [bc.panelPresenter invalidate];
                [be.pending removeAllObjects];
                [be.settling removeAllObjects];
            }

            {
                YMRenameWindow *rw; YMRenameEnvironment *re; YMManagedDisplay *rp;
                YMRenameController *rc = RenameController(&rw, &re, &rp);
                NSUInteger showBefore = rc.showCalls, editorsBefore = rc.editorCreations, savesBefore = rc.saves;
                YMRenameMenuItem *nilItem = [YMRenameMenuItem new];
                nilItem.representedObject = nil;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)nilItem];
                Expect(rc.showCalls == showBefore && rc.editorCreations == editorsBefore && rc.saves == savesBefore,
                       "nil representedObject rejects rename");
                YMRenameMenuItem *objItem = [YMRenameMenuItem new];
                objItem.representedObject = [NSObject new];
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)objItem];
                Expect(rc.showCalls == showBefore && rc.editorCreations == editorsBefore && rc.saves == savesBefore,
                       "non-profile representedObject rejects rename");
                YMManagedDisplay *outsider = [YMManagedDisplay new];
                outsider.friendlyName = @"Outsider";
                YMRenameMenuItem *outItem = [YMRenameMenuItem new];
                outItem.representedObject = outsider;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)outItem];
                Expect(rc.showCalls == showBefore && rc.editorCreations == editorsBefore && rc.saves == savesBefore,
                       "profile outside displayProfiles rejects rename");
                rw.attachedSheet = [NSObject new];
                YMRenameMenuItem *sheetItem = [YMRenameMenuItem new];
                sheetItem.representedObject = rp;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)sheetItem];
                Expect(rc.showCalls == showBefore && rc.editorCreations == editorsBefore && rc.saves == savesBefore,
                       "existing attachedSheet rejects second rename");
                [rc.panelPresenter invalidate];
                [re.pending removeAllObjects];
                [re.settling removeAllObjects];
            }

            {
                YMRenameWindow *cw; YMRenameEnvironment *ce; YMManagedDisplay *cp;
                YMRenameController *cc = RenameController(&cw, &ce, &cp);
                YMRenameMenuItem *caseItem = [YMRenameMenuItem new];
                caseItem.representedObject = cp;
                [cc renameManagedDisplayFromMenu:(NSMenuItem *)(id)caseItem];
                [ce drain];
                [cc.lastEditor cancel:nil];
                Expect(cc.saves == 0 && [cp.friendlyName isEqualToString:@"Original"] && !cc.lastEditor.acceptedResult,
                       "cancel rename saves nothing");
                Expect(cc.panelPresenter.panelOpen && cw.visible, "cancel keeps panel open");
                [cc windowShouldClose:cc.window]; [ce drain];
                Expect(!cw.visible && !cc.panelPresenter.panelOpen, "close after cancel hides once");
                [cc.panelPresenter invalidate];
                [ce.pending removeAllObjects];
                [ce.settling removeAllObjects];
            }

            NSArray<NSDictionary *> *validCases = @[
                @{ @"text": @"  Renamed  ", @"name": @"Renamed" },
                @{ @"text": @"x", @"name": @"x" },
                @{ @"text": [@"" stringByPaddingToLength:60 withString:@"x" startingAtIndex:0],
                   @"name": [@"" stringByPaddingToLength:60 withString:@"x" startingAtIndex:0] }
            ];
            for (NSDictionary *caseInfo in validCases) {
                YMRenameWindow *cw; YMRenameEnvironment *ce; YMManagedDisplay *cp;
                YMRenameController *cc = RenameController(&cw, &ce, &cp);
                NSUInteger inventoryBefore = cc.inventoryUpdates;
                NSUInteger hidesBefore = ce.hides;
                YMRenameMenuItem *caseItem = [YMRenameMenuItem new];
                caseItem.representedObject = cp;
                [cc renameManagedDisplayFromMenu:(NSMenuItem *)(id)caseItem];
                [ce drain];
                [cc.lastEditor submitName:caseInfo[@"text"]];
                Expect(cc.saves == 1 && [cp.friendlyName isEqualToString:caseInfo[@"name"]]
                       && cc.lastEditor.finished && cc.lastEditor.acceptedResult,
                       [[NSString stringWithFormat:@"valid rename %@ saves once", caseInfo[@"name"]] UTF8String]);
                Expect(cc.inventoryUpdates == inventoryBefore + 1, "valid save updates inventory once");
                Expect(cc.panelPresenter.panelOpen && cw.visible && ce.hides == hidesBefore,
                       "rename completion keeps panel open without hiding");
                [cc windowShouldClose:cc.window]; [ce drain];
                Expect(!cw.visible && !cc.panelPresenter.panelOpen && ce.hides == hidesBefore + 1,
                       "explicit close after valid rename hides once");
                [cc.panelPresenter invalidate];
                [ce.pending removeAllObjects];
                [ce.settling removeAllObjects];
            }

            NSArray<NSString *> *invalidNames = @[
                @"   ", @"A\nB", [@"" stringByPaddingToLength:61 withString:@"x" startingAtIndex:0]
            ];
            for (NSString *invalidName in invalidNames) {
                YMRenameWindow *cw; YMRenameEnvironment *ce; YMManagedDisplay *cp;
                YMRenameController *cc = RenameController(&cw, &ce, &cp);
                NSUInteger inventoryBefore = cc.inventoryUpdates;
                YMRenameMenuItem *caseItem = [YMRenameMenuItem new];
                caseItem.representedObject = cp;
                [cc renameManagedDisplayFromMenu:(NSMenuItem *)(id)caseItem];
                [ce drain];
                [cc.lastEditor submitName:invalidName];
                Expect(!cc.lastEditor.finished && cc.lastEditor.lastError != nil && cc.saves == 0
                       && [cp.friendlyName isEqualToString:@"Original"],
                       "invalid rename keeps editor open with error");
                Expect(cc.inventoryUpdates == inventoryBefore, "invalid rename leaves inventory unchanged");
                [cc.lastEditor cancel:nil];
                [cc windowShouldClose:cc.window]; [ce drain];
                [cc.panelPresenter invalidate];
                [ce.pending removeAllObjects];
                [ce.settling removeAllObjects];
            }

            {
                YMRenameWindow *iw; YMRenameEnvironment *ie; YMManagedDisplay *ip;
                YMRenameController *ic = RenameController(&iw, &ie, &ip);
                YMManagedDisplay *selected = [YMManagedDisplay new];
                selected.friendlyName = @"Selected";
                selected.ordinal = 2;
                selected.width = 1920; selected.height = 1080;
                YMFakeDisplay *selectedDisplay = [YMFakeDisplay new];
                selected.display = selectedDisplay;
                [ic.displayProfiles addObject:selected];
                ic.selectedProfile = selected;
                ic.virtualDisplay = selectedDisplay;
                YMRenameMenuItem *targetItem = [YMRenameMenuItem new];
                targetItem.representedObject = ip;
                [ic renameManagedDisplayFromMenu:(NSMenuItem *)(id)targetItem];
                [ie drain];
                [ic.lastEditor submitName:@"MenuTarget"];
                Expect([ip.friendlyName isEqual:@"MenuTarget"] && [selected.friendlyName isEqual:@"Selected"],
                       "valid save renames only the menu target");
                Expect(ic.selectedProfile == selected && ic.virtualDisplay == selectedDisplay,
                       "rename preserves selectedProfile and virtualDisplay identity");
                [ic.panelPresenter invalidate];
                [ie.pending removeAllObjects];
                [ie.settling removeAllObjects];
            }

            {
                YMRenameWindow *iw; YMRenameEnvironment *ie; YMManagedDisplay *ip;
                YMRenameController *ic = RenameController(&iw, &ie, &ip);
                YMRenameMenuItem *targetItem = [YMRenameMenuItem new];
                targetItem.representedObject = ip;
                [ic renameManagedDisplayFromMenu:(NSMenuItem *)(id)targetItem];
                [ie drain];
                [ic.displayProfiles removeObject:ip];
                [ic.lastEditor submitName:@"Gone"];
                Expect(!ic.lastEditor.finished && ic.lastEditor.lastError != nil
                       && ic.saves == 0 && [ip.friendlyName isEqual:@"Original"] && ic.panelPresenter.panelOpen,
                       "removed target at submit keeps editor open without saving");
                [ic.lastEditor cancel:nil];
                [ic windowShouldClose:ic.window]; [ie drain];
                Expect(!iw.visible && !ic.panelPresenter.panelOpen, "panel still closes after removed-target cancel");
                [ic.panelPresenter invalidate];
                [ie.pending removeAllObjects];
                [ie.settling removeAllObjects];
            }
            {
                YMRenameWindow *iw; YMRenameEnvironment *ie; YMManagedDisplay *ip;
                YMRenameController *ic = RenameController(&iw, &ie, &ip);
                YMRenameMenuItem *targetItem = [YMRenameMenuItem new];
                targetItem.representedObject = ip;
                [ic renameManagedDisplayFromMenu:(NSMenuItem *)(id)targetItem];
                [ie drain];
                ic.updateWorkspaceBusy = YES;
                [ic.lastEditor submitName:@"Busy"];
                Expect(!ic.lastEditor.finished && ic.lastEditor.lastError != nil
                       && ic.saves == 0 && [ip.friendlyName isEqual:@"Original"] && ic.panelPresenter.panelOpen,
                       "busy at submit keeps editor open without saving");
                ic.updateWorkspaceBusy = NO;
                [ic.lastEditor cancel:nil];
                [ic windowShouldClose:ic.window]; [ie drain];
                Expect(!iw.visible && !ic.panelPresenter.panelOpen, "panel still closes after busy cancel");
                [ic.panelPresenter invalidate];
                [ie.pending removeAllObjects];
                [ie.settling removeAllObjects];
            }

            {
                YMRenameWindow *sw; YMRenameEnvironment *se; YMManagedDisplay *sp;
                YMRenameController *sc = RenameController(&sw, &se, &sp);
                YMRenameMenuItem *sheetItem = [YMRenameMenuItem new];
                sheetItem.representedObject = sp;
                [sc renameManagedDisplayFromMenu:(NSMenuItem *)(id)sheetItem];
                [se drain];
                NSUInteger hidesBefore = se.hides;
                id sheet = sw.attachedSheet;
                [sc windowShouldClose:sc.window];
                Expect(sw.attachedSheet == sheet && se.hides == hidesBefore && sc.panelPresenter.panelOpen,
                       "sheet protects against close");
                [sc.lastEditor cancel:nil];
                [sc windowShouldClose:sc.window]; [se drain];
                Expect(!sw.visible && !sc.panelPresenter.panelOpen && se.hides == hidesBefore + 1,
                       "close works after sheet cancel");
                [sc.panelPresenter invalidate];
                [se.pending removeAllObjects];
                [se.settling removeAllObjects];
            }

            {
                YMRenameWindow *dw; YMRenameEnvironment *de; YMManagedDisplay *dp;
                YMRenameController *dc = RenameController(&dw, &de, &dp);
                YMRenameMenuItem *dupItem = [YMRenameMenuItem new];
                dupItem.representedObject = dp;
                [dc renameManagedDisplayFromMenu:(NSMenuItem *)(id)dupItem];
                [de drain];
                [dc.lastEditor cancel:nil];
                NSUInteger hidesBefore = de.hides;
                [dc windowShouldClose:dc.window];
                [dc windowShouldClose:dc.window];
                [de drain];
                Expect(de.hides == hidesBefore + 1 && de.activationPolicy == NSApplicationActivationPolicyAccessory,
                       "duplicate close hides once and settles to Accessory");
                Expect(de.pending.count == 0 && de.settling.count == 0, "duplicate close leaves no deferred work");
                [dc showWindow:nil]; [de drain];
                Expect(dw.visible && dc.panelPresenter.panelOpen, "reopen after duplicate close works");
                [dc.panelPresenter invalidate];
                [de.pending removeAllObjects];
                [de.settling removeAllObjects];
            }

            {
                YMRenameWindow *ow; YMRenameEnvironment *oe; YMManagedDisplay *op;
                YMRenameController *oc = RenameController(&ow, &oe, &op);
                [oc showWindow:nil]; [oe drain];
                [oc.panelPresenter closeWindow:oc.window];
                YMRenameMenuItem *lateItem = [YMRenameMenuItem new];
                lateItem.representedObject = op;
                [oc renameManagedDisplayFromMenu:(NSMenuItem *)(id)lateItem];
                [oe drain];
                Expect(oc.panelPresenter.panelOpen && ow.visible
                       && oe.activationPolicy == NSApplicationActivationPolicyRegular,
                       "stale ordinary close cannot demote after rename open");
                [oc.lastEditor cancel:nil];
                [oc.panelPresenter invalidate];
                [oe.pending removeAllObjects];
                [oe.settling removeAllObjects];
            }

            {
                YMRenameWindow *rw; YMRenameEnvironment *re; YMManagedDisplay *rp;
                YMRenameController *rc = RenameController(&rw, &re, &rp);
                [rc showWindow:nil]; [re drain];
                re.rejectAccessory = YES;
                [rc windowShouldClose:rc.window]; [re drain];
                Expect(re.settling.count == 1, "rejected Accessory schedules one settling retry");
                re.rejectAccessory = NO;
                YMRenameMenuItem *retryItem = [YMRenameMenuItem new];
                retryItem.representedObject = rp;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)retryItem];
                [re drain];
                NSUInteger policyBefore = re.policyRequests;
                [re drainSettling];
                Expect(re.policyRequests == policyBefore,
                       "stale settling retry adds no policy request after rename");
                Expect(re.activationPolicy == NSApplicationActivationPolicyRegular,
                       "rename wins over stale Accessory retry");
                [rc.lastEditor cancel:nil];
                [rc.panelPresenter invalidate];
                [re.pending removeAllObjects];
                [re.settling removeAllObjects];
            }

            {
                YMRenameWindow *nw; YMRenameEnvironment *ne; YMManagedDisplay *np;
                YMRenameController *nc = RenameController(&nw, &ne, &np);
                YMSpyHeartbeat *heartbeat = [YMSpyHeartbeat new];
                nc.heartbeatTimer = (NSTimer *)(id)heartbeat;
                YMFakeDisplay *display = (YMFakeDisplay *)np.display;
                NSWindow *windowIdentity = nc.window;
                YMRenameMenuItem *sideItem = [YMRenameMenuItem new];
                sideItem.representedObject = np;
                [nc renameManagedDisplayFromMenu:(NSMenuItem *)(id)sideItem];
                [ne drain];
                [nc.lastEditor cancel:nil];
                [nc windowShouldClose:nc.window]; [ne drain];
                [nc showWindow:nil]; [ne drain];
                sideItem = [YMRenameMenuItem new];
                sideItem.representedObject = np;
                [nc renameManagedDisplayFromMenu:(NSMenuItem *)(id)sideItem];
                [ne drain];
                [nc.lastEditor submitName:@"SideEffect"];
                [nc windowShouldClose:nc.window]; [ne drain];
                [nc showWindow:nil]; [ne drain];
                Expect(heartbeat.invalidations == 0 && display.creates == 0 && display.destroys == 0
                       && nc.stopCalls == 0 && nc.window == windowIdentity,
                       "rename lifecycle has no heartbeat display or stop side effects");
                [nc.panelPresenter invalidate];
                [ne.pending removeAllObjects];
                [ne.settling removeAllObjects];
            }

            {
                YMRenameWindow *aw; YMRenameEnvironment *ae; YMManagedDisplay *ap;
                YMRenameController *ac = RenameController(&aw, &ae, &ap);
                [ac showWindow:nil]; [ae drain];
                NSWindow *windowIdentity = ac.window;
                YMRenameMenuItem *alreadyItem = [YMRenameMenuItem new];
                alreadyItem.representedObject = ap;
                [ac renameManagedDisplayFromMenu:(NSMenuItem *)(id)alreadyItem];
                [ae drain];
                [ac.lastEditor cancel:nil];
                Expect(ac.panelPresenter.panelOpen && aw.visible && ac.saves == 0,
                       "already-open cancel keeps panel open");
                [ac renameManagedDisplayFromMenu:(NSMenuItem *)(id)alreadyItem];
                [ae drain];
                [ac.lastEditor submitName:@"AlreadyOpen"];
                Expect(ac.saves == 1 && [ap.friendlyName isEqual:@"AlreadyOpen"]
                       && ac.panelPresenter.panelOpen && aw.visible && ac.window == windowIdentity,
                       "already-open save keeps same panel identity");
                NSUInteger hidesBefore = ae.hides;
                [ac windowShouldClose:ac.window]; [ae drain];
                Expect(!aw.visible && !ac.panelPresenter.panelOpen && ae.hides == hidesBefore + 1
                       && ac.window == windowIdentity,
                       "already-open path closes once without changing window identity");
                [ac.panelPresenter invalidate];
                [ae.pending removeAllObjects];
                [ae.settling removeAllObjects];
            }

            {
                YMRenameWindow *fw; YMRenameEnvironment *fe; YMManagedDisplay *fp;
                YMRenameController *fc = RenameController(&fw, &fe, &fp);
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = fw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                fc.addDisplayButton = (NSButton *)(id)addButton;
                fw.firstResponder = addButton;
                [fc addDisplay:nil];
                Expect(fc.profileEditor != nil && fc.editorCreations == 1, "focus fixture opens create editor");
                addButton.enabled = NO;
                [fc.lastEditor cancel:nil];
                Expect(addButton.enabled, "cancel refreshes create button from latest permission");
                Expect(fw.firstResponder == addButton, "cancel restores focus to create button");
                Expect(fc.profileEditor == nil, "cancel clears current editor");
                [fc.panelPresenter invalidate];
                [fe.pending removeAllObjects];
                [fe.settling removeAllObjects];
            }

            {
                YMRenameWindow *ow; YMRenameEnvironment *oe; YMManagedDisplay *op;
                YMRenameController *oc = RenameController(&ow, &oe, &op);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = ow;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = ow;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                oc.addDisplayButton = (NSButton *)(id)addButton;
                [oc addDisplay:nil];
                oc.profileEditorOrigin = (NSView *)(id)origin;
                addButton.enabled = NO;
                [oc.lastEditor cancel:nil];
                Expect(ow.firstResponder == origin, "cancel restores an enabled origin control");
                Expect(addButton.enabled, "cancel still refreshes create button when origin wins");
                [oc.panelPresenter invalidate];
                [oe.pending removeAllObjects];
                [oe.settling removeAllObjects];
            }

            {
                YMRenameWindow *rw; YMRenameEnvironment *re; YMManagedDisplay *rp;
                YMRenameController *rc = RenameController(&rw, &re, &rp);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = rw;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = rw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                rc.addDisplayButton = (NSButton *)(id)addButton;
                [rc presentProfileEditorForOrdinal:rp.ordinal mode:YMDisplayProfileEditorModeEdit];
                rc.profileEditorOrigin = (NSView *)(id)origin;
                origin.enabled = NO;
                addButton.enabled = NO;
                [rc.lastEditor cancel:nil];
                Expect(origin.enabled, "cancel refreshes stale saved-row origin before restore");
                Expect(rw.firstResponder == origin, "cancel restores focus to refreshed saved-row origin");
                Expect(addButton.enabled, "cancel still refreshes create button after origin refresh");
                [rc.panelPresenter invalidate];
                [re.pending removeAllObjects];
                [re.settling removeAllObjects];
            }

            {
                YMRenameWindow *sw; YMRenameEnvironment *se; YMManagedDisplay *sp;
                YMRenameController *sc = RenameController(&sw, &se, &sp);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = sw;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = sw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                sc.addDisplayButton = (NSButton *)(id)addButton;
                [sc presentProfileEditorForOrdinal:sp.ordinal mode:YMDisplayProfileEditorModeEdit];
                sc.profileEditorOrigin = (NSView *)(id)origin;
                origin.enabled = NO;
                addButton.enabled = NO;
                [sc.lastEditor submitName:@"SavedFocus"];
                Expect([sp.friendlyName isEqualToString:@"SavedFocus"] && sc.saves == 1,
                       "valid save commits before focus restore");
                Expect(origin.enabled, "valid save refreshes stale saved-row origin before restore");
                Expect(sw.firstResponder == origin, "valid save restores focus to refreshed saved-row origin");
                [sc.panelPresenter invalidate];
                [se.pending removeAllObjects];
                [se.settling removeAllObjects];
            }

            {
                YMRenameWindow *dw; YMRenameEnvironment *de; YMManagedDisplay *dp;
                YMRenameController *dc = RenameController(&dw, &de, &dp);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = dw;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = dw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                dc.addDisplayButton = (NSButton *)(id)addButton;
                [dc presentProfileEditorForOrdinal:dp.ordinal mode:YMDisplayProfileEditorModeEdit];
                dc.profileEditorOrigin = (NSView *)(id)origin;
                origin.enabled = NO;
                addButton.enabled = NO;
                void (^endWhileAttached)(BOOL) = [dc.lastEditor.endHandler copy];
                dc.lastEditor.finished = YES;
                dc.lastEditor.endHandler = nil;
                dc.lastEditor.submitHandler = nil;
                endWhileAttached(NO);
                Expect(dw.attachedSheet != nil, "delayed-detach saved origin keeps attachedSheet");
                Expect(!origin.enabled, "origin stays stale while sheet still attached");
                dw.attachedSheet = nil;
                [dc restoreProfileEditorFocus];
                Expect(origin.enabled, "delayed detach refreshes saved-row origin once");
                Expect(dw.firstResponder == origin, "delayed detach restores refreshed saved-row origin");
                [dc.panelPresenter invalidate];
                [de.pending removeAllObjects];
                [de.settling removeAllObjects];
            }

            {
                YMRenameWindow *pw; YMRenameEnvironment *pe; YMManagedDisplay *pp;
                YMRenameController *pc = RenameController(&pw, &pe, &pp);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = pw;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = pw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                pc.addDisplayButton = (NSButton *)(id)addButton;
                [pc presentProfileEditorForOrdinal:pp.ordinal mode:YMDisplayProfileEditorModeEdit];
                pc.profileEditorOrigin = (NSView *)(id)origin;
                origin.enabled = NO;
                addButton.enabled = NO;
                void (^endWhileAttached)(BOOL) = [pc.lastEditor.endHandler copy];
                pc.lastEditor.finished = YES;
                pc.lastEditor.endHandler = nil;
                pc.lastEditor.submitHandler = nil;
                NSUInteger restoresBeforeEnd = pc.restoreFocusCalls;
                endWhileAttached(NO);
                Expect(pw.attachedSheet != nil && pc.profileEditorFocusPending,
                       "early async fixture keeps sheet and pending restore");
                Expect(pc.restoreFocusCalls == restoresBeforeEnd + 1,
                       "endHandler schedules exactly one restore attempt");
                // Drain while Sheet stays attached: must stay bounded, not busy-spin.
                for (NSUInteger pass = 0; pass < 40 && pw.attachedSheet != nil; pass++) {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                }
                Expect(pw.attachedSheet != nil && pc.profileEditorFocusPending && !origin.enabled,
                       "early async restore leaves origin gated while sheet remains");
                Expect(pc.restoreFocusCalls <= restoresBeforeEnd + 2,
                       "attachedSheet restore stays bounded to one async retry");
                NSUInteger restoresWhileAttached = pc.restoreFocusCalls;
                for (NSUInteger pass = 0; pass < 20; pass++) {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                }
                Expect(pc.restoreFocusCalls == restoresWhileAttached,
                       "no further self-reschedule while attachedSheet remains");
                pw.attachedSheet = nil;
                pc.inventoryDrivesPendingRestore = YES;
                [pc updateInventory];
                Expect(origin.enabled, "inventory handoff refreshes origin after delayed detach");
                Expect(pw.firstResponder == origin, "inventory handoff focuses refreshed origin");
                Expect(!pc.profileEditorFocusPending, "inventory handoff clears pending flag");
                [pc.panelPresenter invalidate];
                [pe.pending removeAllObjects];
                [pe.settling removeAllObjects];
            }

            {
                YMRenameWindow *gw; YMRenameEnvironment *ge; YMManagedDisplay *gp;
                YMRenameController *gc = RenameController(&gw, &ge, &gp);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = gw;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = gw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                gc.addDisplayButton = (NSButton *)(id)addButton;
                [gc presentProfileEditorForOrdinal:gp.ordinal mode:YMDisplayProfileEditorModeEdit];
                gc.profileEditorOrigin = (NSView *)(id)origin;
                origin.enabled = NO;
                addButton.enabled = NO;
                origin.window = nil;
                [gc.lastEditor cancel:nil];
                Expect(gw.firstResponder == addButton, "missing saved-row origin falls back to create");
                Expect(addButton.enabled, "fallback create button is refreshed");
                [gc.panelPresenter invalidate];
                [ge.pending removeAllObjects];
                [ge.settling removeAllObjects];
            }

            {
                YMRenameWindow *bw; YMRenameEnvironment *be; YMManagedDisplay *bp;
                YMRenameController *bc = RenameController(&bw, &be, &bp);
                YMFocusControl *origin = [YMFocusControl new];
                origin.window = bw;
                origin.enabled = YES;
                origin.acceptsFirstResponder = YES;
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = bw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                bc.addDisplayButton = (NSButton *)(id)addButton;
                [bc presentProfileEditorForOrdinal:bp.ordinal mode:YMDisplayProfileEditorModeEdit];
                bc.profileEditorOrigin = (NSView *)(id)origin;
                origin.enabled = NO;
                addButton.enabled = NO;
                bc.updateWorkspaceBusy = YES;
                [bc.lastEditor cancel:nil];
                Expect(!origin.enabled, "busy keeps refreshed origin disabled");
                Expect(!addButton.enabled, "busy keeps create button disabled");
                Expect(bw.firstResponder == nil, "busy falls back safely when no control is enabled");
                [bc.panelPresenter invalidate];
                [be.pending removeAllObjects];
                [be.settling removeAllObjects];
            }

            {
                YMRenameWindow *dw; YMRenameEnvironment *de; YMManagedDisplay *dp;
                YMRenameController *dc = RenameController(&dw, &de, &dp);
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = dw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                dc.addDisplayButton = (NSButton *)(id)addButton;
                [dc addDisplay:nil];
                addButton.enabled = NO;
                dc.topologyRecoverySnapshot = [YMDisplayTopologySnapshot new];
                [dc.lastEditor cancel:nil];
                Expect(!addButton.enabled, "recovery keeps create button disabled after cancel");
                Expect(dw.firstResponder == nil, "cancel yields window when no control is enabled");
                Expect(dc.profileEditor == nil, "cancel still clears editor under recovery");
                [dc.panelPresenter invalidate];
                [de.pending removeAllObjects];
                [de.settling removeAllObjects];
            }

            {
                YMRenameWindow *sw; YMRenameEnvironment *se; YMManagedDisplay *sp;
                YMRenameController *sc = RenameController(&sw, &se, &sp);
                [sc addDisplay:nil];
                YMRenameEditorStandIn *first = sc.lastEditor;
                void (^staleEnd)(BOOL) = [first.endHandler copy];
                Expect(staleEnd != nil, "open editor exposes endHandler");
                YMRenameEditorStandIn *second = [YMRenameEditorStandIn new];
                second.mode = YMDisplayProfileEditorModeCreate;
                sc.profileEditor = (YMDisplayProfileEditor *)(id)second;
                staleEnd(NO);
                Expect(sc.profileEditor == (YMDisplayProfileEditor *)(id)second,
                       "stale endHandler does not clear a newer editor");
                sw.attachedSheet = second.window;
                NSUInteger presentsBefore = sc.presentCalls;
                NSUInteger editorsBefore = sc.editorCreations;
                [sc presentProfileEditorForOrdinal:0 mode:YMDisplayProfileEditorModeCreate];
                Expect(sc.presentCalls == presentsBefore + 1 && sc.editorCreations == editorsBefore
                       && sc.profileEditor == (YMDisplayProfileEditor *)(id)second,
                       "second present is rejected while attachedSheet remains");
                [sc.panelPresenter invalidate];
                [se.pending removeAllObjects];
                [se.settling removeAllObjects];
            }

            {
                YMRenameWindow *lw; YMRenameEnvironment *le; YMManagedDisplay *lp;
                YMRenameController *lc = RenameController(&lw, &le, &lp);
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = lw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                lc.addDisplayButton = (NSButton *)(id)addButton;
                lw.firstResponder = addButton;
                [lc addDisplay:nil];
                Expect(lc.profileEditor != nil && lw.attachedSheet != nil,
                       "delayed-detach fixture opens create sheet");
                addButton.enabled = NO;
                void (^endWhileAttached)(BOOL) = [lc.lastEditor.endHandler copy];
                Expect(endWhileAttached != nil, "delayed-detach fixture exposes endHandler");
                lc.lastEditor.finished = YES;
                lc.lastEditor.endHandler = nil;
                lc.lastEditor.submitHandler = nil;
                endWhileAttached(NO);
                Expect(lc.profileEditor == nil, "endHandler clears editor while sheet still attached");
                Expect(lw.attachedSheet != nil, "endHandler leaves attachedSheet for later detach");
                Expect(lc.profileEditorOrigin != nil, "origin is kept until sheet detaches");
                Expect(!addButton.enabled, "create button stays gated by attachedSheet");
                lw.attachedSheet = nil;
                [lc restoreProfileEditorFocus];
                Expect(addButton.enabled, "delayed detach refreshes create button once");
                Expect(lw.firstResponder == addButton, "focus restores once after delayed detach");
                Expect(lc.profileEditorOrigin == nil, "origin clears after successful delayed restore");
                id responderAfterRestore = lw.firstResponder;
                [lc restoreProfileEditorFocus];
                Expect(lw.firstResponder == responderAfterRestore,
                       "extra restore after success does not reshuffle focus");
                [lc.panelPresenter invalidate];
                [le.pending removeAllObjects];
                [le.settling removeAllObjects];
            }

            {
                YMRenameWindow *nw; YMRenameEnvironment *ne; YMManagedDisplay *np;
                YMRenameController *nc = RenameController(&nw, &ne, &np);
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = nw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                nc.addDisplayButton = (NSButton *)(id)addButton;
                nw.firstResponder = addButton;
                [nc addDisplay:nil];
                addButton.enabled = NO;
                void (^endWhileAttached)(BOOL) = [nc.lastEditor.endHandler copy];
                nc.lastEditor.finished = YES;
                nc.lastEditor.endHandler = nil;
                nc.lastEditor.submitHandler = nil;
                endWhileAttached(NO);
                Expect(nc.profileEditorOrigin != nil, "pending restore keeps origin before new editor");
                YMRenameEditorStandIn *newer = [YMRenameEditorStandIn new];
                newer.mode = YMDisplayProfileEditorModeCreate;
                nc.profileEditor = (YMDisplayProfileEditor *)(id)newer;
                nw.attachedSheet = nil;
                id responderBefore = nw.firstResponder;
                [nc restoreProfileEditorFocus];
                Expect(nc.profileEditor == (YMDisplayProfileEditor *)(id)newer,
                       "pending restore does not clear a newer editor");
                Expect(nw.firstResponder == responderBefore,
                       "pending restore does not steal focus for a newer editor");
                [nc.panelPresenter invalidate];
                [ne.pending removeAllObjects];
                [ne.settling removeAllObjects];
            }

            {
                YMRenameWindow *uw; YMRenameEnvironment *ue; YMManagedDisplay *up;
                YMRenameController *uc = RenameController(&uw, &ue, &up);
                YMFocusControl *addButton = [YMFocusControl new];
                addButton.window = uw;
                addButton.enabled = YES;
                addButton.acceptsFirstResponder = YES;
                uc.addDisplayButton = (NSButton *)(id)addButton;
                uw.firstResponder = addButton;
                [uc addDisplay:nil];
                addButton.enabled = NO;
                void (^endWhileAttached)(BOOL) = [uc.lastEditor.endHandler copy];
                uc.lastEditor.finished = YES;
                uc.lastEditor.endHandler = nil;
                uc.lastEditor.submitHandler = nil;
                endWhileAttached(NO);
                uw.attachedSheet = nil;
                YMFocusControl *userChosen = [YMFocusControl new];
                userChosen.window = uw;
                userChosen.enabled = YES;
                userChosen.acceptsFirstResponder = YES;
                uw.firstResponder = userChosen;
                [uc restoreProfileEditorFocus];
                Expect(uw.firstResponder == userChosen, "pending restore does not steal user focus");
                Expect(uc.profileEditorOrigin == nil, "abandoned pending restore clears origin");
                [uc.panelPresenter invalidate];
                [ue.pending removeAllObjects];
                [ue.settling removeAllObjects];
            }
        }
    rename_tests_done:

        // Display profile accept/start gates and lifecycle projection.
        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            profile.width = 1920; profile.height = 1080;
            sibling.ordinal = 1;
            YMHeadlessProfileEditor *marker = [YMHeadlessProfileEditor new];
            controller.profileEditor = (YMDisplayProfileEditor *)(id)marker;
            YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@" Changed " width:2560 hiDPI:YES];
            NSError *error = nil;
            controller.selectedProfile = sibling;
            BOOL accepted = [controller acceptProfileDraft:draft mode:YMDisplayProfileEditorModeEdit
                ordinal:profile.ordinal editor:(YMDisplayProfileEditor *)(id)marker error:&error];
            Expect(accepted && [profile.friendlyName isEqualToString:@"Changed"], "stable ordinal selects edited profile");
            Expect(profile.width == 2560 && profile.height == 1440 && profile.hiDPI, "all edited fields commit together");
            Expect(display.creates == 0 && controller.saves == 1, "edit saves once without start");
            Expect(![sibling.friendlyName isEqualToString:@"Changed"], "selected sibling remains untouched");
            Expect(NSApp == nil, "profile requests stay headless");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            profile.width = 1920; profile.height = 1080; profile.friendlyName = @"Target";
            sibling.ordinal = 1;
            YMHeadlessProfileEditor *marker = [YMHeadlessProfileEditor new];
            controller.profileEditor = (YMDisplayProfileEditor *)(id)marker;
            NSUInteger baselineProfiles = controller.displayProfiles.count;
            NSUInteger baselineSaves = controller.saves;
            NSUInteger baselineCreates = display.creates;
            YMHeadlessProfileWindow *gateWindow = [YMHeadlessProfileWindow new];
            controller.window = (NSWindow *)(id)gateWindow;
            void (^expectRejected)(NSString *, void (^)(void)) = ^(NSString *name, void (^mutate)(void)) {
                mutate();
                NSError *error = nil;
                YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Blocked" width:1920 hiDPI:NO];
                BOOL accepted = [controller acceptProfileDraft:draft mode:YMDisplayProfileEditorModeEdit
                    ordinal:profile.ordinal editor:(YMDisplayProfileEditor *)(id)marker error:&error];
                Expect(!accepted && error != nil, name.UTF8String);
                Expect(controller.displayProfiles.count == baselineProfiles
                       && controller.saves == baselineSaves && display.creates == baselineCreates
                       && [profile.friendlyName isEqualToString:@"Target"],
                       [[name stringByAppendingString:@" leaves model untouched"] UTF8String]);
                controller.previewMode = NO;
                controller.updateWorkspaceBusy = NO;
                controller.appOperationInProgress = NO;
                controller.displayOperationInProgress = NO;
                controller.armed = NO;
                controller.preparing = NO;
                controller.restoring = NO;
                controller.layoutChangedForTrial = NO;
                controller.recoveryRequested = NO;
                controller.topologyRecoverySnapshot = nil;
                gateWindow.attachedSheet = nil;
                marker.window = nil;
                controller.window = (NSWindow *)(id)gateWindow;
            };
            expectRejected(@"previewMode rejects profile commit", ^{ controller.previewMode = YES; });
            expectRejected(@"updateWorkspaceBusy rejects profile commit", ^{ controller.updateWorkspaceBusy = YES; });
            expectRejected(@"appOperationInProgress rejects profile commit", ^{ controller.appOperationInProgress = YES; });
            expectRejected(@"displayOperationInProgress rejects profile commit", ^{ controller.displayOperationInProgress = YES; });
            expectRejected(@"armed rejects profile commit", ^{ controller.armed = YES; });
            expectRejected(@"preparing rejects profile commit", ^{ controller.preparing = YES; });
            expectRejected(@"restoring rejects profile commit", ^{ controller.restoring = YES; });
            expectRejected(@"layoutChangedForTrial rejects profile commit", ^{ controller.layoutChangedForTrial = YES; });
            expectRejected(@"recoveryRequested rejects profile commit", ^{ controller.recoveryRequested = YES; });
            expectRejected(@"topologyRecoverySnapshot rejects profile commit", ^{
                controller.topologyRecoverySnapshot = topology.snapshot;
            });
            expectRejected(@"foreign attachedSheet rejects profile commit", ^{
                gateWindow.attachedSheet = [NSObject new];
                marker.window = [NSObject new];
            });

            YMHeadlessProfileEditor *stale = [YMHeadlessProfileEditor new];
            NSError *staleError = nil;
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"Stale" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeEdit ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)stale error:&staleError]
                   && controller.saves == baselineSaves, "stale editor identity is rejected");

            NSMutableArray *kept = [NSMutableArray arrayWithObject:sibling];
            controller.displayProfiles = kept;
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"Gone" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeEdit ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && controller.saves == baselineSaves, "removed ordinal cannot be edited");
            controller.displayProfiles = [NSMutableArray arrayWithArray:@[sibling, profile]];

            YMManagedDisplay *duplicate = [YMManagedDisplay new];
            duplicate.ordinal = 9; duplicate.friendlyName = @"Target"; duplicate.width = 1920; duplicate.height = 1080;
            duplicate.display = [YMFakeDisplay new];
            [controller.displayProfiles addObject:duplicate];
            Expect([controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"ByOrdinal" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeEdit ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && [profile.friendlyName isEqualToString:@"ByOrdinal"]
                   && [duplicate.friendlyName isEqualToString:@"Target"],
                   "same-name profiles still resolve by ordinal");
            profile.friendlyName = @"Target";
            controller.saves = baselineSaves;

            display.live = YES;
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"Live" width:2560 hiDPI:YES]
                mode:YMDisplayProfileEditorModeEdit ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && profile.width == 1920 && controller.saves == baselineSaves,
                   "edit rejects an already running target");
            display.live = NO;

            YMManagedDisplay *maxed = [YMManagedDisplay new];
            maxed.ordinal = UINT16_MAX; maxed.friendlyName = @"Max"; maxed.width = 1920; maxed.height = 1080;
            maxed.display = [YMFakeDisplay new];
            [controller.displayProfiles addObject:maxed];
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"Overflow" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeCreate ordinal:0
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && controller.displayProfiles.count == baselineProfiles + 2
                   && controller.saves == baselineSaves && display.creates == baselineCreates,
                   "exhausted ordinals reject create before write");
            [controller.displayProfiles removeObject:maxed];

            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"BadMode" width:1920 hiDPI:NO]
                mode:(YMDisplayProfileEditorMode)99 ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && controller.saves == baselineSaves, "illegal mode is rejected");
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"BadOrdinal" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeCreate ordinal:7
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && controller.saves == baselineSaves, "create requires ordinal zero");
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"a\tb" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeEdit ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && controller.saves == baselineSaves, "control characters reject before write");

            controller.profileEditorCommitInProgress = YES;
            Expect(![controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@"Reentry" width:1920 hiDPI:NO]
                mode:YMDisplayProfileEditorModeEdit ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&staleError]
                   && controller.saves == baselineSaves, "synchronous reentry is rejected");
            controller.profileEditorCommitInProgress = NO;

            id sheet = [NSObject new];
            marker.window = sheet;
            gateWindow.attachedSheet = sheet;
            Expect([controller profileActionsAvailableForEditor:(YMDisplayProfileEditor *)(id)marker],
                   "current sheet may submit through its own editor");
            Expect(![controller profileActionsAvailableForEditor:nil],
                   "external entry stays blocked while sheet is attached");
            Expect(NSApp == nil, "gate checks stay headless");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            profile.width = 1920; profile.height = 1080; profile.friendlyName = @"StartTarget";
            sibling.ordinal = 1;
            YMHeadlessProfileWindow *startWindow = [YMHeadlessProfileWindow new];
            controller.window = (NSWindow *)(id)startWindow;
            controller.profileEditor = nil;
            NSUInteger baselineCreates = display.creates;
            NSUInteger baselineSaves = controller.saves;
            void (^expectStartRejected)(NSString *, void (^)(void)) = ^(NSString *name, void (^mutate)(void)) {
                mutate();
                NSError *error = nil;
                BOOL started = [controller startSavedProfileWithOrdinal:profile.ordinal error:&error];
                Expect(!started && error != nil, name.UTF8String);
                Expect(display.creates == baselineCreates && controller.saves == baselineSaves
                       && !profile.starting && !profile.display.isCreated
                       && [profile.friendlyName isEqualToString:@"StartTarget"],
                       [[name stringByAppendingString:@" leaves model untouched"] UTF8String]);
                controller.previewMode = NO;
                controller.updateWorkspaceBusy = NO;
                controller.appOperationInProgress = NO;
                controller.displayOperationInProgress = NO;
                controller.armed = NO;
                controller.preparing = NO;
                controller.restoring = NO;
                controller.layoutChangedForTrial = NO;
                controller.recoveryRequested = NO;
                controller.topologyRecoverySnapshot = nil;
                startWindow.attachedSheet = nil;
                controller.profileEditor = nil;
                controller.window = (NSWindow *)(id)startWindow;
            };
            expectStartRejected(@"updateWorkspaceBusy rejects saved start", ^{ controller.updateWorkspaceBusy = YES; });
            expectStartRejected(@"appOperationInProgress rejects saved start", ^{ controller.appOperationInProgress = YES; });
            expectStartRejected(@"displayOperationInProgress rejects saved start", ^{ controller.displayOperationInProgress = YES; });
            expectStartRejected(@"armed rejects saved start", ^{ controller.armed = YES; });
            expectStartRejected(@"preparing rejects saved start", ^{ controller.preparing = YES; });
            expectStartRejected(@"restoring rejects saved start", ^{ controller.restoring = YES; });
            expectStartRejected(@"layoutChangedForTrial rejects saved start", ^{ controller.layoutChangedForTrial = YES; });
            expectStartRejected(@"recoveryRequested rejects saved start", ^{ controller.recoveryRequested = YES; });
            expectStartRejected(@"topologyRecoverySnapshot rejects saved start", ^{
                controller.topologyRecoverySnapshot = topology.snapshot;
            });
            expectStartRejected(@"attachedSheet rejects saved start", ^{
                startWindow.attachedSheet = [NSObject new];
            });
            Expect(NSApp == nil, "saved start gate checks stay headless");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1;
            profile.width = 1920; profile.height = 1080;
            controller.deferTopologyOperations = YES;
            NSError *error = nil;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error], "saved start accepted");
            Expect(profile.starting && controller.displayOperationInProgress, "pending state follows real transaction");
            Expect(![controller canMoveIntoProfile:profile], "unverified display rejects admission");
            Expect(display.creates == 1 && controller.saves == 0, "saved start neither duplicates nor resaves profile");
            [controller runNextTopologyOperation];
            Expect(!profile.starting && profile.topologyVerified, "verified completion clears pending state");
            Expect(display.creates == 1 && controller.saves == 0, "completion remains single start with no config write");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            NSError *error = nil;
            topology.captureResult = NO;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error], "capture failure still accepted into transaction");
            Expect(!profile.starting && [profile.startFailureText isEqualToString:@"无法读取显示配置，请重试。"]
                   && [controller.pendingProfileRevealOrdinal isEqualToNumber:@(profile.ordinal)]
                   && display.creates == 0 && controller.saves == 0
                   && [(YMFakeDisplay *)sibling.display destroys] == 0,
                   "capture failure keeps config and sibling");
            Expect([[controller profileActivityText] isEqualToString:@""], "idle activity text stays empty after capture failure");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            NSError *error = nil;
            display.createResult = NO;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error], "create failure accepted");
            Expect(!profile.starting && [profile.startFailureText isEqualToString:@"无法创建虚拟屏，请确认当前系统支持该功能。"]
                   && controller.saves == 0 && [(YMFakeDisplay *)sibling.display destroys] == 0,
                   "create failure retains saved profile");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            NSError *error = nil;
            topology.configureResult = NO;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error], "configure failure accepted");
            Expect(!profile.starting && [profile.startFailureText isEqualToString:@"显示配置核验失败，已恢复原排列；可重试。"]
                   && !display.live && controller.saves == 0
                   && [(YMFakeDisplay *)sibling.display destroys] == 0,
                   "configure failure restores and keeps sibling");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            NSError *error = nil;
            topology.configureResult = NO; topology.restoreResult = NO;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error], "restore failure accepted");
            Expect(!profile.starting && [profile.startFailureText isEqualToString:@"显示排列待恢复，请先使用恢复入口。"]
                   && controller.topologyRecoverySnapshot == topology.snapshot
                   && controller.saves == 0 && [(YMFakeDisplay *)sibling.display destroys] == 0,
                   "incomplete recovery blocks restart messaging");
            NSArray<YMSavedDisplayProfileRow *> *rows = [controller savedProfileRows];
            Expect(rows.count == 1 && rows.firstObject.ordinal == profile.ordinal
                   && !rows.firstObject.canStart && !rows.firstObject.canEdit
                   && [rows.firstObject.message containsString:@"待恢复"],
                   "recovery pending disables saved-row actions");
            Expect([[controller profileActivityText] containsString:@"待恢复"], "activity text exposes recovery gate");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            NSError *error = nil;
            topology.configureResult = NO; topology.restoreResult = NO;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error],
                   "restore failure before retry accepted");
            Expect(controller.topologyRecoverySnapshot == topology.snapshot
                   && ![[controller savedProfileRows].firstObject canStart]
                   && [[[controller savedProfileRows].firstObject message] containsString:@"待恢复"],
                   "pending recovery gates start before retry");
            topology.restoreResult = YES;
            [controller retryTopologyRecovery:nil];
            NSArray<YMSavedDisplayProfileRow *> *rows = [controller savedProfileRows];
            Expect(!controller.topologyRecoverySnapshot
                   && rows.count == 1
                   && rows.firstObject.canStart
                   && rows.firstObject.canEdit
                   && ![rows.firstObject.message containsString:@"待恢复"]
                   && (profile.startFailureText.length == 0
                       || ![profile.startFailureText containsString:@"待恢复"]),
                   "successful recovery clears stale pending message and restores actions");
            Expect(![[controller profileActivityText] containsString:@"待恢复"],
                   "activity text clears after successful recovery");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            NSError *error = nil;
            controller.powerFails = YES;
            Expect([controller startSavedProfileWithOrdinal:profile.ordinal error:&error], "power failure accepted");
            Expect(!profile.starting && [profile.startFailureText isEqualToString:@"无法保持图形桌面唤醒，已取消启动。"]
                   && !display.live && controller.saves == 0
                   && [(YMFakeDisplay *)sibling.display destroys] == 0,
                   "power failure rolls back only the new target");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1; profile.width = 1920; profile.height = 1080;
            YMHeadlessProfileEditor *marker = [YMHeadlessProfileEditor new];
            controller.profileEditor = (YMDisplayProfileEditor *)(id)marker;
            NSUInteger beforeCount = controller.displayProfiles.count;
            NSError *error = nil;
            Expect([controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@" Fresh " width:2560 hiDPI:YES]
                mode:YMDisplayProfileEditorModeCreate ordinal:0
                editor:(YMDisplayProfileEditor *)(id)marker error:&error], "create request accepted");
            Expect(controller.displayProfiles.count == beforeCount + 1 && controller.saves == 1
                   && display.creates == 0, "create persists once before start");
            YMManagedDisplay *created = controller.displayProfiles.lastObject;
            Expect(created.ordinal == 3 && [created.friendlyName isEqualToString:@"Fresh"]
                   && created.width == 2560 && created.height == 1440 && created.hiDPI
                   && created.topologyVerified && !created.starting
                   && [(YMFakeDisplay *)created.display creates] == 1
                   && [(YMFakeDisplay *)sibling.display destroys] == 0,
                   "create allocates next ordinal and starts once");
            NSUInteger createdOrdinal = created.ordinal;
            NSUInteger savesAfterCreate = controller.saves;
            [(YMFakeDisplay *)created.display destroy];
            created.topologyVerified = NO;
            Expect([controller startSavedProfileWithOrdinal:createdOrdinal error:&error]
                   && created.ordinal == createdOrdinal
                   && controller.displayProfiles.count == beforeCount + 1
                   && controller.saves == savesAfterCreate,
                   "retry keeps the same ordinal without another save");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            [controller create:nil];
            Expect(display.creates == 1 && controller.saves == 1 && profile.topologyVerified,
                   "legacy create wrapper still persists on success");
        }

        {
            YMFakeTopology *topology; YMFakeDisplay *display; YMManagedDisplay *profile, *sibling;
            YMFakeController *controller = Controller(&topology, &display, &profile, &sibling);
            sibling.ordinal = 1;
            profile.width = 1920; profile.height = 1080; profile.hiDPI = YES; profile.friendlyName = @"Saved";
            YMHeadlessProfileEditor *marker = [YMHeadlessProfileEditor new];
            controller.profileEditor = (YMDisplayProfileEditor *)(id)marker;
            NSError *error = nil;
            VDVirtualDisplay *originalDisplay = profile.display;
            Expect([controller acceptProfileDraft:[[YMDisplayProfileDraft alloc] initWithName:@" Renamed " width:800 hiDPI:NO]
                mode:YMDisplayProfileEditorModeRename ordinal:profile.ordinal
                editor:(YMDisplayProfileEditor *)(id)marker error:&error]
                   && [profile.friendlyName isEqualToString:@"Renamed"]
                   && profile.width == 1920 && profile.height == 1080 && profile.hiDPI
                   && profile.display == originalDisplay && controller.saves == 1 && display.creates == 0,
                   "rename keeps dimensions display object and saves once");
            NSArray<YMSavedDisplayProfileRow *> *rows = [controller savedProfileRows];
            Expect(rows.count == 1 && rows.firstObject.ordinal == profile.ordinal
                   && [rows.firstObject.name containsString:@"Renamed"]
                   && [rows.firstObject.detail containsString:@"HiDPI"]
                   && rows.firstObject.canStart && rows.firstObject.canEdit,
                   "saved rows project uncreated profiles only");
            display.live = YES;
            Expect([controller savedProfileRows].count == 0, "running profiles leave the saved list");
            display.live = NO;
            profile.starting = YES;
            Expect([[controller profileActivityText] containsString:@"启动中"]
                   && ![controller savedProfileRows].firstObject.canStart,
                   "starting state wins over ordinary actions");
            Expect(NSApp == nil, "projection helpers stay headless");
        }

        Expect(NSApp == nil,"all controller tests leave NSApplication uninitialized");
        printf("Controller boundary tests: %lu passed, %lu failed; no GUI or display calls executed.\n",(unsigned long)(Tests-Failures),(unsigned long)Failures);
        return Failures?1:0;
    }
}
