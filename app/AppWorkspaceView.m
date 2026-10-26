#import "AppWorkspaceView.h"
#import <math.h>
#import <QuartzCore/QuartzCore.h>

static NSPasteboardType const YMWorkspaceApplicationType = @"dev.chekusu.yomado.workspace-application";
static NSNotificationName const YMWorkspaceInteractionEndedNotification = @"YMWorkspaceInteractionEnded";
static NSUInteger YMWorkspaceInteractionDepth = 0;

static void YMWorkspaceBeginInteraction(void) { YMWorkspaceInteractionDepth++; }
static void YMWorkspaceEndInteraction(void) {
    if (!YMWorkspaceInteractionDepth) return;
    YMWorkspaceInteractionDepth--;
    if (!YMWorkspaceInteractionDepth) dispatch_async(dispatch_get_main_queue(), ^{
        if (!YMWorkspaceInteractionDepth)
            [NSNotificationCenter.defaultCenter postNotificationName:YMWorkspaceInteractionEndedNotification object:nil];
    });
}

static BOOL YMWorkspaceAutoscroll(NSView *view, id<NSDraggingInfo>sender) {
    NSScrollView *scroll = view.enclosingScrollView;
    NSView *document = scroll.documentView;
    if (!document || sender.draggingDestinationWindow != view.window) return NO;
    // Native drag updates are periodic even while the pointer rests at an edge.
    // Throttle across cards so entering the next card does not accelerate scrolling.
    static NSTimeInterval lastScrollTime = 0;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - lastScrollTime < 0.04) return NO;
    NSPoint location = sender.draggingLocation;
    NSRect visible = [document convertRect:scroll.contentView.bounds fromView:scroll.contentView];
    NSPoint point = [document convertPoint:location fromView:nil];
    if (!NSPointInRect(point, visible)) return NO;
    NSEvent *event = NSApp.currentEvent;
    BOOL currentMouseDrag = event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeRightMouseDragged ||
                            event.type == NSEventTypeOtherMouseDragged || event.type == NSEventTypeMouseMoved;
    if (currentMouseDrag && event.window == view.window &&
        hypot(event.locationInWindow.x - location.x, event.locationInWindow.y - location.y) <= 2 &&
        [document autoscroll:event]) {
        lastScrollTime = now;
        return YES;
    }
    // Finder-origin drags may not supply a current mouse event for this window.
    // Use the actual NSDraggingInfo position to scroll our own document only;
    // never synthesize or post a mouse event.
    CGFloat delta = point.y < NSMinY(visible) + 28 ? -12 : point.y > NSMaxY(visible) - 28 ? 12 : 0;
    CGFloat horizontal = point.x < NSMinX(visible) + 28 ? -12 : point.x > NSMaxX(visible) - 28 ? 12 : 0;
    if (delta == 0 && horizontal == 0) return NO;
    if ([document scrollRectToVisible:NSOffsetRect(visible, horizontal, delta)]) { lastScrollTime = now; return YES; }
    return NO;
}

static NSTextField *YMWorkspaceLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.selectable = NO;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static NSColor *YMWorkspaceSRGB(unsigned int value) {
    return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0
        green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:1];
}

static void YMWorkspaceScreenPalette(BOOL dark, BOOL physical, BOOL highlighted,
    NSColor **start, NSColor **end, NSColor **border, NSColor **detail) {
    *start = YMWorkspaceSRGB(dark ? (physical ? 0x36383D : 0x263C55)
                                  : (physical ? 0xF0F1F3 : 0xEAF2FF));
    *end = YMWorkspaceSRGB(dark ? (physical ? 0x2E3035 : 0x1E3149)
                                : (physical ? 0xE3E6EB : 0xD7E7FC));
    *border = YMWorkspaceSRGB(dark ? (physical ? 0x77818F : 0x657E9E)
                                   : (physical ? 0x858E9B : 0x7088A8));
    *detail = [NSColor.labelColor colorWithAlphaComponent:dark ? 0.65 : 0.60];
    if (highlighted) {
        *start = [*start blendedColorWithFraction:0.08 ofColor:NSColor.controlAccentColor];
        *end = [*end blendedColorWithFraction:0.12 ofColor:NSColor.controlAccentColor];
        *border = [NSColor.controlAccentColor colorWithAlphaComponent:0.90];
    }
}

