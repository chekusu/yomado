#import "WorkspacePreview.h"
#import "VDVirtualDisplay.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *const YMPreviewEnabledKey = @"YMWorkspacePreviewEnabled";
static NSString *const YMPreviewPiPFrameKey = @"YMWorkspacePreviewPiPFrame";
static const CGFloat YMTabWidth = 14, YMTabHeight = 54, YMTabGap = 6;
static const CGFloat YMCardWidth = 232, YMCardHeight = 130.5, YMCardGap = 12, YMDockPad = 14;

static BOOL YMReduceMotion(void) { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }
static void YMAnimate(NSTimeInterval duration, void (^changes)(void), void (^_Nullable done)(void)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = YMReduceMotion() ? 0 : duration;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
        context.allowsImplicitAnimation = YES;
        changes();
    } completionHandler:done];
}
static void YMSetContents(CALayer *layer, id contents) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = contents;
    [CATransaction commit];
}


// Where a display's picture actually sits inside an aspect-fit layer.
static CGRect YMAspectFitRect(CGSize content, CGRect bounds) {
    if (content.width <= 0 || content.height <= 0 || bounds.size.width <= 0 || bounds.size.height <= 0) return bounds;
    CGFloat scale = MIN(bounds.size.width / content.width, bounds.size.height / content.height);
    CGSize size = CGSizeMake(content.width * scale, content.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - size.width / 2, CGRectGetMidY(bounds) - size.height / 2, size.width, size.height);
}
static void YMAddRipple(CALayer *host, CGPoint at, CGFloat radius) {
    if (!host) return;
    CAShapeLayer *ring = [CAShapeLayer layer];
    CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(-radius, -radius, radius * 2, radius * 2), NULL);
    ring.path = path;
    CGPathRelease(path);
    ring.position = at;
    ring.fillColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:0.22].CGColor;
    ring.strokeColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:1].CGColor;
    ring.lineWidth = MAX(2.5, radius / 4);
    ring.shadowColor = NSColor.whiteColor.CGColor;
    ring.shadowOpacity = 0.9;
    ring.shadowRadius = 1.5;
    ring.shadowOffset = CGSizeZero;
    [host addSublayer:ring];
    CAShapeLayer *dot = [CAShapeLayer layer];
    CGFloat dr = MAX(3, radius / 3.5);
    CGPathRef dotPath = CGPathCreateWithEllipseInRect(CGRectMake(-dr, -dr, dr * 2, dr * 2), NULL);
    dot.path = dotPath;
    CGPathRelease(dotPath);
    dot.position = at;
    dot.fillColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:1].CGColor;
    dot.strokeColor = NSColor.whiteColor.CGColor;
    dot.lineWidth = MAX(1, dr / 3);
    [host addSublayer:dot];
    CABasicAnimation *dotFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    dotFade.fromValue = @1; dotFade.toValue = @0; dotFade.beginTime = CACurrentMediaTime() + 0.8; dotFade.duration = 0.5;
    dotFade.fillMode = kCAFillModeBackwards; dotFade.removedOnCompletion = NO;
    dot.opacity = 0;
    [dot addAnimation:dotFade forKey:@"fade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [dot removeFromSuperlayer]; });
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @(YMReduceMotion() ? 1.0 : 0.35);
    grow.toValue = @(YMReduceMotion() ? 1.0 : 1.5);
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.beginTime = 0.6;
    fade.duration = 0.6;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[grow, fade];
    group.duration = 1.2;
    group.timingFunction = ease;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }];
    [ring addAnimation:group forKey:@"ripple"];
    [CATransaction commit];
}

#pragma mark - Capture source (one ScreenCaptureKit stream per virtual display)

@interface YMPreviewSource : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic) SCStream *stream;
@property(nonatomic) SCDisplay *display;
@property(nonatomic) BOOL live;
@property(nonatomic) NSHashTable<CALayer *> *layers;
@property(nonatomic, nullable) id latest;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation YMPreviewSource
+ (SCStreamConfiguration *)configurationForDisplay:(SCDisplay *)display live:(BOOL)live {
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    double aspect = display.height > 0 ? (double)display.width / (double)display.height : 16.0 / 9.0;
    // Thumbnails stay small and slow; the picture-in-picture panel gets the
    // display's native pixels at 30 fps.
    size_t width = live ? MIN((size_t)display.width * 2, (size_t)3840) : 480;
    configuration.width = width;
    configuration.height = (size_t)llround((double)width / aspect);
    configuration.minimumFrameInterval = live ? CMTimeMake(1, 30) : CMTimeMake(1, 2);
    configuration.queueDepth = 3;
    configuration.showsCursor = YES;
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    return configuration;
}
- (instancetype)initWithDisplay:(SCDisplay *)display {
    if ((self = [super init])) {
        _display = display;
        _displayID = display.displayID;
        _layers = [NSHashTable weakObjectsHashTable];
        _queue = dispatch_queue_create("dev.chekusu.yomado.preview", DISPATCH_QUEUE_SERIAL);
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        _stream = [[SCStream alloc] initWithFilter:filter configuration:[YMPreviewSource configurationForDisplay:display live:NO] delegate:self];
        NSError *error = nil;
        if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&error]) return nil;
        [_stream startCaptureWithCompletionHandler:^(NSError *startError) { (void)startError; }];
    }
    return self;
}
- (void)attachLayer:(CALayer *)layer {
    [self.layers addObject:layer];
    if (self.latest) YMSetContents(layer, self.latest);
}
- (void)detachLayer:(CALayer *)layer {
    [self.layers removeObject:layer];
}
- (void)setLive:(BOOL)live {
    if (_live == live) return;
    _live = live;
    [self.stream updateConfiguration:[YMPreviewSource configurationForDisplay:self.display live:live] completionHandler:^(NSError *error) { (void)error; }];
}
- (void)stop {
    [self.stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
    for (CALayer *layer in self.layers) YMSetContents(layer, nil);
    [self.layers removeAllObjects];
    self.latest = nil;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *status = info[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete) return;
    }
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = pixels ? CVPixelBufferGetIOSurface(pixels) : NULL;
    if (!surface) return;
    id contents = (__bridge id)surface;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.latest = contents;
        for (CALayer *layer in self.layers) YMSetContents(layer, contents);
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream; (void)error;
}
@end

#pragma mark - Panels and views

@interface YMPreviewPanel : NSPanel
@property(nonatomic) BOOL takeoverKey;
@end
@implementation YMPreviewPanel
// Key only while the person is typing into a taken-over display.
- (BOOL)canBecomeKeyWindow { return self.takeoverKey; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static void YMConfigureFloatingPanel(NSPanel *panel) {
    panel.level = NSFloatingWindowLevel;
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.releasedWhenClosed = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
}

// A click target that never activates yomado.
@interface YMPreviewHitView : NSView
@property(nonatomic, copy, nullable) void (^onClick)(void);
@property(nonatomic, copy, nullable) void (^onDoubleClick)(void);
@end
@implementation YMPreviewHitView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return self.onClick == nil; }
- (void)mouseUp:(NSEvent *)event {
    if (event.clickCount == 2 && self.onDoubleClick) self.onDoubleClick();
    else if (event.clickCount == 1 && self.onClick) self.onClick();
}
@end

