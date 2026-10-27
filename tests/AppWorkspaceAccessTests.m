#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
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

static NSDictionary *Frame(double x, double y, double w, double h) {
    return @{@"x": @(x), @"y": @(y), @"width": @(w), @"height": @(h)};
}

static NSDictionary *Identity(pid_t pid, CGWindowID windowID, uint64_t startSeconds) {
    return @{@"pid": @(pid), @"windowID": @(windowID), @"startSeconds": @(startSeconds),
             @"startMicroseconds": @7, @"bundleID": @"test.fixture.app"};
}

static id AXPoint(CGPoint point) {
    return CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point));
}

static id AXSize(CGSize size) {
    return CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &size));
}

@interface YMSystemWorkspaceWindowAccess (Testing)
- (id)copyWindowsForApplication:(NSRunningApplication *)application;
- (id)copyAttribute:(CFStringRef)attribute element:(id)element;
- (NSNumber *)isAttributeSettable:(CFStringRef)attribute element:(id)element;
- (NSDictionary *)identityForElement:(id)element;
- (BOOL)writeAttribute:(CFStringRef)attribute value:(id)value element:(id)element;
- (NSTimeInterval)monotonicTime;
- (nullable NSArray<NSDictionary *> *)whitelistedWindowsFromCGEntries:(NSArray *)raw;
@end

@interface YMAccessAppStub : NSObject
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, copy) NSString *bundleIdentifier;
@end
@implementation YMAccessAppStub
@end

@interface YMAccessFixture : YMSystemWorkspaceWindowAccess
@property(nonatomic, strong) YMAccessAppStub *application;
@property(nonatomic, strong) id element;
@property(nonatomic, strong) NSMutableArray<NSString *> *attributes;
@property(nonatomic) NSUInteger writeCount;
@property(nonatomic) NSUInteger windowCopyCount;
@property(nonatomic) NSTimeInterval clock;
@property(nonatomic) NSTimeInterval clockStep;
@property(nonatomic, strong) NSMutableArray *windowElements;
@property(nonatomic, strong) NSMutableDictionary *attributeValues;
@property(nonatomic, strong) NSMutableDictionary *settableValues;
@property(nonatomic, strong) NSMutableDictionary *identities;
@property(nonatomic) BOOL failWindowCopy;
@property(nonatomic) BOOL failAttribute;
@property(nonatomic, copy) NSString *failAttributeName;
@property(nonatomic) NSUInteger attributeFailAfter;
@property(nonatomic) NSUInteger attributeCalls;
@property(nonatomic) BOOL terminateAfterWindows;
@property(nonatomic, strong) NSMutableArray *visibleOverride;
@property(nonatomic, copy) void (^duringIdentity)(YMAccessFixture *fixture, id element);
@end

@implementation YMAccessFixture
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _attributes = [NSMutableArray array];
    _windowElements = [NSMutableArray array];
    _attributeValues = [NSMutableDictionary dictionary];
    _settableValues = [NSMutableDictionary dictionary];
    _identities = [NSMutableDictionary dictionary];
    _clock = 0;
    _clockStep = 0;
    _application = [YMAccessAppStub new];
    _application.processIdentifier = 4242;
    _application.bundleIdentifier = @"test.fixture.app";
    _element = [NSString stringWithFormat:@"window-%p", self];
    return self;
}

- (void)installOrdinaryWindow:(id)element identity:(NSDictionary *)identity frame:(NSDictionary *)frame {
    [self.windowElements addObject:element];
    NSString *key = [NSString stringWithFormat:@"%p", element];
    self.identities[key] = identity;
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[(__bridge NSString *)kAXRoleAttribute] = (__bridge NSString *)kAXWindowRole;
    attrs[(__bridge NSString *)kAXSubroleAttribute] = (__bridge NSString *)kAXStandardWindowSubrole;
    attrs[(__bridge NSString *)kAXMinimizedAttribute] = @NO;
    attrs[(__bridge NSString *)kAXPositionAttribute] =
        AXPoint(CGPointMake([frame[@"x"] doubleValue], [frame[@"y"] doubleValue]));
    attrs[(__bridge NSString *)kAXSizeAttribute] =
        AXSize(CGSizeMake([frame[@"width"] doubleValue], [frame[@"height"] doubleValue]));
    self.attributeValues[key] = attrs;
    self.settableValues[key] = [@{
        (__bridge NSString *)kAXPositionAttribute: @YES,
        (__bridge NSString *)kAXSizeAttribute: @YES
    } mutableCopy];
}

