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
        Check([YMWorkspaceUnmovableSummary(@[@{@"appName": @"Marvelous Designer", @"count": @1}, @{@"appName": @"文本编辑", @"count": @2},
            @{@"appName": @"文本编辑", @"count": @1}]) isEqualToString:@"「Marvelous Designer」1 个窗口、「文本编辑」3 个窗口"], @"unmovable windows are merged per app in first-seen order");
        Check([YMWorkspaceUnmovableSummary(@[@{@"appName": @"Mail", @"count": @0}, @{@"count": @"2"}, (NSDictionary *)(id)@"bad"]) isEqualToString:@""], @"zero or malformed counts produce no prompt");
        Check([YMWorkspaceUnmovableSummary(@[@{@"appName": @"", @"count": @2}]) isEqualToString:@"「应用」2 个窗口"], @"missing app name uses a generic label");
        if (failures) { fprintf(stderr, "%lu of %lu checks failed.\n", (unsigned long)failures, (unsigned long)checks); return 1; }
        printf("Passed %lu App workspace policy checks; no displays, applications or GUI were accessed.\n", (unsigned long)checks);
        return 0;
    }
}
