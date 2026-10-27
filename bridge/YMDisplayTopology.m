#import "YMDisplayTopology.h"
#import <math.h>
#import <ColorSync/ColorSync.h>
#import <stdatomic.h>

NSErrorDomain const YMDisplayTopologyErrorDomain = @"dev.chekusu.yomado.DisplayTopology";
NSString *const YMDisplayTopologyDiagnosticsKey = @"displayTopologyDiagnostics";

static BOOL YMFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:YMDisplayTopologyErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static NSArray<NSString *> *YMModeKeys(void) {
    return @[@"modeWidth", @"modeHeight", @"pixelWidth", @"pixelHeight", @"refreshRate", @"modeFlags",
        @"modeUsableForDesktopGUI", @"modeID"];
}

static NSArray<NSString *> *YMModePropertyKeys(void) {
    // The driver-local mode identifier is not a requested display property.
    // Keep it in observation/race checks, but do not reset an otherwise equal
    // mode just to recover an older identifier after a topology change.
    return @[@"modeWidth", @"modeHeight", @"pixelWidth", @"pixelHeight", @"refreshRate", @"modeFlags",
        @"modeUsableForDesktopGUI"];
}

static NSDictionary *YMModeDescription(CGDisplayModeRef mode) {
    if (!mode) return @{};
    return @{@"modeToken": CFBridgingRelease(CGDisplayModeRetain(mode)),
        @"modeWidth":@(CGDisplayModeGetWidth(mode)), @"modeHeight":@(CGDisplayModeGetHeight(mode)),
        @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode)),
        @"refreshRate":@(CGDisplayModeGetRefreshRate(mode)), @"modeFlags":@(CGDisplayModeGetIOFlags(mode)),
        @"modeUsableForDesktopGUI":@(CGDisplayModeIsUsableForDesktopGUI(mode)),
        @"modeID":@(CGDisplayModeGetIODisplayModeID(mode))};
}

static BOOL YMValuesEqual(id left, id right) {
    return left == right || [left isEqual:right];
}

static BOOL YMKeysEqual(NSDictionary *left, NSDictionary *right, NSArray<NSString *> *keys) {
    for (NSString *key in keys) if (!YMValuesEqual(left[key], right[key])) return NO;
    return YES;
}

static NSDictionary *YMSafeModeDiagnostic(NSDictionary *item) {
    NSMutableDictionary *mode = [NSMutableDictionary dictionary];
    for (NSString *key in YMModeKeys()) {
        id value = item[key];
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) mode[key] = value;
    }
    return mode.copy;
}

static NSString *YMModeSummary(NSDictionary *mode) {
    if (!mode[@"modeWidth"]) return @"unavailable";
    return [NSString stringWithFormat:@"%@×%@ points, %@×%@ pixels, %@ Hz, flags %@, desktop GUI %@, mode %@",
        mode[@"modeWidth"], mode[@"modeHeight"], mode[@"pixelWidth"], mode[@"pixelHeight"],
        mode[@"refreshRate"], mode[@"modeFlags"], mode[@"modeUsableForDesktopGUI"], mode[@"modeID"]];
}

static BOOL YMModeFailure(NSError **error, NSError *failure, NSDictionary *saved,
                          NSDictionary *current, CGDirectDisplayID newDisplayID) {
    BOOL isNew = newDisplayID && [saved[@"displayID"] unsignedIntValue] == newDisplayID;
    NSString *role = isNew ? @"new virtual display"
        : [saved[@"mirrorOf"] unsignedIntValue] ? @"existing mirror follower"
        : [saved[@"inMirrorSet"] boolValue] ? @"existing mirror primary" : @"existing extended display";
    NSDictionary *savedMode = YMSafeModeDiagnostic(saved), *currentMode = YMSafeModeDiagnostic(current);
    NSInteger code = failure ? failure.code : kCGErrorFailure;
    NSDictionary *details = @{@"operation":@"setDisplayMode", @"role":role,
        @"cgError":@(code), @"active":@([current[@"active"] boolValue]),
        @"main":@([current[@"main"] boolValue]), @"builtin":@([current[@"builtin"] boolValue]),
        @"rotation":@([current[@"rotation"] doubleValue]), @"savedMode":savedMode, @"currentMode":currentMode};
    NSString *message = [NSString stringWithFormat:
        @"macOS could not restore the saved display mode (%@, %@; CGError %ld). Saved: %@. Current: %@.",
        role, [current[@"active"] boolValue] ? @"active" : @"inactive", (long)code,
        YMModeSummary(savedMode), YMModeSummary(currentMode)];
    if (error) *error = [NSError errorWithDomain:failure.domain ?: YMDisplayTopologyErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message, YMDisplayTopologyDiagnosticsKey:details}];
    return NO;
}

static BOOL YMHasRequestedMode(NSDictionary *item, NSUInteger width, NSUInteger height, BOOL hiDPI) {
    NSUInteger scale = hiDPI ? 2 : 1;
    return [item[@"modeWidth"] unsignedIntegerValue] == width
        && [item[@"modeHeight"] unsignedIntegerValue] == height
        && [item[@"pixelWidth"] unsignedIntegerValue] == width * scale
        && [item[@"pixelHeight"] unsignedIntegerValue] == height * scale;
}

