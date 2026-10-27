#import <Foundation/Foundation.h>
#import "YMDisplayTopology.h"

static NSUInteger checks = 0;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static NSDictionary *Mode(NSUInteger width, NSUInteger height, BOOL hiDPI, NSInteger ident) {
    NSDictionary *values = @{@"modeWidth":@(width), @"modeHeight":@(height),
        @"pixelWidth":@(width * (hiDPI ? 2 : 1)), @"pixelHeight":@(height * (hiDPI ? 2 : 1)),
        @"refreshRate":@60, @"modeID":@(ident), @"modeFlags":@0, @"modeUsableForDesktopGUI":@YES};
    NSMutableDictionary *result = [values mutableCopy]; result[@"modeToken"] = values;
    return result;
}
static NSMutableDictionary *Screen(NSInteger ident, NSInteger x, NSInteger y, BOOL main, NSUInteger width, NSUInteger height, BOOL hiDPI) {
    NSMutableDictionary *item = [@{@"displayID":@(ident), @"identity":[NSString stringWithFormat:@"fixture-%ld", (long)ident],
        @"vendor":@505, @"model":@1, @"serial":@(ident), @"builtin":@NO,
        @"x":@(x), @"y":@(y), @"logicalWidth":@(width), @"logicalHeight":@(height),
        @"main":@(main), @"active":@YES, @"online":@YES, @"rotation":@0,
        @"mirrorOf":@0, @"inMirrorSet":@NO} mutableCopy];
    [item addEntriesFromDictionary:Mode(width, height, hiDPI, ident * 100)]; return item;
}

@interface FakeBackend : NSObject <YMDisplayTopologyBackend>
@property NSMutableArray<NSMutableDictionary *> *screens;
@property NSMutableArray<NSMutableDictionary *> *staged;
@property NSMutableArray<NSString *> *calls;
@property NSMutableDictionary *preferredMode;
@property BOOL failCommit;
@property BOOL failMode;
@property BOOL failMirror;
@property BOOL failOrigin;
@property BOOL rejectMode;
@property BOOL suppressCommit;
@property BOOL modeMutationAfterCommit;
@property BOOL foreignAfterCommit;
@property BOOL generationDuringStage;
@property BOOL foreignEditDuringStage;
@property BOOL rejectInactiveFollowerMode;
@property BOOL modeIDEditDuringStage;
@property BOOL modeIDsAfterCommit;
@property BOOL modeIDEveryRead;
@property NSUInteger modeIDChurnReadsAfterCommit;
@property NSError *modeError;
@property NSUInteger modeIDEditAtRead;
@property BOOL delayedReconfiguration;
@property BOOL delayedThenStable;
@property BOOL switched;
@property NSUInteger modeMissingReads;
@property NSUInteger modeMissingAfterCommit;
@property NSUInteger missingModeID;
@property BOOL foreignWhileModeMissing;
@property BOOL mirrorEditWhileModeMissing;
@property NSUInteger reads;
@property NSUInteger waits;
@property NSUInteger delayRemovalID;
@property NSUInteger commits;
@property NSUInteger cancels;
@property(nonatomic) NSUInteger reconfigurationGeneration;
@end

