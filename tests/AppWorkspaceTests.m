#import <Foundation/Foundation.h>
#import "AppWorkspacePolicy.h"
#include <stdio.h>

static NSUInteger checks, failures;
static void Check(BOOL condition, NSString *description) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL: %s\n", description.UTF8String); }
}
static NSDictionary *Frame(double x, double y, double width, double height) {
    return @{@"x": @(x), @"y": @(y), @"width": @(width), @"height": @(height)};
}
static NSDictionary *Display(unsigned int ID, double x, BOOL virtualDisplay, BOOL main, NSString *uuid) {
    return @{@"displayID": @(ID), @"displayUUID": uuid, @"bounds": Frame(x, 0, 1920, 1080),
        @"isActive": @YES, @"isOnline": @YES, @"isVirtual": @(virtualDisplay), @"isMain": @(main)};
}
static NSDictionary *First(NSArray *items) {
    return [items isKindOfClass:NSArray.class] && items.count ? items[0] : nil;
}
int main(void) {
    @autoreleasepool {
        NSDictionary *left = Display(3, -1920, NO, NO, @"left");
        NSDictionary *main = Display(5, 0, NO, YES, @"main");
        NSDictionary *agentA = Display(8, 1920, YES, NO, @"agent-a");
        NSDictionary *agentB = Display(9, 3840, YES, NO, @"agent-b");
        NSArray *displays = @[left, main, agentA, agentB];
        Check(!YMWorkspaceGeometry(Frame(NAN, 0, 10, 10)), @"NaN geometry is rejected");
        Check(!YMWorkspaceGeometry(Frame(0, INFINITY, 10, 10)), @"infinite geometry is rejected");
        Check(!YMWorkspaceGeometry(Frame(0, 0, 0, 10)), @"zero width is rejected");
        Check(!YMWorkspaceGeometry(@{@"x": @"0", @"y": @0, @"width": @100, @"height": @100}), @"numeric strings are rejected");
        Check(YMWorkspaceVisibleOrdinaryGeometry(Frame(0, 32, 400, 200), 0, YES, 1), @"normal visible window qualifies");
        Check(!YMWorkspaceVisibleOrdinaryGeometry(Frame(0, 0, 1920, 30), 0, YES, 1), @"menu-bar ghost is excluded");
        Check(!YMWorkspaceVisibleOrdinaryGeometry(Frame(0, 0, 400, 200), 1, YES, 1), @"floating layer is excluded");
        Check(!YMWorkspaceVisibleOrdinaryGeometry(Frame(0, 0, 400, 200), 0, NO, 1), @"hidden window is excluded");
        Check(!YMWorkspaceVisibleOrdinaryGeometry(Frame(0, 0, 400, 200), 0, YES, 0), @"transparent window is excluded");
        Check([YMWorkspaceDisplayForFrame(Frame(-1700, 50, 400, 200), displays) isEqual:left], @"negative-origin physical display is identified");
        Check([YMWorkspaceDisplayForFrame(Frame(2100, 50, 400, 200), displays) isEqual:agentA], @"first agent workspace is identified");
        Check([YMWorkspaceDisplayForFrame(Frame(4000, 50, 400, 200), displays) isEqual:agentB], @"second agent workspace is identified");
        Check([YMWorkspaceDisplayForFrame(Frame(1800, 50, 200, 200), displays) isEqual:main], @"small virtual edge overlap stays physical");
        Check([YMWorkspaceDisplayForFrame(Frame(1820, 50, 200, 200), displays) isEqual:main], @"physical and virtual exact tie favors physical");
        Check([YMWorkspaceDisplayForFrame(Frame(1820, 50, 200, 200), @[agentA, main]) isEqual:main], @"physical tie is independent of enumeration order");
        Check([YMWorkspaceDisplayForFrame(Frame(3740, 50, 200, 200), @[agentB, agentA]) isEqual:agentA], @"virtual tie uses stable smaller display ID");
        Check(!YMWorkspaceDisplayForFrame(Frame(9000, 0, 400, 200), displays), @"off-desktop window has no owner");
        NSMutableDictionary *offline = [agentA mutableCopy]; offline[@"isOnline"] = @NO;
        Check(!YMWorkspaceDisplayForFrame(Frame(2100, 50, 400, 200), @[offline]), @"offline screen cannot own a window");
        NSDictionary *origin = YMWorkspaceOrigin(Frame(-1700, 80, 700, 500), left);
        Check([origin[@"relative"] isEqual:Frame(220, 80, 700, 500)], @"origin stores relative physical geometry");
        Check(!YMWorkspaceOrigin(Frame(2100, 80, 700, 500), agentA), @"virtual-to-virtual transfer cannot invent physical checkpoint");
        Check([YMWorkspacePhysicalDisplay(@"left", displays) isEqual:left], @"original physical display selected by identity");
        Check([YMWorkspacePhysicalDisplay(@"missing", displays) isEqual:main], @"missing physical display falls back to physical main");
        Check([YMWorkspacePhysicalDisplay(nil, @[agentA, left, agentB]) isEqual:left], @"virtual main never used as return destination");
        Check(!YMWorkspacePhysicalDisplay(nil, @[agentA, agentB]), @"no physical display means no safe return");
        NSDictionary *restored = YMWorkspaceFrameOnDisplay(origin[@"relative"], origin[@"relative"], left);
        Check([restored isEqual:Frame(-1700, 80, 700, 500)], @"restore reconstructs original negative-screen coordinates");
        NSDictionary *centered = YMWorkspaceFrameOnDisplay(Frame(2300, 100, 800, 600), nil, main);
        Check([centered isEqual:Frame(560, 256, 800, 600)], @"manually dragged window falls back to physical main center");
        NSDictionary *clamped = YMWorkspaceFrameOnDisplay(Frame(0, 0, 4000, 3000), Frame(-100, -500, 4000, 3000), main);
        Check([clamped isEqual:Frame(0, 32, 1920, 1048)], @"oversized window clamps beneath menu bar");
        Check(YMWorkspaceFrameFits(clamped, main), @"clamped geometry passes complete-frame verification");
        Check(!YMWorkspaceFrameFits(Frame(1800, 32, 800, 600), main), @"window straddling display fails complete-frame verification");
        Check(!YMWorkspaceFrameFits(Frame(0, 0, 800, 600), main), @"window above reachable titlebar margin fails verification");
        Check(YMWorkspaceSameFrame(Frame(1, 2, 800, 600), Frame(3, 4, 802, 602)), @"small window-server rounding is tolerated");
        Check(!YMWorkspaceSameFrame(Frame(1, 2, 800, 600), Frame(5, 2, 800, 600)), @"moved window invalidates preflight frame");
        Check(YMWorkspaceGenericMutationAllowed(@"org.blenderfoundation.blender"), @"generic Blender move is allowed");
        Check(!YMWorkspaceGenericMutationAllowed(@"com.tencent.xinWeChat"), @"WeChat move delegates to safety recovery");
        Check(YMWorkspaceGenericRestoreAllowed(@"com.tencent.xinWeChat"), @"manual WeChat ordinary-window return is allowed");
        Check(!YMWorkspaceGenericMutationAllowed(@"dev.chekusu.yomado"), @"controller cannot move itself through generic drop");
        Check(!YMWorkspaceGenericRestoreAllowed(@""), @"empty application identity is rejected");
        NSDictionary *physicalWindow = @{@"displayID": @5, @"isVirtual": @NO};
        NSDictionary *agentWindowA = @{@"displayID": @8, @"isVirtual": @YES};
        NSDictionary *agentWindowB = @{@"displayID": @9, @"isVirtual": @YES};
        Check(YMWorkspaceMatchesSource(physicalWindow, nil) && YMWorkspaceMatchesSource(agentWindowB, nil), @"external whole-app drop includes all source screens");
        Check(YMWorkspaceMatchesSource(physicalWindow, @0), @"physical card selects physical windows");
        Check(!YMWorkspaceMatchesSource(agentWindowA, @0), @"physical card cannot sweep virtual workspace");
        Check(YMWorkspaceMatchesSource(agentWindowA, @8), @"workspace card selects its own windows");
        Check(!YMWorkspaceMatchesSource(physicalWindow, @8), @"workspace transfer leaves user physical windows untouched");
        Check(!YMWorkspaceMatchesSource(agentWindowB, @8), @"workspace transfer leaves another agent workspace untouched");
        Check(!YMWorkspaceMatchesSource(@{}, @0), @"unknown geometry ownership is not interpreted as physical");
        Check([YMWorkspaceFrameForExplicitPhysicalReturn(origin, Frame(2100, 50, 700, 500), left) isEqual:Frame(-1700, 80, 700, 500)], @"explicit original physical target restores its recorded position");
        Check([YMWorkspaceFrameForExplicitPhysicalReturn(origin, Frame(2100, 50, 700, 500), main) isEqual:Frame(610, 306, 700, 500)], @"different requested physical target centers rather than reusing old offsets");
        Check([YMWorkspaceFrameForExplicitPhysicalReturn(nil, Frame(2100, 50, 800, 600), left) isEqual:Frame(-1360, 256, 800, 600)], @"manual entry returns to requested negative-origin physical screen");
        Check(!YMWorkspaceFrameForExplicitPhysicalReturn(origin, Frame(2100, 50, 700, 500), agentA), @"explicit physical return rejects virtual targets");
        NSMutableDictionary *offlinePhysical = [main mutableCopy]; offlinePhysical[@"isActive"] = @NO;
        Check(!YMWorkspaceFrameForExplicitPhysicalReturn(origin, Frame(2100, 50, 700, 500), offlinePhysical), @"unavailable requested screen is not silently substituted");
        NSMutableDictionary *dockScreen = [main mutableCopy]; dockScreen[@"visibleBounds"] = Frame(56, 24, 1864, 980);
        Check([YMWorkspaceFrameForExplicitPhysicalReturn(nil, Frame(2100, 50, 800, 600), dockScreen) isEqual:Frame(588, 214, 800, 600)], @"manual return centers inside actual Dock and menu-bar excluded area");
        NSDictionary *edgeOrigin = YMWorkspaceOrigin(Frame(0, 0, 1800, 1000), main);
        Check([YMWorkspaceFrameForExplicitPhysicalReturn(edgeOrigin, Frame(2100, 50, 800, 600), dockScreen) isEqual:Frame(56, 24, 1800, 980)], @"remembered window is clamped inside the current visible area");
        Check(!YMWorkspaceFrameFits(Frame(0, 32, 800, 600), dockScreen), @"observed window behind side Dock cannot pass position verification");
        NSMutableDictionary *invalidVisible = [main mutableCopy]; invalidVisible[@"visibleBounds"] = Frame(-100, 0, 1920, 1080);
        Check([YMWorkspaceUsablePlacementBounds(invalidVisible) isEqual:Frame(0, 32, 1920, 1048)], @"out-of-display visible area falls back to safe display geometry");
        Check(!YMWorkspaceOriginBelongsToDisplay(@{@"displayUUID": @"", @"relative": Frame(0, 0, 100, 100)}, @{@"displayUUID": @""}), @"missing stable display identities never claim same original screen");
        NSDictionary *calculatorPhysical = Frame(830, 675, 230, 408);
        NSDictionary *calculatorVirtual = Frame(3405, 352, 230, 408);
        Check(!YMWorkspacePhysicalReturnConfirmed(calculatorPhysical, calculatorVirtual, displays, NO), @"regression: delayed physical CG snapshot cannot discard a successful virtual AX move checkpoint");
        Check(!YMWorkspacePhysicalReturnConfirmed(calculatorPhysical, nil, displays, NO), @"inaccessible AX geometry preserves original placement");
        Check(!YMWorkspacePhysicalReturnConfirmed(nil, calculatorPhysical, displays, NO), @"missing CG geometry preserves original placement");
        Check(!YMWorkspacePhysicalReturnConfirmed(calculatorVirtual, calculatorVirtual, displays, NO), @"matching virtual observations retain original placement");
        Check(YMWorkspacePhysicalReturnConfirmed(calculatorPhysical, calculatorPhysical, displays, NO), @"matching physical CG and AX observations confirm a manual return");
        Check(!YMWorkspacePhysicalReturnConfirmed(calculatorPhysical, calculatorPhysical, displays, YES), @"in-progress mutation never retires its own checkpoint");
        Check(!YMWorkspacePhysicalReturnConfirmed(calculatorPhysical, Frame(900, 675, 230, 408), displays, NO), @"disagreeing physical positions preserve placement while observations settle");

        NSDictionary *identity = @{@"pid": @42, @"windowID": @1490,
            @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"};
        NSDictionary *cg = @{@"pid": @42, @"windowID": @1490,
            @"frame": Frame(15, 982, 37, 102), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *ax = @{@"identity": identity, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *result = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[ax], YES, displays);
        Check([result[@"windows"] count] == 1, @"small Stage Manager thumbnail keeps its real window");
        Check([First(result[@"windows"])[@"frame"] isEqual:ax[@"frame"]], @"use AX geometry only after exact identity");
        Check([First(result[@"windows"])[@"cgFrame"] isEqual:cg[@"frame"]], @"retain independent raw CG geometry");
        Check(YMWorkspaceSnapshotAllowsSource(result, @5), @"real source screen remains eligible");

        NSDictionary *largeCG = @{@"pid": @42, @"windowID": @1490,
            @"frame": Frame(15, 982, 150, 120), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *largeResult = YMWorkspaceNormalizeWindowSnapshot(@[largeCG], @[ax], YES, displays);
        Check([largeResult[@"windows"] count] == 1, @"larger Stage Manager thumbnail still joins by identity");
        Check([First(largeResult[@"windows"])[@"frame"] isEqual:ax[@"frame"]], @"larger thumbnail still uses AX geometry");

        NSDictionary *identityB = @{@"pid": @42, @"windowID": @1491,
            @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"};
        NSDictionary *cgB = @{@"pid": @42, @"windowID": @1491,
            @"frame": Frame(200, 200, 230, 408), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *axB = @{@"identity": identityB, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *sameFrame = YMWorkspaceNormalizeWindowSnapshot(@[cg, cgB], @[ax, axB], YES, displays);
        Check([sameFrame[@"windows"] count] == 2, @"identical real frames with different window IDs stay distinct");
        BOOL found1490 = NO, found1491 = NO, crossed = NO;
        for (NSDictionary *window in sameFrame[@"windows"]) {
            if ([window[@"windowID"] unsignedIntValue] == 1490 && [window[@"identity"] isEqual:identity]) found1490 = YES;
            if ([window[@"windowID"] unsignedIntValue] == 1491 && [window[@"identity"] isEqual:identityB]) found1491 = YES;
            if ([window[@"windowID"] unsignedIntValue] == 1490 && [window[@"identity"] isEqual:identityB]) crossed = YES;
            if ([window[@"windowID"] unsignedIntValue] == 1491 && [window[@"identity"] isEqual:identity]) crossed = YES;
        }
        Check(found1490 && found1491, @"each identical-frame window keeps its own identity");
        Check(!crossed, @"never bind by array position or identical frame");

        NSDictionary *dupCG = YMWorkspaceNormalizeWindowSnapshot(@[cg, cg], @[ax], YES, displays);
        Check([dupCG[@"windows"] count] == 0 && [dupCG[@"blockers"] count] > 0, @"duplicate CG key becomes blocker");
        Check(!YMWorkspaceSnapshotAllowsSource(dupCG, @5), @"duplicate CG key refuses every source");
        NSDictionary *dupAX = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[ax, ax], YES, displays);
        Check([dupAX[@"windows"] count] == 0 && [dupAX[@"blockers"] count] > 0, @"duplicate AX key becomes blocker");
        Check(!YMWorkspaceSnapshotAllowsSource(dupAX, nil), @"duplicate AX key refuses whole-app drop");
        NSDictionary *otherPID = @{@"pid": @99, @"windowID": @1490,
            @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.other"};
        NSDictionary *cgOther = @{@"pid": @99, @"windowID": @1490,
            @"frame": Frame(100, 100, 200, 200), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *axOther = @{@"identity": otherPID, @"frame": Frame(100, 100, 200, 200),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *crossPID = YMWorkspaceNormalizeWindowSnapshot(@[cg, cgOther], @[ax, axOther], YES, displays);
        Check([crossPID[@"blockers"] count] > 0, @"same window ID under different PIDs is a blocker");
        Check(!YMWorkspaceSnapshotAllowsSource(crossPID, @5), @"cross-PID window ID collision closes sources");

        Check(YMWorkspaceSameWindowIdentity(identity, identity), @"identical five-field identities match");
        NSMutableDictionary *changedStart = [identity mutableCopy];
        changedStart[@"startSeconds"] = @1001;
        Check(!YMWorkspaceSameWindowIdentity(identity, changedStart), @"changed startSeconds cannot inherit origin");
        NSMutableDictionary *changedMicros = [identity mutableCopy];
        changedMicros[@"startMicroseconds"] = @8;
        Check(!YMWorkspaceSameWindowIdentity(identity, changedMicros), @"changed startMicroseconds cannot inherit origin");
        Check(!YMWorkspaceSameWindowIdentity(identity, nil), @"nil identity is never equal");
        Check(!YMWorkspaceSameWindowIdentity(identity, @{@"pid": @42, @"windowID": @1490}), @"partial identity is never equal");
        Check(!YMWorkspaceSameWindowIdentity(
            @{@"pid": @0, @"windowID": @1490, @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"},
            @{@"pid": @0, @"windowID": @1490, @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"}),
            @"zero PID identities are invalid");
        Check(!YMWorkspaceSameWindowIdentity(
            @{@"pid": @42, @"windowID": @(-1), @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"},
            @{@"pid": @42, @"windowID": @(-1), @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"}),
            @"negative window ID identities are invalid");

        NSDictionary *axOnAgent = @{@"identity": identity, @"frame": Frame(2100, 50, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *owned = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[axOnAgent], YES, displays);
        Check([owned[@"windows"] count] == 1, @"thumbnail on physical edge still joins real AX window");
        Check([First(owned[@"windows"])[@"displayID"] isEqual:@8], @"ownership uses AX geometry on agent workspace");
        Check([First(owned[@"windows"])[@"isVirtual"] boolValue], @"AX-owned agent window is virtual");
        Check(!YMWorkspaceMatchesSource(First(owned[@"windows"]), @5), @"physical source cannot collect agent-owned window");
        Check(!YMWorkspaceMatchesSource(First(owned[@"windows"]), @0), @"physical card cannot collect agent-owned window");

        NSDictionary *axOnly = @{@"identity": identityB, @"frame": Frame(400, 400, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *spaceIsolated = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[ax, axOnly], YES, displays);
        Check([spaceIsolated[@"windows"] count] == 1, @"AX window absent from CG visibility stays out of result");
        Check([First(spaceIsolated[@"windows"])[@"windowID"] isEqual:@1490], @"only the CG-visible identity is retained");

        NSDictionary *offscreen = @{@"pid": @42, @"windowID": @1490,
            @"frame": Frame(15, 982, 37, 102), @"layer": @0, @"onScreen": @NO, @"alpha": @1};
        Check([YMWorkspaceNormalizeWindowSnapshot(@[offscreen], @[ax], YES, displays)[@"windows"] count] == 0,
            @"off-screen CG surface is not movable");
        NSDictionary *transparent = @{@"pid": @42, @"windowID": @1490,
            @"frame": Frame(15, 982, 37, 102), @"layer": @0, @"onScreen": @YES, @"alpha": @0};
        Check([YMWorkspaceNormalizeWindowSnapshot(@[transparent], @[ax], YES, displays)[@"windows"] count] == 0,
            @"transparent CG surface is not movable");
        NSDictionary *floating = @{@"pid": @42, @"windowID": @1490,
            @"frame": Frame(15, 982, 37, 102), @"layer": @1, @"onScreen": @YES, @"alpha": @1};
        Check([YMWorkspaceNormalizeWindowSnapshot(@[floating], @[ax], YES, displays)[@"windows"] count] == 0,
            @"non-zero layer CG surface is not movable");

        NSDictionary *minimizedAX = @{@"identity": identity, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @YES, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *minimized = YMWorkspaceNormalizeWindowSnapshot(
            @[@{@"pid": @42, @"windowID": @1490, @"frame": Frame(100, 100, 230, 408),
                @"layer": @0, @"onScreen": @YES, @"alpha": @1}], @[minimizedAX], YES, displays);
        Check([minimized[@"windows"] count] == 0, @"minimized window is never movable");
        Check([minimized[@"blockers"] count] > 0, @"visible minimized window remains a blocker");
        NSDictionary *dialogAX = @{@"identity": identity, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *dialog = YMWorkspaceNormalizeWindowSnapshot(
            @[@{@"pid": @42, @"windowID": @1490, @"frame": Frame(100, 100, 230, 408),
                @"layer": @0, @"onScreen": @YES, @"alpha": @1}], @[dialogAX], YES, displays);
        Check([dialog[@"windows"] count] == 0, @"non-ordinary dialog is never movable");
        Check([dialog[@"blockers"] count] > 0, @"visible non-ordinary dialog remains a blocker");
        NSDictionary *thumbDialog = YMWorkspaceNormalizeWindowSnapshot(
            @[@{@"pid": @42, @"windowID": @1490, @"frame": Frame(15, 982, 37, 102),
                @"layer": @0, @"onScreen": @YES, @"alpha": @1}], @[dialogAX], YES, displays);
        Check([thumbDialog[@"windows"] count] == 0, @"Stage Manager thumbnail cannot make a large dialog movable");
        Check([thumbDialog[@"blockers"] count] > 0,
            @"CG thumbnail must not drop a large non-ordinary blocker");
        Check([First(thumbDialog[@"blockers"])[@"displayID"] isEqual:@5],
            @"large non-ordinary blocker keeps real AX source");
        NSDictionary *thumbMinimized = YMWorkspaceNormalizeWindowSnapshot(
            @[@{@"pid": @42, @"windowID": @1490, @"frame": Frame(15, 982, 37, 102),
                @"layer": @0, @"onScreen": @YES, @"alpha": @1}], @[minimizedAX], YES, displays);
        Check([thumbMinimized[@"windows"] count] == 0, @"Stage Manager thumbnail cannot make a large minimized window movable");
        Check([thumbMinimized[@"blockers"] count] > 0,
            @"CG thumbnail must not drop a large minimized blocker");
        NSDictionary *smallAuxAX = @{@"identity": identity, @"frame": Frame(15, 982, 37, 102),
            @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *smallAux = YMWorkspaceNormalizeWindowSnapshot(
            @[@{@"pid": @42, @"windowID": @1490, @"frame": Frame(15, 982, 37, 102),
                @"layer": @0, @"onScreen": @YES, @"alpha": @1}], @[smallAuxAX], YES, displays);
        Check([smallAux[@"windows"] count] == 0 && [smallAux[@"blockers"] count] == 0,
            @"small non-ordinary auxiliary surface may be excluded");
        NSDictionary *invalidAuxAX = @{@"identity": identity, @"frame": Frame(NAN, 719, 37, 102),
            @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *invalidAux = YMWorkspaceNormalizeWindowSnapshot(
            @[@{@"pid": @42, @"windowID": @1490, @"frame": Frame(15, 982, 37, 102),
                @"layer": @0, @"onScreen": @YES, @"alpha": @1}], @[invalidAuxAX], YES, displays);
        Check([invalidAux[@"windows"] count] == 0, @"invalid AX non-ordinary cannot become movable");
        Check([invalidAux[@"blockers"] count] > 0,
            @"invalid AX non-ordinary with small CG remains an unknown-source blocker");
        Check(First(invalidAux[@"blockers"])[@"displayID"] == nil,
            @"invalid AX non-ordinary blocker omits unreliable displayID");
        Check(!YMWorkspaceSnapshotAllowsSource(invalidAux, @5),
            @"invalid AX non-ordinary blocker refuses every source");

        NSDictionary *nanAX = @{@"identity": identity, @"frame": Frame(NAN, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *nanResult = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[nanAX], YES, displays);
        Check([nanResult[@"windows"] count] == 0, @"NaN AX frame cannot become movable");
        Check(![nanResult[@"complete"] boolValue] || [nanResult[@"blockers"] count] > 0,
            @"NaN AX frame fails closed rather than pretending complete emptiness");
        Check(!YMWorkspaceSnapshotAllowsSource(nanResult, @5), @"NaN AX frame refuses sources");
        NSDictionary *missingIdentity = @{@"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *noIdentity = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[missingIdentity], YES, displays);
        Check([noIdentity[@"windows"] count] == 0, @"missing identity cannot become movable");
        Check(!YMWorkspaceSnapshotAllowsSource(noIdentity, @5), @"missing identity refuses sources");
        NSDictionary *unreadableAX = @{@"identity": identity, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @NO, @"positionSettable": @YES};
        NSDictionary *unreadable = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[unreadableAX], YES, displays);
        Check([unreadable[@"windows"] count] == 0, @"unreadable AX window cannot become movable");
        Check(!YMWorkspaceSnapshotAllowsSource(unreadable, @5), @"unreadable AX window refuses sources");
        NSDictionary *incomplete = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[ax], NO, displays);
        Check([incomplete[@"windows"] count] == 0, @"incomplete enumeration yields no movable windows");
        Check(![incomplete[@"complete"] boolValue], @"incomplete enumeration is never marked complete");
        Check(!YMWorkspaceSnapshotAllowsSource(incomplete, @5), @"incomplete enumeration refuses sources");
        Check(!YMWorkspaceSnapshotAllowsSource(incomplete, nil), @"incomplete enumeration refuses whole-app drop");

        NSDictionary *blockerIdentity = @{@"pid": @42, @"windowID": @1500,
            @"startSeconds": @1000, @"startMicroseconds": @7, @"bundleID": @"test.calculator"};
        NSDictionary *blockerCG = @{@"pid": @42, @"windowID": @1500,
            @"frame": Frame(200, 200, 230, 408), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *blockerAX = @{@"identity": blockerIdentity, @"frame": Frame(2100, 50, 230, 408),
            @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *mixed = YMWorkspaceNormalizeWindowSnapshot(@[cg, blockerCG], @[ax, blockerAX], YES, displays);
        Check([mixed[@"windows"] count] == 1, @"ordinary window on source 5 remains after known other-screen blocker");
        Check([mixed[@"blockers"] count] == 1, @"known other-screen non-ordinary stays a single blocker");
        Check([First(mixed[@"blockers"])[@"displayID"] isEqual:@8], @"blocker keeps reliable real source");
        Check(YMWorkspaceSnapshotAllowsSource(mixed, @5), @"known other-screen blocker does not block unrelated source");
        Check(!YMWorkspaceSnapshotAllowsSource(mixed, @8), @"known blocker source itself is refused");
        Check(!YMWorkspaceSnapshotAllowsSource(mixed, nil), @"whole-app drop still sees the known blocker");
        Check(YMWorkspaceSnapshotAllowsSource(mixed, @0), @"physical card is unaffected by virtual blocker");

        NSDictionary *unknownBlockerAX = @{@"identity": blockerIdentity, @"frame": Frame(9000, 0, 230, 408),
            @"ordinary": @NO, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *unknown = YMWorkspaceNormalizeWindowSnapshot(@[cg, blockerCG], @[ax, unknownBlockerAX], YES, displays);
        Check([unknown[@"windows"] count] == 1, @"ordinary window remains listed beside unknown-source blocker");
        Check([unknown[@"blockers"] count] == 1, @"off-desktop non-ordinary remains a blocker");
        Check(First(unknown[@"blockers"])[@"displayID"] == nil, @"unknown blocker omits unreliable displayID");
        Check(!YMWorkspaceSnapshotAllowsSource(unknown, @5), @"unknown-source blocker refuses every source");
        Check(!YMWorkspaceSnapshotAllowsSource(unknown, @8), @"unknown-source blocker refuses agent sources");
        Check(!YMWorkspaceSnapshotAllowsSource(unknown, @0), @"unknown-source blocker refuses physical card");
        Check(!YMWorkspaceSnapshotAllowsSource(unknown, nil), @"unknown-source blocker refuses whole-app drop");

        NSDictionary *nanCG = @{@"pid": @42, @"windowID": @1490,
            @"frame": Frame(NAN, 982, 37, 102), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *nanCGResult = YMWorkspaceNormalizeWindowSnapshot(@[nanCG], @[ax], YES, displays);
        Check([nanCGResult[@"windows"] count] == 0, @"NaN CG frame cannot become movable");
        Check(![nanCGResult[@"complete"] boolValue] || [nanCGResult[@"blockers"] count] > 0,
            @"NaN CG frame fails closed rather than pretending complete emptiness");
        Check(!YMWorkspaceSnapshotAllowsSource(nanCGResult, @5), @"NaN CG frame refuses sources");
        NSDictionary *missingCGFrame = @{@"pid": @42, @"windowID": @1490,
            @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *missingCGResult = YMWorkspaceNormalizeWindowSnapshot(@[missingCGFrame], @[ax], YES, displays);
        Check([missingCGResult[@"windows"] count] == 0, @"missing CG frame cannot become movable");
        Check(!YMWorkspaceSnapshotAllowsSource(missingCGResult, @5), @"missing CG frame refuses sources");
        NSDictionary *nanCGOther = @{@"pid": @42, @"windowID": @1500,
            @"frame": Frame(NAN, 200, 230, 408), @"layer": @0, @"onScreen": @YES, @"alpha": @1};
        NSDictionary *mixedIllegalCG = YMWorkspaceNormalizeWindowSnapshot(
            @[cg, nanCGOther], @[ax], YES, displays);
        Check(!YMWorkspaceSnapshotAllowsSource(mixedIllegalCG, @5),
            @"illegal CG candidate must not let mixed snapshot authorize other windows");
        NSDictionary *offscreenOnly = YMWorkspaceNormalizeWindowSnapshot(@[offscreen], @[ax], YES, displays);
        Check([offscreenOnly[@"windows"] count] == 0 && [offscreenOnly[@"blockers"] count] == 0,
            @"explicit off-screen CG may be excluded without unknown blocker");
        Check([offscreenOnly[@"complete"] boolValue], @"explicit off-screen exclusion stays complete");
        NSDictionary *transparentOnly = YMWorkspaceNormalizeWindowSnapshot(@[transparent], @[ax], YES, displays);
        Check([transparentOnly[@"windows"] count] == 0 && [transparentOnly[@"blockers"] count] == 0,
            @"explicit transparent CG may be excluded without unknown blocker");
        NSDictionary *floatingOnly = YMWorkspaceNormalizeWindowSnapshot(@[floating], @[ax], YES, displays);
        Check([floatingOnly[@"windows"] count] == 0 && [floatingOnly[@"blockers"] count] == 0,
            @"explicit non-zero layer CG may be excluded without unknown blocker");

        NSMutableDictionary *missingMinimizedAX = [ax mutableCopy];
        [missingMinimizedAX removeObjectForKey:@"minimized"];
        NSDictionary *missingMinimized = YMWorkspaceNormalizeWindowSnapshot(
            @[cg], @[missingMinimizedAX], YES, displays);
        Check([missingMinimized[@"windows"] count] == 0, @"missing minimized state cannot become movable");
        Check([missingMinimized[@"blockers"] count] > 0 || ![missingMinimized[@"complete"] boolValue],
            @"missing minimized state fails closed");
        Check(!YMWorkspaceSnapshotAllowsSource(missingMinimized, @5), @"missing minimized state refuses sources");
        NSMutableDictionary *missingOrdinaryAX = [@{@"identity": identity, @"frame": Frame(15, 982, 37, 102),
            @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES} mutableCopy];
        NSDictionary *missingOrdinary = YMWorkspaceNormalizeWindowSnapshot(
            @[cg], @[missingOrdinaryAX], YES, displays);
        Check([missingOrdinary[@"windows"] count] == 0, @"missing ordinary state cannot become movable");
        Check([missingOrdinary[@"blockers"] count] > 0,
            @"missing ordinary on small window must not silently drop as confirmed aux");
        Check(!YMWorkspaceSnapshotAllowsSource(missingOrdinary, @5), @"missing ordinary state refuses sources");
        NSDictionary *badMinimizedAX = @{@"identity": identity, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @"no", @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *badMinimized = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[badMinimizedAX], YES, displays);
        Check([badMinimized[@"windows"] count] == 0, @"non-boolean minimized cannot become movable");
        Check(!YMWorkspaceSnapshotAllowsSource(badMinimized, @5), @"non-boolean minimized refuses sources");

        NSMutableDictionary *partialIdentity = [identity mutableCopy];
        [partialIdentity removeObjectForKey:@"startSeconds"];
        NSDictionary *partialAX = @{@"identity": partialIdentity, @"frame": Frame(830, 719, 230, 408),
            @"ordinary": @YES, @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES};
        NSDictionary *dupPartialAX = YMWorkspaceNormalizeWindowSnapshot(@[cg], @[ax, partialAX], YES, displays);
        Check([dupPartialAX[@"windows"] count] == 0, @"partial-identity AX duplicate cannot uniquely authorize");
        Check([dupPartialAX[@"blockers"] count] > 0, @"recognizable pid/windowID AX duplicate becomes blocker");
        Check(!YMWorkspaceSnapshotAllowsSource(dupPartialAX, @5),
            @"valid-plus-incomplete AX duplicate refuses sources");

        if (failures) { fprintf(stderr, "%lu of %lu checks failed.\n", (unsigned long)failures, (unsigned long)checks); return 1; }
        printf("Passed %lu App workspace policy checks; no displays, applications or GUI were accessed.\n", (unsigned long)checks);
        return 0;
    }
}
