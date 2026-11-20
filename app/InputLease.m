#import "InputLease.h"

static NSDistributedNotificationCenter *YMLeaseBus(void) { return NSDistributedNotificationCenter.defaultCenter; }

static void YMLeasePost(NSString *name, NSDictionary *info) {
    [YMLeaseBus() postNotificationName:name object:YMInputLeaseObject userInfo:info
                               options:NSDistributedNotificationDeliverImmediately];
}

// Request and lease identifiers travel between processes; accept only short
// UUID-like tokens.
static NSString *YMLeaseIdentifier(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = value;
    if (!text.length || text.length > 64) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? text : nil;
}

static NSTextField *YMLeaseLabel(NSString *text, CGFloat size, NSFontWeight weight, CGFloat width) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.preferredMaxLayoutWidth = width;
    label.selectable = NO;
    return label;
}

// The prompt and notice never become active, so their buttons must act on the
// first click instead of spending it on bringing the panel forward.
@interface YMLeaseButton : NSButton
@end
@implementation YMLeaseButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
@end

static NSScreen *YMLeasePrimaryScreen(void) {
    // The first screen holds the menu bar; yomado keeps a physical display main.
    return NSScreen.screens.firstObject ?: NSScreen.mainScreen;
}

@interface YMInputLeaseCenter ()
@property(nonatomic, readwrite, nullable) NSString *activeLeaseID;
@property(nonatomic, nullable) NSPanel *prompt;
@property(nonatomic, copy, nullable) NSString *promptRequestID;
@property(nonatomic, copy, nullable) NSString *promptAgent;
@property(nonatomic) NSTimeInterval promptSeconds;
@property(nonatomic, nullable) NSDate *promptDeadline;
@property(nonatomic, nullable) NSTextField *promptCountdown;
@property(nonatomic, nullable) NSTimer *promptTimer;
@property(nonatomic, nullable) NSPanel *indicator;
@property(nonatomic, nullable) NSTextField *indicatorDetail;
@property(nonatomic, nullable) NSTimer *leaseTimer;
@property(nonatomic, nullable) NSDate *expiry;
@property(nonatomic, copy, nullable) NSString *leaseAgent;
@property(nonatomic, nullable) NSRunningApplication *previousApplication;
@property(nonatomic) CGPoint previousCursor;
@property(nonatomic) BOOL hasPreviousCursor;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *endedLeases;
@property(nonatomic) BOOL started;
@end

@implementation YMInputLeaseCenter