// Collapsed tab: a sliver of the live picture with a status dot.
@interface YMPreviewTab : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@end
@implementation YMPreviewTab
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 5;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.92].CGColor;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.18].CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspectFill;
        _picture.frame = self.layer.bounds;
        _picture.opacity = 0.85;
        [self.layer addSublayer:_picture];
    }
    return self;
}
- (void)layout { [super layout]; self.picture.frame = self.layer.bounds; }
@end

// Expanded card: live thumbnail with the display name on a soft gradient.
@interface YMPreviewCard : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@property(nonatomic) CAGradientLayer *shade;
@property(nonatomic) NSTextField *label;
@end
@implementation YMPreviewCard
- (instancetype)initWithFrame:(NSRect)frame name:(NSString *)name {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.22].CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_picture];
        _shade = [CAGradientLayer layer];
        _shade.colors = @[(id)[NSColor colorWithWhite:0 alpha:0.55].CGColor, (id)[NSColor colorWithWhite:0 alpha:0].CGColor];
        _shade.startPoint = CGPointMake(0.5, 0);
        _shade.endPoint = CGPointMake(0.5, 1);
        [self.layer addSublayer:_shade];
        _label = [NSTextField labelWithString:name];
        _label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _label.textColor = NSColor.whiteColor;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_label];
        self.toolTip = [NSString stringWithFormat:@"查看 %@", name];
    }
    return self;
}
- (void)layout {
    [super layout];
    self.picture.frame = self.layer.bounds;
    self.shade.frame = CGRectMake(0, 0, self.bounds.size.width, 34);
    self.label.frame = NSMakeRect(10, 7, self.bounds.size.width - 20, 16);
}
@end

// Dock content: tracks hover to expand and collapse.
@interface YMPreviewDockView : NSView
@property(nonatomic, copy, nullable) void (^onHover)(BOOL inside);
@end
@implementation YMPreviewDockView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; if (self.onHover) self.onHover(YES); }
- (void)mouseExited:(NSEvent *)event { (void)event; if (self.onHover) self.onHover(NO); }
@end