@interface YMCoreGraphicsTopologyBackend : NSObject <YMDisplayTopologyBackend> {
    CGDisplayConfigRef _configuration;
    atomic_ulong _generation;
    BOOL _callbackInstalled;
}
- (void)didReconfigure;
@end

static void YMReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    (void)display; (void)flags;
    [(__bridge YMCoreGraphicsTopologyBackend *)context didReconfigure];
}

@implementation YMCoreGraphicsTopologyBackend
- (instancetype)init {
    if ((self = [super init])) {
        atomic_init(&_generation, 0);
        _callbackInstalled = CGDisplayRegisterReconfigurationCallback(YMReconfigured, (__bridge void *)self) == kCGErrorSuccess;
    }
    return self;
}
- (void)dealloc {
    if (_callbackInstalled) CGDisplayRemoveReconfigurationCallback(YMReconfigured, (__bridge void *)self);
    if (_configuration) CGCancelDisplayConfiguration(_configuration);
}
- (void)didReconfigure { atomic_fetch_add(&_generation, 1); }
- (NSUInteger)reconfigurationGeneration { return atomic_load(&_generation); }
- (NSArray<NSDictionary *> *)readDisplaysWithError:(NSError **)error {
    if (!_callbackInstalled) {
        YMFail(error, 1, @"Display change monitoring is unavailable; no display configuration was changed.");
        return nil;
    }
    CGDirectDisplayID displayIDs[256];
    uint32_t count = 0;
    CGError result = CGGetOnlineDisplayList(256, displayIDs, &count);
    if (result != kCGErrorSuccess || count == 0 || count >= 256) {
        YMFail(error, 2, @"The complete online display list could not be read safely.");
        return nil;
    }
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
    BOOL missingActiveMode = NO;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = displayIDs[i];
        CGRect bounds = CGDisplayBounds(display);
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
        NSString *identity = uuid ? CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid)) : nil;
        if (uuid) CFRelease(uuid);
        if (identity.length == 0) {
            YMFail(error, 3, @"A display has no stable identity; automatic layout changes are unavailable.");
            return nil;
        }
        NSMutableDictionary *item = [@{@"displayID":@(display), @"identity":identity,
            @"vendor":@(CGDisplayVendorNumber(display)), @"model":@(CGDisplayModelNumber(display)),
            @"serial":@(CGDisplaySerialNumber(display)), @"main":@(CGDisplayIsMain(display)),
            @"active":@(CGDisplayIsActive(display)), @"online":@(CGDisplayIsOnline(display)),
            @"builtin":@(CGDisplayIsBuiltin(display)), @"rotation":@(CGDisplayRotation(display)),
            @"mirrorOf":@(CGDisplayMirrorsDisplay(display)), @"inMirrorSet":@(CGDisplayIsInMirrorSet(display)),
            @"x":@(bounds.origin.x), @"y":@(bounds.origin.y),
            @"logicalWidth":@(bounds.size.width), @"logicalHeight":@(bounds.size.height)} mutableCopy];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
        if (mode) {
            [item addEntriesFromDictionary:YMModeDescription(mode)];
            CGDisplayModeRelease(mode);
        } else if (CGDisplayIsActive(display)) {
            missingActiveMode = YES;
        }
        [items addObject:item.copy];
    }
    if (missingActiveMode) {
        // AppKit's normal event loop updates process-local mode caches after
        // hot-plug notifications. Preserve a complete identity inventory while
        // the caller waits; never guess a mode from bounds or available modes.
        if (error) *error = [NSError errorWithDomain:YMDisplayTopologyErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey:@"An active display mode is temporarily unavailable; no application moves are permitted.",
            @"displayInventory":items.copy}];
        return nil;
    }
    return items;
}
- (NSDictionary *)modeForDisplay:(CGDirectDisplayID)displayID width:(NSUInteger)width
                         height:(NSUInteger)height hiDPI:(BOOL)hiDPI error:(NSError **)error {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES});
    NSDictionary *selected = nil;
    for (id token in (__bridge NSArray *)modes) {
        NSDictionary *candidate = YMModeDescription((__bridge CGDisplayModeRef)token);
        if (!YMHasRequestedMode(candidate, width, height, hiDPI)) continue;
        if (!selected || fabs([candidate[@"refreshRate"] doubleValue] - 60) <
                         fabs([selected[@"refreshRate"] doubleValue] - 60)) selected = candidate;
    }
    if (modes) CFRelease(modes);
    if (!selected) YMFail(error, 5, @"The virtual display's requested resolution and scale are unavailable.");
    return selected;
}
- (BOOL)beginConfiguration:(NSError **)error {
    if (_configuration) return YMFail(error, 6, @"A display transaction is already in progress.");
    CGError result = CGBeginDisplayConfiguration(&_configuration);
    if (result != kCGErrorSuccess || !_configuration) {
        if (_configuration) { CGCancelDisplayConfiguration(_configuration); _configuration = NULL; }
        return YMFail(error, result, @"macOS could not begin a display configuration transaction.");
    }
    return YES;
}
- (BOOL)setMirrorOfDisplay:(CGDirectDisplayID)displayID toDisplay:(CGDirectDisplayID)targetID error:(NSError **)error {
    CGError result = CGConfigureDisplayMirrorOfDisplay(_configuration, displayID, targetID);
    return result == kCGErrorSuccess || YMFail(error, result, @"macOS could not restore the requested mirror relationship.");
}
- (BOOL)setModeOfDisplay:(CGDirectDisplayID)displayID token:(id)modeToken error:(NSError **)error {
    CGError result = CGConfigureDisplayWithDisplayMode(_configuration, displayID, (__bridge CGDisplayModeRef)modeToken, NULL);
    return result == kCGErrorSuccess || YMFail(error, result, @"macOS could not restore the saved display mode.");
}
- (BOOL)setOriginOfDisplay:(CGDirectDisplayID)displayID x:(int32_t)x y:(int32_t)y error:(NSError **)error {
    CGError result = CGConfigureDisplayOrigin(_configuration, displayID, x, y);
    return result == kCGErrorSuccess || YMFail(error, result, @"macOS could not preserve the saved display position.");
}
- (BOOL)commitConfiguration:(NSError **)error {
    // CoreGraphics consumes the transaction even when completion fails.
    CGDisplayConfigRef configuration = _configuration;
    _configuration = NULL;
    CGError result = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
    return result == kCGErrorSuccess || YMFail(error, result, @"macOS rejected the display configuration transaction.");
}
- (void)cancelConfiguration {
    if (_configuration) { CGCancelDisplayConfiguration(_configuration); _configuration = NULL; }
}
- (void)waitForNextObservation {
    // Let reconfiguration callbacks arrive without activating any applications.
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:0.1];
    while ([limit timeIntervalSinceNow] > 0) {
        if (![[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:limit])
            [NSThread sleepForTimeInterval:MAX(0, [limit timeIntervalSinceNow])];
    }
}
@end