@implementation FakeBackend
- (instancetype)init {
    if ((self = [super init])) {
        _screens = [NSMutableArray arrayWithArray:@[Screen(1, 0, 0, YES, 2560, 1440, YES), Screen(2, -2560, 240, NO, 2560, 1440, YES)]];
        _calls = [NSMutableArray array];
        _preferredMode = [Mode(1920, 1080, NO, 300) mutableCopy];
    }
    return self;
}
- (NSMutableDictionary *)find:(NSUInteger)ident in:(NSArray *)items {
    for (NSMutableDictionary *item in items) if ([item[@"displayID"] unsignedIntegerValue] == ident) return item;
    return nil;
}
- (NSArray *)readDisplaysWithError:(NSError **)error {
    self.reads++;
    if (self.modeIDEveryRead || self.reads == self.modeIDEditAtRead || (self.commits && self.modeIDChurnReadsAfterCommit)) {
        if (self.commits && self.modeIDChurnReadsAfterCommit) self.modeIDChurnReadsAfterCommit--;
        NSMutableDictionary *item=[self find:1 in:self.screens];
        item[@"modeID"]=@([item[@"modeID"] unsignedIntegerValue]+1);
    }
    if (self.modeMissingReads) {
        self.modeMissingReads--;
        NSMutableArray *partial = [NSMutableArray array];
        for (NSDictionary *item in self.screens) {
            NSMutableDictionary *copy = item.mutableCopy;
            if ([copy[@"displayID"] unsignedIntegerValue] == self.missingModeID) {
                for (NSString *key in @[@"modeToken", @"modeWidth", @"modeHeight", @"pixelWidth", @"pixelHeight", @"refreshRate", @"modeID", @"modeFlags", @"modeUsableForDesktopGUI"])
                    [copy removeObjectForKey:key];
            }
            [partial addObject:copy];
        }
        if (error) *error = [NSError errorWithDomain:YMDisplayTopologyErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey:@"Current mode unavailable", @"displayInventory":partial}];
        return nil;
    }
    return [[NSArray alloc] initWithArray:self.screens copyItems:YES];
}
- (NSDictionary *)modeForDisplay:(CGDirectDisplayID)displayID width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI error:(NSError **)error {
    (void)displayID; (void)width; (void)height; (void)hiDPI; (void)error;
    return self.rejectMode ? nil : self.preferredMode;
}
- (BOOL)beginConfiguration:(NSError **)error {
    (void)error; [self.calls addObject:@"begin"];
    self.staged = [NSMutableArray array];
    for (NSDictionary *item in self.screens) [self.staged addObject:item.mutableCopy];
    return YES;
}
- (BOOL)setMirrorOfDisplay:(CGDirectDisplayID)displayID toDisplay:(CGDirectDisplayID)targetID error:(NSError **)error {
    (void)error; [self.calls addObject:[NSString stringWithFormat:@"mirror:%u:%u", displayID, targetID]];
    if (self.failMirror) return NO;
    NSMutableDictionary *item = [self find:displayID in:self.staged]; item[@"mirrorOf"] = @(targetID);
    item[@"active"] = @(targetID == 0);
    return YES;
}
- (BOOL)setModeOfDisplay:(CGDirectDisplayID)displayID token:(id)modeToken error:(NSError **)error {
    (void)error; [self.calls addObject:[NSString stringWithFormat:@"mode:%u", displayID]];
    if (self.failMode) { if (error) *error=self.modeError; return NO; }
    NSMutableDictionary *item = [self find:displayID in:self.staged];
    if (self.rejectInactiveFollowerMode && ![item[@"active"] boolValue] && [item[@"mirrorOf"] unsignedIntValue]) {
        if (error) *error=[NSError errorWithDomain:@"SyntheticModeSetter" code:1001 userInfo:@{NSLocalizedDescriptionKey:@"Synthetic inactive mirror follower rejects mode write"}];
        return NO;
    }
    [item addEntriesFromDictionary:modeToken]; item[@"modeToken"] = modeToken;
    item[@"logicalWidth"] = item[@"modeWidth"]; item[@"logicalHeight"] = item[@"modeHeight"];
    return YES;
}
- (BOOL)setOriginOfDisplay:(CGDirectDisplayID)displayID x:(int32_t)x y:(int32_t)y error:(NSError **)error {
    (void)error; [self.calls addObject:[NSString stringWithFormat:@"origin:%u:%d:%d", displayID, x, y]];
    if (self.failOrigin) return NO;
    if (self.generationDuringStage) { self.reconfigurationGeneration++; self.generationDuringStage = NO; }
    if (self.modeIDEditDuringStage) {
        NSMutableDictionary *item=[self find:1 in:self.screens];
        item[@"modeID"]=@([item[@"modeID"] unsignedIntegerValue]+1);
        self.modeIDEditDuringStage=NO;
    }
    if (self.foreignEditDuringStage) {
        [self find:2 in:self.screens][@"x"] = @-2400;
        self.foreignEditDuringStage = NO;
    }
    NSMutableDictionary *item = [self find:displayID in:self.staged];
    item[@"x"] = @(x); item[@"y"] = @(y); item[@"mirrorOf"] = @0;
    if (x == 0 && y == 0) for (NSMutableDictionary *other in self.staged) other[@"main"] = @(other == item);
    return YES;
}
- (BOOL)commitConfiguration:(NSError **)error {
    (void)error; self.commits++; [self.calls addObject:@"commit"];
    if (self.failCommit) { self.staged = nil; return NO; }
    for (NSMutableDictionary *item in self.staged) item[@"inMirrorSet"] = @([item[@"mirrorOf"] unsignedIntValue] != 0);
    for (NSDictionary *item in self.staged) {
        NSUInteger mirror = [item[@"mirrorOf"] unsignedIntegerValue];
        if (mirror) [self find:mirror in:self.staged][@"inMirrorSet"] = @YES;
    }
    if (!self.suppressCommit) self.screens = self.staged;
    self.staged = nil; self.reconfigurationGeneration++;
    if (self.modeMutationAfterCommit) [self find:1 in:self.screens][@"refreshRate"] = @30;
    if (self.modeIDsAfterCommit) for (NSMutableDictionary *item in self.screens)
        item[@"modeID"]=@([item[@"modeID"] unsignedIntegerValue]+1000);
    if (self.foreignAfterCommit) [self.screens addObject:Screen(9, 7000, 0, NO, 800, 600, NO)];
    self.waits = 0;
    if (self.modeMissingAfterCommit) { self.modeMissingReads = self.modeMissingAfterCommit; self.modeMissingAfterCommit = 0; }
    return YES;
}
- (void)cancelConfiguration { self.staged = nil; self.cancels++; [self.calls addObject:@"cancel"]; }
- (void)waitForNextObservation {
    self.waits++;
    if (self.modeMissingReads && self.foreignWhileModeMissing) {
        [self.screens addObject:Screen(9, 7000, 0, NO, 800, 600, NO)]; self.foreignWhileModeMissing = NO;
    }
    if (self.modeMissingReads && self.mirrorEditWhileModeMissing) {
        [self find:2 in:self.screens][@"mirrorOf"] = @1;
        [self find:2 in:self.screens][@"inMirrorSet"] = @YES; [self find:1 in:self.screens][@"inMirrorSet"] = @YES;
        self.mirrorEditWhileModeMissing = NO;
    }
    if (self.delayRemovalID && self.waits == 3) {
        NSMutableDictionary *item = [self find:self.delayRemovalID in:self.screens]; [self.screens removeObject:item];
        self.delayRemovalID = 0; self.reconfigurationGeneration++;
    }
    if (self.commits && (self.delayedReconfiguration || self.delayedThenStable) && self.waits == 4) {
        [self find:1 in:self.screens][@"pixelWidth"] = @1024;
        self.reconfigurationGeneration++; self.switched = YES;
    }
    if (self.commits && self.delayedThenStable && self.waits == 9) {
        [self find:1 in:self.screens][@"pixelWidth"] = @5120; self.reconfigurationGeneration++;
    }
}
@end