// Picture-in-picture content: live picture; a glass toolbar fades in on hover.
// While the person has taken over, the toolbar and a status pill stay visible
// and an accent ring marks the panel.
@interface YMPiPView : YMPreviewHitView <NSTextInputClient>
@property(nonatomic) CALayer *picture;
@property(nonatomic) NSMutableAttributedString *marked;
@property(nonatomic, copy, nullable) void (^onInsert)(NSString *text);
@property(nonatomic, copy, nullable) void (^onCommand)(NSString *command);
@property(nonatomic, copy, nullable) void (^onMarked)(NSString *text);
@property(nonatomic, copy, nullable) NSRect (^caretRect)(void);   // in view coordinates; NSZeroRect when unknown
@property(nonatomic) NSView *bar;
@property(nonatomic) NSTextField *title;
@property(nonatomic) NSButton *closeButton;
@property(nonatomic) NSVisualEffectView *toolbar;
@property(nonatomic) NSButton *takeoverButton;
@property(nonatomic) NSVisualEffectView *pill;
@property(nonatomic) NSTextField *pillLabel;
@property(nonatomic) BOOL takeover;
@property(nonatomic) BOOL takeoverAvailable;
@property(nonatomic) NSTimer *leaveTimer;
@property(nonatomic, copy, nullable) void (^onTap)(NSPoint point, BOOL secondary, NSInteger clicks);
@property(nonatomic, copy, nullable) void (^onScroll)(NSPoint point, NSEvent *event);
@property(nonatomic, copy, nullable) void (^onKey)(NSEvent *event);
@property(nonatomic, copy, nullable) void (^onLeftTooLong)(void);
@end
@implementation YMPiPView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_picture];
        _bar = [[NSView alloc] init];
        _bar.wantsLayer = YES;
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[(id)[NSColor colorWithWhite:0 alpha:0].CGColor, (id)[NSColor colorWithWhite:0 alpha:0.5].CGColor];
        _bar.layer = gradient;
        _bar.alphaValue = 0;
        [self addSubview:_bar];
        _title = [NSTextField labelWithString:@""];
        _title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        _title.textColor = NSColor.whiteColor;
        [_bar addSubview:_title];
        NSImage *close = [NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"收起预览"];
        _closeButton = [NSButton buttonWithImage:close target:nil action:nil];
        _closeButton.bordered = NO;
        _closeButton.contentTintColor = [NSColor colorWithWhite:1 alpha:0.9];
        _closeButton.toolTip = @"收起预览";
        [_bar addSubview:_closeButton];

        _toolbar = [[NSVisualEffectView alloc] init];
        _toolbar.material = NSVisualEffectMaterialHUDWindow;
        _toolbar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        _toolbar.state = NSVisualEffectStateActive;
        _toolbar.wantsLayer = YES;
        _toolbar.layer.cornerRadius = 22;
        _toolbar.layer.cornerCurve = kCACornerCurveContinuous;
        _toolbar.layer.masksToBounds = YES;
        _toolbar.alphaValue = 0;
        [self addSubview:_toolbar];
        _takeoverButton = [NSButton buttonWithTitle:@"接管" image:[NSImage imageWithSystemSymbolName:@"hand.point.up.left.fill" accessibilityDescription:nil] target:nil action:nil];
        _takeoverButton.bezelStyle = NSBezelStylePush;
        _takeoverButton.controlSize = NSControlSizeLarge;
        _takeoverButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        _takeoverButton.imagePosition = NSImageLeading;
        _takeoverButton.imageHugsTitle = YES;
        [_toolbar addSubview:_takeoverButton];

        _pill = [[NSVisualEffectView alloc] init];
        _pill.material = NSVisualEffectMaterialHUDWindow;
        _pill.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        _pill.state = NSVisualEffectStateActive;
        _pill.wantsLayer = YES;
        _pill.layer.cornerRadius = 14;
        _pill.layer.cornerCurve = kCACornerCurveContinuous;
        _pill.layer.masksToBounds = YES;
        _pill.hidden = YES;
        [self addSubview:_pill];
        _pillLabel = [NSTextField labelWithString:@"你正在操作 · Agent 已暂停 · 按 Esc 交还"];
        _pillLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        _pillLabel.textColor = NSColor.whiteColor;
        _pillLabel.alignment = NSTextAlignmentCenter;
        [_pill addSubview:_pillLabel];
        [self applyTakeoverAppearance];
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return self.takeover; }
- (void)applyTakeoverAppearance {
    BOOL on = self.takeover;
    self.layer.borderWidth = on ? 3 : 0;
    self.layer.borderColor = NSColor.controlAccentColor.CGColor;
    self.layer.shadowColor = NSColor.controlAccentColor.CGColor;
    self.takeoverButton.title = on ? @"交还给 Agent" : @"接管";
    self.takeoverButton.image = [NSImage imageWithSystemSymbolName:on ? @"arrow.uturn.backward.circle.fill" : @"hand.point.up.left.fill" accessibilityDescription:nil];
    self.takeoverButton.bezelColor = on ? NSColor.controlAccentColor : nil;
    self.takeoverButton.toolTip = on ? @"交还给 Agent(Esc)" : @"在这个画面里直接点、输入;Agent 会暂停";
    self.takeoverButton.hidden = !self.takeoverAvailable;
    self.toolbar.hidden = !self.takeoverAvailable;
    self.pill.hidden = !on;
    if (on) { self.toolbar.alphaValue = 1; self.bar.alphaValue = 1; }
    self.needsLayout = YES;
}
- (void)setTakeover:(BOOL)takeover {
    _takeover = takeover;
    [self.leaveTimer invalidate];
    self.leaveTimer = nil;
    [self applyTakeoverAppearance];
    if (takeover) [self.window makeFirstResponder:self];
}
- (void)setTakeoverAvailable:(BOOL)available { _takeoverAvailable = available; [self applyTakeoverAppearance]; }
- (BOOL)mouseDownCanMoveWindow { return !self.takeover; }
- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    self.picture.frame = self.layer.bounds;
    CGFloat height = 40;
    self.bar.frame = NSMakeRect(0, size.height - height, size.width, height);
    self.title.frame = NSMakeRect(14, 12, size.width - 60, 16);
    self.closeButton.frame = NSMakeRect(size.width - 34, 10, 20, 20);
    [self.takeoverButton sizeToFit];
    NSSize button = self.takeoverButton.frame.size;
    CGFloat toolbarWidth = button.width + 16, toolbarHeight = 44;
    self.toolbar.frame = NSMakeRect((size.width - toolbarWidth) / 2, 14, toolbarWidth, toolbarHeight);
    self.takeoverButton.frame = NSMakeRect(8, (toolbarHeight - button.height) / 2, button.width, button.height);
    [self.pillLabel sizeToFit];
    CGFloat pillWidth = self.pillLabel.frame.size.width + 28;
    self.pill.frame = NSMakeRect((size.width - pillWidth) / 2, size.height - 52, pillWidth, 28);
    self.pillLabel.frame = NSMakeRect(14, (28 - self.pillLabel.frame.size.height) / 2, self.pillLabel.frame.size.width, self.pillLabel.frame.size.height);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    [self.leaveTimer invalidate];
    self.leaveTimer = nil;
    YMAnimate(0.18, ^{ self.bar.animator.alphaValue = 1; self.toolbar.animator.alphaValue = 1; }, nil);
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (self.takeover) {
        // Leaving the panel for a while hands control back, so it can never be stranded.
        __weak YMPiPView *weakSelf = self;
        self.leaveTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            if (weakSelf.onLeftTooLong) weakSelf.onLeftTooLong();
        }];
        return;
    }
    YMAnimate(0.25, ^{ self.bar.animator.alphaValue = 0; self.toolbar.animator.alphaValue = 0; }, nil);
}
- (BOOL)eventHitsControl:(NSEvent *)event {
    NSView *hit = [self hitTest:[self.superview convertPoint:event.locationInWindow fromView:nil]];
    for (NSView *view = hit; view; view = view.superview)
        if ([view isKindOfClass:NSControl.class] || view == self.toolbar) return YES;
    return NO;
}
// While taking over, presses are swallowed and each release becomes one
// tap; nothing here ever moves the real pointer or posts global input.
- (void)mouseDown:(NSEvent *)event { if (!self.takeover || [self eventHitsControl:event]) [super mouseDown:event]; }
- (void)mouseDragged:(NSEvent *)event { if (!self.takeover) [super mouseDragged:event]; }
- (void)mouseUp:(NSEvent *)event {
    if (self.takeover && ![self eventHitsControl:event]) {
        if (self.onTap) self.onTap([self convertPoint:event.locationInWindow fromView:nil], NO, event.clickCount);
        return;
    }
    [super mouseUp:event];
}
- (void)rightMouseUp:(NSEvent *)event {
    if (self.takeover && self.onTap) { self.onTap([self convertPoint:event.locationInWindow fromView:nil], YES, 1); return; }
    [super rightMouseUp:event];
}
- (void)scrollWheel:(NSEvent *)event {
    if (self.takeover && self.onScroll) { self.onScroll([self convertPoint:event.locationInWindow fromView:nil], event); return; }
    [super scrollWheel:event];
}
// Keys go through the system input method, so Pinyin and other IMEs compose
// as usual; the committed text is written into the virtual display's field.
- (void)keyDown:(NSEvent *)event {
    if (!self.takeover) { [super keyDown:event]; return; }
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & NSEventModifierFlagCommand) {
        if ([event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"v"] && self.onCommand) self.onCommand(@"paste");
        return;
    }
    [self interpretKeyEvents:@[event]];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.takeover && (event.modifierFlags & NSEventModifierFlagCommand)
        && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"v"]) {
        if (self.onCommand) self.onCommand(@"paste");
        return YES;
    }
    return [super performKeyEquivalent:event];
}
- (void)insertText:(id)string replacementRange:(NSRange)range {
    (void)range;
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    [self unmarkText];
    if (text.length && self.onInsert) self.onInsert(text);
}
- (void)doCommandBySelector:(SEL)selector {
    NSString *command = nil;
    if (selector == @selector(deleteBackward:)) command = @"delete";
    else if (selector == @selector(insertNewline:)) command = @"return";
    else if (selector == @selector(cancelOperation:)) command = @"escape";
    if (command && self.onCommand) self.onCommand(command);
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range {
    (void)selected; (void)range;
    self.marked = [[NSMutableAttributedString alloc] initWithString:[string isKindOfClass:NSAttributedString.class] ? [string string] : string];
    if (self.onMarked) self.onMarked(self.marked.string);
}
- (void)unmarkText {
    self.marked = nil;
    if (self.onMarked) self.onMarked(@"");
}
- (NSRange)selectedRange { return NSMakeRange(self.marked.length, 0); }
- (NSRange)markedRange { return self.marked.length ? NSMakeRange(0, self.marked.length) : NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { return self.marked.length > 0; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
    (void)range; (void)actual; return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    (void)range; (void)actual;
    // Put the candidate window under the field being typed into, as it would
    // be on the virtual display; fall back to under the status pill.
    NSRect local = self.caretRect ? self.caretRect() : NSZeroRect;
    if (NSIsEmptyRect(local)) local = NSMakeRect(NSMidX(self.pill.frame) - 40, NSMinY(self.pill.frame) - 4, 80, 20);
    return [self.window convertRectToScreen:[self convertRect:local toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { (void)point; return NSNotFound; }
@end

#pragma mark - Controller

@interface YMWorkspacePreview ()
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic) NSArray<NSDictionary *> *displays;
@property(nonatomic) NSMutableDictionary<NSNumber *, YMPreviewSource *> *sources;
@property(nonatomic, nullable) YMPreviewPanel *dock;
@property(nonatomic, nullable) YMPreviewDockView *dockView;
@property(nonatomic) NSMutableArray<YMPreviewTab *> *tabs;
@property(nonatomic) NSMutableArray<YMPreviewCard *> *cards;
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL fetching;
@property(nonatomic) NSUInteger retries;
@property(nonatomic, nullable) YMPreviewPanel *pip;
@property(nonatomic, nullable) YMPiPView *pipView;
@property(nonatomic, nullable) NSNumber *pipDisplayID;
@property(nonatomic) BOOL permissionMissing;
@property(nonatomic, readwrite, nullable) NSNumber *takeoverDisplayID;
@property(nonatomic, nullable) id takeoverTextElement;
@property(nonatomic, nullable) id fenceGlobalMonitor;
@property(nonatomic, nullable) id fenceLocalMonitor;
@end

@implementation YMWorkspacePreview
- (instancetype)init {
    if ((self = [super init])) {
        _enabled = [NSUserDefaults.standardUserDefaults boolForKey:YMPreviewEnabledKey];
        _displays = @[];
        _sources = [NSMutableDictionary dictionary];
        _tabs = [NSMutableArray array];
        _cards = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (void)invalidate {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.displays = @[];
    [self updateCursorFence];
    [self teardown];
}
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:YMPreviewEnabledKey];
    if (enabled && !CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    [self reconcile];
}
- (void)updateDisplays:(NSArray<NSDictionary *> *)displays {
    if ([displays isEqualToArray:self.displays]) return;
    self.displays = [displays copy];
    self.retries = 0;
    [self reconcile];
}
- (void)screensChanged:(NSNotification *)note {
    (void)note;
    [self layoutDockAnimated:NO];
}

- (void)teardown {
    for (YMPreviewSource *source in self.sources.allValues) [source stop];
    [self.sources removeAllObjects];
    [self closePiP];
    [self.dock orderOut:nil];
    self.dock = nil;
    self.dockView = nil;
    [self.tabs removeAllObjects];
    [self.cards removeAllObjects];
    self.expanded = NO;
}

- (void)reconcile {
    [self updateCursorFence];
    if (!self.enabled || !self.displays.count) { [self teardown]; return; }
    NSMutableSet *wanted = [NSMutableSet set];
    for (NSDictionary *display in self.displays) [wanted addObject:display[@"displayID"]];
    for (NSNumber *ident in self.sources.allKeys) {
        if ([wanted containsObject:ident]) continue;
        [self.sources[ident] stop];
        [self.sources removeObjectForKey:ident];
    }
    if (self.pipDisplayID && ![wanted containsObject:self.pipDisplayID]) [self closePiP];
    self.permissionMissing = !CGPreflightScreenCaptureAccess();
    [self rebuildDock];
    if (!self.permissionMissing) [self startMissingSources];
}

- (void)startMissingSources {
    BOOL missing = NO;
    for (NSDictionary *display in self.displays) if (!self.sources[display[@"displayID"]]) missing = YES;
    if (!missing || self.fetching) return;
    self.fetching = YES;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.fetching = NO;
            if (!self.enabled) return;
            if (!content || error) {
                self.permissionMissing = !CGPreflightScreenCaptureAccess();
                [self rebuildDock];
                return;
            }
            BOOL stillMissing = NO;
            for (NSDictionary *display in self.displays) {
                NSNumber *ident = display[@"displayID"];
                if (self.sources[ident]) continue;
                SCDisplay *match = nil;
                for (SCDisplay *candidate in content.displays) if (candidate.displayID == ident.unsignedIntValue) match = candidate;
                YMPreviewSource *source = match ? [[YMPreviewSource alloc] initWithDisplay:match] : nil;
                if (source) self.sources[ident] = source; else stillMissing = YES;
            }
            [self bindLayers];
            // A display that was just created can take a moment to reach ScreenCaptureKit.
            if (stillMissing && self.retries < 10) {
                self.retries += 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self startMissingSources]; });
            }
        });
    }];
}