@interface YMDisplayTopologySnapshot ()
@property(nonatomic, copy, readwrite) NSArray<NSDictionary<NSString *, id> *> *displays;
@property(nonatomic) BOOL readOnlyRecovery;
@property(nonatomic, copy) NSSet<NSNumber *> *recoverableMirrorIDs;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSString *> *ownedRemovalIdentities;
@end

@implementation YMDisplayTopologySnapshot
- (YMDisplayTopologySnapshot *)snapshotByExcludingDisplayID:(CGDirectDisplayID)displayID {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableDictionary *removedIdentities = [self.ownedRemovalIdentities mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableSet *recoverableMirrors = [self.recoverableMirrorIDs mutableCopy] ?: [NSMutableSet set];
    for (NSDictionary *item in self.displays) {
        if ([item[@"displayID"] unsignedIntValue] == displayID) {
            removedIdentities[@(displayID)] = item[@"identity"];
            if ([item[@"mirrorOf"] unsignedIntValue]) [recoverableMirrors addObject:item[@"mirrorOf"]];
            continue;
        }
        // A mirror group containing a removed master needs a caller-selected
        // recovery policy; silently choosing a new master would change intent.
        if ([item[@"mirrorOf"] unsignedIntValue] == displayID) return nil;
        [items addObject:item];
    }
    // Removing the last follower also removes its master's mirror-set status.
    // Keep all surviving edges and recompute just their derived membership.
    NSMutableSet *members = [NSMutableSet set];
    for (NSDictionary *item in items) if ([item[@"mirrorOf"] unsignedIntValue]) {
        [members addObject:item[@"displayID"]]; [members addObject:item[@"mirrorOf"]];
    }
    NSMutableArray *survivors = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSMutableDictionary *survivor = item.mutableCopy;
        survivor[@"inMirrorSet"] = @([members containsObject:item[@"displayID"]]);
        [survivors addObject:survivor.copy];
    }
    YMDisplayTopologySnapshot *snapshot = [YMDisplayTopologySnapshot new];
    snapshot.displays = survivors;
    snapshot.readOnlyRecovery = self.readOnlyRecovery;
    snapshot.recoverableMirrorIDs = recoverableMirrors;
    snapshot.ownedRemovalIdentities = removedIdentities;
    return snapshot;
}
@end

@interface YMDisplayTopology ()
@property(nonatomic, strong) id<YMDisplayTopologyBackend> backend;
@property(nonatomic) NSUInteger modeRetriesRemaining;
@end

@implementation YMDisplayTopology
- (instancetype)init { return [self initWithBackend:[YMCoreGraphicsTopologyBackend new]]; }
- (instancetype)initWithBackend:(id<YMDisplayTopologyBackend>)backend {
    if ((self = [super init])) _backend = backend;
    return self;
}

