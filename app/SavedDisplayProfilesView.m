#import "SavedDisplayProfilesView.h"

@implementation YMSavedDisplayProfileRow

- (instancetype)initWithOrdinal:(NSUInteger)ordinal name:(NSString *)name
                         detail:(NSString *)detail message:(NSString *)message
                       starting:(BOOL)starting canStart:(BOOL)canStart canEdit:(BOOL)canEdit {
    self = [super init];
    if (self) {
        _ordinal = ordinal;
        _name = [name copy] ?: @"";
        _detail = [detail copy] ?: @"";
        _message = [message copy] ?: @"";
        _starting = starting;
        _canStart = canStart;
        _canEdit = canEdit;
    }
    return self;
}

@end

@interface YMSavedDisplayProfileRowView : NSView
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *nameLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSTextField *messageLabel;
@property(nonatomic, strong) NSButton *startButton;
@property(nonatomic, strong) NSButton *editButton;
@property(nonatomic, strong) NSStackView *textStack;
- (void)applyRow:(YMSavedDisplayProfileRow *)row;
@end

@implementation YMSavedDisplayProfileRowView

static NSTextField *YMSavedLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.alignment = NSTextAlignmentLeft;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    self.iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:@"虚拟屏"];
    self.iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.iconView.contentTintColor = NSColor.secondaryLabelColor;

    self.nameLabel = YMSavedLabel(@"", 13, NSFontWeightMedium, NSColor.labelColor);
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nameLabel.maximumNumberOfLines = 1;
    self.nameLabel.cell.truncatesLastVisibleLine = YES;
    [self.nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.nameLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.detailLabel = YMSavedLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.detailLabel.maximumNumberOfLines = 1;
    [self.detailLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.detailLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.messageLabel = [NSTextField wrappingLabelWithString:@""];
    self.messageLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.messageLabel.textColor = NSColor.systemRedColor;
    self.messageLabel.alignment = NSTextAlignmentLeft;
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.hidden = YES;
    self.messageLabel.maximumNumberOfLines = 0;
    [self.messageLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.messageLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                forOrientation:NSLayoutConstraintOrientationVertical];
    [self.messageLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.textStack = [[NSStackView alloc] init];
    self.textStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    // Leading + explicit width pins: Width stack alignment left intrinsic-sized
    // labels trailing against the action buttons with a large middle gap.
    self.textStack.alignment = NSLayoutAttributeLeading;
    self.textStack.spacing = 2;
    self.textStack.detachesHiddenViews = YES;
    [self.textStack addArrangedSubview:self.nameLabel];
    [self.textStack addArrangedSubview:self.detailLabel];
    [self.textStack addArrangedSubview:self.messageLabel];
    [self.textStack setContentHuggingPriority:NSLayoutPriorityDefaultLow
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.textStack setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [self.nameLabel.widthAnchor constraintEqualToAnchor:self.textStack.widthAnchor],
        [self.detailLabel.widthAnchor constraintEqualToAnchor:self.textStack.widthAnchor],
        [self.messageLabel.widthAnchor constraintEqualToAnchor:self.textStack.widthAnchor]
    ]];

    self.editButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.editButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.editButton.bezelStyle = NSBezelStyleRounded;
    self.editButton.title = @"编辑";
    [self.editButton setContentHuggingPriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.editButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.startButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.startButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.startButton.bezelStyle = NSBezelStyleRounded;
    self.startButton.title = @"启动";
    [self.startButton setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.startButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    [self addSubview:self.iconView];
    [self addSubview:self.textStack];
    [self addSubview:self.editButton];
    [self addSubview:self.startButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:20],
        [self.iconView.heightAnchor constraintEqualToConstant:20],

        [self.startButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [self.startButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.editButton.trailingAnchor constraintEqualToAnchor:self.startButton.leadingAnchor constant:-8],
        [self.editButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [self.textStack.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:10],
        [self.textStack.trailingAnchor constraintEqualToAnchor:self.editButton.leadingAnchor constant:-10],
        [self.textStack.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [self.textStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        [self.heightAnchor constraintGreaterThanOrEqualToConstant:56]
    ]];
    return self;
}

- (void)layout {
    [super layout];
    CGFloat textWidth = NSWidth(self.textStack.bounds);
    if (textWidth > 1) {
        self.messageLabel.preferredMaxLayoutWidth = textWidth;
        self.nameLabel.preferredMaxLayoutWidth = textWidth;
    }
}

- (void)applyRow:(YMSavedDisplayProfileRow *)row {
    NSString *name = row.name ?: @"";
    self.nameLabel.stringValue = name;
    self.nameLabel.toolTip = name;
    self.nameLabel.accessibilityLabel = name;
    self.detailLabel.stringValue = row.detail ?: @"";
    BOOL hasMessage = row.message.length > 0;
    self.messageLabel.stringValue = row.message ?: @"";
    self.messageLabel.hidden = !hasMessage;
    if (hasMessage) {
        CGFloat textWidth = NSWidth(self.textStack.bounds);
        if (textWidth < 1) textWidth = 400;
        self.messageLabel.preferredMaxLayoutWidth = textWidth;
    }

    self.editButton.tag = (NSInteger)row.ordinal;
    self.startButton.tag = (NSInteger)row.ordinal;
    self.editButton.enabled = row.canEdit;
    self.editButton.accessibilityLabel = [NSString stringWithFormat:@"编辑 %@", name];
    if (row.starting) {
        self.startButton.title = @"启动中…";
        self.startButton.enabled = NO;
    } else {
        self.startButton.title = @"启动";
        self.startButton.enabled = row.canStart;
    }
    self.startButton.accessibilityLabel = [NSString stringWithFormat:@"启动 %@", name];
}

@end

@interface YMSavedRowsStackView : NSStackView
@end
@implementation YMSavedRowsStackView
- (BOOL)isFlipped { return YES; }
@end

@interface YMSavedDisplayProfilesView ()
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YMSavedDisplayProfileRowView *> *rowsByOrdinal;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSStackView *rowsStack;
@property(nonatomic, strong) NSStackView *rootStack;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSButton *collapseButton;
@property(nonatomic, strong) NSLayoutConstraint *viewportMinHeight;
@property(nonatomic, strong) NSLayoutConstraint *viewportMaxHeight;
@property(nonatomic, strong) NSLayoutConstraint *viewportPreferredHeight;
@property(nonatomic, readwrite) BOOL collapsed;
@end

@implementation YMSavedDisplayProfilesView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _rowsByOrdinal = [NSMutableDictionary dictionary];
    _collapsed = NO;
    [self buildChrome];
    self.hidden = YES;
    return self;
}

- (void)buildChrome {
    self.titleLabel = YMSavedLabel(@"未启动的虚拟屏", 13, NSFontWeightSemibold, NSColor.labelColor);
    self.countLabel = YMSavedLabel(@"0", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.collapseButton = [NSButton buttonWithTitle:@"折叠" target:self action:@selector(toggleCollapsed:)];
    self.collapseButton.bezelStyle = NSBezelStyleInline;
    self.collapseButton.bordered = NO;
    self.collapseButton.accessibilityLabel = @"折叠未启动列表";

    NSStackView *header = [[NSStackView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 8;
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header addArrangedSubview:self.titleLabel];
    [header addArrangedSubview:self.countLabel];
    [header addArrangedSubview:spacer];
    [header addArrangedSubview:self.collapseButton];

    self.rowsStack = [[YMSavedRowsStackView alloc] init];
    self.rowsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rowsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rowsStack.alignment = NSLayoutAttributeLeading;
    self.rowsStack.spacing = 4;
    self.rowsStack.detachesHiddenViews = YES;
    [self.rowsStack setHuggingPriority:NSLayoutPriorityDefaultHigh
                        forOrientation:NSLayoutConstraintOrientationVertical];

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
    self.scrollView.documentView = self.rowsStack;

    [NSLayoutConstraint activateConstraints:@[
        [self.rowsStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentView.leadingAnchor],
        [self.rowsStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentView.trailingAnchor],
        [self.rowsStack.topAnchor constraintEqualToAnchor:self.scrollView.contentView.topAnchor],
        [self.rowsStack.widthAnchor constraintEqualToAnchor:self.scrollView.contentView.widthAnchor]
    ]];

    self.viewportMinHeight = [self.scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:56];
    self.viewportMaxHeight = [self.scrollView.heightAnchor constraintLessThanOrEqualToConstant:184];
    self.viewportPreferredHeight = [self.scrollView.heightAnchor constraintEqualToConstant:56];
    // Prefer content height, but yield below the window's min size so 760×520 can hold.
    self.viewportPreferredHeight.priority = NSLayoutPriorityDefaultLow;
    self.viewportMinHeight.active = YES;
    self.viewportMaxHeight.active = YES;
    self.viewportPreferredHeight.active = YES;
    [self.scrollView setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationVertical];
    [self.scrollView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                              forOrientation:NSLayoutConstraintOrientationVertical];

    self.rootStack = [[NSStackView alloc] init];
    self.rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rootStack.alignment = NSLayoutAttributeLeading;
    self.rootStack.spacing = 8;
    self.rootStack.detachesHiddenViews = YES;
    [self.rootStack addArrangedSubview:header];
    [self.rootStack addArrangedSubview:self.scrollView];
    [self addSubview:self.rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.rootStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.rootStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.rootStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.rootStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [header.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor],
        [self.scrollView.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor]
    ]];
}

- (void)start:(NSButton *)sender {
    if (sender.enabled && self.onStart) self.onStart((NSUInteger)sender.tag);
}

- (void)edit:(NSButton *)sender {
    if (sender.enabled && self.onEdit) self.onEdit((NSUInteger)sender.tag);
}

- (void)toggleCollapsed:(id)sender {
    (void)sender;
    self.collapsed = !self.collapsed;
    [self applyCollapsedState];
}

- (void)applyCollapsedState {
    self.scrollView.hidden = self.collapsed;
    self.viewportMinHeight.active = !self.collapsed;
    self.viewportMaxHeight.active = !self.collapsed;
    self.viewportPreferredHeight.active = !self.collapsed;
    self.collapseButton.title = self.collapsed ? @"展开" : @"折叠";
    self.collapseButton.accessibilityLabel = self.collapsed ? @"展开未启动列表" : @"折叠未启动列表";
    // Collapse skips height refresh; recompute from current rows on expand
    // (manual toggle or error reveal) so viewport matches latest count.
    if (!self.collapsed) {
        [self refreshPreferredHeight];
    }
}

- (void)refreshPreferredHeight {
    if (self.collapsed) return;
    [self.rowsStack layoutSubtreeIfNeeded];
    CGFloat contentHeight = MAX(self.rowsStack.fittingSize.height, 56);
    self.viewportPreferredHeight.constant = MIN(184, contentHeight);
}

- (void)restoreSavedScrollOrigin:(NSPoint)savedOrigin {
    [self layoutSubtreeIfNeeded];
    [self.rowsStack layoutSubtreeIfNeeded];
    CGFloat contentHeight = MAX(self.rowsStack.fittingSize.height, NSHeight(self.rowsStack.bounds));
    CGFloat viewportHeight = NSHeight(self.scrollView.contentView.bounds);
    NSPoint target = savedOrigin;
    // When content fits the viewport, keep the origin at zero so post-layout
    // clip drift cannot hide the only rows. Mid-list offsets stay untouched.
    if (contentHeight <= viewportHeight + 0.5) target = NSZeroPoint;
    [self.scrollView.contentView scrollToPoint:target];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

- (void)updateRows:(NSArray<YMSavedDisplayProfileRow *> *)rows
     revealOrdinal:(NSNumber *)revealOrdinal {
    NSPoint savedOrigin = self.scrollView.contentView.bounds.origin;
    NSArray<YMSavedDisplayProfileRow *> *incoming = rows ?: @[];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    NSMutableArray<YMSavedDisplayProfileRow *> *unique = [NSMutableArray array];
    for (YMSavedDisplayProfileRow *row in incoming) {
        NSNumber *key = @(row.ordinal);
        if ([seen containsObject:key]) {
            NSCAssert(NO, @"duplicate saved display ordinal %lu", (unsigned long)row.ordinal);
            continue;
        }
        [seen addObject:key];
        [unique addObject:row];
    }

    NSArray<NSNumber *> *existingKeys = self.rowsByOrdinal.allKeys;
    for (NSNumber *key in existingKeys) {
        if (![seen containsObject:key]) {
            YMSavedDisplayProfileRowView *rowView = self.rowsByOrdinal[key];
            [self.rowsStack removeArrangedSubview:rowView];
            [rowView removeFromSuperview];
            [self.rowsByOrdinal removeObjectForKey:key];
        }
    }

    NSUInteger index = 0;
    for (YMSavedDisplayProfileRow *row in unique) {
        NSNumber *key = @(row.ordinal);
        YMSavedDisplayProfileRowView *rowView = self.rowsByOrdinal[key];
        BOOL created = NO;
        if (!rowView) {
            rowView = [[YMSavedDisplayProfileRowView alloc] initWithFrame:NSZeroRect];
            rowView.startButton.target = self;
            rowView.startButton.action = @selector(start:);
            rowView.editButton.target = self;
            rowView.editButton.action = @selector(edit:);
            self.rowsByOrdinal[key] = rowView;
            created = YES;
        }
        [rowView applyRow:row];
        NSUInteger currentIndex = [self.rowsStack.arrangedSubviews indexOfObjectIdenticalTo:rowView];
        if (currentIndex == NSNotFound) {
            [self.rowsStack insertArrangedSubview:rowView atIndex:index];
        } else if (currentIndex != index) {
            // Keep the view in the hierarchy so widthAnchor to rowsStack survives reorder.
            [self.rowsStack removeArrangedSubview:rowView];
            [self.rowsStack insertArrangedSubview:rowView atIndex:index];
        }
        if (created) {
            [rowView.widthAnchor constraintEqualToAnchor:self.rowsStack.widthAnchor].active = YES;
        }
        index++;
    }

    self.countLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)unique.count];
    self.hidden = unique.count == 0;
    [self refreshPreferredHeight];

    if (revealOrdinal != nil) {
        if (self.collapsed) {
            self.collapsed = NO;
            [self applyCollapsedState];
        }
        [self layoutSubtreeIfNeeded];
        YMSavedDisplayProfileRowView *target = self.rowsByOrdinal[revealOrdinal];
        if (target) {
            NSRect rect = [target convertRect:target.bounds toView:self.scrollView.documentView];
            [self.scrollView.documentView scrollRectToVisible:rect];
            [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
        }
    } else if (!self.collapsed && !self.hidden) {
        [self restoreSavedScrollOrigin:savedOrigin];
    }
}

@end
