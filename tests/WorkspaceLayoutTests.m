#import <AppKit/AppKit.h>

// Compile only the presentation component into this fixture. Importing its
// implementation gives the assertions access to the actual nested scroll views
// without exposing test-only API or launching the application controller.
// An override is useful when verifying this regression against an older source.
#ifndef YOMADO_WORKSPACE_VIEW_SOURCE
#define YOMADO_WORKSPACE_VIEW_SOURCE "AppWorkspaceView.m"
#endif
#import YOMADO_WORKSPACE_VIEW_SOURCE

static NSUInteger scenarios;

static void AppearanceRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL appearance: %s\n", message.UTF8String);
        exit(1);
    }
}

static CGFloat ColorDistance(NSColor *a, NSColor *b) {
    a = [a colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    b = [b colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return MAX(MAX(fabs(a.redComponent-b.redComponent),
                   fabs(a.greenComponent-b.greenComponent)),
                   fabs(a.blueComponent-b.blueComponent));
}

static NSBitmapImageRep *RenderScreen(YMWorkspaceScreenView *screen,
                                     NSAppearance *appearance) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.bounds
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    window.appearance = appearance;
    window.contentView = screen;
    __block NSBitmapImageRep *bitmap;
    [appearance performAsCurrentDrawingAppearance:^{
        [screen layoutSubtreeIfNeeded];
        screen.needsDisplay = YES;
        bitmap = [screen bitmapImageRepForCachingDisplayInRect:screen.bounds];
        AppearanceRequire(bitmap != nil, @"bitmap allocation");
        [screen cacheDisplayInRect:screen.bounds toBitmapImageRep:bitmap];
    }];
    window.contentView = [NSView new];
    [window close];
    return bitmap;
}

static NSColor *ScreenSample(YMWorkspaceScreenView *screen, NSAppearance *appearance) {
    NSBitmapImageRep *bitmap = RenderScreen(screen, appearance);
    return [[bitmap colorAtX:bitmap.pixelsWide/2
                          y:(NSInteger)(bitmap.pixelsHigh*0.70)]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

static void TypeRendering(void) {
    for (NSString *name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        NSAppearance *appearance = [NSAppearance appearanceNamed:name];
        for (NSUInteger highlighted=0; highlighted<2; highlighted++) {
            YMWorkspaceScreenView *screen = [[YMWorkspaceScreenView alloc]
                initWithFrame:NSMakeRect(0,0,216,122)];
            screen.name = @"Same screen";
            screen.detail = @"1920 × 1080";
            screen.highlighted = highlighted;
            screen.physical = YES;
            NSColor *physical = ScreenSample(screen, appearance);
            screen.physical = NO;
            NSColor *virtual = ScreenSample(screen, appearance);
            AppearanceRequire(ColorDistance(physical, virtual)>2.0/255,
                [NSString stringWithFormat:@"%@ highlight=%lu types must differ",
                    name, (unsigned long)highlighted]);
        }
    }
    printf("PASS appearance: rendered type separation\n");
}

static NSColor *ExpectedRGB(unsigned int value) {
    return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0
        green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:1];
}

static double LinearChannel(double v) { return v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4); }
static double RelativeLuminance(NSColor *color) {
    color=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return 0.2126*LinearChannel(color.redComponent)+0.7152*LinearChannel(color.greenComponent)+0.0722*LinearChannel(color.blueComponent);
}
static double ColorContrast(NSColor *a, NSColor *b) {
    double x=RelativeLuminance(a),y=RelativeLuminance(b);
    return (MAX(x,y)+0.05)/(MIN(x,y)+0.05);
}
static NSColor *CompositeColor(NSColor *foreground, NSColor *background) {
    NSColor *a=[foreground colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *b=[background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    double f=a.alphaComponent;
    return [NSColor colorWithSRGBRed:a.redComponent*f+b.redComponent*(1-f)
        green:a.greenComponent*f+b.greenComponent*(1-f)
        blue:a.blueComponent*f+b.blueComponent*(1-f) alpha:1];
}

static void PaletteValues(void) {
    static const unsigned int expected[2][2][3] = {
        {{0xEAF2FF,0xD7E7FC,0x7088A8}, {0xF0F1F3,0xE3E6EB,0x858E9B}},
        {{0x263C55,0x1E3149,0x657E9E}, {0x36383D,0x2E3035,0x77818F}}
    };
    for (NSUInteger dark=0; dark<2; dark++) {
        NSAppearance *appearance = [NSAppearance appearanceNamed:
            dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        [appearance performAsCurrentDrawingAppearance:^{
            for (NSUInteger physical=0; physical<2; physical++) {
                for (NSUInteger highlighted=0; highlighted<2; highlighted++) {
                    NSColor *start, *end, *border, *detail;
                    YMWorkspaceScreenPalette(dark,physical,highlighted,&start,&end,&border,&detail);
                    NSColor *a=ExpectedRGB(expected[dark][physical][0]);
                    NSColor *b=ExpectedRGB(expected[dark][physical][1]);
                    NSColor *c=ExpectedRGB(expected[dark][physical][2]);
                    if (highlighted) {
                        a=[a blendedColorWithFraction:0.08 ofColor:NSColor.controlAccentColor];
                        b=[b blendedColorWithFraction:0.12 ofColor:NSColor.controlAccentColor];
                        c=[NSColor.controlAccentColor colorWithAlphaComponent:0.90];
                    }
                    AppearanceRequire(ColorDistance(start,a)<1.0/255 && ColorDistance(end,b)<1.0/255 &&
                        ColorDistance(border,c)<1.0/255, @"palette RGB contract");
                    AppearanceRequire(fabs(start.alphaComponent-1)<0.001 && fabs(end.alphaComponent-1)<0.001 &&
                        fabs(border.alphaComponent-(highlighted ? 0.90 : 1))<0.001, @"palette alpha contract");
                    AppearanceRequire(ColorDistance(detail,NSColor.labelColor)<1.0/255 &&
                        fabs(detail.alphaComponent-(dark ? 0.65 : 0.60))<0.001, @"detail color contract");
                    NSColor *panel=[NSColor.windowBackgroundColor blendedColorWithFraction:0.035 ofColor:NSColor.labelColor];
                    AppearanceRequire(ColorContrast(CompositeColor(detail,start),start)>=4.5 &&
                                      ColorContrast(CompositeColor(detail,end),end)>=4.5,@"detail contrast");
                    if (!highlighted) {
                        NSColor *oldStart=[NSColor.controlBackgroundColor blendedColorWithFraction:0.045 ofColor:NSColor.systemBlueColor];
                        NSColor *oldEnd=[NSColor.controlBackgroundColor blendedColorWithFraction:0.10 ofColor:NSColor.systemBlueColor];
                        AppearanceRequire(ColorContrast(border,panel)>=3,@"normal border contrast");
                        AppearanceRequire(ColorContrast(start,panel)>ColorContrast(oldStart,panel) &&
                                          ColorContrast(end,panel)>ColorContrast(oldEnd,panel),@"fill contrast improvement");
                    }
                }
            }
        }];
    }
    printf("PASS appearance: exact palette values\n");
}

static void AppearanceEdgeCases(void) {
    NSAppearance *light=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSAppearance *dark=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(216,122)],
                            [NSValue valueWithSize:NSMakeSize(104,58)]]) {
        YMWorkspaceScreenView *screen=[[YMWorkspaceScreenView alloc]
            initWithFrame:(NSRect){NSZeroPoint,size.sizeValue}];
        screen.name=@"Same screen"; screen.detail=@"1920 × 1080";
        for (NSUInteger physical=0; physical<2; physical++) {
            screen.physical=physical; screen.highlighted=NO;
            NSColor *before=ScreenSample(screen,light);
            NSColor *night=ScreenSample(screen,dark);
            AppearanceRequire(ColorDistance(before,night)>0.1,@"appearance changes fill");
            AppearanceRequire(ColorDistance(before,ScreenSample(screen,light))<1.0/255,@"appearance round trip");
            for (NSAppearance *appearance in @[light,dark]) {
                NSColor *base=ScreenSample(screen,appearance);
                screen.highlighted=YES;
                AppearanceRequire(ColorDistance(base,ScreenSample(screen,appearance))>2.0/255,@"highlight changes fill");
                screen.highlighted=NO;
                AppearanceRequire(ColorDistance(base,ScreenSample(screen,appearance))<1.0/255,@"highlight round trip");
                screen.physical=!physical;
                AppearanceRequire(ColorDistance(base,ScreenSample(screen,appearance))>2.0/255,@"type changes fill");
                screen.physical=physical;
                for (NSString *name in @[@"",@"A very long display name that must truncate"]) {
                    screen.name=name;
                    AppearanceRequire(ColorDistance(base,ScreenSample(screen,appearance))<1.0/255,@"name must not change palette");
                }
            }
        }
    }
    YMAppWorkspaceView *tile=[YMAppWorkspaceView new];
    tile.displayID=7; tile.physicalDisplay=YES;
    AppearanceRequire(tile.screenView.physical,@"physical display mapping");
    tile.physicalDisplay=NO;
    AppearanceRequire(!tile.screenView.physical,@"virtual display mapping");
    tile.displayID=0;
    AppearanceRequire(tile.screenView.physical,@"zero display ID remains physical return target");
    for (NSString *name in @[NSAppearanceNameAccessibilityHighContrastAqua,
                            NSAppearanceNameAccessibilityHighContrastDarkAqua]) {
        NSAppearance *appearance=[NSAppearance appearanceNamed:name];
        NSString *match=[appearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]];
        BOOL expectsDark=[name isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua];
        AppearanceRequire([match isEqualToString:expectsDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua],
            @"high contrast appearance family");
        YMWorkspaceScreenView *screen=[[YMWorkspaceScreenView alloc] initWithFrame:NSMakeRect(0,0,216,122)];
        screen.name=@""; screen.detail=@""; screen.physical=YES;
        NSColor *physical=ScreenSample(screen,appearance);
        screen.physical=NO;
        AppearanceRequire(ColorDistance(physical,ScreenSample(screen,appearance))>2.0/255,
            @"high contrast rendered type separation");
    }
    printf("PASS appearance: state and metadata edge cases\n");
}