- (void)start {
    if (self.started) return;
    self.started = YES;
    self.endedLeases = [NSMutableDictionary dictionary];
    for (NSString *name in @[YMInputLeaseRequestName, YMInputLeaseReleaseName, YMInputLeaseStatusName])
        [YMLeaseBus() addObserver:self selector:@selector(received:) name:name object:YMInputLeaseObject
               suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
}

- (void)stop {
    if (!self.started) return;
    if (self.prompt) [self finishPromptGranted:NO status:@"denied"];
    [self endActiveLeaseWithReason:@"quit"];
    [YMLeaseBus() removeObserver:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.started = NO;
}

- (void)respond:(NSString *)requestID status:(NSString *)status extra:(NSDictionary *)extra {
    NSMutableDictionary *info = [extra mutableCopy];
    info[@"requestID"] = requestID;
    info[@"status"] = status;
    YMLeasePost(YMInputLeaseResponseName, info);
}

- (void)received:(NSNotification *)note {
    NSDictionary *info = [note.userInfo isKindOfClass:NSDictionary.class] ? note.userInfo : @{};
    NSString *requestID = YMLeaseIdentifier(info[@"requestID"]);
    if (!requestID) return;
    if ([note.name isEqualToString:YMInputLeaseRequestName]) [self handleRequest:info requestID:requestID];
    else if ([note.name isEqualToString:YMInputLeaseReleaseName]) [self handleRelease:info requestID:requestID];
    else if ([note.name isEqualToString:YMInputLeaseStatusName]) [self handleStatus:info requestID:requestID];
}

- (void)handleRequest:(NSDictionary *)info requestID:(NSString *)requestID {
    [self expireElapsedState];
    if (self.activeLeaseID || self.prompt) {
        [self respond:requestID status:@"busy" extra:@{@"message":@"另一个 Agent 正在使用或申请鼠标键盘。"}];
        return;
    }
    NSString *agent = YMInputLeaseDisplayText(info[@"agent"], YMInputLeaseAgentLength, @"未命名 Agent");
    NSString *reason = YMInputLeaseDisplayText(info[@"reason"], YMInputLeaseReasonLength, @"未说明原因");
    NSTimeInterval seconds = YMInputLeaseClampSeconds(info[@"seconds"]);
    [self respond:requestID status:@"pending" extra:@{@"decisionSeconds":@(YMInputLeaseDecisionSeconds)}];
    [self showPromptForRequest:requestID agent:agent reason:reason seconds:seconds];
}

- (void)handleRelease:(NSDictionary *)info requestID:(NSString *)requestID {
    [self expireElapsedState];
    NSString *leaseID = YMLeaseIdentifier(info[@"leaseID"]);
    if (leaseID && [leaseID isEqualToString:self.activeLeaseID]) {
        [self endActiveLeaseWithReason:@"released"];
        [self respond:requestID status:@"released" extra:@{@"leaseID":leaseID}];
    } else if (leaseID && self.endedLeases[leaseID]) {
        [self respond:requestID status:@"ended" extra:@{@"leaseID":leaseID, @"reason":self.endedLeases[leaseID]}];
    } else {
        [self respond:requestID status:@"unknown" extra:@{}];
    }
}

- (void)handleStatus:(NSDictionary *)info requestID:(NSString *)requestID {
    [self expireElapsedState];
    NSString *leaseID = YMLeaseIdentifier(info[@"leaseID"]);
    if (!leaseID) {
        [self respond:requestID status:(self.activeLeaseID || self.prompt) ? @"busy" : @"idle" extra:@{}];
    } else if ([leaseID isEqualToString:self.activeLeaseID]) {
        [self respond:requestID status:@"active" extra:@{@"leaseID":leaseID,
            @"remainingSeconds":@(MAX(round(self.expiry.timeIntervalSinceNow), 0))}];
    } else if (self.endedLeases[leaseID]) {
        [self respond:requestID status:@"ended" extra:@{@"leaseID":leaseID, @"reason":self.endedLeases[leaseID]}];
    } else {
        [self respond:requestID status:@"unknown" extra:@{}];
    }
}

#pragma mark - Prompt

- (void)expireElapsedState {
    NSDate *now = [NSDate date];
    if (self.activeLeaseID && YMInputLeaseDeadlineExpired(self.expiry, now)) {
        [self endActiveLeaseWithReason:@"expired"];
    }
    if (self.promptRequestID && YMInputLeaseDeadlineExpired(self.promptDeadline, now)) {
        [self finishPromptGranted:NO status:@"timeout"];
    }
}

- (void)showPromptForRequest:(NSString *)requestID agent:(NSString *)agent reason:(NSString *)reason
                     seconds:(NSTimeInterval)seconds {
    const CGFloat width = 400;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width + 40, 200)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"yomado";
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:YMLeaseLabel([NSString stringWithFormat:@"「%@」请求使用你的鼠标键盘", agent],
                                           15, NSFontWeightSemibold, width)];
    [stack addArrangedSubview:YMLeaseLabel([NSString stringWithFormat:@"原因：%@", reason], 13, NSFontWeightRegular, width)];
    NSTextField *note = YMLeaseLabel([NSString stringWithFormat:
        @"允许后最长 %@。期间屏幕右上角会一直显示提示，你可以随时停止。Agent 操作时请先不要动鼠标键盘。",
        YMInputLeaseRemainingText(seconds)], 12, NSFontWeightRegular, width);
    note.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:note];
    NSTextField *countdown = YMLeaseLabel(@"", 11, NSFontWeightRegular, width);
    countdown.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:countdown];

    NSButton *deny = [YMLeaseButton buttonWithTitle:@"拒绝" target:self action:@selector(denyPrompt:)];
    deny.keyEquivalent = @"\e";
    NSButton *allow = [YMLeaseButton buttonWithTitle:@"允许" target:self action:@selector(allowPrompt:)];
    allow.bezelColor = NSColor.controlAccentColor;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[deny, allow]];
    buttons.spacing = 8;
    NSStackView *row = [NSStackView stackViewWithViews:@[[[NSView alloc] init], buttons]];
    row.distribution = NSStackViewDistributionFill;
    [stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToConstant:width].active = YES;

    NSView *content = [[NSView alloc] init];
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
    ]];
    panel.contentView = content;
    [content layoutSubtreeIfNeeded];
    [panel setContentSize:NSMakeSize(width + 40, stack.fittingSize.height + 36)];

    NSRect visible = YMLeasePrimaryScreen().visibleFrame;
    NSSize size = panel.frame.size;
    [panel setFrameOrigin:NSMakePoint(NSMidX(visible) - size.width / 2,
                                      NSMaxY(visible) - size.height - visible.size.height * 0.18)];

    // Remember where the person left off before the prompt appeared: clicking
    // it can bring yomado forward. A lease that finishes normally hands back
    // the same front app and pointer position.
    self.previousApplication = NSWorkspace.sharedWorkspace.frontmostApplication;
    CGEventRef probe = CGEventCreate(NULL);
    self.hasPreviousCursor = probe != NULL;
    if (probe) { self.previousCursor = CGEventGetLocation(probe); CFRelease(probe); }

    self.prompt = panel;
    self.promptRequestID = requestID;
    self.promptAgent = agent;
    self.promptSeconds = seconds;
    self.promptDeadline = [NSDate dateWithTimeIntervalSinceNow:YMInputLeaseDecisionSeconds];
    self.promptCountdown = countdown;
    [self promptTick:nil];
    self.promptTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(promptTick:)
                                                      userInfo:nil repeats:YES];
    [panel orderFrontRegardless];
    [NSApp requestUserAttention:NSInformationalRequest];
}