- (void)bindLayers {
    for (NSUInteger index = 0; index < self.displays.count && index < self.cards.count; index++) {
        YMPreviewSource *source = self.sources[self.displays[index][@"displayID"]];
        if (!source) continue;
        [source attachLayer:self.cards[index].picture];
        if (index < self.tabs.count) [source attachLayer:self.tabs[index].picture];
    }
    if (self.pipDisplayID && self.sources[self.pipDisplayID]) {
        [self.sources[self.pipDisplayID] attachLayer:self.pipView.picture];
        self.sources[self.pipDisplayID].live = YES;
    }
}

#pragma mark Dock

- (NSScreen *)dockScreen {
    // The rightmost physical screen; virtual displays are never used for the dock.
    NSScreen *best = nil;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID ident = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if ([VDVirtualDisplay isVirtualDisplay:ident]) continue;
        if (!best || NSMaxX(screen.frame) > NSMaxX(best.frame)) best = screen;
    }
    return best ?: NSScreen.mainScreen;
}

- (NSUInteger)itemCount { return self.permissionMissing ? 1 : self.displays.count; }

- (NSRect)dockFrameExpanded:(BOOL)expanded {
    NSRect visible = [self dockScreen].visibleFrame;
    CGFloat count = (CGFloat)MAX((NSUInteger)1, [self itemCount]);
    CGFloat width = expanded ? YMCardWidth + YMDockPad * 2 : YMTabWidth;
    CGFloat height = expanded ? count * YMCardHeight + (count - 1) * YMCardGap + YMDockPad * 2
                              : count * YMTabHeight + (count - 1) * YMTabGap;
    return NSMakeRect(NSMaxX(visible) - width, NSMidY(visible) - height / 2, width, height);
}