@interface YMWorkspaceScreenView : NSView
@property(nonatomic) BOOL physical;
@property(nonatomic) BOOL highlighted;
@property(nonatomic,copy) NSString *detail;
@property(nonatomic,copy) NSString *name;
@end
@implementation YMWorkspaceScreenView
- (BOOL)isFlipped { return YES; }
- (void)setPhysical:(BOOL)value { _physical=value; self.needsDisplay=YES; }
- (void)setHighlighted:(BOOL)value { _highlighted=value; self.needsDisplay=YES; }
- (void)setDetail:(NSString *)value { _detail=[value copy]; self.needsDisplay=YES; }
- (void)setName:(NSString *)value { _name=[value copy]; self.needsDisplay=YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect rect=NSInsetRect(self.bounds,0.75,0.75);
    CGFloat width=rect.size.width;
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *top, *bottom, *borderColor, *detailColor;
    YMWorkspaceScreenPalette(dark, self.physical, self.highlighted,
        &top, &bottom, &borderColor, &detailColor);
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:7 yRadius:7];
    [[[NSGradient alloc] initWithStartingColor:top endingColor:bottom] drawInBezierPath:shape angle:90];
    [borderColor setStroke];
    shape.lineWidth=self.highlighted ? 1.5 : 1;
    [shape stroke];
    NSMutableParagraphStyle *nameStyle=[NSMutableParagraphStyle new]; nameStyle.alignment=NSTextAlignmentCenter; nameStyle.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.name drawInRect:NSMakeRect(NSMinX(rect)+9,7,width-18,15) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:nameStyle}];
    if (self.detail.length) {
        NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=NSTextAlignmentCenter; style.lineBreakMode=NSLineBreakByTruncatingTail;
        [self.detail drawInRect:NSMakeRect(NSMinX(rect)+8,22,width-16,13) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:8.5], NSForegroundColorAttributeName:detailColor,NSParagraphStyleAttributeName:style}];
    }
}
@end

@interface YMWorkspaceApplicationIcon : NSView <NSDraggingSource, NSMenuDelegate>
@property(nonatomic,strong) NSDictionary *row;
@property(nonatomic) uint32_t sourceDisplayID;
@property(nonatomic) BOOL movable;
@property(nonatomic) BOOL physical;
@property(nonatomic) BOOL beganDragging;
@property(nonatomic) BOOL sourceDragActive;
@property(nonatomic) BOOL menuTracking;
@property(nonatomic) NSPoint mouseDownPoint;
@property(nonatomic,strong) NSImage *appIcon;
@property(nonatomic) CGFloat iconSize;
@property(nonatomic,strong) NSTextField *nameLabel;
@property(nonatomic,copy) void (^restoreApplication)(NSString *);
@end
@implementation YMWorkspaceApplicationIcon
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if (self) {
        _iconSize=40; self.wantsLayer=YES;
        _nameLabel=YMWorkspaceLabel(@"",10,NSFontWeightRegular,NSColor.labelColor);
        _nameLabel.translatesAutoresizingMaskIntoConstraints=YES;
        _nameLabel.alignment=NSTextAlignmentCenter; _nameLabel.maximumNumberOfLines=2; _nameLabel.hidden=YES;
        _nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        [self addSubview:_nameLabel]; [self setAccessibilityElement:YES];
    }
    return self;
}
- (void)setIconSize:(CGFloat)value { _iconSize=value; self.needsDisplay=YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)acceptsFirstResponder { return !self.physical && self.movable; }
- (BOOL)becomeFirstResponder { self.needsDisplay=YES; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay=YES; return YES; }
- (NSView *)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }
- (void)layout { [super layout]; self.nameLabel.frame=NSMakeRect(0,44,self.bounds.size.width,28); }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; CGFloat center=NSMidX(self.bounds);
    if (self.window.firstResponder==self) {
        [[NSColor.keyboardFocusIndicatorColor colorWithAlphaComponent:0.14] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(center-self.iconSize/2-4,0,self.iconSize+8,self.iconSize+8) xRadius:8 yRadius:8] fill];
    }
    [self.appIcon drawInRect:NSMakeRect(center-self.iconSize/2,4,self.iconSize,self.iconSize) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSUInteger count=[self.row[@"windowCount"] unsignedIntegerValue];
    if (count>1) {
        NSString *text=[NSString stringWithFormat:@"%lu",(unsigned long)count];
        NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
        NSSize size=[text sizeWithAttributes:attributes];
        NSRect badge=NSMakeRect(center+self.iconSize/2-9,1,MAX(14,size.width+7),14);
        [NSColor.controlBackgroundColor setFill]; [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:7 yRadius:7] fill];
        [text drawAtPoint:NSMakePoint(NSMidX(badge)-size.width/2,NSMidY(badge)-size.height/2) withAttributes:attributes];
    }
}
- (void)mouseDown:(NSEvent *)event {
    self.mouseDownPoint=event.locationInWindow; self.beganDragging=NO;
    if (self.acceptsFirstResponder) [self.window makeFirstResponder:self];
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.movable || self.beganDragging) return;
    NSPoint location=event.locationInWindow;
    if (hypot(location.x-self.mouseDownPoint.x,location.y-self.mouseDownPoint.y)<4) return;
    NSString *identifier=self.row[@"bundleIdentifier"]; if (!identifier.length) return;
    NSMutableDictionary *payload=[@{@"bundleIdentifier":identifier,@"sourceDisplayID":@(self.sourceDisplayID)} mutableCopy];
    NSURL *URL=self.row[@"appURL"];
    if ([URL isKindOfClass:NSURL.class] && URL.isFileURL) payload[@"applicationURL"]=URL.absoluteString;
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL]; if (!data) return;
    NSPasteboardItem *item=[NSPasteboardItem new]; [item setData:data forType:YMWorkspaceApplicationType];
    NSDraggingItem *drag=[[NSDraggingItem alloc] initWithPasteboardWriter:item];
    NSPoint point=[self convertPoint:location fromView:nil];
    [drag setDraggingFrame:NSMakeRect(point.x-self.iconSize/2,point.y-self.iconSize/2,self.iconSize,self.iconSize) contents:self.appIcon]; self.beganDragging=YES;
    self.sourceDragActive=YES; YMWorkspaceBeginInteraction();
    @try {
        [self beginDraggingSessionWithItems:@[drag] event:event source:self].animatesToStartingPositionsOnCancelOrFail=YES;
    } @catch (NSException *exception) {
        self.sourceDragActive=NO; self.beganDragging=NO; YMWorkspaceEndInteraction(); @throw exception;
    }
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session; return context==NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    (void)session; (void)point; (void)operation;
    self.beganDragging=NO;
    if (self.sourceDragActive) { self.sourceDragActive=NO; YMWorkspaceEndInteraction(); }
}
- (NSMenu *)menuForEvent:(NSEvent *)event { (void)event; return [self restoreMenu]; }
- (NSMenu *)restoreMenu {
    if (self.physical) return nil;
    NSMenu *menu=[[NSMenu alloc] initWithTitle:self.nameLabel.stringValue]; menu.autoenablesItems=NO; menu.delegate=self;
    NSString *title=[self.row[@"managedWindowCount"] unsignedIntegerValue] ? @"返回原显示器" : @"移回实体屏";
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(restore:) keyEquivalent:@""];
    item.target=self; item.enabled=self.movable && self.restoreApplication!=nil; [menu addItem:item]; return menu;
}
- (void)menuWillOpen:(NSMenu *)menu { (void)menu; if (!self.menuTracking) { self.menuTracking=YES; YMWorkspaceBeginInteraction(); } }
- (void)menuDidClose:(NSMenu *)menu { (void)menu; if (self.menuTracking) { self.menuTracking=NO; YMWorkspaceEndInteraction(); } }
- (void)dealloc { if (_sourceDragActive) YMWorkspaceEndInteraction(); if (_menuTracking) YMWorkspaceEndInteraction(); }
- (void)restore:(id)sender { (void)sender; if (self.movable && self.restoreApplication) self.restoreApplication(self.row[@"bundleIdentifier"]); }
- (BOOL)accessibilityPerformPress {
    NSMenu *menu=[self restoreMenu]; if (!menu || !self.movable) return NO;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,43) inView:self]; return YES;
}
- (BOOL)accessibilityPerformShowMenu { return [self accessibilityPerformPress]; }
- (void)keyDown:(NSEvent *)event {
    if ([event.charactersIgnoringModifiers isEqualToString:@" "] || [event.charactersIgnoringModifiers isEqualToString:@"\r"]) { (void)[self accessibilityPerformPress]; return; }
    [super keyDown:event];
}
@end

