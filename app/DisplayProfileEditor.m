#import "DisplayProfileEditor.h"

@implementation YMDisplayProfileDraft

- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width hiDPI:(BOOL)hiDPI {
    self = [super init];
    if (self) {
        _name = [name copy] ?: @"";
        _width = width;
        _hiDPI = hiDPI;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return [[YMDisplayProfileDraft alloc] initWithName:self.name width:self.width hiDPI:self.hiDPI];
}

- (YMDisplayProfileDraft *)normalizedCopyValidatingDisplaySettings:(BOOL)validateSettings
                                                             error:(NSError **)error {
    NSString *name = [self.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL invalidName = !name.length || name.length > 60 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound;
    BOOL invalidSize = validateSettings && self.width != 1920 && self.width != 2560;
    if (invalidName || invalidSize) {
        if (error) {
            *error = [NSError errorWithDomain:@"dev.chekusu.yomado.profile"
                                         code:invalidName ? 1 : 2
                                     userInfo:@{NSLocalizedDescriptionKey:
                         invalidName ? @"请输入 1–60 个字符，且不含换行或控制字符。" : @"请选择支持的分辨率。"}];
        }
        return nil;
    }
    if (error) *error = nil;
    return [[YMDisplayProfileDraft alloc] initWithName:name width:self.width hiDPI:self.hiDPI];
}

@end

@interface YMDisplayProfileEditor ()
@property(nonatomic, strong) YMDisplayProfileDraft *initialDraft;
@property(nonatomic, strong) NSTextField *nameField;
@property(nonatomic, strong) NSArray<NSButton *> *resolutionButtons;
@property(nonatomic, strong) NSButton *hiDPIButton;
@property(nonatomic, strong) NSTextField *pixelNote;
@property(nonatomic, strong) NSTextField *errorLabel;
@property(nonatomic) BOOL submitting;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL accepted;
- (void)finishWithAccepted:(BOOL)accepted;
- (void)refreshPixelNote;
- (void)showError:(NSError *)error;
- (NSUInteger)selectedWidth;
- (BOOL)selectedHiDPI;
- (YMDisplayProfileDraft *)draftFromControls;
@end

@implementation YMDisplayProfileEditor

static NSTextField *YMProfileLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

- (instancetype)initWithMode:(YMDisplayProfileEditorMode)mode draft:(YMDisplayProfileDraft *)draft {
    self = [super initWithWindow:nil];
    if (self) {
        _mode = mode;
        _initialDraft = [[YMDisplayProfileDraft alloc] initWithName:draft.name ?: @""
                                                              width:draft.width
                                                              hiDPI:draft.hiDPI];
    }
    return self;
}

- (NSString *)sheetTitle {
    switch (self.mode) {
        case YMDisplayProfileEditorModeEdit: return @"编辑虚拟屏";
        case YMDisplayProfileEditorModeRename: return @"重命名虚拟屏";
        case YMDisplayProfileEditorModeCreate:
        default: return @"新建虚拟屏";
    }
}

- (NSString *)confirmTitle {
    return self.mode == YMDisplayProfileEditorModeCreate ? @"创建并启动" : @"保存设置";
}

- (NSString *)sheetBlurb {
    switch (self.mode) {
        case YMDisplayProfileEditorModeEdit:
            return @"修改未启动配置的名称与显示设置。保存后不会自动启动。";
        case YMDisplayProfileEditorModeRename:
            return @"运行中的虚拟屏只能改名；分辨率与 HiDPI 需关闭后再编辑。";
        case YMDisplayProfileEditorModeCreate:
        default:
            return @"填写名称与显示设置后创建并启动。取消不会写入配置。";
    }
}

- (NSWindow *)window {
    NSWindow *existing = [super window];
    if (!existing) {
        [self loadWindow];
        existing = [super window];
    }
    return existing;
}

- (void)loadWindow {
    if ([super window]) return;
    BOOL rename = self.mode == YMDisplayProfileEditorModeRename;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 360)
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    panel.releasedWhenClosed = NO;
    panel.title = [self sheetTitle];
    self.window = panel;

    NSView *content = panel.contentView;
    NSStackView *root = [[NSStackView alloc] init];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 14;
    root.edgeInsets = NSEdgeInsetsMake(24, 24, 24, 24);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.detachesHiddenViews = YES;
    [content addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:content.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [content.widthAnchor constraintEqualToConstant:440]
    ]];

    NSTextField *title = YMProfileLabel([self sheetTitle], 15, NSFontWeightSemibold, NSColor.labelColor);
    NSTextField *blurb = YMProfileLabel([self sheetBlurb], 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    [root addArrangedSubview:title];
    [root addArrangedSubview:blurb];

    NSTextField *nameCaption = YMProfileLabel(@"名称", 12, NSFontWeightMedium, NSColor.labelColor);
    self.nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.nameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameField.stringValue = self.mode == YMDisplayProfileEditorModeCreate ? @"" : (self.initialDraft.name ?: @"");
    self.nameField.placeholderString = @"例如 Codex · Blender";
    self.nameField.delegate = self;
    self.nameField.accessibilityLabel = @"名称";
    [self.nameField.heightAnchor constraintEqualToConstant:22].active = YES;
    [root addArrangedSubview:nameCaption];
    [root addArrangedSubview:self.nameField];

    NSTextField *sizeCaption = YMProfileLabel(@"分辨率", 12, NSFontWeightMedium, NSColor.labelColor);
    sizeCaption.hidden = rename;
    NSStackView *sizeRow = [[NSStackView alloc] init];
    sizeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    sizeRow.spacing = 12;
    sizeRow.alignment = NSLayoutAttributeCenterY;
    sizeRow.hidden = rename;
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    for (NSNumber *width in @[@1920, @2560]) {
        NSString *titleText = width.unsignedIntegerValue == 1920 ? @"1920 × 1080" : @"2560 × 1440";
        NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.buttonType = NSButtonTypeToggle;
        button.bezelStyle = NSBezelStyleRounded;
        button.title = titleText;
        button.tag = (NSInteger)width.unsignedIntegerValue;
        button.target = self;
        button.action = @selector(selectResolution:);
        button.state = (width.unsignedIntegerValue == self.initialDraft.width) ? NSControlStateValueOn : NSControlStateValueOff;
        button.hidden = rename;
        button.accessibilityLabel = titleText;
        [buttons addObject:button];
        [sizeRow addArrangedSubview:button];
    }
    if (self.initialDraft.width != 1920 && self.initialDraft.width != 2560 && buttons.count) {
        buttons.firstObject.state = NSControlStateValueOn;
    }
    self.resolutionButtons = [buttons copy];
    [root addArrangedSubview:sizeCaption];
    [root addArrangedSubview:sizeRow];

    self.hiDPIButton = [NSButton checkboxWithTitle:@"HiDPI 更清晰" target:self action:@selector(toggleHiDPI:)];
    self.hiDPIButton.state = self.initialDraft.hiDPI ? NSControlStateValueOn : NSControlStateValueOff;
    self.hiDPIButton.hidden = rename;
    self.hiDPIButton.accessibilityLabel = @"HiDPI";
    [root addArrangedSubview:self.hiDPIButton];

    self.pixelNote = YMProfileLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.pixelNote.hidden = rename;
    [root addArrangedSubview:self.pixelNote];
    [self refreshPixelNote];

    self.errorLabel = YMProfileLabel(@"", 12, NSFontWeightRegular, NSColor.systemRedColor);
    self.errorLabel.hidden = YES;
    [root addArrangedSubview:self.errorLabel];

    NSStackView *actions = [[NSStackView alloc] init];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.spacing = 10;
    actions.alignment = NSLayoutAttributeCenterY;
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.title = @"取消";
    cancelButton.target = self;
    cancelButton.action = @selector(cancel:);
    cancelButton.keyEquivalent = @"\e";
    cancelButton.keyEquivalentModifierMask = 0;
    NSButton *confirmButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    confirmButton.bezelStyle = NSBezelStyleRounded;
    confirmButton.title = [self confirmTitle];
    confirmButton.target = self;
    confirmButton.action = @selector(submit:);
    confirmButton.keyEquivalent = @"\r";
    confirmButton.keyEquivalentModifierMask = 0;
    [actions addArrangedSubview:spacer];
    [actions addArrangedSubview:cancelButton];
    [actions addArrangedSubview:confirmButton];
    [root addArrangedSubview:actions];

    [title.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
    [blurb.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
    [self.nameField.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
    [self.pixelNote.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
    [self.errorLabel.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
    [actions.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;

    panel.initialFirstResponder = self.nameField;
}

- (NSUInteger)selectedWidth {
    for (NSButton *button in self.resolutionButtons) {
        if (button.state == NSControlStateValueOn) return (NSUInteger)button.tag;
    }
    return self.initialDraft.width ?: 1920;
}

- (BOOL)selectedHiDPI {
    return self.hiDPIButton.state == NSControlStateValueOn;
}

- (void)refreshPixelNote {
    NSUInteger width = [self selectedWidth];
    NSUInteger height = width == 2560 ? 1440 : 1080;
    NSUInteger scale = [self selectedHiDPI] ? 2 : 1;
    self.pixelNote.stringValue = [NSString stringWithFormat:
        @"逻辑尺寸 %lu × %lu，渲染像素 %lu × %lu。HiDPI 只提高清晰度，不改变逻辑桌面大小。",
        (unsigned long)width, (unsigned long)height,
        (unsigned long)(width * scale), (unsigned long)(height * scale)];
}

- (void)selectResolution:(NSButton *)sender {
    for (NSButton *button in self.resolutionButtons) {
        button.state = (button == sender) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self refreshPixelNote];
}

- (void)toggleHiDPI:(id)sender {
    (void)sender;
    [self refreshPixelNote];
}

- (void)showError:(NSError *)error {
    self.errorLabel.stringValue = error.localizedDescription ?: @"";
    self.errorLabel.hidden = self.errorLabel.stringValue.length == 0;
}

- (YMDisplayProfileDraft *)draftFromControls {
    NSUInteger width = self.initialDraft.width;
    BOOL hiDPI = self.initialDraft.hiDPI;
    if (self.mode != YMDisplayProfileEditorModeRename) {
        width = [self selectedWidth];
        hiDPI = [self selectedHiDPI];
    }
    return [[YMDisplayProfileDraft alloc] initWithName:self.nameField.stringValue width:width hiDPI:hiDPI];
}

- (void)finishWithAccepted:(BOOL)accepted {
    if (self.finished) return;
    self.finished = YES;
    self.accepted = accepted;
    NSWindow *sheet = self.window;
    NSWindow *parent = sheet.sheetParent;
    if (parent) {
        [parent endSheet:sheet returnCode:accepted ? NSModalResponseOK : NSModalResponseCancel];
        return;
    }
    void (^callback)(BOOL) = self.endHandler;
    self.endHandler = nil;
    if (callback) callback(accepted);
}

- (void)beginSheetForWindow:(NSWindow *)parent {
    (void)self.window;
    __weak YMDisplayProfileEditor *weakSelf = self;
    [parent beginSheet:self.window completionHandler:^(NSModalResponse response) {
        YMDisplayProfileEditor *editor = weakSelf;
        if (!editor) return;
        void (^callback)(BOOL) = editor.endHandler;
        editor.endHandler = nil;
        if (callback) callback(response == NSModalResponseOK);
    }];
}

- (void)submit:(id)sender {
    (void)sender;
    if (self.finished || self.submitting) return;
    NSText *fieldEditor = self.nameField.currentEditor;
    if ([fieldEditor isKindOfClass:NSTextView.class] && [(NSTextView *)fieldEditor hasMarkedText]) return;

    YMDisplayProfileDraft *current = [self draftFromControls];
    BOOL validateSettings = self.mode != YMDisplayProfileEditorModeRename;
    NSError *error = nil;
    YMDisplayProfileDraft *normalized = [current normalizedCopyValidatingDisplaySettings:validateSettings error:&error];
    if (!normalized) {
        [self showError:error];
        return;
    }

    self.submitting = YES;
    BOOL accepted = NO;
    @try {
        BOOL (^handler)(YMDisplayProfileDraft *, NSError **) = self.submitHandler;
        if (handler) {
            NSError *handlerError = nil;
            accepted = handler(normalized, &handlerError);
            if (!accepted) error = handlerError;
        } else {
            accepted = YES;
        }
    } @finally {
        self.submitting = NO;
    }

    if (!accepted) {
        [self showError:error];
        return;
    }
    [self finishWithAccepted:YES];
}

- (void)cancel:(id)sender {
    (void)sender;
    if (self.finished || self.submitting) return;
    [self finishWithAccepted:NO];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (control != self.nameField || textView.hasMarkedText) return NO;
    if (command == @selector(cancelOperation:)) {
        [self cancel:control];
        return YES;
    }
    if (command == @selector(insertNewline:)) {
        [self submit:control];
        return YES;
    }
    return NO;
}

@end