- (void)rebuildDock {
    if (!self.dock) {
        YMPreviewPanel *panel = [[YMPreviewPanel alloc] initWithContentRect:[self dockFrameExpanded:NO]
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        YMConfigureFloatingPanel(panel);
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = NO;
        YMPreviewDockView *view = [[YMPreviewDockView alloc] initWithFrame:NSZeroRect];
        view.wantsLayer = YES;
        __weak YMWorkspacePreview *weakSelf = self;
        view.onHover = ^(BOOL inside) { [weakSelf hoverChanged:inside]; };
        panel.contentView = view;
        self.dock = panel;
        self.dockView = view;
    }
    for (NSView *view in [(NSArray<NSView *> *)self.tabs arrayByAddingObjectsFromArray:(NSArray<NSView *> *)self.cards]) [view removeFromSuperview];
    for (YMPreviewSource *source in self.sources.allValues) [source.layers removeAllObjects];
    [self.tabs removeAllObjects];
    [self.cards removeAllObjects];
    __weak YMWorkspacePreview *weakSelf = self;
    if (self.permissionMissing) {
        YMPreviewTab *tab = [[YMPreviewTab alloc] initWithFrame:NSZeroRect];
        tab.layer.backgroundColor = NSColor.systemOrangeColor.CGColor;
        tab.onClick = ^{ [weakSelf requestPermission]; };
        YMPreviewCard *card = [[YMPreviewCard alloc] initWithFrame:NSZeroRect name:@"需要「屏幕录制」权限才能预览 · 点此授权"];
        card.layer.backgroundColor = [NSColor colorWithWhite:0.16 alpha:0.95].CGColor;
        card.label.lineBreakMode = NSLineBreakByWordWrapping;
        card.onClick = ^{ [weakSelf requestPermission]; };
        [self.tabs addObject:tab];
        [self.cards addObject:card];
    } else {
        for (NSDictionary *display in self.displays) {
            NSNumber *ident = display[@"displayID"];
            YMPreviewTab *tab = [[YMPreviewTab alloc] initWithFrame:NSZeroRect];
            tab.toolTip = display[@"name"];
            tab.onClick = ^{ [weakSelf openPiPForDisplayID:ident]; };
            YMPreviewCard *card = [[YMPreviewCard alloc] initWithFrame:NSZeroRect name:display[@"name"] ?: @""];
            card.onClick = ^{ [weakSelf openPiPForDisplayID:ident]; };
            [self.tabs addObject:tab];
            [self.cards addObject:card];
        }
    }
    for (NSView *view in [(NSArray<NSView *> *)self.tabs arrayByAddingObjectsFromArray:(NSArray<NSView *> *)self.cards]) [self.dockView addSubview:view];
    [self bindLayers];
    [self layoutDockAnimated:NO];
    [self.dock orderFrontRegardless];
}

- (void)layoutSubviewsExpanded:(BOOL)expanded inSize:(NSSize)size {
    CGFloat y = size.height - (expanded ? YMDockPad : 0);
    for (NSUInteger index = 0; index < self.cards.count; index++) {
        if (expanded) {
            y -= YMCardHeight;
            self.cards[index].frame = NSMakeRect(YMDockPad, y, YMCardWidth, YMCardHeight);
            y -= YMCardGap;
        } else {
            y -= YMTabHeight;
            self.tabs[index].frame = NSMakeRect(0, y, YMTabWidth, YMTabHeight);
            y -= YMTabGap;
        }
    }
}

- (void)layoutDockAnimated:(BOOL)animated {
    if (!self.dock) return;
    BOOL expanded = self.expanded;
    NSRect frame = [self dockFrameExpanded:expanded];
    [self layoutSubviewsExpanded:expanded inSize:frame.size];
    void (^changes)(void) = ^{
        [self.dock.animator setFrame:frame display:YES];
        for (YMPreviewTab *tab in self.tabs) tab.animator.alphaValue = expanded ? 0 : 1;
        for (YMPreviewCard *card in self.cards) card.animator.alphaValue = expanded ? 1 : 0;
    };
    if (animated) YMAnimate(0.24, changes, nil);
    else {
        [self.dock setFrame:frame display:YES];
        for (YMPreviewTab *tab in self.tabs) tab.alphaValue = expanded ? 0 : 1;
        for (YMPreviewCard *card in self.cards) card.alphaValue = expanded ? 1 : 0;
    }
}

- (void)hoverChanged:(BOOL)inside {
    if (inside) {
        if (self.expanded) return;
        self.expanded = YES;
        [self layoutDockAnimated:YES];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.dock || NSPointInRect(NSEvent.mouseLocation, self.dock.frame)) return;
        [self collapseDock];
    });
}
- (void)collapseDock {
    if (!self.expanded) return;
    self.expanded = NO;
    [self layoutDockAnimated:YES];
}

- (void)requestPermission {
    CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

#pragma mark Agent action marks

- (void)markPoint:(CGPoint)point {
    if (!self.enabled) return;
    for (NSUInteger index = 0; index < self.displays.count; index++) {
        NSNumber *ident = self.displays[index][@"displayID"];
        CGRect bounds = CGDisplayBounds(ident.unsignedIntValue);
        if (!CGRectContainsPoint(bounds, point)) continue;
        // Normalized position, origin bottom-left to match AppKit layers.
        CGFloat nx = (point.x - bounds.origin.x) / bounds.size.width;
        CGFloat ny = 1 - (point.y - bounds.origin.y) / bounds.size.height;
        NSMutableArray<CALayer *> *hosts = [NSMutableArray array];
        if (index < self.cards.count) [hosts addObject:self.cards[index].picture];
        if ([self.pipDisplayID isEqual:ident] && self.pip.visible) [hosts addObject:self.pipView.picture];
        for (CALayer *host in hosts) {
            CGRect fit = YMAspectFitRect(bounds.size, host.bounds);
            CGPoint at = CGPointMake(CGRectGetMinX(fit) + nx * fit.size.width, CGRectGetMinY(fit) + ny * fit.size.height);
            YMAddRipple(host, at, MAX(7, fit.size.width / 60));
        }
        return;
    }
}


#pragma mark Cursor fence

// Virtual displays are part of the desktop, so the person's pointer can slide
// past a physical edge into a screen they cannot see and appear lost. Agents
// never use the real pointer, so keep it on physical displays: whenever it
// enters a virtual display, put it back at the nearest physical point.
- (void)updateCursorFence {
    id setting = [NSUserDefaults.standardUserDefaults objectForKey:@"YMCursorFenceEnabled"];
    // On while the preview is on (the agent-screen setup), unless set explicitly.
    BOOL want = self.displays.count > 0 && (setting ? [setting boolValue] : self.enabled);
    if (want && !self.fenceGlobalMonitor) {
        __weak YMWorkspacePreview *weakSelf = self;
        NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged;
        self.fenceGlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) { (void)event; [weakSelf enforceCursorFence]; }];
        self.fenceLocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) { [weakSelf enforceCursorFence]; return event; }];
        [self enforceCursorFence];
    } else if (!want && self.fenceGlobalMonitor) {
        [NSEvent removeMonitor:self.fenceGlobalMonitor];
        if (self.fenceLocalMonitor) [NSEvent removeMonitor:self.fenceLocalMonitor];
        self.fenceGlobalMonitor = nil;
        self.fenceLocalMonitor = nil;
    }
}
- (void)enforceCursorFence {
    CGEventRef now = CGEventCreate(NULL);
    if (!now) return;
    CGPoint point = CGEventGetLocation(now);
    CFRelease(now);
    BOOL inside = NO;
    for (NSDictionary *display in self.displays)
        if (CGRectContainsPoint(CGDisplayBounds([display[@"displayID"] unsignedIntValue]), point)) inside = YES;
    if (!inside) return;
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) return;
    CGPoint best = CGPointZero;
    double bestDistance = INFINITY;
    for (uint32_t index = 0; index < count; index++) {
        if ([VDVirtualDisplay isVirtualDisplay:ids[index]]) continue;
        CGRect bounds = CGDisplayBounds(ids[index]);
        CGPoint clamped = CGPointMake(MIN(MAX(point.x, CGRectGetMinX(bounds)), CGRectGetMaxX(bounds) - 2),
                                      MIN(MAX(point.y, CGRectGetMinY(bounds)), CGRectGetMaxY(bounds) - 2));
        double distance = hypot(clamped.x - point.x, clamped.y - point.y);
        if (distance < bestDistance) { bestDistance = distance; best = clamped; }
    }
    if (!isfinite(bestDistance)) return;
    CGWarpMouseCursorPosition(best);
    CGAssociateMouseAndMouseCursorPosition(true);
}

#pragma mark Takeover