static YMDisplayTopologySnapshot *Baseline(YMDisplayTopology *topology) {
    NSError *error = nil;
    YMDisplayTopologySnapshot *snapshot = [topology captureSnapshotWithError:&error];
    Check(snapshot != nil, [NSString stringWithFormat:@"capture: %@", error]); return snapshot;
}
static void AddNew(FakeBackend *backend) { [backend.screens addObject:Screen(3, 100, 0, NO, 1920, 1080, NO)]; }
static BOOL Configure(YMDisplayTopology *topology, YMDisplayTopologySnapshot *snapshot) {
    NSError *error = nil;
    return [topology configureAndVerifyNewDisplay:3 width:1920 height:1080 hiDPI:NO baseline:snapshot error:&error];
}
// Issue-shaped synthetic topology only: no claim that these mode tokens or
// setter behavior reproduce any reporter's particular display driver.
static FakeBackend *MirroredRotatedFixture(void) {
    FakeBackend *backend=[FakeBackend new];
    NSMutableDictionary *root=Screen(1,0,0,YES,1920,1080,YES);
    root[@"inMirrorSet"]=@YES;
    NSMutableDictionary *follower=Screen(2,0,0,NO,1920,1080,YES);
    follower[@"builtin"]=@YES; follower[@"active"]=@NO;
    follower[@"mirrorOf"]=@1; follower[@"inMirrorSet"]=@YES;
    NSMutableDictionary *rotated=Screen(4,-900,0,NO,900,1600,YES);
    rotated[@"rotation"]=@90;
    backend.screens=[NSMutableArray arrayWithArray:@[root,follower,rotated]];
    backend.rejectInactiveFollowerMode=YES;
    return backend;
}
static void CheckOriginalMirrorAndRotation(FakeBackend *backend) {
    NSDictionary *root=[backend find:1 in:backend.screens];
    NSDictionary *follower=[backend find:2 in:backend.screens];
    NSDictionary *rotated=[backend find:4 in:backend.screens];
    Check([root[@"main"] boolValue]&&[root[@"active"] boolValue]&&[root[@"inMirrorSet"] boolValue],@"existing mirror root remains main and active");
    Check([follower[@"mirrorOf"] unsignedIntValue]==1&&[follower[@"inMirrorSet"] boolValue]&&![follower[@"active"] boolValue],@"existing inactive mirror follower retains its edge");
    Check([rotated[@"rotation"] integerValue]==90&&[rotated[@"x"] integerValue]==-900&&[rotated[@"y"] integerValue]==0
        &&[rotated[@"logicalWidth"] integerValue]==900&&[rotated[@"logicalHeight"] integerValue]==1600,@"rotated external retains orientation and bounds");
}
static void RunEquivalentModeRegressions(void) {
    for (NSNumber *changedDisplay in @[@2,@1,@4]) {
        FakeBackend *backend=MirroredRotatedFixture();
        YMDisplayTopology *topology=[[YMDisplayTopology alloc] initWithBackend:backend];
        YMDisplayTopologySnapshot *snapshot=Baseline(topology); AddNew(backend);
        NSMutableDictionary *changed=[backend find:changedDisplay.unsignedIntegerValue in:backend.screens];
        changed[@"modeID"]=@([changed[@"modeID"] unsignedIntegerValue]+1000);
        NSError *error=nil;
        BOOL accepted=[topology configureAndVerifyNewDisplay:3 width:1920 height:1080 hiDPI:NO baseline:snapshot error:&error];
        Check(accepted,[NSString stringWithFormat:@"equivalent mode renumber on display %@ permits creation without rewriting saved mode (error %@)",changedDisplay,error]);
        for (NSNumber *ident in @[@1,@2,@4]) Check(![backend.calls containsObject:[NSString stringWithFormat:@"mode:%@",ident]],@"physically equivalent existing modes are not rewritten");
        Check(![backend.calls containsObject:@"mirror:2:0"]&&![backend.calls containsObject:@"origin:2:0:0"],@"existing follower is neither detached nor repositioned");
        Check([topology isExtendedTarget:3 width:1920 height:1080 hiDPI:NO],@"new extended target admitted after complete verification");
        CheckOriginalMirrorAndRotation(backend);
        [backend.screens removeObject:[backend find:3 in:backend.screens]];
        NSUInteger priorCalls=backend.calls.count;
        Check([topology restoreAndVerifySnapshot:snapshot excludingDisplayID:3 error:NULL],@"ID-only mode changes do not prevent verified removal recovery");
        Check(backend.calls.count==priorCalls,@"equivalent removal recovery performs no redundant writes");
        CheckOriginalMirrorAndRotation(backend);
    }
    FakeBackend *backend=MirroredRotatedFixture();
    YMDisplayTopology *topology=[[YMDisplayTopology alloc] initWithBackend:backend];
    YMDisplayTopologySnapshot *snapshot=Baseline(topology); AddNew(backend); backend.modeIDsAfterCommit=YES;
    Check(Configure(topology,snapshot),@"mode IDs renumbered by transaction do not reject an equivalent final topology");
    CheckOriginalMirrorAndRotation(backend);
    [backend.screens removeObject:[backend find:3 in:backend.screens]];
    NSUInteger calls=backend.calls.count;
    Check([topology restoreAndVerifySnapshot:snapshot excludingDisplayID:3 error:NULL]&&backend.calls.count==calls,@"post-commit mode renumber remains read-only recoverable");
}
static void RunModeSafetyRegressions(void) {
    // Every non-ID mode field still matters, including both HiDPI dimensions.
    for (NSString *field in @[@"modeWidth",@"modeHeight",@"pixelWidth",@"pixelHeight",@"refreshRate",@"modeFlags",@"modeUsableForDesktopGUI"]) {
        FakeBackend *backend=MirroredRotatedFixture();
        YMDisplayTopology *topology=[[YMDisplayTopology alloc] initWithBackend:backend];
        YMDisplayTopologySnapshot *snapshot=Baseline(topology); AddNew(backend);
        NSMutableDictionary *follower=[backend find:2 in:backend.screens];
        follower[field]=[field isEqual:@"modeUsableForDesktopGUI"]?@NO:@([follower[field] integerValue]+1);
        Check(!Configure(topology,snapshot),[NSString stringWithFormat:@"actual follower %@ change cannot be silently accepted",field]);
        Check([backend.calls containsObject:@"mode:2"]&&backend.commits==0&&backend.cancels==1,@"real follower drift still requires a supported mode restore");
    }
    FakeBackend *backend=MirroredRotatedFixture();
    YMDisplayTopology *topology=[[YMDisplayTopology alloc] initWithBackend:backend];
    backend.modeIDEveryRead=YES;
    Check([topology captureSnapshotWithError:NULL]==nil&&backend.calls.count==0,@"capture cannot freeze continuously renumbering observations");
    for (NSUInteger stage=0;stage<2;stage++) {
        backend=MirroredRotatedFixture(); topology=[[YMDisplayTopology alloc] initWithBackend:backend];
        YMDisplayTopologySnapshot *snapshot=Baseline(topology); AddNew(backend);
        if (stage==0) backend.modeIDEditAtRead=backend.reads+2; else backend.modeIDEditDuringStage=YES;
        NSError *error=nil;
        Check(![topology configureAndVerifyNewDisplay:3 width:1920 height:1080 hiDPI:NO baseline:snapshot error:&error],@"mode-ID race between observations still refuses a transaction");
        Check(error.code==(stage==0?20:22)&&backend.commits==0,@"ID-only concurrent edit retains precise preflight/precommit guard");
        Check(stage==0?backend.calls.count==0:backend.cancels==1,@"concurrent mode change cancels before applying anything");
        [backend.screens removeObject:[backend find:3 in:backend.screens]];
        [backend find:4 in:backend.screens][@"x"]=@-800;
        NSUInteger previousCalls=backend.calls.count;
        Check(![topology restoreAndVerifySnapshot:snapshot excludingDisplayID:3 error:NULL]&&backend.calls.count==previousCalls,@"race still latches rollback read-only instead of reverting later layout");
    }
    for (NSNumber *churnCount in @[@100,@20]) {
        backend=MirroredRotatedFixture(); topology=[[YMDisplayTopology alloc] initWithBackend:backend];
        YMDisplayTopologySnapshot *churnBaseline=Baseline(topology); AddNew(backend);
        backend.modeIDChurnReadsAfterCommit=churnCount.unsignedIntegerValue;
        NSError *churnError=nil;
        BOOL accepted=[topology configureAndVerifyNewDisplay:3 width:1920 height:1080 hiDPI:NO baseline:churnBaseline error:&churnError];
        if (churnCount.unsignedIntegerValue==100) {
            Check(!accepted&&churnError.code==17&&backend.waits==30,@"continuous post-commit mode-ID churn exhausts bounded verification instead of admitting");
        } else {
            Check(accepted&&backend.waits>=24,@"settled mode-ID replacement needs five consecutive identical observations");
        }
    }
    backend=MirroredRotatedFixture(); topology=[[YMDisplayTopology alloc] initWithBackend:backend];
    YMDisplayTopologySnapshot *snapshot=Baseline(topology); AddNew(backend);
    [backend find:4 in:backend.screens][@"rotation"]=@270;
    Check(!Configure(topology,snapshot)&&backend.calls.count==0,@"changed external rotation remains a refusal without writes");
    [backend.screens removeObject:[backend find:3 in:backend.screens]];
    Check(![topology restoreAndVerifySnapshot:snapshot excludingDisplayID:3 error:NULL]&&backend.calls.count==0,@"rotation refusal keeps recovery read-only");
}
static void RunModeDiagnosticRegressions(void) {
    NSDictionary *roles=@{@1:@"existing mirror primary",@2:@"existing mirror follower",@4:@"existing extended display",@3:@"new virtual display"};
    NSSet *modeKeys=[NSSet setWithArray:@[@"modeWidth",@"modeHeight",@"pixelWidth",@"pixelHeight",@"refreshRate",@"modeFlags",@"modeID",@"modeUsableForDesktopGUI"]];
    NSSet *detailKeys=[NSSet setWithArray:@[@"operation",@"role",@"cgError",@"active",@"main",@"builtin",@"rotation",@"savedMode",@"currentMode"]];
    for (NSNumber *ident in @[@1,@2,@4,@3]) {
        FakeBackend *backend=MirroredRotatedFixture();
        for (NSMutableDictionary *item in backend.screens) {
            item[@"identity"]=[NSString stringWithFormat:@"PRIVATE-IDENTITY-CANARY-%@",item[@"displayID"]];
            NSMutableDictionary *token=[item[@"modeToken"] mutableCopy]; token[@"privateMetadata"]=@"PRIVATE-TOKEN-CANARY"; item[@"modeToken"]=token;
        }
        YMDisplayTopology *topology=[[YMDisplayTopology alloc] initWithBackend:backend];
        YMDisplayTopologySnapshot *snapshot=Baseline(topology); AddNew(backend);
        NSMutableDictionary *changed=[backend find:ident.unsignedIntegerValue in:backend.screens];
        changed[@"pixelWidth"]=@([changed[@"pixelWidth"] integerValue]+1);
        backend.failMode=YES;
        NSError *underlying=[NSError errorWithDomain:@"SyntheticUnderlying" code:5 userInfo:@{NSLocalizedDescriptionKey:@"PRIVATE-UNDERLYING-CANARY"}];
        backend.modeError=[NSError errorWithDomain:@"SyntheticCGError" code:1001 userInfo:@{
            NSLocalizedDescriptionKey:@"PRIVATE-ERROR-TEXT-CANARY", NSUnderlyingErrorKey:underlying,@"privateData":@"PRIVATE-CREDENTIAL-CANARY"}];
        NSError *error=nil;
        Check(![topology configureAndVerifyNewDisplay:3 width:1920 height:1080 hiDPI:NO baseline:snapshot error:&error],@"mode-setting failure with role context still fails closed");
        NSDictionary *details=error.userInfo[YMDisplayTopologyDiagnosticsKey];
        Check([error.domain isEqual:@"SyntheticCGError"]&&error.code==1001&&[details[@"cgError"] integerValue]==1001,@"diagnostics preserve returned domain and numeric CGError");
        Check([details[@"role"] isEqual:roles[ident]]&&[details[@"operation"] isEqual:@"setDisplayMode"],@"diagnostics identify failing display role without an identifier");
        Check([[NSSet setWithArray:details.allKeys] isEqual:detailKeys],@"diagnostics expose only allowlisted role/mode context");
        Check([details[@"active"] isEqual:changed[@"active"]]&&[details[@"main"] isEqual:changed[@"main"]]
            &&[details[@"builtin"] isEqual:changed[@"builtin"]]&&[details[@"rotation"] isEqual:changed[@"rotation"]],@"diagnostics retain relevant current flags and rotation");
        for (NSString *key in @[@"savedMode",@"currentMode"]) {
            NSDictionary *mode=details[key];
            Check([[NSSet setWithArray:mode.allKeys] isEqual:modeKeys],@"mode diagnostics contain exactly numeric mode properties");
            for (id value in mode.allValues) Check([value isKindOfClass:NSNumber.class]&&isfinite([value doubleValue]),@"diagnostic mode values are finite numbers");
        }
        Check(![details[@"savedMode"][@"pixelWidth"] isEqual:details[@"currentMode"][@"pixelWidth"]],@"saved and failing current mode difference is visible");
        Check([[NSSet setWithArray:error.userInfo.allKeys] isEqual:[NSSet setWithArray:@[NSLocalizedDescriptionKey,YMDisplayTopologyDiagnosticsKey]]],@"underlying errors and arbitrary metadata are not copied");
        NSData *json=[NSJSONSerialization dataWithJSONObject:error.userInfo options:0 error:NULL];
        NSString *serialized=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        Check(json!=nil&&![serialized containsString:@"CANARY"]&&![serialized containsString:@"modeToken"]&&![serialized containsString:@"displayID"]
            &&![serialized containsString:@"identity"]&&![serialized containsString:@"serial"]&&![serialized containsString:@"vendor"],@"serialized diagnostic has no identities tokens private text or private metadata");
        Check([error.localizedDescription containsString:roles[ident]]&&[error.localizedDescription containsString:@"1001"],@"user-visible error names role and CGError");
    }
}
static void RunTests(void) {
    FakeBackend *b = [FakeBackend new]; YMDisplayTopology *t = [[YMDisplayTopology alloc] initWithBackend:b];
    YMDisplayTopologySnapshot *s = Baseline(t); AddNew(b);
    Check(Configure(t, s), @"ordinary creation verifies");
    Check([[b find:3 in:b.screens][@"x"] integerValue] == 2560, @"new screen uses frozen right edge");
    Check([[b find:2 in:b.screens][@"x"] integerValue] == -2560, @"left physical position retained");
    Check([[b find:2 in:b.screens][@"y"] integerValue] == 240, @"staggered physical position retained");
    Check([t isExtendedTarget:3 width:1920 height:1080 hiDPI:NO], @"verified extended admission");
    Check(![t isExtendedTarget:3 width:1920 height:1080 hiDPI:YES], @"incorrect scale denied");
    Check(b.waits >= 15, @"at least 1.5 seconds of stable observations required");
    Check(![b.calls containsObject:@"mode:1"], @"unchanged original mode not rewritten");

    for (NSUInteger mirrored = 0; mirrored < 2; mirrored++) {
        b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
        if (mirrored == 0) { [b find:3 in:b.screens][@"mirrorOf"] = @1; [b find:3 in:b.screens][@"active"] = @NO; }
        else { [b find:1 in:b.screens][@"mirrorOf"] = @3; [b find:1 in:b.screens][@"active"] = @NO;
            [b find:1 in:b.screens][@"main"] = @NO; [b find:3 in:b.screens][@"main"] = @YES; }
        [b find:1 in:b.screens][@"inMirrorSet"] = @YES; [b find:3 in:b.screens][@"inMirrorSet"] = @YES;
        Check(![t isExtendedTarget:3 width:1920 height:1080 hiDPI:NO], @"mirror root and follower denied before configuration");
        Check(Configure(t, s), @"new mirror follower/root detached while restoring original main");
        Check([[b find:1 in:b.screens][@"main"] boolValue], @"original main preserved");
        Check(![[b find:3 in:b.screens][@"inMirrorSet"] boolValue], @"new screen not a mirror root");
        Check(![[b find:1 in:b.screens][@"inMirrorSet"] boolValue], @"former related root restored");
    }

    b = [FakeBackend new];
    NSMutableDictionary *follower = Screen(4, -2560, 240, NO, 2560, 1440, YES);
    follower[@"mirrorOf"] = @2; follower[@"inMirrorSet"] = @YES; follower[@"active"] = @NO;
    [b find:2 in:b.screens][@"inMirrorSet"] = @YES; [b.screens addObject:follower];
    t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    [b find:3 in:b.screens][@"mirrorOf"] = @1; [b find:3 in:b.screens][@"inMirrorSet"] = @YES;
    [b find:1 in:b.screens][@"inMirrorSet"] = @YES;
    Check(Configure(t, s), @"unrelated existing mirror group survives new mirror repair");
    Check(![b.calls containsObject:@"mirror:4:0"], @"no unrelated unmirror");
    Check(![b.calls containsObject:@"origin:4:-2560:240"], @"follower origin must not be set because it unmirrors");
    Check([[b find:4 in:b.screens][@"mirrorOf"] unsignedIntValue] == 2, @"existing follower retained");
    Check([t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL] == NO, @"restore waits for owned removal and fails if not gone");
    b.waits = 0; b.delayRemovalID = 3;
    Check([t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL], @"asynchronous removal then full restore verified");

    for (NSUInteger kind = 0; kind < 5; kind++) {
        b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
        if (kind == 0) b.failOrigin = YES;
        if (kind == 1) { b.failMirror = YES; [b find:3 in:b.screens][@"mirrorOf"] = @1;
            [b find:3 in:b.screens][@"inMirrorSet"] = @YES; [b find:1 in:b.screens][@"inMirrorSet"] = @YES; }
        if (kind == 2) { b.failMode = YES; [b find:1 in:b.screens][@"pixelWidth"] = @1280; }
        if (kind == 3) b.failCommit = YES;
        if (kind == 4) b.generationDuringStage = YES;
        Check(!Configure(t, s), @"transaction error must not grant admission");
        Check(b.cancels == 1, @"every uncommitted configuration is cancelled");
        Check(b.staged == nil, @"no retained transaction after failure");
    }

    for (NSUInteger mutation = 0; mutation < 5; mutation++) {
        b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
        if (mutation == 0) [b.screens addObject:Screen(9, 6000, 0, NO, 800, 600, NO)];
        if (mutation == 1) [b find:1 in:b.screens][@"identity"] = @"replacement";
        if (mutation == 2) [b find:1 in:b.screens][@"displayID"] = @5;
        if (mutation == 3) [b find:1 in:b.screens][@"rotation"] = @90;
        if (mutation == 4) { [b find:2 in:b.screens][@"mirrorOf"] = @1;
            [b find:2 in:b.screens][@"inMirrorSet"] = @YES; [b find:1 in:b.screens][@"inMirrorSet"] = @YES; }
        Check(!Configure(t, s), @"foreign topology change fails closed");
        Check(b.commits == 0 && b.calls.count == 0, @"foreign topology change never starts configuration");
    }

    for (NSUInteger kind = 0; kind < 3; kind++) {
        b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
        if (kind == 0) b.modeMutationAfterCommit = YES;
        if (kind == 1) b.foreignAfterCommit = YES;
        if (kind == 2) b.suppressCommit = YES;
        Check(!Configure(t, s), @"commit success alone does not prove final layout/mode");
    }

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    [b find:1 in:b.screens][@"pixelWidth"] = @2560; [b find:1 in:b.screens][@"refreshRate"] = @30;
    Check(Configure(t, s), @"restore original scale and refresh when creation changed mode");
    Check([b.calls containsObject:@"mode:1"], @"retained original mode passed to backend");
    Check([[b find:1 in:b.screens][@"pixelWidth"] integerValue] == 5120, @"original physical mode restored");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    [b find:3 in:b.screens][@"pixelWidth"] = @960; b.rejectMode = YES;
    Check(!Configure(t, s) && b.calls.count == 0, @"unsupported new mode fails before transaction");
    b.rejectMode = NO;
    Check(Configure(t, s), @"available intended virtual mode repaired before admission");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    b.delayedReconfiguration = YES;
    Check(!Configure(t, s), @"cached good samples preceding late mode change cannot admit");
    Check(b.switched, @"late reconfiguration was observed");
    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    b.delayedThenStable = YES;
    Check(Configure(t, s), @"late change that settles to complete intended state can admit");
    Check(b.waits >= 13, @"settle counter restarts after generation and state change");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t);
    [b find:1 in:b.screens][@"modeWidth"] = @1280; [b find:1 in:b.screens][@"logicalWidth"] = @1280;
    b.failMode = YES;
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:0 error:NULL], @"unsupported original mode restore reports failure");
    Check(b.cancels == 1, @"restore error cancels staged transaction");
    b.failMode = NO;
    Check([t restoreAndVerifySnapshot:s excludingDisplayID:0 error:NULL], @"recovery can be verified after supported mode returns");
    Check([t verifySnapshot:s error:NULL], @"read-only final baseline verification");
    [b find:1 in:b.screens][@"pixelHeight"] = @720;
    Check(![t verifySnapshot:s error:NULL], @"same origin/main with different scale is not recovery");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t);
    [b.screens addObject:Screen(9, 6000, 0, NO, 800, 600, NO)];
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:0 error:NULL] && b.calls.count == 0, @"recovery never writes with foreign device present");
    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b];
    [b find:1 in:b.screens][@"identity"] = @"";
    Check([t captureSnapshotWithError:NULL] == nil, @"missing identity fails safe before creation");
    // Creation refusal followed by rollback must not undo the unrelated edit.
    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    [b find:2 in:b.screens][@"mirrorOf"] = @1;
    [b find:2 in:b.screens][@"inMirrorSet"] = @YES; [b find:1 in:b.screens][@"inMirrorSet"] = @YES;
    Check(!Configure(t, s), @"foreign mirror edit refuses creation");
    [b.screens removeObject:[b find:3 in:b.screens]];
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL], @"rollback cannot undo refused mirror edit");
    Check(b.calls.count == 0 && [[b find:2 in:b.screens][@"mirrorOf"] unsignedIntValue] == 1,
        @"foreign mirror relationship stays intact during rollback");
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL] && b.calls.count == 0,
        @"manual retry cannot use a stale baseline to override user intent");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    b.foreignEditDuringStage = YES;
    Check(!Configure(t, s) && b.commits == 0 && b.cancels == 1,
        @"precommit read catches foreign state even before callback delivery");
    [b.screens removeObject:[b find:3 in:b.screens]];
    NSUInteger callsAfterRefusal = b.calls.count;
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL] && b.calls.count == callsAfterRefusal,
        @"precommit race latches recovery read-only");
    [b find:2 in:b.screens][@"x"] = @-2560;
    Check([t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL] && b.calls.count == callsAfterRefusal,
        @"manual correction can be verified without a write");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t);
    [b.screens addObject:Screen(9, 6000, 0, NO, 800, 600, NO)];
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:0 error:NULL], @"restore-only foreign device latches refusal");
    [b.screens removeObject:[b find:9 in:b.screens]]; [b find:2 in:b.screens][@"x"] = @-2400;
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:0 error:NULL] && b.calls.count == 0,
        @"device departure does not make stale recovery writable again");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    b.failOrigin = YES; Check(!Configure(t, s), @"prepare failed creation identity capture");
    [b find:3 in:b.screens][@"identity"] = @"foreign-device-reusing-id";
    NSUInteger callsBeforeReuse = b.calls.count;
    Check(![t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL] && b.calls.count == callsBeforeReuse,
        @"removal ID reuse never targets the replacement device");

    b = [FakeBackend new];
    follower = Screen(4, -2560, 240, NO, 2560, 1440, YES);
    follower[@"mirrorOf"] = @2; follower[@"inMirrorSet"] = @YES; follower[@"active"] = @NO;
    for (NSString *key in @[@"modeToken", @"modeWidth", @"modeHeight", @"pixelWidth", @"pixelHeight", @"refreshRate", @"modeID", @"modeFlags", @"modeUsableForDesktopGUI"])
        [follower removeObjectForKey:key];
    [b find:2 in:b.screens][@"inMirrorSet"] = @YES; [b.screens addObject:follower];
    t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    Check(Configure(t, s), @"unrelated inactive hardware mirror without a mode can be preserved");
    Check(![b.calls containsObject:@"mode:4"], @"unknown inactive mirror mode is not guessed");
    [b find:3 in:b.screens][@"rotation"] = @90;
    Check(![t isExtendedTarget:3 width:1920 height:1080 hiDPI:NO], @"rotated target fails live admission");

    b = [FakeBackend new]; AddNew(b); t = [[YMDisplayTopology alloc] initWithBackend:b];
    YMDisplayTopologySnapshot *closeSnapshot = [Baseline(t) snapshotByExcludingDisplayID:3];
    [b find:3 in:b.screens][@"identity"] = @"replacement-during-normal-close";
    Check(![t restoreAndVerifySnapshot:closeSnapshot excludingDisplayID:3 error:NULL] && b.calls.count == 0,
        @"normal close exclusion retains removed display identity");
    [b.screens removeObject:[b find:3 in:b.screens]]; [b find:2 in:b.screens][@"x"] = @-2400;
    Check(![t restoreAndVerifySnapshot:closeSnapshot excludingDisplayID:3 error:NULL] && b.calls.count == 0,
        @"normal close ID reuse latches retries read-only");

    for (NSUInteger otherFollowers = 0; otherFollowers < 2; otherFollowers++) {
        b = [FakeBackend new]; AddNew(b);
        [b find:3 in:b.screens][@"mirrorOf"] = @1; [b find:3 in:b.screens][@"inMirrorSet"] = @YES;
        [b find:3 in:b.screens][@"active"] = @NO; [b find:1 in:b.screens][@"inMirrorSet"] = @YES;
        if (otherFollowers) {
            follower = Screen(4, 0, 0, NO, 2560, 1440, YES);
            follower[@"mirrorOf"] = @1; follower[@"inMirrorSet"] = @YES; follower[@"active"] = @NO;
            [b.screens addObject:follower];
        }
        t = [[YMDisplayTopology alloc] initWithBackend:b];
        closeSnapshot = [Baseline(t) snapshotByExcludingDisplayID:3];
        [b.screens removeObject:[b find:3 in:b.screens]];
        [b find:1 in:b.screens][@"inMirrorSet"] = @(otherFollowers != 0);
        Check([t restoreAndVerifySnapshot:closeSnapshot excludingDisplayID:3 error:NULL],
            @"closing a mirror follower derives the surviving master's membership correctly");
        Check(b.calls.count == 0, @"closing a mirror follower does not reconfigure an unchanged surviving group");
    }

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b];
    b.missingModeID = 1; b.modeMissingReads = 3;
    s = Baseline(t);
    Check(b.calls.count == 0 && b.waits >= 3, @"capture waits for actual mode without a write");
    AddNew(b); b.missingModeID = 3; b.modeMissingReads = 4;
    Check(Configure(t, s), @"creation waits for process-local mode cache to refresh");
    Check([t isExtendedTarget:3 width:1920 height:1080 hiDPI:NO], @"complete mode evidence permits admission");

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    b.missingModeID = 3; b.modeMissingReads = 999;
    NSUInteger beforeWait = b.waits;
    NSError *modeFailure = nil;
    Check(![t configureAndVerifyNewDisplay:3 width:1920 height:1080 hiDPI:NO baseline:s error:&modeFailure]
        && modeFailure.code == 4 && b.calls.count == 0, @"missing mode never grants admission or triggers a write");
    Check(b.waits - beforeWait == 50, @"mode-cache waiting is bounded to five seconds per operation");
    [b.screens removeObject:[b find:3 in:b.screens]]; b.modeMissingReads = 0;
    [b find:1 in:b.screens][@"pixelWidth"] = @2560;
    Check([t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL],
        @"missing owned mode alone does not block guarded restoration after removal");
    Check([b.calls containsObject:@"mode:1"], @"known original mode can be restored after unavailable new mode");

    for (NSUInteger change = 0; change < 2; change++) {
        b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
        b.missingModeID = 3; b.modeMissingReads = 10;
        b.foreignWhileModeMissing = change == 0; b.mirrorEditWhileModeMissing = change == 1;
        Check(!Configure(t, s) && b.calls.count == 0, @"partial inventories preserve foreign identity and mirror guards");
        [b.screens removeObject:[b find:3 in:b.screens]]; b.modeMissingReads = 0;
        Check(![t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL] && b.calls.count == 0,
            @"foreign changes during mode waiting permanently inhibit recovery writes");
    }

    b = [FakeBackend new]; t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t); AddNew(b);
    b.missingModeID = 3; b.modeMissingAfterCommit = 3;
    Check(Configure(t, s), @"post-commit verification tolerates transient mode cache unavailability");
    [b.screens removeObject:[b find:3 in:b.screens]];
    b.missingModeID = 1; b.modeMissingReads = 3;
    Check([t restoreAndVerifySnapshot:s excludingDisplayID:3 error:NULL], @"recovery waits for current original modes before any decision");
    b.modeMissingReads = 3;
    Check([t verifySnapshot:s error:NULL], @"read-only verification also waits for a complete mode inventory");

    // Update restart restores only owned output origins; all other state is pinned.
    b = [FakeBackend new]; AddNew(b); t = [[YMDisplayTopology alloc] initWithBackend:b]; s = Baseline(t);
    NSArray *physicalBefore = @[[b find:1 in:b.screens].copy, [b find:2 in:b.screens].copy];
    Check([t positionOwnedDisplays:@{@3:@{@"x":@2560,@"y":@176}} baseline:s error:NULL], @"restart can restore an owned origin");
    Check([[b find:3 in:b.screens][@"x"] isEqual:@2560] && [[b find:3 in:b.screens][@"y"] isEqual:@176], @"saved virtual origin restored exactly");
    Check([[b find:1 in:b.screens] isEqual:physicalBefore[0]] && [[b find:2 in:b.screens] isEqual:physicalBefore[1]], @"restart positioning preserves both physical screens exactly");
    s = Baseline(t); [b.calls removeAllObjects];
    Check(![t positionOwnedDisplays:@{@1:@{@"x":@20,@"y":@0}} baseline:s error:NULL] && b.calls.count == 0, @"restart cannot reposition main screen");
    Check(![t positionOwnedDisplays:@{@99:@{@"x":@20,@"y":@0}} baseline:s error:NULL] && b.calls.count == 0, @"unknown owned identity refused without writes");
    Check(![t positionOwnedDisplays:@{@3:@{@"x":@2.5,@"y":@0}} baseline:s error:NULL] && b.calls.count == 0, @"fractional saved origin refused");
    [b find:2 in:b.screens][@"y"] = @333;
    Check(![t positionOwnedDisplays:@{@3:@{@"x":@2560,@"y":@0}} baseline:s error:NULL] && b.calls.count == 0, @"concurrent physical edit preserved without writes");

    printf("Display topology: %lu checks passed (synthetic backend; no live display changes).\n", (unsigned long)checks);
}
int main(void) { @autoreleasepool {
    NSString *regression=NSProcessInfo.processInfo.environment[@"YOMADO_TOPOLOGY_REGRESSION"];
    if ([regression isEqual:@"equivalent-mode"]) RunEquivalentModeRegressions();
    else if ([regression isEqual:@"mode-safety"]) RunModeSafetyRegressions();
    else if ([regression isEqual:@"mode-diagnostics"]) RunModeDiagnosticRegressions();
    else { RunEquivalentModeRegressions(); RunModeSafetyRegressions(); RunModeDiagnosticRegressions(); RunTests(); }
    if (regression) printf("Display topology regression %s: %lu checks passed (synthetic backend).\n",regression.UTF8String,(unsigned long)checks);
} return 0; }