- (NSTimeInterval)monotonicTime {
    return self.clock;
}

- (id)copyWindowsForApplication:(NSRunningApplication *)application {
    (void)application;
    self.windowCopyCount++;
    if (self.failWindowCopy) return nil;
    if (self.terminateAfterWindows) self.application.terminated = YES;
    self.clock += self.clockStep;
    return self.windowElements.copy;
}

- (id)copyAttribute:(CFStringRef)attribute element:(id)element {
    NSString *name = (__bridge NSString *)attribute;
    [self.attributes addObject:name];
    static NSSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSSet setWithArray:@[
            (__bridge NSString *)kAXRoleAttribute,
            (__bridge NSString *)kAXSubroleAttribute,
            (__bridge NSString *)kAXMinimizedAttribute,
            (__bridge NSString *)kAXPositionAttribute,
            (__bridge NSString *)kAXSizeAttribute
        ]];
    });
    if (![allowed containsObject:name]) {
        Check(NO, [NSString stringWithFormat:@"attribute whitelist violated: %@", name]);
        return nil;
    }
    self.attributeCalls++;
    self.clock += self.clockStep;
    if (self.failAttribute &&
        (!self.failAttributeName.length || [self.failAttributeName isEqual:name]) &&
        (!self.attributeFailAfter || self.attributeCalls >= self.attributeFailAfter))
        return nil;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    return self.attributeValues[key][name];
}

- (NSNumber *)isAttributeSettable:(CFStringRef)attribute element:(id)element {
    NSString *name = (__bridge NSString *)attribute;
    [self.attributes addObject:[@"settable:" stringByAppendingString:name]];
    self.clock += self.clockStep;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    NSNumber *value = self.settableValues[key][name];
    return value;
}

- (NSDictionary *)identityForElement:(id)element {
    if (self.duringIdentity) {
        void (^hook)(YMAccessFixture *, id) = self.duringIdentity;
        self.duringIdentity = nil;
        hook(self, element);
    }
    self.clock += self.clockStep;
    if (self.application.terminated) return nil;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    return self.identities[key];
}

- (BOOL)writeAttribute:(CFStringRef)attribute value:(id)value element:(id)element {
    (void)attribute;
    (void)value;
    (void)element;
    self.writeCount++;
    self.clock += self.clockStep;
    return YES;
}

- (BOOL)accessibilityTrusted { return YES; }

- (nullable NSArray<NSDictionary *> *)visibleWindows {
    return self.visibleOverride;
}

- (nullable id)resolveIdentity:(NSDictionary *)identity error:(NSError **)error {
    for (id element in self.windowElements) {
        NSString *key = [NSString stringWithFormat:@"%p", element];
        if ([self.identities[key] isEqual:identity]) return element;
    }
    if (error) *error = [NSError errorWithDomain:@"fixture" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: @"missing"}];
    return nil;
}
@end

static YMAccessFixture *OrdinaryFixture(void) {
    YMAccessFixture *fixture = [YMAccessFixture new];
    NSDictionary *identity = Identity(4242, 1490, 1000);
    [fixture installOrdinaryWindow:fixture.element identity:identity frame:Frame(100, 200, 400, 300)];
    return fixture;
}