// The person drives the virtual display from the picture-in-picture panel
// without lending their pointer: a tap is resolved to the accessibility
// element at that spot and pressed (or focused, for text); typing edits the
// focused text element; scrolling is delivered to the owning process only.
// The real pointer, the front app and the person's key window are never used.
static BOOL YMTakeoverEnabled(void) { return [NSUserDefaults.standardUserDefaults boolForKey:@"YMWorkspacePreviewTakeoverEnabled"]; }
static BOOL YMElementHasAction(AXUIElementRef element, CFStringRef action) {
    CFArrayRef names = NULL;
    if (AXUIElementCopyActionNames(element, &names) != kAXErrorSuccess || !names) return NO;
    BOOL found = CFArrayContainsValue(names, CFRangeMake(0, CFArrayGetCount(names)), action);
    CFRelease(names);
    return found;
}
static NSString *YMElementRole(AXUIElementRef element) {
    CFTypeRef role = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) != kAXErrorSuccess || !role) return @"";
    return CFBridgingRelease(role);
}
static BOOL YMElementIsText(AXUIElementRef element) {
    NSString *role = YMElementRole(element);
    return [@[@"AXTextField", @"AXTextArea", @"AXSearchField", @"AXComboBox"] containsObject:role];
}


#include <dlfcn.h>
typedef AXError (*YMPreviewWindowIDFunction)(AXUIElementRef, CGWindowID *);
// The top ordinary window at a global point: owner pid and CGWindowID.
static BOOL YMWindowAtPoint(CGPoint point, pid_t *pid, CGWindowID *windowID) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *info in list) {
        if ([info[(id)kCGWindowLayer] integerValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds) || !CGRectContainsPoint(bounds, point)) continue;
        *pid = [info[(id)kCGWindowOwnerPID] intValue];
        *windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        return YES;
    }
    return NO;
}
// The top ordinary window at a global point, as an accessibility element.
static AXUIElementRef YMCopyWindowAtPoint(CGPoint point) {
    static YMPreviewWindowIDFunction getWindow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ getWindow = (YMPreviewWindowIDFunction)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); });
    if (!getWindow) return NULL;
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *info in list) {
        if ([info[(id)kCGWindowLayer] integerValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds) || !CGRectContainsPoint(bounds, point)) continue;
        pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
        CGWindowID windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        CFArrayRef windows = NULL;
        AXUIElementRef found = NULL;
        if (app && AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
            for (CFIndex index = 0; index < CFArrayGetCount(windows); index++) {
                AXUIElementRef element = (AXUIElementRef)CFArrayGetValueAtIndex(windows, index);
                CGWindowID candidate = 0;
                if (getWindow(element, &candidate) == kAXErrorSuccess && candidate == windowID) { found = (AXUIElementRef)CFRetain(element); break; }
            }
        }
        if (windows) CFRelease(windows);
        if (app) CFRelease(app);
        return found;   // the topmost window wins, found or not
    }
    return NULL;
}