- (NSDictionary<NSNumber *, NSDictionary *> *)index:(NSArray<NSDictionary *> *)items error:(NSError **)error {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableSet *identities = [NSMutableSet set];
    NSUInteger mainCount = 0;
    for (NSDictionary *item in items) {
        NSNumber *key = item[@"displayID"];
        NSString *identity = item[@"identity"];
        if (!key.unsignedIntValue || identity.length == 0 || result[key] || [identities containsObject:identity]
            || ![item[@"online"] boolValue]) {
            YMFail(error, 10, @"The display identities are incomplete or changed during configuration.");
            return nil;
        }
        [identities addObject:identity];
        for (NSString *field in @[@"x", @"y", @"logicalWidth", @"logicalHeight", @"rotation"])
            if (!item[field] || !isfinite([item[field] doubleValue])) {
                YMFail(error, 11, @"A display's geometry could not be read safely."); return nil;
            }
        if ([item[@"main"] boolValue]) mainCount++;
        result[key] = item;
    }
    if (items.count == 0 || mainCount != 1) {
        YMFail(error, 12, @"The original main display could not be identified safely."); return nil;
    }
    for (NSDictionary *item in items) {
        NSNumber *target = item[@"mirrorOf"];
        if (target.unsignedIntValue && (!result[target] || [target isEqual:item[@"displayID"]])) {
            YMFail(error, 13, @"An incomplete display mirror relationship was reported."); return nil;
        }
    }
    return result;
}

- (BOOL)identitiesOf:(NSArray<NSDictionary *> *)actual match:(NSArray<NSDictionary *> *)expected error:(NSError **)error {
    NSDictionary *byID = [self index:actual error:error];
    if (!byID) return NO;
    if (actual.count != expected.count) return YMFail(error, 14, @"Another display was connected or removed; automatic layout recovery was stopped.");
    for (NSDictionary *item in expected) {
        NSDictionary *live = byID[item[@"displayID"]];
        if (!live || !YMKeysEqual(item, live, @[@"identity", @"vendor", @"model", @"serial", @"builtin"]))
            return YMFail(error, 15, @"A display was replaced or re-enumerated; automatic layout recovery was stopped.");
    }
    return YES;
}

- (BOOL)statesOf:(NSArray<NSDictionary *> *)actual match:(NSArray<NSDictionary *> *)expected
 includingModeIdentifiers:(BOOL)includingModeIdentifiers {
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *item in actual) byID[item[@"displayID"]] = item;
    NSArray *keys = @[@"main", @"active", @"online", @"rotation", @"mirrorOf", @"inMirrorSet",
        @"x", @"y", @"logicalWidth", @"logicalHeight"];
    for (NSDictionary *item in expected) {
        NSDictionary *live = byID[item[@"displayID"]];
        if (!live || !YMKeysEqual(item, live, keys)
            || !YMKeysEqual(item, live, includingModeIdentifiers ? YMModeKeys() : YMModePropertyKeys())) return NO;
    }
    return YES;
}

- (BOOL)statesOf:(NSArray<NSDictionary *> *)actual match:(NSArray<NSDictionary *> *)expected {
    return [self statesOf:actual match:expected includingModeIdentifiers:YES];
}

- (NSArray<NSDictionary *> *)readCompleteDisplaysWithGuard:(BOOL (^)(NSArray<NSDictionary *> *, NSError **))guard
                                                     error:(NSError **)error {
    NSArray *identityAnchor = nil;
    for (;;) {
        NSError *failure = nil;
        NSArray *complete = [self.backend readDisplaysWithError:&failure];
        BOOL transientMode = [failure.domain isEqualToString:YMDisplayTopologyErrorDomain] && failure.code == 4;
        NSArray *inventory = complete ?: (transientMode ? failure.userInfo[@"displayInventory"] : nil);
        if (![inventory isKindOfClass:NSArray.class]) {
            if (error) *error = failure;
            return nil;
        }
        if (![self index:inventory error:error]) return nil;
        if (guard) {
            if (!guard(inventory, error)) return nil;
        } else if (identityAnchor && ![self identitiesOf:inventory match:identityAnchor error:error]) {
            return nil;
        }
        if (complete) return complete;
        if (!transientMode || self.modeRetriesRemaining == 0) {
            if (error) *error = failure;
            return nil;
        }
        if (!identityAnchor) identityAnchor = inventory;
        self.modeRetriesRemaining--;
        [self.backend waitForNextObservation];
    }
}

- (BOOL)guardCreationInventory:(NSArray<NSDictionary *> *)inventory baseline:(YMDisplayTopologySnapshot *)baseline
                     display:(CGDirectDisplayID)displayID error:(NSError **)error {
    NSMutableArray *expected = [baseline.displays mutableCopy];
    NSDictionary *added = nil;
    for (NSDictionary *item in inventory) if ([item[@"displayID"] unsignedIntValue] == displayID) added = item;
    if (added) {
        NSString *known = baseline.ownedRemovalIdentities[@(displayID)];
        if (known && ![known isEqual:added[@"identity"]])
            return YMFail(error, 31, @"The new display identity changed while its mode was loading.");
        baseline.ownedRemovalIdentities = @{@(displayID):added[@"identity"]};
        [expected addObject:added];
    }
    if (![self identitiesOf:inventory match:expected error:error]) return NO;
    NSMutableSet *affected = [NSMutableSet setWithObject:@(displayID)];
    BOOL expanded = YES;
    while (expanded) {
        expanded = NO;
        for (NSDictionary *item in [inventory arrayByAddingObjectsFromArray:baseline.displays]) {
            NSNumber *ident = item[@"displayID"], *mirror = item[@"mirrorOf"];
            if (mirror.unsignedIntValue && ([affected containsObject:ident] || [affected containsObject:mirror])) {
                NSUInteger old = affected.count; [affected addObject:ident]; [affected addObject:mirror];
                expanded |= old != affected.count;
            }
        }
    }
    baseline.recoverableMirrorIDs = affected.copy;
    NSDictionary *byID = [self index:inventory error:error];
    for (NSDictionary *item in baseline.displays) {
        if (![affected containsObject:item[@"displayID"]]
            && !YMKeysEqual(item, byID[item[@"displayID"]], @[@"mirrorOf", @"inMirrorSet"]))
            return YMFail(error, 26, @"An unrelated mirror group changed; automatic layout changes were stopped.");
    }
    return YES;
}