- (void)promptTick:(NSTimer *)timer {
    (void)timer;
    NSTimeInterval remaining = self.promptDeadline.timeIntervalSinceNow;
    if (remaining <= 0) { [self finishPromptGranted:NO status:@"timeout"]; return; }
    self.promptCountdown.stringValue = [NSString stringWithFormat:@"%ld 秒内不回应将自动拒绝。", (long)ceil(remaining)];
}

- (void)allowPrompt:(id)sender { (void)sender; [self finishPromptGranted:YES status:@"granted"]; }
- (void)denyPrompt:(id)sender { (void)sender; [self finishPromptGranted:NO status:@"denied"]; }

- (void)finishPromptGranted:(BOOL)granted status:(NSString *)status {
    NSString *requestID = self.promptRequestID;
    if (!requestID) return;
    if (YMInputLeaseDeadlineExpired(self.promptDeadline, [NSDate date])) {
        granted = NO;
        status = @"timeout";
    }
    [self.promptTimer invalidate];
    self.promptTimer = nil;
    [self.prompt orderOut:nil];
    self.prompt = nil;
    self.promptRequestID = nil;
    self.promptCountdown = nil;
    if (!granted) {
        self.previousApplication = nil;
        self.hasPreviousCursor = NO;
        [self respond:requestID status:status extra:@{}];
        return;
    }

    NSString *leaseID = NSUUID.UUID.UUIDString.lowercaseString;
    self.activeLeaseID = leaseID;
    self.leaseAgent = self.promptAgent;
    self.expiry = [NSDate dateWithTimeIntervalSinceNow:self.promptSeconds];
    [self showIndicator];
    self.leaseTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(leaseTick:)
                                                     userInfo:nil repeats:YES];
    [self respond:requestID status:@"granted" extra:@{@"leaseID":leaseID, @"seconds":@(self.promptSeconds),
        @"expiresAt":@(self.expiry.timeIntervalSince1970)}];
}