static NSArray<NSDictionary *> *FixtureRows(NSUInteger count) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger index = 0; index < count; index++) {
        [rows addObject:@{
            @"appName": [NSString stringWithFormat:@"Example App %lu", (unsigned long)index],
            @"bundleIdentifier": [NSString stringWithFormat:@"example.app.%lu", (unsigned long)index],
            @"windowCount": @1,
            @"pid": @1
        }];
    }
    return rows;
}

static void CheckLayout(NSString *scenario, NSScrollView *board,
                        NSArray<YMAppWorkspaceView *> *tiles) {
    [board.window.contentView layoutSubtreeIfNeeded];
    for (YMAppWorkspaceView *tile in tiles) {
        NSRect screenInDocument = [tile.screenView convertRect:tile.screenView.bounds
                                                       toView:board.documentView];
        // AppKit may round a frame by one point at these proportional widths.
        BOOL correctRatio = fabs(tile.bounds.size.height -
                                 tile.bounds.size.width / tile.displayAspectRatio) <= 1;
        // The board uses an unflipped NSStackView, so its top is maxY.
        BOOL topAligned = fabs(NSMaxY(screenInDocument) -
                               NSMaxY(board.documentView.bounds)) <= 1;
        if (tile.hasAmbiguousLayout || !correctRatio || !topAligned) {
            fprintf(stderr, "FAIL %s: tile=%u ambiguous=%d frame=%s screenInDocument=%s\n",
                    scenario.UTF8String, tile.displayID, tile.hasAmbiguousLayout,
                    NSStringFromRect(tile.frame).UTF8String,
                    NSStringFromRect(screenInDocument).UTF8String);
            exit(1);
        }
    }
    scenarios++;
    printf("PASS %s: 3 proportional tiles, unambiguous, top aligned\n", scenario.UTF8String);
}

