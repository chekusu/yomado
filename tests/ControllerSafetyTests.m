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
@end
@implementation YMFakeDisplay
- (instancetype)init { if ((self = [super init])) _createResult = YES; return self; }
- (BOOL)isCreated { return self.live; }
- (CGDirectDisplayID)displayID { return self.live ? self.fixtureID : 0; }
- (BOOL)createWithWidth:(NSUInteger)w height:(NSUInteger)h hiDPI:(BOOL)hiDPI name:(NSString *)name error:(NSError **)error {
    (void)w; (void)h; (void)hiDPI; (void)name; self.creates++;
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
- (void)showWindow:(id)sender {
    self.showCalls++;
    if (self.useRealPanelPresentation) [super showWindow:sender];
}
- (void)resumeTerminationAfterTopologyRecovery:(BOOL)recovered {
    if (self.terminationAfterTopologyRecovery && recovered) self.resumedTerminations++;
    self.terminationAfterTopologyRecovery=NO;
}
- (BOOL)writeStateEnding:(BOOL)end { (void)end; return YES; }
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

@interface ADController (YMRenameTestDeclaration)
- (NSAlert *)makeRenameAlertForProfile:(YMManagedDisplay *)profile;
@end

@interface YMRenameText : NSObject
@property(nonatomic, copy) NSString *stringValue;
@end
@implementation YMRenameText
@end

@interface YMRenameWindow : NSObject
@property(nonatomic) BOOL visible;
@property(nonatomic, strong) id attachedSheet;
@end
@implementation YMRenameWindow
@end

@interface YMRenameAlert : NSObject
@property(nonatomic, strong) YMRenameText *accessoryView;
@property(nonatomic, weak) YMRenameWindow *parent;
@property(nonatomic, copy) void (^completion)(NSModalResponse);
@property(nonatomic) NSUInteger begins;
- (void)beginSheetModalForWindow:(NSWindow *)window
              completionHandler:(void (^)(NSModalResponse))completion;
- (void)finish:(NSModalResponse)response;
@end
@implementation YMRenameAlert
- (void)beginSheetModalForWindow:(NSWindow *)window
              completionHandler:(void (^)(NSModalResponse))completion {
    self.parent = (YMRenameWindow *)(id)window;
    self.parent.attachedSheet = self;
    self.parent.visible = YES;
    self.completion = completion;
    self.begins++;
}
- (void)finish:(NSModalResponse)response {
    self.parent.attachedSheet = nil;
    void (^completion)(NSModalResponse) = self.completion;
    self.completion = nil;
    if (completion) completion(response);
}
@end

@interface YMRenameMenuItem : NSObject
@property(nonatomic, strong) id representedObject;
@end
@implementation YMRenameMenuItem
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

@interface YMRenameController : YMFakeController
@property(nonatomic) NSUInteger alertCreations;
@property(nonatomic, strong) YMRenameAlert *lastRenameAlert;
@end
@implementation YMRenameController
- (NSAlert *)makeRenameAlertForProfile:(YMManagedDisplay *)profile {
    self.alertCreations++;
    YMRenameAlert *alert = [YMRenameAlert new];
    alert.accessoryView = [YMRenameText new];
    alert.accessoryView.stringValue = profile.friendlyName ?: @"";
    self.lastRenameAlert = alert;
    return (NSAlert *)(id)alert;
}
@end

static YMRenameController *RenameController(YMRenameWindow **window, YMRenameEnvironment **environment, YMManagedDisplay **profile) {
    YMRenameController *c = [YMRenameController new];
    YMRenameWindow *w = [YMRenameWindow new];
    YMRenameEnvironment *e = [YMRenameEnvironment new];
    YMFakeDisplay *display = [YMFakeDisplay new];
    YMManagedDisplay *p = [YMManagedDisplay new];
    p.width = 800; p.height = 600; p.ordinal = 1;
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
            Expect(gate.needsRestorePolls >= 1,
                   "convergence polling observes needsRestore without a second write");
            Expect(closeD.live && closeD.destroys == 0, "successful restore does not destroy the display");

            gate.restoreCalls = 0; gate.readyPolls = 0; gate.needsRestorePolls = 0;
            gate.inventoryReady = NO;
            gate.refreshesBeforeReady = 0; // never becomes ready
            NSDate *started = [NSDate date];
            restored = [closeController restoreApplicationsForDisplayID:202];
            NSTimeInterval waited = -[started timeIntervalSinceNow];
            Expect(!restored && gate.restoreCalls == 0,
                   "inventory ready timeout never performs restore writes");
            Expect(waited >= 1.4 && waited < 3.0, "ready wait bounds near 1.5 seconds");
            Expect(closeD.live && closeD.destroys == 0,
                   "timeout does not remove the virtual display");
            Expect(closeController.reports >= 1, "timeout reports and retains the screen");

            // Ready after several refreshes, then a single restore write.
            gate.restoreCalls = 0; gate.readyPolls = 0; gate.needsRestorePolls = 0;
            gate.needsRestoreFlag = NO;
            gate.restoreResult = YES;
            gate.inventoryReady = NO;
            gate.refreshesBeforeReady = 3;
            [gate.events removeAllObjects];
            restored = [closeController restoreApplicationsForDisplayID:202];
            Expect(restored && gate.restoreCalls == 1,
                   "ready after several refreshes restores the display exactly once");
            Expect(gate.readyPolls >= 3, "controller waits through refreshesBeforeReady");

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
                @selector(makeRenameAlertForProfile:)];
            Expect(seamAvailable, "rename alert construction has a headless boundary");
            if (!seamAvailable) goto rename_tests_done;

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
            Expect(c.panelPresenter.panelOpen, "rename restores logical open state");
            [e drain];
            Expect(e.activationPolicy == NSApplicationActivationPolicyRegular,
                   "rename restores regular lifecycle");
            [c.lastRenameAlert finish:NSAlertSecondButtonReturn];
            Expect(c.panelPresenter.panelOpen && w.visible && c.saves == 0,
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

            NSArray<NSString *> *blockedFlags = @[
                @"previewMode", @"updateWorkspaceBusy", @"appOperationInProgress",
                @"displayOperationInProgress", @"armed", @"preparing", @"restoring",
                @"layoutChangedForTrial", @"recoveryRequested"
            ];
            for (NSString *flag in blockedFlags) {
                YMRenameWindow *bw; YMRenameEnvironment *be; YMManagedDisplay *bp;
                YMRenameController *bc = RenameController(&bw, &be, &bp);
                NSUInteger showBefore = bc.showCalls, alertsBefore = bc.alertCreations, savesBefore = bc.saves;
                [bc setValue:@YES forKey:flag];
                YMRenameMenuItem *blockedItem = [YMRenameMenuItem new];
                blockedItem.representedObject = bp;
                [bc renameManagedDisplayFromMenu:(NSMenuItem *)(id)blockedItem];
                Expect(bc.showCalls == showBefore && bc.alertCreations == alertsBefore && bc.saves == savesBefore,
                       [[NSString stringWithFormat:@"blocked flag %@ rejects rename", flag] UTF8String]);
                [bc.panelPresenter invalidate];
                [be.pending removeAllObjects];
                [be.settling removeAllObjects];
            }

            {
                YMRenameWindow *rw; YMRenameEnvironment *re; YMManagedDisplay *rp;
                YMRenameController *rc = RenameController(&rw, &re, &rp);
                NSUInteger showBefore = rc.showCalls, alertsBefore = rc.alertCreations, savesBefore = rc.saves;
                YMRenameMenuItem *nilItem = [YMRenameMenuItem new];
                nilItem.representedObject = nil;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)nilItem];
                Expect(rc.showCalls == showBefore && rc.alertCreations == alertsBefore && rc.saves == savesBefore,
                       "nil representedObject rejects rename");
                YMRenameMenuItem *objItem = [YMRenameMenuItem new];
                objItem.representedObject = [NSObject new];
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)objItem];
                Expect(rc.showCalls == showBefore && rc.alertCreations == alertsBefore && rc.saves == savesBefore,
                       "non-profile representedObject rejects rename");
                YMManagedDisplay *outsider = [YMManagedDisplay new];
                outsider.friendlyName = @"Outsider";
                YMRenameMenuItem *outItem = [YMRenameMenuItem new];
                outItem.representedObject = outsider;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)outItem];
                Expect(rc.showCalls == showBefore && rc.alertCreations == alertsBefore && rc.saves == savesBefore,
                       "profile outside displayProfiles rejects rename");
                rw.attachedSheet = [NSObject new];
                YMRenameMenuItem *sheetItem = [YMRenameMenuItem new];
                sheetItem.representedObject = rp;
                [rc renameManagedDisplayFromMenu:(NSMenuItem *)(id)sheetItem];
                Expect(rc.showCalls == showBefore && rc.alertCreations == alertsBefore && rc.saves == savesBefore,
                       "existing attachedSheet rejects second rename");
                [rc.panelPresenter invalidate];
                [re.pending removeAllObjects];
                [re.settling removeAllObjects];
            }

            NSArray<NSDictionary *> *cases = @[
                @{ @"text": @"Ignored", @"response": @(NSAlertSecondButtonReturn), @"saves": @0, @"name": @"Original" },
                @{ @"text": @"  Renamed  ", @"response": @(NSAlertFirstButtonReturn), @"saves": @1, @"name": @"Renamed" },
                @{ @"text": @"x", @"response": @(NSAlertFirstButtonReturn), @"saves": @1, @"name": @"x" },
                @{ @"text": [@"" stringByPaddingToLength:60 withString:@"x" startingAtIndex:0],
                   @"response": @(NSAlertFirstButtonReturn), @"saves": @1,
                   @"name": [@"" stringByPaddingToLength:60 withString:@"x" startingAtIndex:0] },
                @{ @"text": @"   ", @"response": @(NSAlertFirstButtonReturn), @"saves": @0, @"name": @"Original" },
                @{ @"text": @"A\nB", @"response": @(NSAlertFirstButtonReturn), @"saves": @0, @"name": @"Original" },
                @{ @"text": [@"" stringByPaddingToLength:61 withString:@"x" startingAtIndex:0],
                   @"response": @(NSAlertFirstButtonReturn), @"saves": @0, @"name": @"Original" }
            ];
            for (NSDictionary *caseInfo in cases) {
                YMRenameWindow *cw; YMRenameEnvironment *ce; YMManagedDisplay *cp;
                YMRenameController *cc = RenameController(&cw, &ce, &cp);
                NSUInteger inventoryBefore = cc.inventoryUpdates;
                NSUInteger hidesBefore = ce.hides;
                YMRenameMenuItem *caseItem = [YMRenameMenuItem new];
                caseItem.representedObject = cp;
                [cc renameManagedDisplayFromMenu:(NSMenuItem *)(id)caseItem];
                [ce drain];
                cc.lastRenameAlert.accessoryView.stringValue = caseInfo[@"text"];
                [cc.lastRenameAlert finish:[caseInfo[@"response"] integerValue]];
                NSUInteger expectedSaves = [caseInfo[@"saves"] unsignedIntegerValue];
                Expect(cc.saves == expectedSaves && [cp.friendlyName isEqualToString:caseInfo[@"name"]],
                       [[NSString stringWithFormat:@"rename case %@ saves and name", caseInfo[@"name"]] UTF8String]);
                if (expectedSaves == 1) {
                    Expect(cc.inventoryUpdates == inventoryBefore + 1, "valid save updates inventory once");
                } else {
                    Expect(cc.inventoryUpdates == inventoryBefore, "non-save leaves inventory unchanged");
                }
                Expect(cc.panelPresenter.panelOpen && cw.visible && ce.hides == hidesBefore,
                       "rename completion keeps panel open without hiding");
                [cc windowShouldClose:cc.window]; [ce drain];
                Expect(!cw.visible && !cc.panelPresenter.panelOpen && ce.hides == hidesBefore + 1,
                       "explicit close after rename case hides once");
                [cc.panelPresenter invalidate];
                [ce.pending removeAllObjects];
                [ce.settling removeAllObjects];
            }

            {
                YMRenameWindow *iw; YMRenameEnvironment *ie; YMManagedDisplay *ip;
                YMRenameController *ic = RenameController(&iw, &ie, &ip);
                YMManagedDisplay *selected = [YMManagedDisplay new];
                selected.friendlyName = @"Selected";
                YMFakeDisplay *selectedDisplay = [YMFakeDisplay new];
                selected.display = selectedDisplay;
                [ic.displayProfiles addObject:selected];
                ic.selectedProfile = selected;
                ic.virtualDisplay = selectedDisplay;
                YMRenameMenuItem *targetItem = [YMRenameMenuItem new];
                targetItem.representedObject = ip;
                [ic renameManagedDisplayFromMenu:(NSMenuItem *)(id)targetItem];
                [ie drain];
                ic.lastRenameAlert.accessoryView.stringValue = @"MenuTarget";
                [ic.lastRenameAlert finish:NSAlertFirstButtonReturn];
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
                ic.lastRenameAlert.accessoryView.stringValue = @"Gone";
                [ic.lastRenameAlert finish:NSAlertFirstButtonReturn];
                Expect(ic.saves == 0 && [ip.friendlyName isEqual:@"Original"] && ic.panelPresenter.panelOpen,
                       "removed target at finish does not save");
                [ic windowShouldClose:ic.window]; [ie drain];
                Expect(!iw.visible && !ic.panelPresenter.panelOpen, "panel still closes after removed-target finish");
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
                ic.lastRenameAlert.accessoryView.stringValue = @"Busy";
                [ic.lastRenameAlert finish:NSAlertFirstButtonReturn];
                Expect(ic.saves == 0 && [ip.friendlyName isEqual:@"Original"] && ic.panelPresenter.panelOpen,
                       "busy at finish does not save");
                ic.updateWorkspaceBusy = NO;
                [ic windowShouldClose:ic.window]; [ie drain];
                Expect(!iw.visible && !ic.panelPresenter.panelOpen, "panel still closes after busy finish");
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
                [sc.lastRenameAlert finish:NSAlertSecondButtonReturn];
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
                [dc.lastRenameAlert finish:NSAlertSecondButtonReturn];
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
                [oc.lastRenameAlert finish:NSAlertSecondButtonReturn];
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
                [rc.lastRenameAlert finish:NSAlertSecondButtonReturn];
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
                [nc.lastRenameAlert finish:NSAlertSecondButtonReturn];
                [nc windowShouldClose:nc.window]; [ne drain];
                [nc showWindow:nil]; [ne drain];
                sideItem = [YMRenameMenuItem new];
                sideItem.representedObject = np;
                [nc renameManagedDisplayFromMenu:(NSMenuItem *)(id)sideItem];
                [ne drain];
                nc.lastRenameAlert.accessoryView.stringValue = @"SideEffect";
                [nc.lastRenameAlert finish:NSAlertFirstButtonReturn];
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
                [ac.lastRenameAlert finish:NSAlertSecondButtonReturn];
                Expect(ac.panelPresenter.panelOpen && aw.visible && ac.saves == 0,
                       "already-open cancel keeps panel open");
                [ac renameManagedDisplayFromMenu:(NSMenuItem *)(id)alreadyItem];
                [ae drain];
                ac.lastRenameAlert.accessoryView.stringValue = @"AlreadyOpen";
                [ac.lastRenameAlert finish:NSAlertFirstButtonReturn];
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
        }
    rename_tests_done:

        Expect(NSApp == nil,"all controller tests leave NSApplication uninitialized");
        printf("Controller boundary tests: %lu passed, %lu failed; no GUI or display calls executed.\n",(unsigned long)(Tests-Failures),(unsigned long)Failures);
        return Failures?1:0;
    }
}