#pragma mark - Indicator

- (void)showIndicator {
    const NSSize size = NSMakeSize(330, 64);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    background.material = NSVisualEffectMaterialHUDWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 12;
    background.layer.masksToBounds = YES;

    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:@"cursorarrow.rays" accessibilityDescription:@"Agent 输入"] ?: [[NSImage alloc] init]];
    icon.contentTintColor = NSColor.systemOrangeColor;
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:20 weight:NSFontWeightSemibold];
    NSTextField *title = [NSTextField labelWithString:@"Agent 正在使用你的鼠标键盘"];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSTextField *detail = [NSTextField labelWithString:@""];
    detail.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    detail.textColor = NSColor.secondaryLabelColor;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    NSStackView *text = [NSStackView stackViewWithViews:@[title, detail]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *stop = [YMLeaseButton buttonWithTitle:@"停止" target:self action:@selector(stopPressed:)];
    stop.toolTip = @"立即收回鼠标键盘，Agent 下次检查时会停下。";
    NSStackView *row = [NSStackView stackViewWithViews:@[icon, text, stop]];
    row.spacing = 10;
    row.edgeInsets = NSEdgeInsetsMake(0, 14, 0, 12);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],
        [row.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
    ]];
    panel.contentView = background;

    self.indicator = panel;
    self.indicatorDetail = detail;
    [self positionIndicator];
    [self leaseTick:nil];
    [panel orderFrontRegardless];
}

- (void)positionIndicator {
    if (!self.indicator) return;
    [self.indicator setFrame:YMInputLeaseIndicatorFrame(YMLeasePrimaryScreen().visibleFrame,
                                                        self.indicator.frame.size, 12) display:YES];
}

- (void)screensChanged:(NSNotification *)note {
    (void)note;
    [self positionIndicator];
}

- (void)leaseTick:(NSTimer *)timer {
    (void)timer;
    if (!self.activeLeaseID) return;
    NSTimeInterval remaining = self.expiry.timeIntervalSinceNow;
    if (remaining <= 0) { [self endActiveLeaseWithReason:@"expired"]; return; }
    self.indicatorDetail.stringValue = [NSString stringWithFormat:@"%@ · 剩余 %@",
        self.leaseAgent ?: @"Agent", YMInputLeaseRemainingText(remaining)];
}

- (void)stopPressed:(id)sender {
    (void)sender;
    [self endActiveLeaseWithReason:@"stopped"];
}

- (void)endActiveLeaseWithReason:(NSString *)reason {
    NSString *leaseID = self.activeLeaseID;
    if (!leaseID) return;
    if (self.endedLeases.count >= 64) [self.endedLeases removeAllObjects];
    self.endedLeases[leaseID] = reason;
    [self.leaseTimer invalidate];
    self.leaseTimer = nil;
    [self.indicator orderOut:nil];
    self.indicator = nil;
    self.indicatorDetail = nil;
    self.activeLeaseID = nil;
    self.leaseAgent = nil;
    self.expiry = nil;
    // A person who pressed Stop is already at the controls; leave them be.
    if ([reason isEqualToString:@"released"] || [reason isEqualToString:@"expired"]) [self restorePreviousControls];
    self.previousApplication = nil;
    self.hasPreviousCursor = NO;
    YMLeasePost(YMInputLeaseEndedName, @{@"leaseID":leaseID, @"reason":reason});
}

- (void)restorePreviousControls {
    if (self.hasPreviousCursor) {
        CGWarpMouseCursorPosition(self.previousCursor);
        CGAssociateMouseAndMouseCursorPosition(true);
    }
    NSRunningApplication *previous = self.previousApplication;
    if (previous && !previous.terminated && !previous.active) [previous activateWithOptions:0];
}