int main(void) {
    @autoreleasepool {
        // Requires a macOS WindowServer session. This process never orders a
        // window front, activates itself, enumerates applications, creates a
        // virtual display, captures the desktop, or sends keyboard/mouse input.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        TypeRendering();
        PaletteValues();
        AppearanceEdgeCases();
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1000, 412)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered defer:YES];
        NSScrollView *board = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 18, 952, 310)];
        board.hasHorizontalScroller = YES;
        board.hasVerticalScroller = YES;
        board.autohidesScrollers = YES;
        board.drawsBackground = NO;
        [window.contentView addSubview:board];

        NSStackView *cards = [NSStackView new];
        cards.translatesAutoresizingMaskIntoConstraints = NO;
        cards.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        cards.alignment = NSLayoutAttributeTop;
        cards.distribution = NSStackViewDistributionFill;
        cards.spacing = 14;
        cards.detachesHiddenViews = YES;
        board.documentView = cards;
        NSLayoutConstraint *preferredWidth = [cards.widthAnchor constraintEqualToAnchor:board.contentView.widthAnchor];
        preferredWidth.priority = NSLayoutPriorityDefaultHigh;
        preferredWidth.active = YES;
        [NSLayoutConstraint activateConstraints:@[
            [cards.leadingAnchor constraintEqualToAnchor:board.contentView.leadingAnchor],
            [cards.topAnchor constraintEqualToAnchor:board.contentView.topAnchor],
            [cards.widthAnchor constraintGreaterThanOrEqualToAnchor:board.contentView.widthAnchor],
            [cards.heightAnchor constraintGreaterThanOrEqualToAnchor:board.contentView.heightAnchor]
        ]];

        NSMutableArray<YMAppWorkspaceView *> *tiles = [NSMutableArray array];
        for (NSUInteger index = 0; index < 3; index++) {
            YMAppWorkspaceView *tile = [YMAppWorkspaceView new];
            tile.displayID = (uint32_t)(index + 1);
            tile.physicalDisplay = index < 2;
            tile.displayName = [NSString stringWithFormat:@"Screen %lu", (unsigned long)index + 1];
            tile.displayAspectRatio = 16.0 / 9.0;
            [cards addArrangedSubview:tile];
            CGFloat fraction = (index < 2 ? 2560.0 : 1920.0) / 7040.0;
            [tile.widthAnchor constraintEqualToAnchor:cards.widthAnchor
                                           multiplier:fraction constant:-28 * fraction].active = YES;
            [tile updateRows:FixtureRows(index == 1 ? 18 : 0)
                virtualDisplayAvailable:YES accessibilityTrusted:YES];
            [tiles addObject:tile];
        }
        CheckLayout(@"initial", board, tiles);

        YMAppWorkspaceView *middle = tiles[1];
        NSRect visible = [middle.grid convertRect:middle.desktopScroll.contentView.bounds
                                         fromView:middle.desktopScroll.contentView];
        [middle.grid scrollRectToVisible:NSOffsetRect(visible, 0, -12)];
        CheckLayout(@"grid scroll up", board, tiles);
        [middle.grid scrollRectToVisible:NSOffsetRect(visible, 0, 12)];
        CheckLayout(@"grid scroll down", board, tiles);

        [middle updateRows:FixtureRows(5) virtualDisplayAvailable:YES accessibilityTrusted:YES];
        [tiles[2] updateRows:FixtureRows(1) virtualDisplayAvailable:YES accessibilityTrusted:YES];
        CheckLayout(@"after transfer rows", board, tiles);
        for (NSUInteger refresh = 0; refresh < 40; refresh++) {
            for (YMAppWorkspaceView *tile in tiles) {
                tile.displayName = tile.displayName;
                tile.displayDetail = @"2560 × 1440";
                tile.statusText = @"";
                [tile updateRows:tile.rows virtualDisplayAvailable:YES accessibilityTrusted:YES];
            }
            [window.contentView layoutSubtreeIfNeeded];
        }
        CheckLayout(@"after repeated update", board, tiles);

        for (NSUInteger step = 0; step < 10; step++) {
            NSRect boardVisible = [cards convertRect:board.contentView.bounds fromView:board.contentView];
            [cards scrollRectToVisible:NSOffsetRect(boardVisible, 0, 12)];
        }
        CheckLayout(@"outer scroll 120", board, tiles);
        for (NSUInteger pass = 0; pass < 5; pass++) {
            for (YMAppWorkspaceView *tile in tiles) [tile exerciseAmbiguityInLayout];
            CheckLayout([NSString stringWithFormat:@"exercise ambiguity %lu", (unsigned long)pass], board, tiles);
        }
        [board setFrameSize:NSMakeSize(760, 370)];
        CheckLayout(@"resize narrow taller", board, tiles);
        [board setFrameSize:NSMakeSize(1080, 300)];
        CheckLayout(@"resize wide shorter", board, tiles);
        printf("Passed %lu AppKit layout scenarios using a hidden fixture; no real application windows were read or moved.\n",
               (unsigned long)scenarios);
        return 0;
    }
}
