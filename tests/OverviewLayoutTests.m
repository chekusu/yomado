#import <AppKit/AppKit.h>

// Builds the production control panel in preview mode with synthetic display
// snapshots, so the overview's real card sizing is measured. Requires a macOS
// WindowServer session; the hidden window is never ordered front and no
// display, application window or input is read or changed.
#define main YMIgnoredApplicationMain
#import "Yomado.m"
#undef main

static NSUInteger scenarios;

static NSDictionary *Display(uint32_t identifier, double x, double width, double height, BOOL virtualDisplay) {
    return @{@"displayID":@(identifier), @"name":[NSString stringWithFormat:@"Screen %u", identifier],
             @"x":@(x), @"y":@0, @"logicalWidth":@(width), @"logicalHeight":@(height),
             @"isMain":@(identifier == 1), @"isVirtual":@(virtualDisplay), @"isActive":@YES, @"isOnline":@YES};
}

static NSArray<NSDictionary *> *TwoMixed(void) {
    return @[Display(1, 0, 1920, 1080, NO), Display(2, 1920, 1470, 956, NO)];
}
static NSArray<NSDictionary *> *TwoEqual(void) {
    return @[Display(1, 0, 2560, 1440, NO), Display(2, 2560, 2560, 1440, NO)];
}
static NSArray<NSDictionary *> *ThreeMixed(void) {
    return [TwoMixed() arrayByAddingObject:Display(3, 3390, 1920, 1080, YES)];
}
static NSArray<NSDictionary *> *One(void) {
    return @[Display(1, 0, 1920, 1080, NO)];
}

static ADController *Panel(NSArray<NSDictionary *> *snapshot, NSScrollerStyle style, BOOL statusRow) {
    ADController *controller = [[ADController alloc] init];
    controller.previewMode = YES;
    controller.previewState = @"running";
    controller.previewSnapshot = snapshot;
    [controller buildWindow];
    if (!NSEqualSizes(controller.window.contentMinSize, NSMakeSize(760, 520))) {
        fprintf(stderr, "FAIL: profile-management panel minimum content size changed\n");
        exit(1);
    }
    controller.applicationCards.enclosingScrollView.scrollerStyle = style;
    [controller updateInventory];
    controller.updateStatusLabel.stringValue = statusRow ? @"已是最新版本" : @"";
    controller.updateStatusRow.hidden = !statusRow;
    return controller;
}