@end

#pragma mark - Command-line client

static int YMLeaseUsage(void) {
    fprintf(stderr,
        "Usage: Yomado --input request --agent <name> --reason <text> [--seconds <10-600>]\n"
        "       Yomado --input status [--lease <id>]\n"
        "       Yomado --input release --lease <id>\n");
    return 64;
}

static NSDictionary *YMLeaseExchange(NSString *name, NSDictionary *info, NSTimeInterval acknowledge, NSTimeInterval total) {
    NSString *requestID = NSUUID.UUID.UUIDString.lowercaseString;
    __block NSDictionary *pending = nil, *final = nil;
    id token = [YMLeaseBus() addObserverForName:YMInputLeaseResponseName object:YMInputLeaseObject queue:nil
                                     usingBlock:^(NSNotification *note) {
        NSDictionary *reply = note.userInfo;
        if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"requestID"] isEqual:requestID]) return;
        if ([reply[@"status"] isEqual:@"pending"]) pending = reply; else final = reply;
    }];
    NSMutableDictionary *message = [info mutableCopy];
    message[@"requestID"] = requestID;
    YMLeasePost(name, message);
    NSDate *start = NSDate.date;
    while (!final) {
        NSTimeInterval elapsed = -start.timeIntervalSinceNow;
        if ((!pending && elapsed > acknowledge) || elapsed > total) break;
        @autoreleasepool {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
    [YMLeaseBus() removeObserver:token];
    if (final) {
        NSMutableDictionary *result = [final mutableCopy];
        [result removeObjectForKey:@"requestID"];
        return result;
    }
    return pending ? @{@"status":@"timeout"} : nil;
}

int YMInputLeaseCommand(int argc, const char *_Nonnull argv[_Nonnull]) {
    @autoreleasepool {
        if (argc < 3) return YMLeaseUsage();
        NSString *action = [NSString stringWithUTF8String:argv[2]];
        NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
        for (int index = 3; index < argc; index += 2) {
            NSString *key = [NSString stringWithUTF8String:argv[index]];
            if (index + 1 >= argc || ![@[@"--agent", @"--reason", @"--seconds", @"--lease"] containsObject:key])
                return YMLeaseUsage();
            options[key] = [NSString stringWithUTF8String:argv[index + 1]];
        }

        NSDictionary *reply = nil;
        if ([action isEqualToString:@"request"]) {
            if (!options[@"--agent"] || !options[@"--reason"]) return YMLeaseUsage();
            NSMutableDictionary *info = [@{@"agent":options[@"--agent"], @"reason":options[@"--reason"]} mutableCopy];
            if (options[@"--seconds"]) info[@"seconds"] = @(options[@"--seconds"].doubleValue);
            reply = YMLeaseExchange(YMInputLeaseRequestName, info, 3, YMInputLeaseDecisionSeconds + 5);
        } else if ([action isEqualToString:@"status"]) {
            reply = YMLeaseExchange(YMInputLeaseStatusName,
                                    options[@"--lease"] ? @{@"leaseID":options[@"--lease"]} : @{}, 3, 3);
        } else if ([action isEqualToString:@"release"]) {
            if (!options[@"--lease"]) return YMLeaseUsage();
            reply = YMLeaseExchange(YMInputLeaseReleaseName, @{@"leaseID":options[@"--lease"]}, 3, 3);
        } else {
            return YMLeaseUsage();
        }

        if (!reply) reply = @{@"status":@"not-running", @"message":@"yomado is not running or did not answer."};
        NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingSortedKeys error:nil];
        printf("%s\n", json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String : "{}");
        NSString *status = reply[@"status"];
        if ([@[@"granted", @"released", @"active", @"idle"] containsObject:status]) return 0;
        return [status isEqualToString:@"not-running"] ? 3 : 2;
    }
}