- (YMDisplayTopologySnapshot *)captureSnapshotWithError:(NSError **)error {
    self.modeRetriesRemaining = 50;
    // Two independent reads and an unchanged generation avoid freezing a
    // half-applied configuration. Subsequent operations also check identities.
    for (NSUInteger attempt = 0; attempt < 8; attempt++) {
        NSUInteger generation = self.backend.reconfigurationGeneration;
        NSArray *first = [self readCompleteDisplaysWithGuard:nil error:error];
        if (!first || ![self index:first error:error]) return nil;
        [self.backend waitForNextObservation];
        NSArray *second = [self readCompleteDisplaysWithGuard:^BOOL(NSArray *items, NSError **guardError) {
            return [self identitiesOf:items match:first error:guardError];
        } error:error];
        if (!second) return nil;
        if (generation == self.backend.reconfigurationGeneration
            && [self identitiesOf:second match:first error:NULL] && [self statesOf:second match:first]) {
            YMDisplayTopologySnapshot *snapshot = [YMDisplayTopologySnapshot new];
            snapshot.displays = [[NSArray alloc] initWithArray:second copyItems:YES];
            snapshot.recoverableMirrorIDs = [NSSet set];
            snapshot.ownedRemovalIdentities = @{};
            return snapshot;
        }
    }
    YMFail(error, 16, @"The display arrangement is still changing. Try again after it settles.");
    return nil;
}

- (BOOL)verifyExpected:(NSArray<NSDictionary *> *)expected error:(NSError **)error {
    NSUInteger stable = 0, generation = self.backend.reconfigurationGeneration;
    NSArray *previous = nil;
    // Success requires matching full topology across independent observations,
    // not merely waiting a fixed delay or seeing a single cached good snapshot.
    for (NSUInteger attempt = 0; attempt < 30; attempt++) {
        [self.backend waitForNextObservation];
        NSArray *live = [self readCompleteDisplaysWithGuard:^BOOL(NSArray *items, NSError **guardError) {
            return [self identitiesOf:items match:expected error:guardError];
        } error:error];
        if (!live || ![self identitiesOf:live match:expected error:error]) return NO;
        NSUInteger nextGeneration = self.backend.reconfigurationGeneration;
        if (generation != nextGeneration || (previous && ![self statesOf:live match:previous])) stable = 0;
        generation = nextGeneration;
        previous = live;
        if ([self statesOf:live match:expected includingModeIdentifiers:NO]) stable++; else stable = 0;
        if (stable >= 5 && attempt >= 14) return YES;
    }
    return YMFail(error, 17, @"macOS did not preserve the requested display layout, main screen, modes and mirror relationships. Application moves remain disabled.");
}