static void Settle(ADController *controller, NSSize content) {
    [controller.window setContentSize:content];
    for (NSUInteger pass = 0; pass < 3; pass++) {
        [controller.window.contentView layoutSubtreeIfNeeded];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

static void CheckWindowKept(NSString *scenario, ADController *controller, NSSize content) {
    if (controller.window.visible || NSApp.activationPolicy != NSApplicationActivationPolicyProhibited) {
        fprintf(stderr, "FAIL %s: fixture must remain hidden and non-activating\n", scenario.UTF8String);
        exit(1);
    }
    // Cards must shrink to the board, or the board scroll; enlarging the window
    // would hide the overflow and act as a hidden minimum size.
    NSSize window = controller.window.contentView.frame.size;
    if (fabs(window.width - content.width) > 0.5 || fabs(window.height - content.height) > 0.5) {
        fprintf(stderr, "FAIL %s: window content %s, expected %s\n", scenario.UTF8String,
                NSStringFromSize(window).UTF8String, NSStringFromSize(content).UTF8String);
        exit(1);
    }
}

static void CheckFits(NSString *scenario, ADController *controller, NSArray<NSDictionary *> *snapshot, NSSize content) {
    CheckWindowKept(scenario, controller, content);
    NSScrollView *board = controller.applicationCards.enclosingScrollView;
    NSSize clip = board.contentView.bounds.size, document = controller.applicationCards.frame.size;
    // A card overflowing the board shows a scroller; a later layout can keep the
    // document wider than a clip view narrowed by a legacy vertical scroller.
    BOOL fits = fabs(document.width - clip.width) <= 1 && fabs(document.height - clip.height) <= 1;
    // Only the board may take the panel's spare height.
    BOOL ambiguous = board.hasAmbiguousLayout;
    for (NSView *row in board.superview.subviews) ambiguous = ambiguous || row.hasAmbiguousLayout;
    BOOL scrollers = !board.verticalScroller.isHidden || !board.horizontalScroller.isHidden;
    double scale = -1;
    BOOL proportional = YES;
    for (NSDictionary *item in snapshot) {
        YMAppWorkspaceView *tile = controller.workspaceViews[item[@"displayID"]];
        double width = [item[@"logicalWidth"] doubleValue], height = [item[@"logicalHeight"] doubleValue];
        if (!tile) { proportional = NO; break; }
        ambiguous = ambiguous || tile.hasAmbiguousLayout;
        // AppKit may round a frame by one point at these proportional widths.
        if (fabs(tile.frame.size.height - tile.frame.size.width * height / width) > 1) proportional = NO;
        if (scale < 0) scale = tile.frame.size.width / width;
        else if (fabs(tile.frame.size.width - scale * width) > 1) proportional = NO;
    }
    if (!fits || scrollers || !proportional || ambiguous) {
        fprintf(stderr, "FAIL %s: clip=%s document=%s verticalScroller=%d horizontalScroller=%d proportional=%d ambiguous=%d\n",
                scenario.UTF8String, NSStringFromSize(clip).UTF8String, NSStringFromSize(document).UTF8String,
                !board.verticalScroller.isHidden, !board.horizontalScroller.isHidden, proportional, ambiguous);
        for (NSDictionary *item in snapshot)
            fprintf(stderr, "    tile %s %s\n", [item[@"name"] UTF8String],
                    NSStringFromRect(controller.workspaceViews[item[@"displayID"]].frame).UTF8String);
        exit(1);
    }
    scenarios++;
    printf("PASS %s: %lu proportional tiles fit without scrollers\n", scenario.UTF8String, (unsigned long)snapshot.count);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSDictionary<NSString *, NSArray *> *layouts = @{@"one":One(), @"two mixed":TwoMixed(), @"two equal":TwoEqual(), @"three mixed":ThreeMixed()};
        // At the minimum window the 140 pt card width can exceed the board; the
        // board may scroll then, but the window must keep its size.
        NSDictionary<NSString *, NSArray *> *tight = @{
            @"one portrait":@[Display(1, 0, 1080, 1920, NO)],
            @"portrait and landscape":@[Display(1, 0, 1080, 1920, NO), Display(2, 1080, 1920, 1080, NO)],
            @"small virtual":@[Display(1, 0, 1920, 1080, NO), Display(2, 1920, 640, 480, YES)]};
        NSArray<NSValue *> *sizes = @[[NSValue valueWithSize:NSMakeSize(1000, 620)], [NSValue valueWithSize:NSMakeSize(760, 520)]];
        for (NSNumber *style in @[@(NSScrollerStyleOverlay), @(NSScrollerStyleLegacy)]) {
            NSString *styleName = style.integerValue == NSScrollerStyleLegacy ? @"legacy" : @"overlay";
            for (NSString *name in [layouts.allKeys sortedArrayUsingSelector:@selector(compare:)])
                for (NSValue *size in sizes)
                    for (NSNumber *statusRow in @[@NO, @YES]) {
                        ADController *controller = Panel(layouts[name], style.integerValue, statusRow.boolValue);
                        Settle(controller, size.sizeValue);
                        CheckFits([NSString stringWithFormat:@"%@ %@ %@%@", name, styleName, NSStringFromSize(size.sizeValue),
                                   statusRow.boolValue ? @" status" : @""], controller, layouts[name], size.sizeValue);
                        [controller.window close];
                    }

            for (NSValue *size in sizes) {
                ADController *controller = Panel(ThreeMixed(), style.integerValue, YES);
                YMManagedDisplay *saved = [controller newProfileWithOrdinal:1 name:@"Saved screen" width:1920 height:1080 hiDPI:NO];
                controller.displayProfiles = [NSMutableArray arrayWithObject:saved];
                [controller updateInventory];
                Settle(controller, size.sizeValue);
                if (controller.savedProfilesView.hidden) {
                    fprintf(stderr, "FAIL: saved-profile integration case must show its list\n");
                    exit(1);
                }
                CheckFits([NSString stringWithFormat:@"three mixed with saved list %@ %@", styleName, NSStringFromSize(size.sizeValue)],
                          controller, ThreeMixed(), size.sizeValue);
                [controller.window close];
            }

            for (NSString *name in [tight.allKeys sortedArrayUsingSelector:@selector(compare:)])
                for (NSNumber *statusRow in @[@NO, @YES]) {
                    ADController *controller = Panel(tight[name], style.integerValue, statusRow.boolValue);
                    Settle(controller, NSMakeSize(760, 520));
                    NSString *scenario = [NSString stringWithFormat:@"%@ %@ minimum%@", name, styleName, statusRow.boolValue ? @" status" : @""];
                    CheckWindowKept(scenario, controller, NSMakeSize(760, 520));
                    scenarios++;
                    printf("PASS %s: window keeps its size\n", scenario.UTF8String);
                    [controller.window close];
                }

            // Closing a virtual display rebuilds the cards while the board keeps its scroll state.
            ADController *controller = Panel(ThreeMixed(), style.integerValue, YES);
            Settle(controller, NSMakeSize(1000, 620));
            controller.previewSnapshot = TwoMixed();
            [controller updateInventory];
            Settle(controller, NSMakeSize(1000, 620));
            CheckFits([NSString stringWithFormat:@"three to two %@", styleName], controller, TwoMixed(), NSMakeSize(1000, 620));
            controller.previewSnapshot = ThreeMixed();
            [controller updateInventory];
            Settle(controller, NSMakeSize(1000, 620));
            CheckFits([NSString stringWithFormat:@"two to three %@", styleName], controller, ThreeMixed(), NSMakeSize(1000, 620));
            [controller.window close];
        }
        printf("Passed %lu overview layout scenarios using a hidden preview panel; no displays or application windows were read or moved.\n",
               (unsigned long)scenarios);
        return 0;
    }
}