int main(void) {
    @autoreleasepool {
        // Step 1 red-light assertions against a failure shell / incomplete impl.
        YMAccessFixture *fixture = OrdinaryFixture();
        NSDictionary *replacement = Identity(4242, 1490, 1001);
        NSDictionary *observation = [fixture observeApplication:(id)fixture.application deadline:1.0];
        Check([observation[@"windows"] count] == 1, @"metadata adapter returns one ordinary identity");
        Check([observation[@"complete"] boolValue], @"all metadata was confirmed");
        Check(![fixture.attributes containsObject:(__bridge NSString *)kAXTitleAttribute],
              @"never read titles");
        Check(![fixture setPosition:CGPointMake(10, 20) element:fixture.element expectedIdentity:replacement],
              @"writer refuses a changed lifecycle identity");
        Check(fixture.writeCount == 0, @"identity failure causes no native write");

        // Budget: stop before the next AX call once the deadline is reached.
        // Enumeration + eight first-window primitives cost exactly 0.18 with step 0.02.
        YMAccessFixture *budget = OrdinaryFixture();
        id second = @"window-second";
        [budget installOrdinaryWindow:second identity:Identity(4242, 1491, 1000) frame:Frame(10, 10, 200, 200)];
        budget.clockStep = 0.02;
        NSDictionary *timed = [budget observeApplication:(id)budget.application deadline:0.18];
        Check(![timed[@"complete"] boolValue], @"budget exhaustion marks incomplete");
        Check([timed[@"windows"] count] == 1, @"budget exhaustion keeps earlier windows");
        Check([timed[@"windows"] count] < 2, @"budget exhaustion stops before later windows");

        // Window cap: the 129th window is never read.
        YMAccessFixture *capped = [YMAccessFixture new];
        for (NSUInteger i = 0; i < 129; i++) {
            id element = [NSString stringWithFormat:@"cap-%lu", (unsigned long)i];
            [capped installOrdinaryWindow:element identity:Identity(4242, (CGWindowID)(2000 + i), 1000)
                                    frame:Frame(10, 10, 200, 200)];
        }
        NSUInteger attrsBefore = capped.attributes.count;
        NSDictionary *over = [capped observeApplication:(id)capped.application deadline:100.0];
        Check(![over[@"complete"] boolValue], @"more than 128 windows is incomplete");
        Check([over[@"windows"] count] == 0, @"never pretend a truncated list is complete");
        Check(capped.attributes.count == attrsBefore, @"129th window is not read");

        // One enumeration per observeApplication.
        YMAccessFixture *once = OrdinaryFixture();
        [once observeApplication:(id)once.application deadline:10.0];
        Check(once.windowCopyCount == 1, @"observeApplication enumerates AXWindows once");

        // Enumeration failure is not an empty success.
        YMAccessFixture *enumFail = OrdinaryFixture();
        enumFail.failWindowCopy = YES;
        NSDictionary *failedEnum = [enumFail observeApplication:(id)enumFail.application deadline:10.0];
        Check(![failedEnum[@"complete"] boolValue], @"enumeration failure is incomplete");
        Check([failedEnum[@"windows"] count] == 0, @"enumeration failure yields no windows");
        Check([failedEnum[@"reason"] length] > 0, @"enumeration failure exposes a reason");

        YMAccessFixture *empty = [YMAccessFixture new];
        NSDictionary *emptyObs = [empty observeApplication:(id)empty.application deadline:10.0];
        Check([emptyObs[@"complete"] boolValue], @"true empty enumeration can be complete");
        Check([emptyObs[@"windows"] count] == 0, @"true empty enumeration returns no windows");

        // Missing role / minimized / frame → incomplete, not false defaults.
        YMAccessFixture *missingRole = OrdinaryFixture();
        NSString *roleKey = [NSString stringWithFormat:@"%p", missingRole.element];
        [missingRole.attributeValues[roleKey] removeObjectForKey:(__bridge NSString *)kAXRoleAttribute];
        missingRole.failAttribute = YES;
        missingRole.failAttributeName = (__bridge NSString *)kAXRoleAttribute;
        NSDictionary *noRole = [missingRole observeApplication:(id)missingRole.application deadline:10.0];
        Check(![noRole[@"complete"] boolValue], @"missing role is incomplete");

        YMAccessFixture *missingMin = OrdinaryFixture();
        missingMin.failAttribute = YES;
        missingMin.failAttributeName = (__bridge NSString *)kAXMinimizedAttribute;
        NSDictionary *noMin = [missingMin observeApplication:(id)missingMin.application deadline:10.0];
        Check(![noMin[@"complete"] boolValue], @"missing minimized is incomplete");
        Check([noMin[@"windows"] count] == 0, @"missing minimized does not invent not-minimized");

        YMAccessFixture *missingFrame = OrdinaryFixture();
        missingFrame.failAttribute = YES;
        missingFrame.failAttributeName = (__bridge NSString *)kAXPositionAttribute;
        NSDictionary *noFrame = [missingFrame observeApplication:(id)missingFrame.application deadline:10.0];
        Check(![noFrame[@"complete"] boolValue], @"missing frame is incomplete");

        // Private identity unavailable.
        YMAccessFixture *noID = OrdinaryFixture();
        [noID.identities removeAllObjects];
        NSDictionary *noIdentity = [noID observeApplication:(id)noID.application deadline:10.0];
        Check(![noIdentity[@"complete"] boolValue], @"unavailable private window ID is incomplete");

        // Duplicate identities.
        YMAccessFixture *dup = OrdinaryFixture();
        id dupElement = @"window-dup";
        [dup installOrdinaryWindow:dupElement identity:Identity(4242, 1490, 1000) frame:Frame(1, 1, 100, 100)];
        NSDictionary *dupObs = [dup observeApplication:(id)dup.application deadline:10.0];
        Check(![dupObs[@"complete"] boolValue], @"duplicate identities are incomplete");

        // Process exit during enumeration.
        YMAccessFixture *died = OrdinaryFixture();
        died.terminateAfterWindows = YES;
        NSDictionary *diedObs = [died observeApplication:(id)died.application deadline:10.0];
        Check(![diedObs[@"complete"] boolValue], @"process exit during enumeration is incomplete");

        // setSize also refuses a changed identity with no write.
        YMAccessFixture *sizeFixture = OrdinaryFixture();
        Check(![sizeFixture setSize:CGSizeMake(10, 20) element:sizeFixture.element expectedIdentity:replacement],
              @"setSize refuses a changed lifecycle identity");
        Check(sizeFixture.writeCount == 0, @"setSize identity failure causes no native write");

        // Successful identity write path records a write without claiming landing.
        YMAccessFixture *writer = OrdinaryFixture();
        NSDictionary *okIdentity = Identity(4242, 1490, 1000);
        Check([writer setPosition:CGPointMake(11, 22) element:writer.element expectedIdentity:okIdentity],
              @"matching identity allows position write API");
        Check(writer.writeCount == 1, @"matching identity performs one native write");
        Check(![writer.attributes containsObject:(__bridge NSString *)kAXTitleAttribute],
              @"writer never reads titles");

        // observeElement returns a full record or nil.
        YMAccessFixture *one = OrdinaryFixture();
        NSDictionary *record = [one observeElement:one.element];
        Check(record != nil, @"observeElement returns a record");
        Check([record[@"ordinary"] boolValue], @"observeElement marks ordinary");
        Check([record[@"readable"] boolValue], @"observeElement marks readable");
        Check(record[@"element"] == one.element, @"observeElement retains element");
        Check(YMWorkspaceIdentityValid(record[@"identity"]), @"observeElement supplies valid identity");
        Check(YMWorkspaceGeometry(record[@"frame"]) != nil, @"observeElement supplies frame");

        YMAccessFixture *bad = OrdinaryFixture();
        bad.failAttribute = YES;
        bad.failAttributeName = (__bridge NSString *)kAXMinimizedAttribute;
        Check([bad observeElement:bad.element] == nil, @"observeElement fails closed on missing minimized");

        // Last identity read past deadline must not report complete success.
        YMAccessFixture *lastRead = OrdinaryFixture();
        lastRead.clockStep = 0.02;
        NSDictionary *lastTimed = [lastRead observeApplication:(id)lastRead.application deadline:0.17];
        Check(![lastTimed[@"complete"] boolValue], @"final identity past deadline is incomplete");
        Check([lastTimed[@"windows"] count] == 1, @"final identity timeout retains the read window");
        Check([lastTimed[@"reason"] isEqual:@"timeout"], @"final identity timeout reports timeout");

        // Empty enumeration that already exhausted the budget is incomplete.
        YMAccessFixture *emptyTimed = [YMAccessFixture new];
        emptyTimed.clockStep = 0.1;
        NSDictionary *emptyPast = [emptyTimed observeApplication:(id)emptyTimed.application deadline:0.05];
        Check(![emptyPast[@"complete"] boolValue], @"empty enumeration past deadline is incomplete");
        Check([emptyPast[@"reason"] isEqual:@"timeout"], @"empty enumeration past deadline reports timeout");

        // Nested observeElement / writers must not clear an outer observe budget.
        YMAccessFixture *nested = OrdinaryFixture();
        id nestedSecond = @"window-nested-second";
        [nested installOrdinaryWindow:nestedSecond identity:Identity(4242, 1492, 1000)
                                frame:Frame(10, 10, 200, 200)];
        nested.clockStep = 0.02;
        NSDictionary *nestedIdentity = Identity(4242, 1490, 1000);
        nested.duringIdentity = ^(YMAccessFixture *fixture, id element) {
            (void)element;
            [fixture observeElement:fixture.element];
            [fixture setPosition:CGPointMake(1, 2) element:fixture.element expectedIdentity:nestedIdentity];
            [fixture setSize:CGSizeMake(3, 4) element:fixture.element expectedIdentity:nestedIdentity];
        };
        NSDictionary *nestedObs = [nested observeApplication:(id)nested.application deadline:0.18];
        Check(![nestedObs[@"complete"] boolValue], @"nested writers do not clear outer budget");
        Check([nestedObs[@"windows"] count] == 1, @"outer budget still stops later windows");

        // Nested observeApplication with its own deadline must not drop the outer budget.
        YMAccessFixture *nestedObsApp = OrdinaryFixture();
        id nestedObsSecond = @"window-nested-obs-second";
        [nestedObsApp installOrdinaryWindow:nestedObsSecond identity:Identity(4242, 1494, 1000)
                                      frame:Frame(10, 10, 200, 200)];
        nestedObsApp.clockStep = 0.02;
        __block NSDictionary *innerAppObs = nil;
        nestedObsApp.duringIdentity = ^(YMAccessFixture *fixture, id element) {
            (void)element;
            innerAppObs = [fixture observeApplication:(id)fixture.application deadline:fixture.clock];
        };
        NSDictionary *outerAppObs =
            [nestedObsApp observeApplication:(id)nestedObsApp.application deadline:0.18];
        Check(![innerAppObs[@"complete"] boolValue], @"inner observeApplication uses its own deadline");
        Check(![outerAppObs[@"complete"] boolValue], @"outer observeApplication keeps its deadline");
        Check([outerAppObs[@"windows"] count] == 1, @"outer deadline still stops later windows");

        // Controllable same-instance interleaving across threads (no sleep / no native lock).
        YMAccessFixture *shared = OrdinaryFixture();
        id sharedSecond = @"window-shared-second";
        [shared installOrdinaryWindow:sharedSecond identity:Identity(4242, 1493, 1000)
                                frame:Frame(10, 10, 200, 200)];
        shared.clockStep = 0.02;
        dispatch_queue_t bg = dispatch_queue_create("ym.access.budget", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t atHook = dispatch_semaphore_create(0);
        dispatch_semaphore_t resume = dispatch_semaphore_create(0);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSDictionary *bgObs = nil;
        shared.duringIdentity = ^(YMAccessFixture *fixture, id element) {
            (void)fixture;
            (void)element;
            dispatch_semaphore_signal(atHook);
            dispatch_semaphore_wait(resume, DISPATCH_TIME_FOREVER);
        };
        dispatch_async(bg, ^{
            bgObs = [shared observeApplication:(id)shared.application deadline:0.18];
            dispatch_semaphore_signal(done);
        });
        dispatch_semaphore_wait(atHook, DISPATCH_TIME_FOREVER);
        [shared observeElement:shared.element];
        [shared setPosition:CGPointMake(9, 9) element:shared.element
           expectedIdentity:Identity(4242, 1490, 1000)];
        [shared setSize:CGSizeMake(5, 5) element:shared.element
       expectedIdentity:Identity(4242, 1490, 1000)];
        dispatch_semaphore_signal(resume);
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        Check(![bgObs[@"complete"] boolValue], @"concurrent calls do not clear background budget");
        Check([bgObs[@"windows"] count] == 1, @"background budget still stops later windows");

        // Production CG whitelist: unknown fields fail closed; titles never retained.
        YMSystemWorkspaceWindowAccess *cgAccess = [YMSystemWorkspaceWindowAccess new];
        NSString *boundsKey = (__bridge NSString *)kCGWindowBounds;
        NSString *pidKey = (__bridge NSString *)kCGWindowOwnerPID;
        NSString *idKey = (__bridge NSString *)kCGWindowNumber;
        NSString *layerKey = (__bridge NSString *)kCGWindowLayer;
        NSString *onScreenKey = (__bridge NSString *)kCGWindowIsOnscreen;
        NSString *alphaKey = (__bridge NSString *)kCGWindowAlpha;
        NSString *nameKey = (__bridge NSString *)kCGWindowName;
        NSDictionary *rawMissingPresence = @{
            pidKey: @4242, idKey: @1490, layerKey: @0,
            boundsKey: @{@"X": @15, @"Y": @982, @"Width": @37, @"Height": @102},
            nameKey: @"Secret Title"
        };
        NSArray *cleanedMissing = [cgAccess whitelistedWindowsFromCGEntries:@[rawMissingPresence]];
        Check(cleanedMissing.count == 1, @"production CG keep records missing onScreen/alpha");
        Check(cleanedMissing[0][@"onScreen"] == nil, @"missing onScreen is not defaulted invisible");
        Check(cleanedMissing[0][@"alpha"] == nil, @"missing alpha is not defaulted invisible");
        Check(cleanedMissing[0][nameKey] == nil, @"production CG never retains window titles");
        Check(cleanedMissing[0][@"title"] == nil, @"production CG never invents title keys");
        NSDictionary *normMissing = YMWorkspaceNormalizeWindowSnapshot(
            cleanedMissing, @[], YES, @[]);
        Check([normMissing[@"blockers"] count] > 0 || ![normMissing[@"complete"] boolValue],
              @"missing presence fields fail closed via normalizer");
        Check(!YMWorkspaceSnapshotAllowsSource(normMissing, nil),
              @"missing presence fields refuse inventory close");

        NSDictionary *rawBadBounds = @{
            pidKey: @4242, idKey: @1491, layerKey: @0,
            onScreenKey: @YES, alphaKey: @1,
            boundsKey: @{@"X": @"bad", @"Y": @0, @"Width": @10, @"Height": @10}
        };
        NSArray *cleanedBadBounds = [cgAccess whitelistedWindowsFromCGEntries:@[rawBadBounds]];
        Check(cleanedBadBounds.count == 1, @"illegal bounds keep a whitelist record");
        Check(cleanedBadBounds[0][@"frame"] == nil, @"illegal bounds omit frame");
        NSDictionary *normBadBounds = YMWorkspaceNormalizeWindowSnapshot(
            cleanedBadBounds, @[], YES, @[]);
        Check([normBadBounds[@"blockers"] count] > 0 || ![normBadBounds[@"complete"] boolValue],
              @"illegal bounds fail closed rather than empty success");

        NSDictionary *rawMissingPID = @{
            idKey: @1492, layerKey: @0, onScreenKey: @YES, alphaKey: @1,
            boundsKey: @{@"X": @0, @"Y": @0, @"Width": @10, @"Height": @10}
        };
        NSArray *cleanedMissingPID = [cgAccess whitelistedWindowsFromCGEntries:@[rawMissingPID]];
        Check(cleanedMissingPID.count == 1, @"missing PID keeps a whitelist record");
        NSDictionary *normMissingPID = YMWorkspaceNormalizeWindowSnapshot(
            cleanedMissingPID, @[], YES, @[]);
        Check(![normMissingPID[@"complete"] boolValue],
              @"missing PID is incomplete observation not empty success");

        Check([cgAccess whitelistedWindowsFromCGEntries:@[ @"not-a-dictionary" ]] == nil,
              @"non-dictionary CG entries fail the query");

        if (failures) {
            fprintf(stderr, "%u of %u App workspace access checks failed.\n",
                    (unsigned)failures, (unsigned)checks);
            return 1;
        }
        printf("Passed %u App workspace access checks; no displays, applications or GUI were accessed.\n",
               (unsigned)checks);
        return 0;
    }
}