- (BOOL)apply:(NSArray<NSDictionary *> *)expected from:(NSArray<NSDictionary *> *)current
 newDisplayID:(CGDirectDisplayID)newDisplayID error:(NSError **)error {
    if (![self identitiesOf:current match:expected error:error]) return NO;
    NSDictionary *currentByID = [self index:current error:error];
    if (!currentByID) return NO;
    // Rotation has no public transaction setter. Never claim it was restored.
    for (NSDictionary *item in expected) {
        NSDictionary *live = currentByID[item[@"displayID"]];
        if (!YMValuesEqual(item[@"rotation"], live[@"rotation"]))
            return YMFail(error, 18, @"A display's rotation changed; restore it in System Settings before continuing.");
        if (!YMKeysEqual(item, live, YMModePropertyKeys()) && !item[@"modeToken"])
            return YMFail(error, 19, @"The original display mode cannot be restored safely.");
    }
    if ([self statesOf:current match:expected includingModeIdentifiers:NO]) return [self verifyExpected:expected error:error];
    // Fresh identity check immediately before obtaining the transaction.
    NSUInteger generation = self.backend.reconfigurationGeneration;
    NSArray *fresh = [self readCompleteDisplaysWithGuard:^BOOL(NSArray *items, NSError **guardError) {
        return [self identitiesOf:items match:expected error:guardError];
    } error:error];
    if (!fresh || ![self identitiesOf:fresh match:expected error:error]
        || ![self statesOf:fresh match:current])
        return YMFail(error, 20, @"The display configuration changed before the transaction could start.");
    if (![self.backend beginConfiguration:error]) return NO;
    BOOL staged = YES;
    // Remove changed follower edges only. Never issue a global unmirror, and
    // never touch unrelated pre-existing mirror relationships.
    for (NSDictionary *item in expected) {
        NSDictionary *live = currentByID[item[@"displayID"]];
        if (!YMValuesEqual(item[@"mirrorOf"], live[@"mirrorOf"]) && [live[@"mirrorOf"] unsignedIntValue]) {
            staged = [self.backend setMirrorOfDisplay:[item[@"displayID"] unsignedIntValue] toDisplay:0 error:error];
            if (!staged) break;
        }
    }
    if (staged) for (NSDictionary *item in expected) {
        NSDictionary *live = currentByID[item[@"displayID"]];
        if (!YMKeysEqual(item, live, YMModePropertyKeys())) {
            NSError *failure = nil;
            staged = [self.backend setModeOfDisplay:[item[@"displayID"] unsignedIntValue] token:item[@"modeToken"] error:&failure];
            if (!staged) YMModeFailure(error, failure, item, live, newDisplayID);
            if (!staged) break;
        }
    }
    // Pin every extended root's saved origin because CoreGraphics may otherwise
    // reposition unspecified displays. Setting a follower's origin unmirrors it,
    // so followers are deliberately omitted and their edges are restored last.
    if (staged) for (NSNumber *mainPass in @[@YES, @NO]) {
        for (NSDictionary *item in expected) {
            if ([item[@"main"] boolValue] != mainPass.boolValue || [item[@"mirrorOf"] unsignedIntValue]) continue;
            double x = [item[@"x"] doubleValue], y = [item[@"y"] doubleValue];
            if (x < INT32_MIN || x > INT32_MAX || y < INT32_MIN || y > INT32_MAX || x != trunc(x) || y != trunc(y)) {
                staged = YMFail(error, 21, @"The saved display position is outside the supported coordinate range."); break;
            }
            staged = [self.backend setOriginOfDisplay:[item[@"displayID"] unsignedIntValue] x:(int32_t)x y:(int32_t)y error:error];
            if (!staged) break;
        }
        if (!staged) break;
    }
    if (staged) for (NSDictionary *item in expected) {
        NSDictionary *live = currentByID[item[@"displayID"]];
        CGDirectDisplayID mirror = [item[@"mirrorOf"] unsignedIntValue];
        if (mirror && !YMValuesEqual(item[@"mirrorOf"], live[@"mirrorOf"])) {
            staged = [self.backend setMirrorOfDisplay:[item[@"displayID"] unsignedIntValue] toDisplay:mirror error:error];
            if (!staged) break;
        }
    }
    if (staged) {
        NSArray *beforeCommit = [self.backend readDisplaysWithError:error];
        if (!beforeCommit || ![self identitiesOf:beforeCommit match:current error:error]
            || ![self statesOf:beforeCommit match:current]
            || generation != self.backend.reconfigurationGeneration)
            staged = YMFail(error, 22, @"A concurrent display change interrupted the transaction.");
    }
    if (!staged) { [self.backend cancelConfiguration]; return NO; }
    if (![self.backend commitConfiguration:error]) { [self.backend cancelConfiguration]; return NO; }
    return [self verifyExpected:expected error:error];
}

- (void)restrictRecoveryOf:(YMDisplayTopologySnapshot *)snapshot afterError:(NSError *)error {
    if (![error.domain isEqualToString:YMDisplayTopologyErrorDomain]) return;
    // Retrying recovery must not undo the unrelated edit that caused refusal.
    // Transaction setter/commit errors and an unsettled owned layout may still
    // be recoverable; foreign identities, intent changes and races are not.
    NSIndexSet *unsafe = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 3)];
    if ([unsafe containsIndex:(NSUInteger)error.code] || (error.code >= 10 && error.code <= 16)
        || error.code == 18 || error.code == 20 || error.code == 22 || error.code == 26 || error.code == 31)
        snapshot.readOnlyRecovery = YES;
}

- (BOOL)configureAndVerifyNewDisplay:(CGDirectDisplayID)displayID width:(NSUInteger)width height:(NSUInteger)height
                             hiDPI:(BOOL)hiDPI baseline:(YMDisplayTopologySnapshot *)baseline error:(NSError **)error {
    self.modeRetriesRemaining = 50;
    if (baseline.readOnlyRecovery) return YMFail(error, 30, @"An unrelated display change requires a new baseline before creating a screen.");
    NSError *failure = nil;
    BOOL result = [self configureOwnedDisplay:displayID width:width height:height hiDPI:hiDPI baseline:baseline error:&failure];
    if (!result) { [self restrictRecoveryOf:baseline afterError:failure]; if (error) *error = failure; }
    return result;
}