static CGRect YMElementFrame(AXUIElementRef element) {
    CFTypeRef frameValue = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXFrame"), &frameValue) == kAXErrorSuccess && frameValue) {
        CGRect frame = CGRectZero;
        BOOL ok = CFGetTypeID(frameValue) == AXValueGetTypeID() && AXValueGetValue((AXValueRef)frameValue, kAXValueTypeCGRect, &frame);
        CFRelease(frameValue);
        if (ok && frame.size.width > 0) return frame;
    }
    CFTypeRef positionValue = NULL, sizeValue = NULL;
    CGPoint position = CGPointZero; CGSize size = CGSizeZero;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &positionValue) == kAXErrorSuccess && positionValue) {
        AXValueGetValue((AXValueRef)positionValue, kAXValueTypeCGPoint, &position); CFRelease(positionValue);
    }
    if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess && sizeValue) {
        AXValueGetValue((AXValueRef)sizeValue, kAXValueTypeCGSize, &size); CFRelease(sizeValue);
    }
    return CGRectMake(position.x, position.y, size.width, size.height);
}
// Web content often answers a hit test with a stack of generic groups in front
// of the real control, so search the window's tree for the smallest control
// whose frame contains the point.
static NSArray *YMControlsAtPoint(AXUIElementRef window, CGPoint point, NSArray *controls, BOOL prune) {
    NSMutableArray *found = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(__bridge id)window];
    NSUInteger visited = 0;
    while (queue.count && visited < (prune ? 6000 : 12000)) {
        id item = queue.firstObject; [queue removeObjectAtIndex:0]; visited++;
        AXUIElementRef element = (__bridge AXUIElementRef)item;
        CGRect frame = YMElementFrame(element);
        BOOL sized = frame.size.width > 0 && frame.size.height > 0;
        NSString *role = YMElementRole(element);
        // Web groups can report frames that do not cover their children, so the
        // second pass walks everything (bounded) instead of pruning.
        if (prune && sized && !CGRectContainsPoint(frame, point)) continue;
        if (sized && CGRectContainsPoint(frame, point) && ([controls containsObject:role] || YMElementIsText(element)))
            [found addObject:@{@"element":item, @"area":@(frame.size.width * frame.size.height), @"role":role}];
        CFArrayRef children = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef *)&children) == kAXErrorSuccess && children) {
            [queue addObjectsFromArray:(__bridge NSArray *)children];
            CFRelease(children);
        }
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"area"] compare:b[@"area"]]; }];
    return found;
}
- (void)toggleTakeover:(id)sender {
    (void)sender;
    if (self.takeoverDisplayID) [self endTakeover]; else [self beginTakeover];
}
- (void)beginTakeover {
    if (!YMTakeoverEnabled() || !self.pipDisplayID || !AXIsProcessTrusted()) return;
    self.takeoverDisplayID = self.pipDisplayID;
    self.takeoverTextElement = nil;
    self.pip.takeoverKey = YES;
    [self.pip makeKeyWindow];
    self.pipView.takeover = YES;
}
- (void)endTakeover {
    if (!self.takeoverDisplayID) return;
    self.takeoverDisplayID = nil;
    self.takeoverTextElement = nil;
    self.pipView.takeover = NO;
    self.pip.takeoverKey = NO;
    [self.pip resignKeyWindow];
}
- (CGPoint)takeoverTargetForViewPoint:(NSPoint)point valid:(BOOL *)valid {
    CGRect bounds = CGDisplayBounds(self.takeoverDisplayID.unsignedIntValue);
    CGRect fit = YMAspectFitRect(bounds.size, self.pipView.picture.bounds);
    CGFloat nx = (point.x - fit.origin.x) / fit.size.width;
    CGFloat ny = 1 - (point.y - fit.origin.y) / fit.size.height;
    *valid = nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1;
    return CGPointMake(bounds.origin.x + nx * bounds.size.width, bounds.origin.y + ny * bounds.size.height);
}
// Shared with --display tap so the same path can be exercised without a mouse.
- (NSDictionary *)tapAtGlobalPoint:(CGPoint)target secondary:(BOOL)secondary {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementRef hit = NULL;
    AXError error = AXUIElementCopyElementAtPosition(system, (float)target.x, (float)target.y, &hit);
    CFRelease(system);
    if (error != kAXErrorSuccess || !hit) return @{@"status":@"miss"};
    // Only act inside a virtual display; never on the person's screens.
    BOOL onVirtual = NO;
    for (NSDictionary *display in self.displays)
        if (CGRectContainsPoint(CGDisplayBounds([display[@"displayID"] unsignedIntValue]), target)) onVirtual = YES;
    if (!onVirtual) { CFRelease(hit); return @{@"status":@"outside"}; }
    NSString *role = YMElementRole(hit);
    // Collect the chain from the hit element upward, then prefer a real control
    // (button, link, checkbox, ...) over a generic group that also lists AXPress.
    NSMutableArray *chain = [NSMutableArray array];
    AXUIElementRef element = (AXUIElementRef)CFRetain(hit);
    for (int depth = 0; depth < 10 && element; depth++) {
        [chain addObject:(__bridge id)element];
        AXUIElementRef parent = NULL;
        AXUIElementCopyAttributeValue(element, kAXParentAttribute, (CFTypeRef *)&parent);
        CFRelease(element);
        element = parent;
        if (element && [YMElementRole(element) isEqualToString:@"AXWebArea"]) { CFRelease(element); element = NULL; }
    }
    if (element) CFRelease(element);
    NSArray *controls = @[@"AXButton", @"AXLink", @"AXCheckBox", @"AXRadioButton", @"AXMenuItem", @"AXMenuButton",
                          @"AXPopUpButton", @"AXTab", @"AXDisclosureTriangle", @"AXCell", @"AXRow"];
    NSDictionary *result = nil;
    CFStringRef action = secondary ? kAXShowMenuAction : kAXPressAction;
    AXUIElementRef window = YMCopyWindowAtPoint(target);
    NSArray *candidates = window ? YMControlsAtPoint(window, target, controls, YES) : @[];
    if (window && !candidates.count) candidates = YMControlsAtPoint(window, target, controls, NO);
    if (window) CFRelease(window);
    for (NSDictionary *candidate in candidates) {
        AXUIElementRef element = (__bridge AXUIElementRef)candidate[@"element"];
        if (!secondary && YMElementIsText(element)) {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute, kCFBooleanTrue);
            self.takeoverTextElement = candidate[@"element"];
            result = @{@"status":@"focused", @"role":candidate[@"role"]};
            break;
        }
        if (YMElementHasAction(element, action) && AXUIElementPerformAction(element, action) == kAXErrorSuccess) {
            result = @{@"status":@"pressed", @"role":candidate[@"role"]};
            break;
        }
    }
    // Fall back to the hit-test chain (generic elements that still accept a press).
    for (id item in chain) {
        if (result) break;
        AXUIElementRef candidate = (__bridge AXUIElementRef)item;
        if (YMElementHasAction(candidate, action) && AXUIElementPerformAction(candidate, action) == kAXErrorSuccess)
            result = @{@"status":@"pressed", @"role":YMElementRole(candidate), @"fallback":@YES};
    }
    CFRelease(hit);
    [self markPoint:target];
    return result ?: @{@"status":@"nothing-to-press", @"role":role};
}
// Web inputs ignore inserted selected text but accept a whole new value, so
// edit the value string: append on typing, drop the last character on delete.
static NSString *YMElementValue(AXUIElementRef element) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) != kAXErrorSuccess || !value) return @"";
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:NSString.class] ? object : @"";
}
- (NSDictionary *)typeText:(NSString *)text {
    id target = self.takeoverTextElement;
    if (!target) return @{@"status":@"no-text-focus"};
    AXUIElementRef element = (__bridge AXUIElementRef)target;
    NSString *next = [YMElementValue(element) stringByAppendingString:text];
    AXError error = AXUIElementSetAttributeValue(element, kAXValueAttribute, (__bridge CFStringRef)next);
    return @{@"status":error == kAXErrorSuccess ? @"typed" : @"failed", @"value":YMElementValue(element)};
}
- (void)deleteBackward {
    id target = self.takeoverTextElement;
    if (!target) return;
    AXUIElementRef element = (__bridge AXUIElementRef)target;
    NSString *current = YMElementValue(element);
    if (!current.length) return;
    NSRange last = [current rangeOfComposedCharacterSequenceAtIndex:current.length - 1];
    AXUIElementSetAttributeValue(element, kAXValueAttribute, (__bridge CFStringRef)[current substringToIndex:last.location]);
}
- (void)handleTakeoverCommand:(NSString *)command {
    if ([command isEqualToString:@"escape"]) { [self endTakeover]; return; }
    if ([command isEqualToString:@"delete"]) { [self deleteBackward]; return; }
    if ([command isEqualToString:@"paste"]) {
        NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
        if (text.length) [self typeText:text];
        return;
    }
    if ([command isEqualToString:@"return"]) {
        AXUIElementRef target = (__bridge AXUIElementRef)self.takeoverTextElement;
        if (target && YMElementHasAction(target, kAXConfirmAction)) AXUIElementPerformAction(target, kAXConfirmAction);
    }
}
// The typing position (caret, else the field) mapped from the virtual display
// into the picture-in-picture view.
- (NSRect)caretRectInPiP {
    AXUIElementRef field = (__bridge AXUIElementRef)self.takeoverTextElement;
    if (!field || !self.takeoverDisplayID) return NSZeroRect;
    CGRect global = CGRectNull;
    CFTypeRef rangeValue = NULL;
    if (AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute, &rangeValue) == kAXErrorSuccess && rangeValue) {
        CFTypeRef boundsValue = NULL;
        if (AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute, rangeValue, &boundsValue) == kAXErrorSuccess && boundsValue) {
            CGRect caret = CGRectZero;
            if (AXValueGetValue((AXValueRef)boundsValue, kAXValueTypeCGRect, &caret) && caret.size.height > 0) global = caret;
            CFRelease(boundsValue);
        }
        CFRelease(rangeValue);
    }
    if (CGRectIsNull(global)) {
        CGRect frame = YMElementFrame(field);
        if (frame.size.height <= 0) return NSZeroRect;
        global = CGRectMake(frame.origin.x + 4, frame.origin.y, 2, frame.size.height);
    }
    CGRect bounds = CGDisplayBounds(self.takeoverDisplayID.unsignedIntValue);
    CGRect fit = YMAspectFitRect(bounds.size, self.pipView.picture.bounds);
    CGFloat sx = fit.size.width / bounds.size.width, sy = fit.size.height / bounds.size.height;
    CGFloat x = fit.origin.x + (global.origin.x - bounds.origin.x) * sx;
    CGFloat bottom = fit.origin.y + (1 - (CGRectGetMaxY(global) - bounds.origin.y) / bounds.size.height) * fit.size.height;
    return NSMakeRect(x, bottom, MAX(2, global.size.width * sx), MAX(8, global.size.height * sy));
}
- (void)showComposition:(NSString *)text {
    self.pipView.pillLabel.stringValue = text.length
        ? [NSString stringWithFormat:@"输入中：%@", text]
        : @"你正在操作 · Agent 已暂停 · 按 Esc 交还";
    self.pipView.needsLayout = YES;
}
- (void)handleTakeoverScroll:(NSEvent *)event atViewPoint:(NSPoint)point {
    BOOL valid = NO;
    CGPoint target = [self takeoverTargetForViewPoint:point valid:&valid];
    if (!valid) return;
    double scale = event.hasPreciseScrollingDeltas ? 1 : 10;
    [self scrollAtGlobalPoint:target dx:event.scrollingDeltaX * scale dy:event.scrollingDeltaY * scale];
}
// Scroll the window under a virtual-display point without moving the pointer:
// the wheel event goes to that app only and names the window it is for.
- (NSDictionary *)scrollAtGlobalPoint:(CGPoint)target dx:(double)dx dy:(double)dy {
    BOOL onVirtual = NO;
    for (NSDictionary *display in self.displays)
        if (CGRectContainsPoint(CGDisplayBounds([display[@"displayID"] unsignedIntValue]), target)) onVirtual = YES;
    pid_t pid = 0; CGWindowID windowID = 0;
    if (!onVirtual || !YMWindowAtPoint(target, &pid, &windowID)) return @{@"status":@"miss"};
    CGEventRef wheel = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, (int32_t)llround(dy), (int32_t)llround(dx), 0);
    if (!wheel) return @{@"status":@"failed"};
    CGEventSetLocation(wheel, target);
    CGEventSetIntegerValueField(wheel, kCGMouseEventWindowUnderMousePointer, windowID);
    CGEventSetIntegerValueField(wheel, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, windowID);
    CGEventPostToPid(pid, wheel);
    CFRelease(wheel);
    return @{@"status":@"scrolled", @"window":@(windowID)};
}

