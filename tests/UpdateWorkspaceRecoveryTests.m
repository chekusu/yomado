#import <Foundation/Foundation.h>
#import "UpdateWorkspaceRecovery.h"
#import "AppWorkspacePolicy.h"
#import <sys/stat.h>
#import <unistd.h>

extern BOOL YMUpdateIsVerifiedMenuCursorChrome(NSDictionary *candidate, NSDictionary *displayBounds,
    double topInset, NSInteger mainMenuLevel, NSDictionary *systemMenu, NSInteger cursorLevel);
extern BOOL YMUpdateIsPointerSurface(NSDictionary *candidate, NSInteger cursorLevel, BOOL windowServer);

static NSUInteger checks=0;
static void Check(BOOL value, NSString *name) { checks++; if (!value) { fprintf(stderr,"FAIL %s\n",name.UTF8String); exit(1); } }
static NSDictionary *Frame(double x,double y,double w,double h) { return @{@"x":@(x),@"y":@(y),@"width":@(w),@"height":@(h)}; }
static NSDictionary *Display(unsigned ID,NSString *uuid,BOOL main,double x,double width,double height) {
    return @{@"displayID":@(ID),@"identity":uuid,@"main":@(main),@"active":@YES,@"rotation":@0,@"mirrorOf":@0,@"inMirrorSet":@NO,
        @"bounds":Frame(x,0,width,height),@"mode":@{@"width":@(width),@"height":@(height),@"pixelWidth":@(width),@"pixelHeight":@(height),@"refresh":@60,@"flags":@1,@"desktopUsable":@YES}};
}
static NSDictionary *Identity(unsigned ID) { return @{@"pid":@400,@"windowID":@(ID),@"startSeconds":@1000,@"startMicroseconds":@4,@"bundleID":@"test.fixture"}; }
static NSArray *Profiles(unsigned ID) { return @[@{@"ordinal":@1,@"displayID":@(ID),@"width":@1920,@"height":@1080,@"hiDPI":@NO}]; }
static NSError *Error(void) { return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Fixture failure"}]; }
@interface FakeRecovery : NSObject <YMUpdateWorkspaceRecoveryBackend>
@property NSMutableArray *displays;
@property NSMutableDictionary *windows;
@property NSString *version;
@property NSString *build;
@property NSString *boot;
@property NSTimeInterval time;
@property NSUInteger writes;
@property BOOL failRead;
@property BOOL failCapture;
@property NSUInteger failMoveNumber;
@property NSUInteger readCalls;
@property NSUInteger failReadNumber;
@property NSError *readFailure;
@property NSDictionary *readFailureResult;
@property void (^onCapture)(void);
@end
@implementation FakeRecovery
- (instancetype)init { self=[super init]; if (self) {
    _version=@"1.0";_build=@"10";_boot=@"same-boot";_time=10000;
    _displays=[@[Display(1,@"physical",YES,0,1280,900),Display(2,@"owned",NO,1280,1920,1080)] mutableCopy];
    _windows=[NSMutableDictionary dictionary];
    for (NSNumber *ID in @[@42,@43,@44]) _windows[ID]=[@{@"identity":Identity(ID.unsignedIntValue),@"displayID":ID.intValue==44 ? @1:@2,
        @"frame":Frame(ID.intValue==44 ? 50:1400,(ID.intValue-41)*100,500,300)} mutableCopy];
} return self; }
- (NSDictionary *)captureWithProfiles:(NSArray<NSDictionary *> *)profiles error:(NSError **)error {
    if (self.onCapture) self.onCapture();
    if (self.failCapture) { if(error)*error=Error(); return nil; }
    NSSet *owned=[NSSet setWithArray:[profiles valueForKey:@"displayID"]]; NSMutableArray *windows=[NSMutableArray array];
    for (NSDictionary *w in self.windows.allValues) if ([owned containsObject:w[@"displayID"]]) [windows addObject:w.copy];
    return @{@"displays":self.displays.copy,@"windows":windows.copy,@"privatePath":@"PRIVATE_CANARY_DO_NOT_PERSIST"};
}
- (NSDictionary *)readWindow:(NSDictionary *)identity error:(NSError **)error {
    self.readCalls++;
    if (self.failReadNumber && self.readCalls==self.failReadNumber) {
        if (error) *error=self.readFailure;
        return self.readFailureResult;
    }
    NSDictionary *w=self.windows[identity[@"windowID"]];
    if (self.failRead || ![w[@"identity"] isEqual:identity]) { if(error)*error=Error(); return nil; }
    return @{@"identity":w[@"identity"],@"frame":w[@"frame"]};
}
- (BOOL)moveWindow:(NSDictionary *)identity fromFrame:(NSDictionary *)before toFrame:(NSDictionary *)after error:(NSError **)error {
    NSMutableDictionary *w=self.windows[identity[@"windowID"]];
    if (![w[@"identity"] isEqual:identity] || ![w[@"frame"] isEqual:before] || (self.failMoveNumber && self.writes+1==self.failMoveNumber)) { if(error)*error=Error(); return NO; }
    self.writes++;w[@"frame"]=after;
    for (NSDictionary *d in self.displays) if ([after[@"x"] doubleValue]>=[d[@"bounds"][@"x"] doubleValue]) w[@"displayID"]=d[@"displayID"];
    return YES;
}
- (NSTimeInterval)now { return self.time; }
- (NSString *)bootSessionIdentifier { return self.boot; }
- (NSString *)runningVersion { return self.version; }
- (NSString *)runningBuild { return self.build; }
@end
static NSURL *Directory(void) {
    NSString *root=@"/private/tmp";
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:[@"yomado-recovery-test-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
}
static YMUpdateWorkspaceRecovery *Recovery(NSURL *dir,FakeRecovery *backend) { return [[YMUpdateWorkspaceRecovery alloc] initWithDirectoryURL:dir backend:backend]; }
static BOOL Prepare(YMUpdateWorkspaceRecovery *r,NSError **error) {
    BOOL okay = [r prepareRestartWithProfiles:Profiles(2) targetVersion:@"1.1" targetBuild:@"11"
        originCheckpoints:@[@{@"identity":Identity(42),@"origin":@{@"displayUUID":@"physical",@"relative":Frame(50,50,500,300)}}] error:error];
    return okay;
}
static void Restart(FakeRecovery *b) {
    b.version=@"1.1";b.build=@"11";[b.displays removeLastObject];
    for (NSNumber *ID in @[@42,@43]) { b.windows[ID][@"displayID"]=@1;b.windows[ID][@"frame"]=Frame(30,30,500,300); }
}
static void Create(FakeRecovery *b) { [b.displays addObject:Display(9,@"new-owned",NO,1280,1920,1080)]; }
static void Cleanup(NSURL *dir) { [NSFileManager.defaultManager removeItemAtURL:dir error:NULL]; }
static void MainRoundtrip(void) {
    NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
    Check(Prepare(r,&e),@"prepare occupied exact windows");Check(b.writes==0,@"prepare read-only");
    struct stat s;Check(stat(dir.fileSystemRepresentation,&s)==0 && (s.st_mode&0777)==0700,@"private directory");
    NSURL *file=[dir URLByAppendingPathComponent:@"restart.json"];
    Check(stat(file.fileSystemRepresentation,&s)==0 && (s.st_mode&0777)==0600,@"private journal");
    NSString *text=[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL];
    Check(![text containsString:@"PRIVATE_CANARY"] && ![text containsString:@"privatePath"],@"allowlist strips unrelated metadata");
    Check([r commitPreparedRestart:&e],@"arm final stable checkpoint");Restart(b);
    YMUpdateWorkspaceRecovery *next=Recovery(dir,b);NSArray *pending=[next pendingProfilesWithError:&e];
    Check(pending.count==1 && [pending[0][@"bounds"] isEqual:Frame(1280,0,1920,1080)],@"claim exact target once");
    Check([next verifyRestorationEnvironmentWithProfiles:@[] error:&e],@"precreate physical gate");
    YMUpdateWorkspaceRecovery *other=Recovery(dir,b);e=nil;
    Check(![other pendingProfilesWithError:&e] && e!=nil,@"no automatic second claim");
    Create(b);NSDictionary *physical=[b.windows[@44] copy];
    Check([next restoreWithProfiles:Profiles(9) error:&e],@"restore recreated display ID");
    Check(b.writes==2 && [b.windows[@44] isEqual:physical],@"only two exact owned windows moved");
    Check(next.restoredOriginCheckpoints.count==1,@"origin ownership handoff available");
    Check([NSFileManager.defaultManager fileExistsAtPath:file.path],@"journal retained until origin adoption");
    Check([next completeRestoration:&e],@"explicit completion");Check(![NSFileManager.defaultManager fileExistsAtPath:file.path],@"consume after verified completion");Cleanup(dir);
}
static void FinalGateChanges(void) {
    for (NSUInteger scenario=0;scenario<6;scenario++) {
        NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
        Check(Prepare(r,&e),@"final gate setup");
        if(scenario==0)b.windows[@42][@"frame"]=Frame(1500,100,500,300);
        if(scenario==1)[b.windows removeObjectForKey:@42];
        if(scenario==2)b.windows[@45]=[@{@"identity":Identity(45),@"displayID":@2,@"frame":Frame(1700,100,500,300)} mutableCopy];
        if(scenario==3){NSMutableDictionary *d=[b.displays[0] mutableCopy];d[@"rotation"]=@90;b.displays[0]=d;}
        if(scenario==4){NSMutableDictionary *identity=[Identity(42) mutableCopy];identity[@"startMicroseconds"]=@9;b.windows[@42][@"identity"]=identity;}
        if(scenario==5)[b.displays addObject:Display(3,@"foreign",NO,3200,1024,768)];
        Check(![r commitPreparedRestart:&e] && b.writes==0,@"final gate refuses changed state");
        Check([r cancelPreparedRestart:&e],@"safe cancellation permits new prepare");Cleanup(dir);
    }
}
static void StartupAndRestoreGates(void) {
    for(NSUInteger scenario=0;scenario<12;scenario++) {
        NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
        Check(Prepare(r,&e) && [r commitPreparedRestart:&e],@"gate setup");Restart(b);
        if(scenario==0)b.build=@"12";
        if(scenario==1)b.boot=@"new-boot";
        if(scenario==2)b.time+=301;
        if(scenario==3){NSMutableDictionary *d=[b.displays[0] mutableCopy];d[@"bounds"]=Frame(10,0,1280,900);b.displays[0]=d;}
        if(scenario==4)[b.displays addObject:Display(4,@"foreign",NO,3200,1024,768)];
        YMUpdateWorkspaceRecovery *next=Recovery(dir,b);
        NSArray *pending=[next pendingProfilesWithError:&e];
        if(scenario<5) {
            Check(!pending && e && !b.writes,@"startup rejects mismatch before any creation");
            e=nil;Check([next discardRecoveryAfterUserRequest:&e],@"explicit discard accepts validated expired checkpoint");Cleanup(dir);continue;
        }
        Check(pending.count==1,@"valid startup");Create(b);
        if(scenario==5)[b.windows removeObjectForKey:@42];
        if(scenario==6){NSMutableDictionary *i=[Identity(42) mutableCopy];i[@"startSeconds"]=@2000;b.windows[@42][@"identity"]=i;}
        if(scenario==7){NSMutableDictionary *d=[b.displays[1] mutableCopy];d[@"bounds"]=Frame(1400,0,1920,1080);b.displays[1]=d;}
        if(scenario==8){NSMutableDictionary *d=[b.displays[1] mutableCopy];d[@"mirrorOf"]=@1;d[@"inMirrorSet"]=@YES;b.displays[1]=d;}
        if(scenario==9){NSMutableDictionary *d=[b.displays[1] mutableCopy];NSMutableDictionary *mode=[d[@"mode"] mutableCopy];mode[@"pixelWidth"]=@3840;d[@"mode"]=mode;b.displays[1]=d;}
        if(scenario==10){NSMutableDictionary *d=[b.displays[0] mutableCopy];d[@"identity"]=@"replacement";b.displays[0]=d;}
        if(scenario==11)b.failRead=YES;
        Check(![next restoreWithProfiles:Profiles(9) error:&e] && b.writes==0,@"restore gates before first move");
        Check([NSFileManager.defaultManager fileExistsAtPath:[dir URLByAppendingPathComponent:@"restart.json"].path],@"failure retains checkpoint");Cleanup(dir);
    }
}
static void ReadFailureDiagnostics(void) {
    for (NSUInteger stage=0;stage<3;stage++) for (NSUInteger failure=0;failure<5;failure++) {
        NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *source=Recovery(dir,b);NSError *e=nil;
        Check(Prepare(source,&e)&&[source commitPreparedRestart:&e],@"read diagnostics setup");Restart(b);
        YMUpdateWorkspaceRecovery *next=Recovery(dir,b);Check([next pendingProfilesWithError:&e]!=nil,@"read diagnostics claim");Create(b);
        if (stage==2) Check([next restoreWithProfiles:Profiles(9) error:&e],@"read diagnostics restored before handoff");
        b.failReadNumber=b.readCalls+(stage==1 ? 3:1);
        if (failure<2) b.readFailure=[NSError errorWithDomain:YMUpdateWorkspaceRecoveryErrorDomain code:failure+1
            userInfo:@{NSLocalizedDescriptionKey:failure==0 ? @"Window control permission is unavailable.":@"Saved application identity changed."}];
        if (failure==3) b.readFailureResult=@{@"identity":Identity(999),@"frame":Frame(1400,100,500,300)};
        if (failure==4) b.readFailureResult=@{@"identity":Identity(42),@"frame":@{}};
        e=Error();
        BOOL result=stage==2 ? [next completeRestoration:&e]:[next restoreWithProfiles:Profiles(9) error:&e];
        Check(!result,@"read failure cannot complete restoration");
        Check(failure<2 ? e==b.readFailure : [e.domain isEqual:YMUpdateWorkspaceRecoveryErrorDomain]&&e.code==34,
            @"native read errors survive; absent error and malformed observations retain generic mismatch diagnostics");
        Check(b.writes==(stage==0 ? 0:2),@"read failures never trigger extra movement or retries");
        Check([NSFileManager.defaultManager fileExistsAtPath:[dir URLByAppendingPathComponent:@"restart.json"].path],
            @"all read failures retain the recovery checkpoint");Cleanup(dir);
    }
}
static void RetryAndPrivacy(void) {
    NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
    Check(Prepare(r,&e)&&[r commitPreparedRestart:&e],@"retry setup");Restart(b);
    YMUpdateWorkspaceRecovery *next=Recovery(dir,b);Check([next pendingProfilesWithError:&e]!=nil,@"retry claim");Create(b);b.failMoveNumber=2;
    Check(![next restoreWithProfiles:Profiles(9) error:&e] && b.writes==1,@"partial failure retains exact completed move");
    Check(![next cancelPreparedRestart:&e],@"claimed checkpoint cannot cancel accidentally");
    b.failMoveNumber=0;Check([next restoreWithProfiles:Profiles(9) error:&e] && b.writes==2,@"explicit controller retry moves remaining exact window");
    Check([next completeRestoration:&e],@"retry complete");Cleanup(dir);
    for(NSUInteger kind=0;kind<5;kind++) {
        dir=Directory();b=[FakeRecovery new];r=Recovery(dir,b);e=nil;
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        NSString *path=[dir URLByAppendingPathComponent:@"restart.json"].path;
        if(kind==0)symlink("/dev/null",path.fileSystemRepresentation);
        if(kind==1){[@"{}" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];chmod(path.fileSystemRepresentation,0644);}
        if(kind==2)chmod(dir.fileSystemRepresentation,0755);
        if(kind==3){NSMutableData *data=[NSMutableData dataWithLength:1024*1024+1];[data writeToFile:path atomically:NO];chmod(path.fileSystemRepresentation,0600);}
        if(kind==4){[@"{}" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];chmod(path.fileSystemRepresentation,0600);}
        Check(!Prepare(r,&e) && e && b.writes==0,@"unsafe existing record rejected without mutation");
        e=nil;Check(![r discardRecoveryAfterUserRequest:&e] && e,@"discard cannot delete invalid/unsafe record");Cleanup(dir);
    }
}
static void EmptyAndPartial(void) {
    NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];[b.windows removeObjectForKey:@42];[b.windows removeObjectForKey:@43];b.failRead=YES;
    YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
    Check([r prepareRestartWithProfiles:Profiles(2) targetVersion:@"1.1" targetBuild:@"11" originCheckpoints:@[] error:&e],@"empty workspace no window access");
    Check([r commitPreparedRestart:&e],@"empty commit");Restart(b);YMUpdateWorkspaceRecovery *next=Recovery(dir,b);
    Check([next pendingProfilesWithError:&e]!=nil,@"empty startup");Create(b);
    NSMutableDictionary *d=[b.displays[1] mutableCopy];d[@"bounds"]=Frame(1800,0,1920,1080);b.displays[1]=d;
    Check([next verifyRestorationEnvironmentWithProfiles:Profiles(9) error:&e],@"partial mode gate permits not-yet-restored origin");
    Check(![next restoreWithProfiles:Profiles(9) error:&e],@"final gate requires saved origin");
    b.displays[1]=Display(9,@"new-owned",NO,1280,1920,1080);
    Check([next restoreWithProfiles:Profiles(9) error:&e] && [next completeRestoration:&e],@"empty restore");Cleanup(dir);
}
static void GeometryAndOriginSelection(void) {
    NSArray *owned=@[@{@"displayID":@2,@"bounds":Frame(1280,0,1920,1080)}];
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(50,50,500,300),owned)==YMUpdateWindowOutsideOwned,@"fully physical window excluded");
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(1400,50,500,300),owned)==YMUpdateWindowContainedInOwned,@"fully virtual window saved");
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(1000,50,500,300),owned)==YMUpdateWindowCrossesOwnedBoundary,@"physical-majority overlap blocks update");
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(1200,50,500,300),owned)==YMUpdateWindowCrossesOwnedBoundary,@"virtual-majority overlap blocks update");
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(780,50,500,300),owned)==YMUpdateWindowOutsideOwned,@"touching edge is not overlap");
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(1280,0,1920,1080),owned)==YMUpdateWindowContainedInOwned,@"exact owned bounds");
    NSArray *pair=[owned arrayByAddingObject:@{@"displayID":@3,@"bounds":Frame(3200,0,1920,1080)}];
    Check(YMUpdateWindowRelationToOwnedDisplays(Frame(3000,50,500,300),pair)==YMUpdateWindowCrossesOwnedBoundary,@"spanning two owned blocks");
    Check(YMUpdateWindowRelationToOwnedDisplays(@{},owned)==YMUpdateWindowCrossesOwnedBoundary,@"unknown geometry fails closed");
    NSDictionary *current=@{@"pid":@400,@"windowID":@42,@"displayID":@2};
    Check([YMWorkspaceCheckpointWindow(400,42,@[current],@[@2]) isEqual:current],@"exact existing origin handed off");
    Check(!YMWorkspaceCheckpointWindow(400,41,@[current],@[@2]),@"closed ID origin not handed off");
    Check(!YMWorkspaceCheckpointWindow(399,42,@[current],@[@2]),@"another process origin not handed off");
    Check(!YMWorkspaceCheckpointWindow(400,42,@[@{@"pid":@400,@"windowID":@42,@"displayID":@1}],@[@2]),@"manual physical return origin excluded");
    Check(!YMWorkspaceCheckpointWindow(400,42,@[@{@"pid":@400,@"windowID":@43,@"displayID":@2}],@[@2]),@"replacement window does not inherit old origin");
    Check(!YMWorkspaceCheckpointWindow(400,42,@[current,current],@[@2]),@"ambiguous current observation not exported");
}
static void MalformedShapes(void) {
    for(NSUInteger kind=0;kind<9;kind++) {
        NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
        Check(Prepare(r,&e),@"malformed setup");NSURL *file=[dir URLByAppendingPathComponent:@"restart.json"];
        NSMutableDictionary *j=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] options:NSJSONReadingMutableContainers error:NULL];
        if(kind==0)j[@"transaction"]=@3;
        if(kind==1)j[@"state"][@"displays"][0]=@3;
        if(kind==2)j[@"state"][@"windows"][0]=@3;
        if(kind==3)j[@"origins"][0][@"origin"]=@3;
        if(kind==4)j[@"state"][@"windows"][0][@"identity"]=@3;
        if(kind==5)j[@"state"][@"displays"][0][@"mode"]=@3;
        if(kind==6)j[@"profiles"][0]=@3;
        if(kind==7)j[@"state"][@"displays"][0][@"bounds"]=@3;
        if(kind==8)j[@"state"][@"windows"][0][@"privatePath"]=@"PRIVATE_CANARY_DO_NOT_PERSIST";
        [[NSJSONSerialization dataWithJSONObject:j options:0 error:NULL] writeToURL:file atomically:NO];chmod(file.fileSystemRepresentation,0600);
        Restart(b);YMUpdateWorkspaceRecovery *next=Recovery(dir,b);e=nil;
        Check(![next pendingProfilesWithError:&e] && e,@"malformed journal returns error without exception");Cleanup(dir);
    }
}
static void LastMomentGuards(void) {
    for(NSUInteger kind=0;kind<5;kind++) {
        NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
        Check(Prepare(r,&e)&&[r commitPreparedRestart:&e],@"last moment setup");Restart(b);YMUpdateWorkspaceRecovery *next=Recovery(dir,b);
        Check([next pendingProfilesWithError:&e]!=nil,@"last moment claim");Create(b);
        Check([next verifyRestorationEnvironmentWithProfiles:Profiles(9) error:&e],@"record recreated identity");
        if(kind<2) {
            NSMutableDictionary *d=[b.displays[1] mutableCopy];
            if(kind==0)d[@"identity"]=@"reused-output-ID";
            if(kind==1){NSMutableDictionary *m=[d[@"mode"] mutableCopy];m[@"refresh"]=@75;d[@"mode"]=m;}
            b.displays[1]=d;
            Check(![next restoreWithProfiles:Profiles(9) error:&e] && b.writes==0,@"fresh owned identity and full mode guard");
        } else {
            Check([next restoreWithProfiles:Profiles(9) error:&e],@"restore before final handoff guard");
            if(kind==2)b.windows[@42][@"frame"]=Frame(1600,100,500,300);
            if(kind==3)[b.windows removeObjectForKey:@43];
            if(kind==4){NSMutableDictionary *d=[b.displays[0] mutableCopy];d[@"rotation"]=@90;b.displays[0]=d;}
            Check(![next completeRestoration:&e],@"completion checks handoff state again");
            Check([NSFileManager.defaultManager fileExistsAtPath:[dir URLByAppendingPathComponent:@"restart.json"].path],@"handoff failure retains journal");
        }
        Cleanup(dir);
    }
    NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];[b.displays removeLastObject];[b.windows removeAllObjects];
    YMUpdateWorkspaceRecovery *r=Recovery(dir,b);NSError *e=nil;
    Check([r prepareRestartWithProfiles:@[] targetVersion:@"1.1" targetBuild:@"11" originCheckpoints:@[] error:&e] && [r commitPreparedRestart:&e],@"zero owned screens update");
    b.version=@"1.1";b.build=@"11";YMUpdateWorkspaceRecovery *next=Recovery(dir,b);
    Check([next pendingProfilesWithError:&e].count==0 && e==nil,@"zero screen journal still claimed");
    Check([next restoreWithProfiles:@[] error:&e] && [next completeRestoration:&e],@"zero screen handoff complete");Cleanup(dir);
}
static void CancellationOwnership(void) {
    NSURL *dir=Directory();FakeRecovery *b=[FakeRecovery new];YMUpdateWorkspaceRecovery *source=Recovery(dir,b);NSError *e=nil;
    Check(Prepare(source,&e)&&[source commitPreparedRestart:&e],@"cancellation ownership setup");
    Restart(b);
    NSDictionary *physical=b.displays[0];NSMutableDictionary *changed=[physical mutableCopy];
    changed[@"bounds"]=Frame(10,0,1280,900);b.displays[0]=changed;
    YMUpdateWorkspaceRecovery *target=Recovery(dir,b);
    Check(![target pendingProfilesWithError:&e] && e.code==32,@"startup environment failure leaves unclaimed armed recovery");
    NSURL *file=[dir URLByAppendingPathComponent:@"restart.json"];
    NSData *retained=[NSData dataWithContentsOfURL:file];e=nil;
    Check(![target cancelPreparedRestart:&e] && e!=nil,@"startup reader cannot cancel a record it did not prepare");
    Check([[NSData dataWithContentsOfURL:file] isEqual:retained] && b.writes==0,@"failed claim cleanup preserves exact recovery record without window writes");
    b.displays[0]=physical;e=nil;
    Check([target retryPendingProfilesWithError:&e].count==1,@"corrected environment can explicitly retry retained checkpoint");
    Create(b);
    Check([target restoreWithProfiles:Profiles(9) error:&e] && [target completeRestoration:&e],@"retained checkpoint completes normally");
    Cleanup(dir);

    // Cancellation ownership belongs to the instance that prepared the update,
    // and does not impose startup's TTL on cleaning up its own stale proposal.
    for (NSUInteger armed=0;armed<2;armed++) {
        dir=Directory();b=[FakeRecovery new];source=Recovery(dir,b);e=nil;
        Check(Prepare(source,&e),@"source cancellation setup");
        if(armed)Check([source commitPreparedRestart:&e],@"source cancellation arms record");
        b.time+=301;
        Check([source cancelPreparedRestart:&e],@"source can cancel its own prepared or armed record after delay");
        Check(![NSFileManager.defaultManager fileExistsAtPath:[dir URLByAppendingPathComponent:@"restart.json"].path],@"source cancellation consumes only its own record");
        Check(Prepare(source,&e),@"source can prepare a later transaction after cancellation");
        Check([source cancelPreparedRestart:&e],@"later source transaction acquires cancellation ownership");Cleanup(dir);
    }
}
static void MenuChromeClassification(void) {
    NSDictionary *display=Frame(1024,0,1280,800), *band=Frame(1024,0,1280,30);
    NSDictionary *system=@{@"pid":@160,@"windowID":@107,@"frame":band,@"layer":@24,
        @"onscreen":@YES,@"trustedWindowServer":@YES};
    NSDictionary *candidate=@{@"pid":@400,@"windowID":@125,@"frame":band,@"layer":@0,@"onscreen":@NO};
    NSDictionary *ordinary=@{@"role":@"AXWindow",@"windowID":@91,@"frame":Frame(1124,120,460,312),
        @"safe":@YES,@"hasDialog":@NO};
    NSDictionary *owner=@{@"pid":@400,@"bundleID":@"test.fixture",@"menuRole":@"AXMenuBar",@"windows":@[ordinary]};
    Check(YMUpdateIsVerifiedMenuChrome(system,display,31,24,system,nil,nil),@"exact trusted system menu surface is non-document chrome");
    for (NSNumber *ID in @[@118,@119,@120,@125]) {
        NSMutableDictionary *copy=candidate.mutableCopy;copy[@"windowID"]=ID;
        Check(YMUpdateIsVerifiedMenuChrome(copy,display,31,24,system,owner,nil),@"observed duplicate hidden menu backings do not require nonexistent AX menu CG IDs");
    }
    NSMutableDictionary *copyOwner=owner.mutableCopy;copyOwner[@"menuFrame"]=band;
    Check(YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,copyOwner,nil),@"available exact AX menu geometry corroborates the exclusion");
    copyOwner=owner.mutableCopy;copyOwner[@"windows"]=@[];
    Check(YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,copyOwner,nil),@"app with no document windows can still own a menu backing");
    NSDictionary *desktop=@{@"role":@"AXScrollArea",@"windowID":@0,@"hasDialog":@NO};
    copyOwner=owner.mutableCopy;copyOwner[@"bundleID"]=@"com.apple.finder";copyOwner[@"windows"]=@[desktop];
    Check(YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,copyOwner,nil),@"Finder desktop AXScrollArea is not an unknown document window");
    for (NSUInteger scenario=0;scenario<29;scenario++) {
        NSMutableDictionary *c=candidate.mutableCopy,*s=system.mutableCopy,*o=owner.mutableCopy;
        NSMutableDictionary *w=ordinary.mutableCopy;NSDictionary *d=display;double inset=31;NSInteger level=24;
        switch (scenario) {
            case 0:c[@"onscreen"]=@YES;break;
            case 1:c[@"layer"]=@1;break;
            case 2:c[@"frame"]=Frame(1024,0,1100,30);break;
            case 3:c[@"frame"]=Frame(1024,5,1280,30);break;
            case 4:c[@"frame"]=Frame(1024,0,1280,60);break;
            case 5:s[@"trustedWindowServer"]=@NO;break;
            case 6:s[@"onscreen"]=@NO;break;
            case 7:s[@"layer"]=@25;break;
            case 8:s[@"frame"]=Frame(1024,3,1280,30);break;
            case 9:inset=0;break;
            case 10:inset=NAN;break;
            case 11:inset=300;break;
            case 12:d=Frame(0,0,1280,800);break;
            case 13:o[@"menuRole"]=@"AXWindow";break;
            case 14:o[@"windows"]=NSNull.null;break;
            case 15:o[@"pid"]=@401;break;
            case 16:o[@"menuFrame"]=Frame(1024,40,1280,30);break;
            case 17:o[@"menuFrame"]=@{};break;
            case 18:w[@"windowID"]=candidate[@"windowID"];o[@"windows"]=@[w];break;
            case 19:w[@"frame"]=band;o[@"windows"]=@[w];break;
            case 20:w[@"windowID"]=@0;o[@"windows"]=@[w];break;
            case 21:w[@"safe"]=@NO;o[@"windows"]=@[w];break;
            case 22:w[@"hasDialog"]=@YES;o[@"windows"]=@[w];break;
            case 23:[w removeObjectForKey:@"frame"];o[@"windows"]=@[w];break;
            case 24:o[@"windows"]=@[desktop];break;
            case 25:w=desktop.mutableCopy;w[@"windowID"]=@91;o[@"bundleID"]=@"com.apple.finder";o[@"windows"]=@[w];break;
            case 26:c[@"windowID"]=@0;break;
            case 27:s[@"pid"]=@0;break;
            case 28:level=25;break;
        }
        Check(!YMUpdateIsVerifiedMenuChrome(c,d,inset,level,s,o,nil),@"incomplete menu evidence or a real/unknown window keeps the update blocked");
    }
    Check(!YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,nil,nil),@"failed AX owner enumeration cannot exclude a hidden surface");
    copyOwner=owner.mutableCopy;copyOwner[@"windows"]=@[NSNull.null];
    Check(!YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,copyOwner,nil),@"malformed AX inventory fails closed");
    NSMutableDictionary *untrusted=system.mutableCopy;untrusted[@"trustedWindowServer"]=@NO;
    Check(!YMUpdateIsVerifiedMenuChrome(untrusted,display,31,24,untrusted,nil,nil),@"a menu-like process name or level alone is insufficient");

    NSDictionary *primaryBounds=Frame(0,0,1024,768), *primaryBand=Frame(0,0,1024,30);
    NSMutableDictionary *primaryMenu=system.mutableCopy;
    primaryMenu[@"windowID"]=@106;primaryMenu[@"frame"]=primaryBand;
    NSDictionary *primaryRegion=@{@"surface":primaryMenu.copy,@"bounds":primaryBounds,@"topInset":@31};
    copyOwner=owner.mutableCopy;copyOwner[@"menuFrame"]=primaryBand;
    Check(YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,copyOwner,@[primaryRegion]),
        @"primary AX menu frame corroborates a secondary display backing through its independently verified menu");
    Check(!YMUpdateIsVerifiedMenuChrome(candidate,display,31,24,system,copyOwner,@[]),
        @"an exposed frame on another display requires actual system-menu corroboration");
    for (NSUInteger scenario=0;scenario<14;scenario++) {
        NSMutableDictionary *region=primaryRegion.mutableCopy, *surface=primaryMenu.mutableCopy;
        NSMutableDictionary *o=copyOwner.mutableCopy, *c=candidate.mutableCopy, *w=ordinary.mutableCopy;
        id regions=nil;
        switch (scenario) {
            case 0:surface[@"trustedWindowServer"]=@NO;break;
            case 1:surface[@"onscreen"]=@NO;break;
            case 2:surface[@"layer"]=@25;break;
            case 3:surface[@"pid"]=@0;break;
            case 4:surface[@"windowID"]=@0;break;
            case 5:region[@"bounds"]=Frame(0,3,1024,768);break;
            case 6:region[@"topInset"]=@0;break;
            case 7:region[@"topInset"]=@"31";break;
            case 8:o[@"menuFrame"]=Frame(0,40,1024,30);break;
            case 9:c[@"frame"]=primaryBand;break;
            case 10:w[@"windowID"]=candidate[@"windowID"];o[@"windows"]=@[w];break;
            case 11:w[@"frame"]=band;o[@"windows"]=@[w];break;
            case 12:regions=@[NSNull.null];break;
            case 13:regions=NSNull.null;break;
        }
        region[@"surface"]=surface;
        Check(!YMUpdateIsVerifiedMenuChrome(c,display,31,24,system,o,regions ?: @[region]),
            @"other-screen corroboration cannot bypass trusted geometry or real-window protection");
    }
}
static void CursorMenuChromeClassification(void) {
    NSDictionary *display=Frame(1024,0,1280,800), *band=Frame(1024,0,1280,30);
    NSDictionary *menu=@{@"pid":@166,@"windowID":@106,@"frame":band,@"layer":@24,
        @"onscreen":@YES,@"trustedWindowServer":@YES};
    NSInteger cursorLevel=2147483630;
    NSDictionary *candidate=@{@"pid":@166,@"windowID":@133,@"frame":Frame(2129,1,28,28),
        @"layer":@(cursorLevel),@"onscreen":@YES};
    for (NSNumber *ID in @[@133,@134]) {
        NSMutableDictionary *copy=candidate.mutableCopy;copy[@"windowID"]=ID;
        Check(YMUpdateIsVerifiedMenuCursorChrome(copy,display,31,24,menu,cursorLevel),
            @"observed WindowServer cursor-level menu surfaces are not workspace windows");
    }
    for (NSDictionary *frame in @[Frame(1024,0,30,30),Frame(2274,0,30,30),Frame(2129,1,28,29)]) {
        NSMutableDictionary *copy=candidate.mutableCopy;copy[@"frame"]=frame;
        Check(YMUpdateIsVerifiedMenuCursorChrome(copy,display,31,24,menu,cursorLevel),
            @"exact boundaries and one-point aspect difference remain inside the actual menu");
    }
    for (NSUInteger scenario=0;scenario<27;scenario++) {
        NSMutableDictionary *c=candidate.mutableCopy,*m=menu.mutableCopy;NSDictionary *d=display;
        double inset=31;NSInteger menuLevel=24,level=cursorLevel;
        switch (scenario) {
            case 0:c[@"frame"]=Frame(1023.999,1,28,28);break;
            case 1:c[@"frame"]=Frame(2276.001,1,28,28);break;
            case 2:c[@"frame"]=Frame(2129,-.001,28,28);break;
            case 3:c[@"frame"]=Frame(2129,2.001,28,28);break;
            case 4:c[@"frame"]=Frame(2129,0,30.001,30);break;
            case 5:c[@"frame"]=Frame(2129,0,30,30.001);break;
            case 6:c[@"frame"]=Frame(2129,1,28,26.999);break;
            case 7:c[@"pid"]=@400;break;
            case 8:m[@"trustedWindowServer"]=@NO;break;
            case 9:c[@"layer"]=@(cursorLevel-1);break;
            case 10:c[@"layer"]=@(cursorLevel+1);break;
            case 11:c[@"layer"]=@0;break;
            case 12:c[@"onscreen"]=@NO;break;
            case 13:m=nil;break;
            case 14:m[@"onscreen"]=@NO;break;
            case 15:m[@"layer"]=@25;break;
            case 16:d=Frame(1024,4,1280,800);break;
            case 17:inset=0;break;
            case 18:c[@"frame"]=Frame(NAN,1,28,28);break;
            case 19:c[@"frame"]=Frame(2129,INFINITY,28,28);break;
            case 20:c[@"frame"]=Frame(2129,1,0,28);break;
            case 21:c[@"frame"]=Frame(2129,1,28,-1);break;
            case 22:c[@"windowID"]=@0;break;
            case 23:c[@"pid"]=@0;m[@"pid"]=@0;break;
            case 24:level=menuLevel;break;
            case 25:m[@"frame"]=Frame(1024,0,1200,30);break;
            case 26:c[@"frame"]=band;break;
        }
        Check(!YMUpdateIsVerifiedMenuCursorChrome(c,d,inset,menuLevel,m,level),
            @"unknown, application, oversized, or even slightly out-of-band surfaces remain blocked");
    }
}
static void PointerSurfaceClassification(void) {
    NSInteger cursorLevel=2147483630;
    // Observed in a Hayabuild VM: the pointer straddling the edge between the main display and an owned one.
    NSDictionary *pointer=@{@"pid":@163,@"windowID":@96,@"frame":Frame(1896,1,28,28),@"layer":@(cursorLevel),@"onscreen":@YES};
    Check(YMUpdateIsPointerSurface(pointer,cursorLevel,YES),@"the pointer across an owned display's edge is not a window");
    for (NSDictionary *frame in @[Frame(3176,1,28,28),Frame(0,0,64,64),Frame(10,10,32,33)]) {
        NSMutableDictionary *copy=pointer.mutableCopy;copy[@"frame"]=frame;
        Check(YMUpdateIsPointerSurface(copy,cursorLevel,YES),@"pointer-sized WindowServer cursor surfaces anywhere are ignored");
    }
    Check(!YMUpdateIsPointerSurface(pointer,cursorLevel,NO),@"an app's surface at the cursor level still blocks");
    for (NSDictionary *frame in @[Frame(1896,1,65,65),Frame(1896,1,28,40),Frame(1896,1,0,0)]) {
        NSMutableDictionary *copy=pointer.mutableCopy;copy[@"frame"]=frame;
        Check(!YMUpdateIsPointerSurface(copy,cursorLevel,YES),@"large, non-square or empty surfaces still block");
    }
    for (NSNumber *layer in @[@0,@24,@(cursorLevel-1),@(cursorLevel+1)]) {
        NSMutableDictionary *copy=pointer.mutableCopy;copy[@"layer"]=layer;
        Check(!YMUpdateIsPointerSurface(copy,cursorLevel,YES),@"only the exact cursor level is the pointer");
    }
    Check(!YMUpdateIsPointerSurface(pointer,0,YES),@"an unknown cursor level ignores nothing");
    Check(!YMUpdateIsPointerSurface((NSDictionary *)@[],cursorLevel,YES),@"malformed metadata is not the pointer");
}
int main(void) { @autoreleasepool { MainRoundtrip();FinalGateChanges();StartupAndRestoreGates();ReadFailureDiagnostics();RetryAndPrivacy();EmptyAndPartial();GeometryAndOriginSelection();MalformedShapes();LastMomentGuards();CancellationOwnership();MenuChromeClassification();CursorMenuChromeClassification();PointerSurfaceClassification();printf("UpdateWorkspaceRecovery: %lu checks passed\n",(unsigned long)checks); } return 0; }