- (BOOL)configureOwnedDisplay:(CGDirectDisplayID)displayID width:(NSUInteger)width height:(NSUInteger)height
                             hiDPI:(BOOL)hiDPI baseline:(YMDisplayTopologySnapshot *)baseline error:(NSError **)error {
    if (!displayID || width < 320 || height < 240 || width > 8192 || height > 8192 || baseline.displays.count == 0)
        return YMFail(error, 23, @"A valid baseline and virtual display are required.");
    NSDictionary *beforeByID = [self index:baseline.displays error:error];
    if (!beforeByID || beforeByID[@(displayID)])
        return YMFail(error, 24, @"The new virtual display conflicts with an existing display identity.");
    NSArray *current = nil;
    NSDictionary *newDisplay = nil;
    // Creation visibility is asynchronous. No configuration writes occur until
    // the exact baseline plus the new ID is visible; foreign devices abort.
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        current = [self readCompleteDisplaysWithGuard:^BOOL(NSArray *items, NSError **guardError) {
            return [self guardCreationInventory:items baseline:baseline display:displayID error:guardError];
        } error:error];
        if (!current) return NO;
        for (NSDictionary *item in current) {
            if ([item[@"displayID"] unsignedIntValue] == displayID) newDisplay = item;
        }
        // Mirror-root creation can temporarily make the new display main; the
        // full current list is validated below, not this baseline subset.
        NSMutableArray *identityExpected = [baseline.displays mutableCopy];
        if (newDisplay) [identityExpected addObject:newDisplay];
        if (![self identitiesOf:current match:identityExpected error:error]) return NO;
        if (newDisplay) break;
        [self.backend waitForNextObservation];
    }
    if (!newDisplay) return YMFail(error, 25, @"The new virtual display did not become online.");
    baseline.ownedRemovalIdentities = @{@(displayID):newDisplay[@"identity"]};
    NSDictionary *currentByID = [self index:current error:error];
    if (!currentByID) return NO;
    NSDictionary *mode = YMHasRequestedMode(newDisplay, width, height, hiDPI) ? newDisplay
        : [self.backend modeForDisplay:displayID width:width height:height hiDPI:hiDPI error:error];
    if (!mode) return NO;
    double right = -DBL_MAX, top = 0;
    for (NSDictionary *item in baseline.displays) {
        if (![item[@"active"] boolValue] || [item[@"mirrorOf"] unsignedIntValue]) continue;
        double edge = [item[@"x"] doubleValue] + [item[@"logicalWidth"] doubleValue];
        if (edge > right) { right = edge; top = [item[@"y"] doubleValue]; }
    }
    if (!isfinite(right) || right == -DBL_MAX || right < INT32_MIN || right > INT32_MAX)
        return YMFail(error, 27, @"There is no safe right edge for the virtual display.");
    NSMutableDictionary *target = [newDisplay mutableCopy];
    for (NSString *key in YMModeKeys()) if (mode[key]) target[key] = mode[key];
    target[@"modeToken"] = mode[@"modeToken"];
    target[@"x"] = @(right); target[@"y"] = @(top);
    target[@"logicalWidth"] = @(width); target[@"logicalHeight"] = @(height);
    target[@"main"] = @NO; target[@"active"] = @YES; target[@"online"] = @YES;
    target[@"mirrorOf"] = @0; target[@"inMirrorSet"] = @NO;
    target[@"rotation"] = @0;
    NSMutableArray *expected = [baseline.displays mutableCopy];
    [expected addObject:target];
    return [self apply:expected from:current newDisplayID:displayID error:error];
}

- (BOOL)restoreAndVerifySnapshot:(YMDisplayTopologySnapshot *)snapshot excludingDisplayID:(CGDirectDisplayID)displayID error:(NSError **)error {
    self.modeRetriesRemaining = 50;
    NSError *failure = nil;
    BOOL result = [self restoreOwnedSnapshot:snapshot excludingDisplayID:displayID error:&failure];
    if (!result) { [self restrictRecoveryOf:snapshot afterError:failure]; if (error) *error = failure; }
    return result;
}