#pragma mark Picture in picture

- (NSString *)nameForDisplayID:(NSNumber *)ident {
    for (NSDictionary *display in self.displays) if ([display[@"displayID"] isEqual:ident]) return display[@"name"] ?: @"";
    return @"";
}

- (NSRect)defaultPiPFrame {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:YMPreviewPiPFrameKey];
    NSRect frame = saved.length ? NSRectFromString(saved) : NSZeroRect;
    for (NSScreen *screen in NSScreen.screens)
        if (frame.size.width >= 240 && NSContainsRect(screen.visibleFrame, frame)) return frame;
    NSRect visible = [self dockScreen].visibleFrame;
    CGFloat width = 640, height = 360;
    return NSMakeRect(NSMaxX(visible) - width - YMTabWidth - 24, NSMinY(visible) + 24, width, height);
}

- (void)openPiPForDisplayID:(NSNumber *)ident {
    [self collapseDock];
    if (self.pipDisplayID && ![self.pipDisplayID isEqual:ident]) {
        [self endTakeover];
        YMPreviewSource *previous = self.sources[self.pipDisplayID];
        [previous detachLayer:self.pipView.picture];
        previous.live = NO;
    }
    if (!self.pip) {
        YMPreviewPanel *panel = [[YMPreviewPanel alloc] initWithContentRect:[self defaultPiPFrame]
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        YMConfigureFloatingPanel(panel);
        panel.titleVisibility = NSWindowTitleHidden;
        panel.titlebarAppearsTransparent = YES;
        for (NSWindowButton button = NSWindowCloseButton; button <= NSWindowZoomButton; button++)
            [panel standardWindowButton:button].hidden = YES;
        panel.movableByWindowBackground = YES;
        panel.contentAspectRatio = NSMakeSize(16, 9);
        panel.minSize = NSMakeSize(320, 180);
        panel.backgroundColor = NSColor.blackColor;
        YMPiPView *view = [[YMPiPView alloc] initWithFrame:NSZeroRect];
        __weak YMWorkspacePreview *weakSelf = self;
        view.onDoubleClick = ^{ [weakSelf togglePiPSize]; };
        view.closeButton.target = self;
        view.closeButton.action = @selector(closePiPFromButton:);
        view.takeoverAvailable = YMTakeoverEnabled();
        view.takeoverButton.target = self;
        view.takeoverButton.action = @selector(toggleTakeover:);
        view.onTap = ^(NSPoint point, BOOL secondary, NSInteger clicks) {
            (void)clicks;
            YMWorkspacePreview *strong = weakSelf;
            if (!strong.takeoverDisplayID) return;
            BOOL valid = NO;
            CGPoint target = [strong takeoverTargetForViewPoint:point valid:&valid];
            if (valid) [strong tapAtGlobalPoint:target secondary:secondary];
        };
        view.onScroll = ^(NSPoint point, NSEvent *event) { [weakSelf handleTakeoverScroll:event atViewPoint:point]; };
        view.onInsert = ^(NSString *text) { [weakSelf typeText:text]; };
        view.onCommand = ^(NSString *command) { [weakSelf handleTakeoverCommand:command]; };
        view.onMarked = ^(NSString *text) { [weakSelf showComposition:text]; };
        view.caretRect = ^NSRect { return [weakSelf caretRectInPiP]; };
        view.onLeftTooLong = ^{ [weakSelf endTakeover]; };
        panel.contentView = view;
        self.pip = panel;
        self.pipView = view;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pipFrameChanged:) name:NSWindowDidEndLiveResizeNotification object:panel];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pipFrameChanged:) name:NSWindowDidMoveNotification object:panel];
    }
    self.pipDisplayID = ident;
    self.pipView.takeoverAvailable = YMTakeoverEnabled();
    self.pipView.title.stringValue = [self nameForDisplayID:ident];
    YMSetContents(self.pipView.picture, nil);
    YMPreviewSource *source = self.sources[ident];
    if (source) { [source attachLayer:self.pipView.picture]; source.live = YES; }
    if (!self.pip.visible) {
        self.pip.alphaValue = 0;
        [self.pip orderFrontRegardless];
        YMAnimate(0.2, ^{ self.pip.animator.alphaValue = 1; }, nil);
    }
}

- (void)pipFrameChanged:(NSNotification *)note {
    (void)note;
    if (self.pip) [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(self.pip.frame) forKey:YMPreviewPiPFrameKey];
}

- (void)togglePiPSize {
    NSRect frame = self.pip.frame;
    NSRect visible = (self.pip.screen ?: [self dockScreen]).visibleFrame;
    BOOL large = frame.size.width >= 1000;
    CGFloat width = large ? 640 : MIN(1280, visible.size.width - 48);
    CGFloat height = width * 9 / 16;
    NSRect next = NSMakeRect(NSMaxX(frame) - width, NSMinY(frame), width, height);
    next.origin.x = MAX(NSMinX(visible) + 12, MIN(next.origin.x, NSMaxX(visible) - width - 12));
    next.origin.y = MAX(NSMinY(visible) + 12, MIN(next.origin.y, NSMaxY(visible) - height - 12));
    YMAnimate(0.25, ^{ [self.pip.animator setFrame:next display:YES]; }, nil);
}

- (void)closePiPFromButton:(id)sender { (void)sender; [self closePiP]; }

- (void)closePiP {
    if (!self.pip) return;
    [self endTakeover];
    if (self.pipDisplayID) {
        YMPreviewSource *source = self.sources[self.pipDisplayID];
        [source detachLayer:self.pipView.picture];
        source.live = NO;
    }
    self.pipDisplayID = nil;
    YMPreviewPanel *panel = self.pip;
    YMAnimate(0.18, ^{ panel.animator.alphaValue = 0; }, ^{ [panel orderOut:nil]; });
}
@end