@interface YMWorkspaceIconGrid : NSView
@property(nonatomic,copy) NSArray<YMWorkspaceApplicationIcon *> *icons;
@property(nonatomic) CGFloat contentHeight;
@property(nonatomic) CGFloat iconSize;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

@interface YMWorkspaceDesktopScrollView : NSScrollView
- (void)resizeIconDocument;
@end

@implementation YMWorkspaceIconGrid
- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric,self.contentHeight); }
- (NSUInteger)columnsForWidth:(CGFloat)width { CGFloat step=(self.iconSize ?: 40)+14; return MAX(1,(NSUInteger)floor((MAX(width,step-6)+6)/step)); }
- (CGFloat)heightForWidth:(CGFloat)width { return ceil((double)self.icons.count/[self columnsForWidth:width])*((self.iconSize ?: 40)+8); }
- (void)setIconSize:(CGFloat)value { _iconSize=value; for (YMWorkspaceApplicationIcon *icon in self.icons) icon.iconSize=value; self.needsLayout=YES; }
- (void)setIcons:(NSArray<YMWorkspaceApplicationIcon *> *)icons {
    if ([_icons isEqualToArray:icons]) return;
    NSSet *retained=[NSSet setWithArray:icons];
    for (NSView *view in self.subviews.copy) if (![retained containsObject:view]) [view removeFromSuperview];
    _icons=[icons copy]; for (NSView *view in icons) if (view.superview!=self) [self addSubview:view];
    CGFloat width=self.bounds.size.width>0 ? self.bounds.size.width : 184;
    self.contentHeight=[self heightForWidth:width];
    [self invalidateIntrinsicContentSize]; self.needsLayout=YES;
    if ([self.enclosingScrollView isKindOfClass:YMWorkspaceDesktopScrollView.class]) [(YMWorkspaceDesktopScrollView *)self.enclosingScrollView resizeIconDocument];
}
- (void)layout {
    [super layout]; NSUInteger columns=[self columnsForWidth:self.bounds.size.width];
    CGFloat cellWidth=MIN((self.iconSize ?: 40)+8,MAX(1,(self.bounds.size.width-6*(columns-1))/columns));
    CGFloat totalWidth=cellWidth*columns+6*(columns-1), start=MAX(0,(self.bounds.size.width-totalWidth)/2), rowHeight=(self.iconSize ?: 40)+8;
    for (NSUInteger i=0;i<self.icons.count;i++) self.icons[i].frame=NSMakeRect(start+(i%columns)*(cellWidth+6),(i/columns)*rowHeight,cellWidth,rowHeight);
    self.contentHeight=[self heightForWidth:self.bounds.size.width];
}