- (BOOL)restoreOwnedSnapshot:(YMDisplayTopologySnapshot *)snapshot excludingDisplayID:(CGDirectDisplayID)displayID error:(NSError **)error {
    YMDisplayTopologySnapshot *desired = displayID ? [snapshot snapshotByExcludingDisplayID:displayID] : snapshot;
    if (!desired || ![self index:desired.displays error:error])
        return YMFail(error, 28, @"The saved display configuration cannot be restored after this removal.");
    NSArray *current = nil;
    for (NSUInteger attempt = 0; attempt < 30; attempt++) {
        current = [self readCompleteDisplaysWithGuard:^BOOL(NSArray *items, NSError **guardError) {
            NSMutableArray *allowed = [desired.displays mutableCopy];
            NSString *known = snapshot.ownedRemovalIdentities[@(displayID)];
            for (NSDictionary *saved in snapshot.displays)
                if ([saved[@"displayID"] unsignedIntValue] == displayID) known = saved[@"identity"];
            for (NSDictionary *item in items) if (displayID && [item[@"displayID"] unsignedIntValue] == displayID) {
                if (known && ![known isEqual:item[@"identity"]])
                    return YMFail(guardError, 31, @"The removed display ID was reused by another device; recovery was stopped.");
                [allowed addObject:item];
            }
            return [self identitiesOf:items match:allowed error:guardError];
        } error:error];
        if (!current) return NO;
        BOOL removed = YES;
        NSString *removedIdentity = snapshot.ownedRemovalIdentities[@(displayID)];
        for (NSDictionary *item in snapshot.displays)
            if ([item[@"displayID"] unsignedIntValue] == displayID) removedIdentity = item[@"identity"];
        for (NSDictionary *item in current) if (displayID && [item[@"displayID"] unsignedIntValue] == displayID) {
            removed = NO;
            if (removedIdentity && ![item[@"identity"] isEqual:removedIdentity])
                return YMFail(error, 31, @"The removed display ID was reused by another device; recovery was stopped.");
        }
        if (removed) break;
        // Identity comparison uses the whole online inventory while the owned
        // display is still disappearing, so mirror roots/main remain valid.
        NSMutableArray *expected = [desired.displays mutableCopy];
        for (NSDictionary *item in current) if ([item[@"displayID"] unsignedIntValue] == displayID) [expected addObject:item];
        if (![self identitiesOf:current match:expected error:error]) return NO;
        if (attempt == 29) return YMFail(error, 29, @"The removed virtual display is still online; recovery could not be verified.");
        [self.backend waitForNextObservation];
    }
    NSDictionary *byID = [self index:current error:error];
    if (!byID || ![self identitiesOf:current match:desired.displays error:error]) return NO;
    for (NSDictionary *item in desired.displays) {
        if (![snapshot.recoverableMirrorIDs containsObject:item[@"displayID"]]
            && !YMKeysEqual(item, byID[item[@"displayID"]], @[@"mirrorOf", @"inMirrorSet"]))
            snapshot.readOnlyRecovery = YES;
    }
    if (snapshot.readOnlyRecovery) {
        if ([self verifyExpected:desired.displays error:NULL]) return YES;
        return YMFail(error, 30, @"Another display setting changed. Automatic recovery has been stopped to preserve that change; restore the intended layout in System Settings.");
    }
    return [self apply:desired.displays from:current newDisplayID:0 error:error];
}

- (BOOL)verifySnapshot:(YMDisplayTopologySnapshot *)snapshot error:(NSError **)error {
    self.modeRetriesRemaining = 50;
    return [self index:snapshot.displays error:error] && [self verifyExpected:snapshot.displays error:error];
}

- (BOOL)positionOwnedDisplays:(NSDictionary<NSNumber *, NSDictionary *> *)origins
                     baseline:(YMDisplayTopologySnapshot *)baseline error:(NSError **)error {
    self.modeRetriesRemaining = 50;
    NSDictionary *byID = [self index:baseline.displays error:error];
    if (!byID || !origins.count || baseline.readOnlyRecovery)
        return YMFail(error, 32, @"A stable display baseline is required before restoring workspace positions.");
    NSMutableArray *expected = [NSMutableArray array];
    for (NSNumber *ident in origins) {
        NSDictionary *screen = byID[ident], *origin = origins[ident];
        double x = [origin[@"x"] doubleValue], y = [origin[@"y"] doubleValue];
        if (!screen || [screen[@"main"] boolValue] || [screen[@"inMirrorSet"] boolValue]
            || ![screen[@"active"] boolValue] || !origin[@"x"] || !origin[@"y"]
            || !isfinite(x) || !isfinite(y) || x != trunc(x) || y != trunc(y)
            || x < INT32_MIN || x > INT32_MAX || y < INT32_MIN || y > INT32_MAX)
            return YMFail(error, 33, @"The saved virtual screen position cannot be restored safely.");
    }
    for (NSDictionary *screen in baseline.displays) {
        NSMutableDictionary *target = screen.mutableCopy;
        NSDictionary *origin = origins[screen[@"displayID"]];
        if (origin) { target[@"x"] = origin[@"x"]; target[@"y"] = origin[@"y"]; }
        [expected addObject:target];
    }
    // A journal cannot authorize undoing any change made after this baseline.
    NSArray *current = [self readCompleteDisplaysWithGuard:^BOOL(NSArray *items, NSError **guardError) {
        return [self identitiesOf:items match:baseline.displays error:guardError];
    } error:error];
    if (!current || ![self statesOf:current match:baseline.displays])
        return YMFail(error, 34, @"The display layout changed during workspace restoration; no positions were written.");
    return [self apply:expected from:current newDisplayID:0 error:error];
}

- (BOOL)isExtendedTarget:(CGDirectDisplayID)displayID width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI {
    NSUInteger generation = self.backend.reconfigurationGeneration;
    NSArray *items = [self.backend readDisplaysWithError:NULL];
    if (!items || ![self index:items error:NULL]) return NO;
    NSDictionary *target = nil;
    for (NSDictionary *item in items) {
        if ([item[@"mirrorOf"] unsignedIntValue] == displayID) return NO;
        if ([item[@"displayID"] unsignedIntValue] == displayID) target = item;
    }
    return target && [target[@"active"] boolValue] && ![target[@"mirrorOf"] unsignedIntValue]
        && ![target[@"inMirrorSet"] boolValue] && [target[@"rotation"] doubleValue] == 0 && YMHasRequestedMode(target, width, height, hiDPI)
        && [target[@"logicalWidth"] unsignedIntegerValue] == width
        && [target[@"logicalHeight"] unsignedIntegerValue] == height
        && generation == self.backend.reconfigurationGeneration;
}
@end