@end

@implementation YMWorkspaceDesktopScrollView
- (void)tile { [super tile]; [self resizeIconDocument]; }
- (void)resizeIconDocument {
    if (![self.documentView isKindOfClass:YMWorkspaceIconGrid.class]) return;
    YMWorkspaceIconGrid *grid=(YMWorkspaceIconGrid *)self.documentView;
    NSSize viewport=self.contentView.bounds.size;
    if (viewport.width<=0 || viewport.height<=0) return;
    grid.iconSize=viewport.height<48 ? 32 : 40;
    NSSize size=NSMakeSize(viewport.width,MAX(viewport.height,[grid heightForWidth:viewport.width]));
    if (!NSEqualSizes(grid.frame.size,size)) [grid setFrameSize:size];
    grid.needsLayout=YES;
}
@end

@interface YMAppWorkspaceView () <NSDraggingDestination, NSMenuDelegate>
@property(nonatomic,strong) YMWorkspaceScreenView *screenView;
@property(nonatomic,strong) NSTextField *titleLabel;
@property(nonatomic,strong) NSTextField *countLabel;
@property(nonatomic,strong) NSTextField *emptyLabel;
@property(nonatomic,strong) NSTextField *statusLabel;
@property(nonatomic,strong) NSTextField *noteLabel;
@property(nonatomic,strong) NSButton *chooseButton;
@property(nonatomic,strong) NSButton *manageButton;
@property(nonatomic,strong) YMWorkspaceIconGrid *grid;
@property(nonatomic,strong) YMWorkspaceDesktopScrollView *desktopScroll;
@property(nonatomic,strong) NSImageView *emptyDropGlyph;
@property(nonatomic,strong) NSLayoutConstraint *desktopBottomConstraint;
@property(nonatomic,strong) NSLayoutConstraint *screenAspectConstraint;
@property(nonatomic,copy) NSArray<NSDictionary *> *rows;
@property(nonatomic,copy) NSArray<NSString *> *rowSignature;
@property(nonatomic) BOOL available;
@property(nonatomic) BOOL trusted;
@property(nonatomic) BOOL highlighted;
@property(nonatomic) BOOL menuTracking;
@property(nonatomic,copy) NSArray<NSDictionary *> *pendingRows;
@property(nonatomic) BOOL pendingAvailable;
@property(nonatomic) BOOL pendingTrusted;
@end
@implementation YMAppWorkspaceView
+ (BOOL)hasActiveInteraction { return YMWorkspaceInteractionDepth>0; }
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if (self) {
        _displayName=@"虚拟屏"; _displayAspectRatio=16.0/9.0; _displayDetail=@""; _statusText=@""; _contextNote=@""; _rows=@[]; _rowSignature=@[]; _acceptsApplications=YES;
        self.translatesAutoresizingMaskIntoConstraints=NO;
        [self registerForDraggedTypes:@[YMWorkspaceApplicationType,NSPasteboardTypeFileURL]];
        _screenView=[[YMWorkspaceScreenView alloc] initWithFrame:NSZeroRect]; _screenView.translatesAutoresizingMaskIntoConstraints=NO;
        [_screenView setAccessibilityElement:YES]; [_screenView setAccessibilityRole:NSAccessibilityGroupRole];
        _titleLabel=YMWorkspaceLabel(_displayName,12,NSFontWeightSemibold,NSColor.labelColor);
        _titleLabel.maximumNumberOfLines=1; _titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        _countLabel=YMWorkspaceLabel(@"0 个应用",10,NSFontWeightRegular,NSColor.secondaryLabelColor);
        _emptyLabel=YMWorkspaceLabel(@"拖入应用",11,NSFontWeightRegular,NSColor.tertiaryLabelColor); _emptyLabel.alignment=NSTextAlignmentCenter;
        _chooseButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil] target:self action:@selector(choose:)];
        _manageButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:nil] target:self action:@selector(manage:)];
        for (NSButton *button in @[_chooseButton,_manageButton]) { button.bordered=NO; button.controlSize=NSControlSizeSmall; [button.widthAnchor constraintEqualToConstant:22].active=YES; [button.heightAnchor constraintEqualToConstant:22].active=YES; }
        NSStackView *actions=[NSStackView stackViewWithViews:@[_chooseButton,_manageButton]];
        actions.translatesAutoresizingMaskIntoConstraints=NO; actions.orientation=NSUserInterfaceLayoutOrientationHorizontal; actions.spacing=2;
        [_screenView addSubview:actions];
        [NSLayoutConstraint activateConstraints:@[[actions.trailingAnchor constraintEqualToAnchor:_screenView.trailingAnchor constant:-5],[actions.bottomAnchor constraintEqualToAnchor:_screenView.bottomAnchor constant:-4]]];
        _grid=[[YMWorkspaceIconGrid alloc] initWithFrame:NSZeroRect]; _grid.translatesAutoresizingMaskIntoConstraints=YES;
        _desktopScroll=[[YMWorkspaceDesktopScrollView alloc] initWithFrame:NSZeroRect];
        _desktopScroll.translatesAutoresizingMaskIntoConstraints=NO;
        _desktopScroll.drawsBackground=NO; _desktopScroll.contentView.drawsBackground=NO;
        _desktopScroll.borderType=NSNoBorder; _desktopScroll.hasVerticalScroller=YES;
        _desktopScroll.hasHorizontalScroller=NO; _desktopScroll.autohidesScrollers=YES;
        _desktopScroll.scrollerStyle=NSScrollerStyleOverlay; _desktopScroll.documentView=_grid;
        [_screenView addSubview:_desktopScroll];
        self.desktopBottomConstraint=[_desktopScroll.bottomAnchor constraintEqualToAnchor:_screenView.bottomAnchor constant:-28];
        [NSLayoutConstraint activateConstraints:@[[_desktopScroll.leadingAnchor constraintEqualToAnchor:_screenView.leadingAnchor constant:8],[_desktopScroll.trailingAnchor constraintEqualToAnchor:_screenView.trailingAnchor constant:-8],[_desktopScroll.topAnchor constraintEqualToAnchor:_screenView.topAnchor constant:40],self.desktopBottomConstraint]];
        _emptyDropGlyph=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil]];
        _emptyDropGlyph.translatesAutoresizingMaskIntoConstraints=NO; _emptyDropGlyph.contentTintColor=NSColor.controlAccentColor;
        _emptyDropGlyph.wantsLayer=YES; _emptyDropGlyph.hidden=YES; [_emptyDropGlyph setAccessibilityElement:NO];
        [_screenView addSubview:_emptyDropGlyph];
        [NSLayoutConstraint activateConstraints:@[[_emptyDropGlyph.widthAnchor constraintEqualToConstant:24],[_emptyDropGlyph.heightAnchor constraintEqualToConstant:24],[_emptyDropGlyph.centerXAnchor constraintEqualToAnchor:_desktopScroll.centerXAnchor],[_emptyDropGlyph.centerYAnchor constraintEqualToAnchor:_desktopScroll.centerYAnchor]]];
        _statusLabel=YMWorkspaceLabel(@"",10,NSFontWeightRegular,NSColor.secondaryLabelColor); _noteLabel=YMWorkspaceLabel(@"",10,NSFontWeightRegular,NSColor.secondaryLabelColor);
        // A tile is exactly one display. An intermediate stack with detached
        // status labels leaves its height underconstrained when the outer
        // horizontal stack is taller than its displays.
        [self addSubview:_screenView];
        self.screenAspectConstraint=[_screenView.heightAnchor constraintEqualToAnchor:_screenView.widthAnchor multiplier:1.0/_displayAspectRatio];
        [NSLayoutConstraint activateConstraints:@[[_screenView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[_screenView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[_screenView.topAnchor constraintEqualToAnchor:self.topAnchor],[_screenView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],self.screenAspectConstraint]];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(accessibilityOptionsChanged:) name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(workspaceInteractionEnded:) name:YMWorkspaceInteractionEndedNotification object:nil];
        [self updatePresentation]; [self rebuildIcons];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isPhysicalWorkspace { return self.physicalDisplay || self.displayID==0; }
- (void)setDisplayID:(uint32_t)value { if (_displayID==value) return; _displayID=value; [self updatePresentation]; [self rebuildIcons]; }
- (void)setPhysicalDisplay:(BOOL)value { if (_physicalDisplay==value) return; _physicalDisplay=value; [self updatePresentation]; [self rebuildIcons]; }
- (void)setAcceptsApplications:(BOOL)value { _acceptsApplications=value; if (!value) self.highlighted=NO; [self updatePresentation]; }
- (void)setDisplayAspectRatio:(CGFloat)value {
    if (!isfinite(value) || value<0.25 || value>8 || fabs(_displayAspectRatio-value)<0.0001) return;
    _displayAspectRatio=value; self.screenAspectConstraint.active=NO;
    self.screenAspectConstraint=[self.screenView.heightAnchor constraintEqualToAnchor:self.screenView.widthAnchor multiplier:1.0/value]; self.screenAspectConstraint.active=YES;
}
- (void)setDisplayName:(NSString *)value { _displayName=[value copy] ?: @""; [self updatePresentation]; }
- (void)setDisplayDetail:(NSString *)value { _displayDetail=[value copy] ?: @""; [self updatePresentation]; }
- (void)setStatusText:(NSString *)value { _statusText=[value copy] ?: @""; [self updatePresentation]; }
- (void)setContextNote:(NSString *)value { _contextNote=[value copy] ?: @""; [self updatePresentation]; }
- (void)setOnManageDisplay:(void (^)(void))value { _onManageDisplay=[value copy]; [self updatePresentation]; }
- (void)setHighlighted:(BOOL)value {
    BOOL changed=_highlighted!=value; _highlighted=value; self.screenView.highlighted=value;
    if (changed) [self updateDragFeedback]; self.needsDisplay=YES;
}
- (void)accessibilityOptionsChanged:(NSNotification *)notification { (void)notification; [self updateDragFeedback]; }
- (void)updateDragFeedback {
    BOOL animate=self.highlighted && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.emptyDropGlyph.hidden=!(self.highlighted && !self.rows.count);
    NSMutableArray<CALayer *> *layers=[NSMutableArray array];
    for (YMWorkspaceApplicationIcon *icon in self.grid.icons) if (icon.layer) [layers addObject:icon.layer];
    if (!self.rows.count && self.emptyDropGlyph.layer) [layers addObject:self.emptyDropGlyph.layer];
    for (NSUInteger index=0;index<layers.count;index++) {
        CALayer *layer=layers[index];
        if (!animate) { [layer removeAnimationForKey:@"yomado.dragWiggle"]; continue; }
        if ([layer animationForKey:@"yomado.dragWiggle"]) continue;
        CAKeyframeAnimation *wiggle=[CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        wiggle.values=@[@(-0.035),@(0.035),@(-0.035)]; wiggle.keyTimes=@[@0,@0.5,@1];
        wiggle.duration=0.26+0.02*(index%3); wiggle.repeatCount=HUGE_VALF;
        wiggle.beginTime=CACurrentMediaTime()+0.025*(index%2);
        [layer addAnimation:wiggle forKey:@"yomado.dragWiggle"];
    }
    if (!animate || self.rows.count) [self.emptyDropGlyph.layer removeAnimationForKey:@"yomado.dragWiggle"];
}
- (void)viewWillMoveToWindow:(NSWindow *)newWindow { if (!newWindow) self.highlighted=NO; [super viewWillMoveToWindow:newWindow]; }
- (void)dealloc { [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; [NSNotificationCenter.defaultCenter removeObserver:self]; if (_menuTracking) YMWorkspaceEndInteraction(); }
- (void)layout { [super layout]; [self.desktopScroll resizeIconDocument]; }
- (void)drawRect:(NSRect)dirtyRect { (void)dirtyRect; if (!self.highlighted) return; [[NSColor.controlAccentColor colorWithAlphaComponent:0.05] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,0.5,0.5) xRadius:10 yRadius:10] fill]; }
- (void)choose:(id)sender {
    (void)sender; if (!(self.available && self.trusted && self.acceptsApplications && self.onChooseApplication)) return;
    YMWorkspaceBeginInteraction(); @try { self.onChooseApplication(); } @finally { YMWorkspaceEndInteraction(); }
}
- (void)manage:(id)sender {
    (void)sender; if (!self.onManageDisplay) return;
    YMWorkspaceBeginInteraction(); @try { self.onManageDisplay(); } @finally { YMWorkspaceEndInteraction(); }
}
- (void)menuWillOpen:(NSMenu *)menu { (void)menu; if (!self.menuTracking) { self.menuTracking=YES; YMWorkspaceBeginInteraction(); } }
- (void)menuDidClose:(NSMenu *)menu { (void)menu; if (self.menuTracking) { self.menuTracking=NO; YMWorkspaceEndInteraction(); } }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event; if (self.isPhysicalWorkspace) return nil;
    NSMenu *menu=[[NSMenu alloc] initWithTitle:self.displayName]; menu.autoenablesItems=NO; menu.delegate=self;
    NSMenuItem *add=[[NSMenuItem alloc] initWithTitle:@"添加应用…" action:@selector(choose:) keyEquivalent:@""]; add.target=self; add.enabled=self.available && self.trusted && self.acceptsApplications && self.onChooseApplication!=nil; [menu addItem:add];
    if (self.onManageDisplay) { NSMenuItem *manage=[[NSMenuItem alloc] initWithTitle:@"管理这个屏幕…" action:@selector(manage:) keyEquivalent:@""]; manage.target=self; [menu addItem:manage]; }
    return menu;
}
- (void)updatePresentation {
    BOOL physical=self.isPhysicalWorkspace;
    self.titleLabel.stringValue=self.displayName.length ? self.displayName : (physical ? @"实体屏" : @"虚拟屏");
    self.screenView.name=self.titleLabel.stringValue;
    self.desktopBottomConstraint.constant=physical ? -6 : -28;
    self.screenView.physical=physical; self.screenView.detail=self.displayDetail.length ? self.displayDetail : (physical ? @"实体屏" : @"虚拟屏");
    [self.screenView setAccessibilityLabel:[NSString stringWithFormat:@"%@，%@",self.titleLabel.stringValue,self.screenView.detail]];
    self.chooseButton.hidden=physical; self.chooseButton.enabled=self.available && self.trusted && self.acceptsApplications;
    self.chooseButton.toolTip=[NSString stringWithFormat:@"向 %@ 添加应用",self.titleLabel.stringValue]; [self.chooseButton setAccessibilityLabel:self.chooseButton.toolTip];
    self.manageButton.hidden=physical || !self.onManageDisplay; self.manageButton.toolTip=[NSString stringWithFormat:@"管理 %@",self.titleLabel.stringValue]; [self.manageButton setAccessibilityLabel:self.manageButton.toolTip];
    self.emptyLabel.stringValue=(!self.available || !self.acceptsApplications) ? @"屏幕未就绪" : physical ? @"暂无应用窗口" : @"拖入应用";
    self.toolTip=self.trusted ? @"将应用图标拖到另一个屏幕；也可以从 Finder 拖入已打开的 App。" : @"允许窗口控制后，即可拖放应用。";
    self.statusLabel.stringValue=self.statusText;
    BOOL generic=[self.statusText hasSuffix:@" 个应用 · 可见窗口"] || [self.statusText isEqualToString:@"从上方工作屏拖回，或选择要移回的应用。"] || [self.statusText isEqualToString:@"辅助功能授权后可移动应用窗口"];
    self.statusLabel.hidden=!self.statusText.length || generic; self.noteLabel.stringValue=self.contextNote;
    BOOL repeated=[self.contextNote isEqualToString:@"只移动你拖入的应用；也会识别你手动拖入的可见窗口。"] || [self.contextNote isEqualToString:@"通过 yomado 移入的窗口优先回原位置；手动拖入的窗口回实体主屏。"];
    self.noteLabel.hidden=!self.contextNote.length || repeated;
}
- (void)updateRows:(NSArray<NSDictionary *> *)rows virtualDisplayAvailable:(BOOL)available accessibilityTrusted:(BOOL)trusted {
    if (YMWorkspaceInteractionDepth) {
        self.pendingRows=[rows copy]; self.pendingAvailable=available; self.pendingTrusted=trusted;
        // Revocation takes effect immediately, but keep the dragged view alive.
        if (!available || !trusted) {
            self.available=available; self.trusted=trusted; self.highlighted=NO;
            for (YMWorkspaceApplicationIcon *icon in self.grid.icons) icon.movable=NO;
            [self updatePresentation];
        }
        return;
    }
    self.pendingRows=nil;
    NSMutableArray *valid=[NSMutableArray array],*signature=[NSMutableArray array]; NSUInteger windows=0;
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier=row[@"bundleIdentifier"]; NSNumber *count=row[@"windowCount"];
        if (![identifier isKindOfClass:NSString.class] || !identifier.length || ![count isKindOfClass:NSNumber.class] || count.integerValue<=0) continue;
        [valid addObject:row]; windows+=count.unsignedIntegerValue;
        [signature addObject:[NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@",identifier,row[@"appName"] ?: @"",row[@"pid"] ?: @0,count,row[@"managedWindowCount"] ?: @0,row[@"appURL"] ?: @""]];
    }
    BOOL changed=![signature isEqualToArray:self.rowSignature] || self.available!=available || self.trusted!=trusted;
    self.rows=valid; self.rowSignature=signature; self.available=available; self.trusted=trusted;
    if (!available || !trusted) self.highlighted=NO;
    self.countLabel.stringValue=[NSString stringWithFormat:@"%lu 个应用",(unsigned long)valid.count];
    self.countLabel.toolTip=[NSString stringWithFormat:@"%lu 个可见普通窗口",(unsigned long)windows];
    [self.countLabel setAccessibilityLabel:[NSString stringWithFormat:@"%lu 个应用，%lu 个可见窗口",(unsigned long)valid.count,(unsigned long)windows]];
    [self updatePresentation]; if (changed) [self rebuildIcons];
}
- (void)workspaceInteractionEnded:(NSNotification *)notification {
    (void)notification;
    if (YMWorkspaceInteractionDepth || !self.pendingRows) return;
    NSArray *rows=self.pendingRows; BOOL available=self.pendingAvailable, trusted=self.pendingTrusted;
    self.pendingRows=nil;
    [self updateRows:rows virtualDisplayAvailable:available accessibilityTrusted:trusted];
}
- (void)rebuildIcons {
    NSMutableArray *icons=[NSMutableArray array];
    NSMutableDictionary<NSString *,YMWorkspaceApplicationIcon *> *existing=[NSMutableDictionary dictionary];
    for (YMWorkspaceApplicationIcon *icon in self.grid.icons) {
        NSString *identifier=icon.row[@"bundleIdentifier"];
        if (identifier.length) existing[identifier]=icon;
    }
    for (NSDictionary *row in self.rows) {
        YMWorkspaceApplicationIcon *icon=existing[row[@"bundleIdentifier"]] ?: [[YMWorkspaceApplicationIcon alloc] initWithFrame:NSZeroRect];
        icon.row=row; icon.sourceDisplayID=self.displayID; icon.physical=self.isPhysicalWorkspace; icon.movable=self.available && self.trusted;
        icon.appIcon=[row[@"appIcon"] isKindOfClass:NSImage.class] ? row[@"appIcon"] : [NSImage imageWithSystemSymbolName:@"app" accessibilityDescription:nil];
        icon.nameLabel.stringValue=[row[@"appName"] isKindOfClass:NSString.class] ? row[@"appName"] : row[@"bundleIdentifier"];
        icon.toolTip=[NSString stringWithFormat:@"%@ · %@ 个窗口\n拖到其他屏幕%@",icon.nameLabel.stringValue,row[@"windowCount"],icon.physical ? @"" : @"；右键可返回实体屏"];
        [icon setAccessibilityRole:icon.physical ? NSAccessibilityImageRole : NSAccessibilityButtonRole];
        [icon setAccessibilityLabel:[NSString stringWithFormat:@"%@，%@ 个窗口",icon.nameLabel.stringValue,row[@"windowCount"]]];
        [icon setAccessibilityHelp:icon.physical ? @"拖到虚拟屏，或使用目标屏幕的添加应用按钮。" : @"拖到其他屏幕，或按空格打开返回菜单。"];
        __weak typeof(self) weakSelf=self;
        icon.restoreApplication=^(NSString *identifier) { if (weakSelf.onRestoreBundleIdentifier) weakSelf.onRestoreBundleIdentifier(identifier); };
        icon.needsDisplay=YES;
        [icons addObject:icon];
    }
    self.grid.icons=icons; self.emptyLabel.hidden=YES; [self updateDragFeedback];
}
- (NSDictionary *)payloadForDraggingInfo:(id<NSDraggingInfo>)sender {
    if (!(self.available && self.trusted && self.acceptsApplications)) return nil;
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSData *data = [pasteboard dataForType:YMWorkspaceApplicationType];
    if (data.length && data.length < 16384) {
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![decoded isKindOfClass:NSDictionary.class]) return nil;
        NSString *bundleIdentifier = decoded[@"bundleIdentifier"];
        NSNumber *sourceDisplayID = decoded[@"sourceDisplayID"];
        if (![bundleIdentifier isKindOfClass:NSString.class] || bundleIdentifier.length == 0 ||
            bundleIdentifier.length > 1024 || ![sourceDisplayID isKindOfClass:NSNumber.class] ||
            sourceDisplayID.unsignedIntValue == self.displayID) return nil;
        NSMutableDictionary *payload = [@{@"bundleIdentifier":bundleIdentifier,
                                          @"sourceDisplayID":sourceDisplayID} mutableCopy];
        NSString *URLString = decoded[@"applicationURL"];
        if ([URLString isKindOfClass:NSString.class]) {
            NSURL *URL = [NSURL URLWithString:URLString];
            if (URL.isFileURL && [URL.pathExtension.lowercaseString isEqualToString:@"app"]) {
                payload[@"applicationURL"] = URL;
            }
        }
        return payload;
    }
    NSArray<NSURL *> *URLs = [pasteboard readObjectsForClasses:@[NSURL.class]
                                                     options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    // One drop is one explicit application move; never partially process a multi-app drop.
    if (URLs.count != 1 || ![URLs.firstObject.pathExtension.lowercaseString isEqualToString:@"app"]) return nil;
    return @{@"applicationURL":URLs.firstObject};
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    self.highlighted = [self payloadForDraggingInfo:sender] != nil;
    if (!self.highlighted) return NSDragOperationNone;
    return [sender.draggingPasteboard availableTypeFromArray:@[YMWorkspaceApplicationType]] ? NSDragOperationMove : NSDragOperationCopy;
}
- (BOOL)wantsPeriodicDraggingUpdates { return YES; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    // The source card rejects a drop onto itself, but must still allow scrolling
    // through that card to reach another screen farther down the panel.
    if ((self.available && self.trusted) && [sender.draggingPasteboard availableTypeFromArray:@[YMWorkspaceApplicationType, NSPasteboardTypeFileURL]])
        if (!YMWorkspaceAutoscroll(self.grid, sender)) YMWorkspaceAutoscroll(self, sender);
    return [self draggingEntered:sender];
}
- (void)draggingExited:(id<NSDraggingInfo>)sender { (void)sender; self.highlighted = NO; }
- (void)draggingEnded:(id<NSDraggingInfo>)sender { (void)sender; self.highlighted = NO; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return [self payloadForDraggingInfo:sender] != nil; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSDictionary *payload = [self payloadForDraggingInfo:sender];
    self.highlighted = NO;
    if (!payload || !self.onDropApplication) return NO;
    self.onDropApplication(payload);
    return YES;
}
@end
