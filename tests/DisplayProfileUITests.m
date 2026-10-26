#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>

#import "DisplayProfileEditor.m"
#import "SavedDisplayProfilesView.m"

@interface YMMarkedTextFixture : NSTextView
@property(nonatomic) BOOL fixtureMarked;
@end
@implementation YMMarkedTextFixture
- (BOOL)hasMarkedText { return self.fixtureMarked; }
@end

@interface YMNameFieldFixture : NSTextField
@property(nonatomic, strong) YMMarkedTextFixture *fixtureEditor;
@end
@implementation YMNameFieldFixture
- (NSText *)currentEditor { return self.fixtureEditor; }
- (void)setStringValue:(NSString *)stringValue {
    [super setStringValue:stringValue];
    self.fixtureEditor.string = [stringValue copy] ?: @"";
}
- (NSString *)stringValue {
    if (self.fixtureEditor) return [self.fixtureEditor.string copy] ?: @"";
    return [super stringValue];
}
@end

static void Check(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        exit(1);
    }
}

static YMNameFieldFixture *InstallNameFixture(YMDisplayProfileEditor *editor) {
    YMNameFieldFixture *field = [[YMNameFieldFixture alloc] initWithFrame:NSZeroRect];
    field.delegate = editor;
    field.fixtureEditor = [[YMMarkedTextFixture alloc] init];
    field.stringValue = editor.nameField.stringValue ?: @"";
    editor.nameField = field;
    return field;
}

static void DraftValidation(void) {
    NSError *error = nil;
    YMDisplayProfileDraft *source = [[YMDisplayProfileDraft alloc]
        initWithName:@"  Codex · Blender  " width:1920 hiDPI:YES];
    YMDisplayProfileDraft *value = [source normalizedCopyValidatingDisplaySettings:YES error:&error];
    Check(value != nil && error == nil, "valid draft accepted");
    Check([value.name isEqualToString:@"Codex · Blender"], "name normalized");
    source.name = @"changed";
    Check([value.name isEqualToString:@"Codex · Blender"], "accepted draft is a copy");
    for (NSString *name in @[@"", @" \n ", @"a\nb", @"a\tb",
                             [@"x" stringByPaddingToLength:61 withString:@"x" startingAtIndex:0]]) {
        YMDisplayProfileDraft *bad = [[YMDisplayProfileDraft alloc] initWithName:name width:1920 hiDPI:NO];
        error = nil;
        Check([bad normalizedCopyValidatingDisplaySettings:YES error:&error] == nil && error != nil,
              "invalid name rejected with error");
    }
    YMDisplayProfileDraft *legacy = [[YMDisplayProfileDraft alloc] initWithName:@"Name" width:800 hiDPI:NO];
    Check([legacy normalizedCopyValidatingDisplaySettings:YES error:&error] == nil, "new settings reject unknown size");
    Check([legacy normalizedCopyValidatingDisplaySettings:NO error:&error] != nil, "rename does not rewrite legacy dimensions");
}

static void EditorAcceptance(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeCreate draft:draft];
    (void)editor.window;
    __block NSUInteger submits = 0, ends = 0;
    __block BOOL permit = NO;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        submits++;
        Check([value.name isEqualToString:@"Codex"], "handler receives normalized value");
        if (!permit && error) {
            *error = [NSError errorWithDomain:@"fixture" code:1
                                    userInfo:@{NSLocalizedDescriptionKey:@"正在恢复显示排列，请稍后重试。"}];
        }
        return permit;
    };
    editor.endHandler = ^(BOOL accepted) {
        Check(accepted, "accepted result");
        ends++;
    };
    editor.nameField.stringValue = @"   ";
    [editor submit:nil];
    Check(submits == 0 && ends == 0, "invalid value never reaches controller");
    editor.nameField.stringValue = @" Codex ";
    [editor submit:nil];
    Check(submits == 1 && ends == 0 && !editor.errorLabel.hidden, "rejected request keeps form");
    Check([editor.nameField.stringValue isEqualToString:@" Codex "], "rejection preserves draft");
    permit = YES;
    [editor submit:nil];
    [editor submit:nil];
    [editor cancel:nil];
    Check(submits == 2 && ends == 1, "accepted form finishes exactly once");
}

static void EditorCancel(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Original" width:2560 hiDPI:YES];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeEdit draft:draft];
    (void)editor.window;
    __block NSUInteger submits = 0, ends = 0;
    __block BOOL endAccepted = YES;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)value;
        (void)error;
        submits++;
        return YES;
    };
    editor.endHandler = ^(BOOL accepted) {
        endAccepted = accepted;
        ends++;
    };
    editor.nameField.stringValue = @" Changed ";
    for (NSButton *button in editor.resolutionButtons) {
        button.state = (button.tag == 1920) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    editor.hiDPIButton.state = NSControlStateValueOff;
    [editor cancel:nil];
    Check(submits == 0, "cancel never submits");
    Check(ends == 1 && endAccepted == NO, "cancel ends once with NO");
    Check([editor.initialDraft.name isEqualToString:@"Original"], "cancel leaves initial draft untouched");
    Check(editor.initialDraft.width == 2560 && editor.initialDraft.hiDPI == YES, "cancel leaves display settings untouched");
}

static void EditorRenameMode(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Running" width:800 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeRename draft:draft];
    (void)editor.window;
    __block YMDisplayProfileDraft *submitted = nil;
    __block NSUInteger ends = 0;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)error;
        submitted = value;
        return YES;
    };
    editor.endHandler = ^(BOOL accepted) {
        Check(accepted, "rename accepted");
        ends++;
    };
    for (NSButton *button in editor.resolutionButtons) {
        Check(button.hidden, "rename hides resolution");
    }
    Check(editor.hiDPIButton.hidden && editor.pixelNote.hidden, "rename hides display settings");
    editor.nameField.stringValue = @" Renamed ";
    editor.hiDPIButton.state = NSControlStateValueOn;
    for (NSButton *button in editor.resolutionButtons) {
        button.state = (button.tag == 2560) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [editor submit:nil];
    Check(submitted != nil, "rename submits");
    Check([submitted.name isEqualToString:@"Renamed"], "rename normalizes name");
    Check(submitted.width == 800 && submitted.hiDPI == NO, "rename does not rewrite width or hiDPI");
    Check(ends == 1, "rename finishes once");
}

static void EditorCommandsAndMarkedText(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Base" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeEdit draft:draft];
    (void)editor.window;
    YMNameFieldFixture *field = InstallNameFixture(editor);
    __block NSUInteger submits = 0, ends = 0;
    __block BOOL endAccepted = YES;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)error;
        submits++;
        Check([value.name isEqualToString:@"Entered"], "newline submit normalizes");
        return YES;
    };
    editor.endHandler = ^(BOOL accepted) {
        endAccepted = accepted;
        ends++;
    };

    field.fixtureEditor.fixtureMarked = YES;
    field.stringValue = @"Codex";
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(cancelOperation:)] == NO,
          "marked text leaves cancel to the field editor");
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(insertNewline:)] == NO,
          "marked text leaves newline to the field editor");
    [editor submit:nil];
    Check(submits == 0 && ends == 0, "marked text blocks submit action");

    field.fixtureEditor.fixtureMarked = NO;
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(deleteBackward:)] == NO,
          "unrelated commands stay unhandled");
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(cancelOperation:)] == YES,
          "clear cancelOperation is handled");
    Check(submits == 0 && ends == 1 && endAccepted == NO, "cancelOperation ends once without submit");

    YMDisplayProfileEditor *enterEditor =
        [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeCreate
                                               draft:[[YMDisplayProfileDraft alloc] initWithName:@"" width:1920 hiDPI:NO]];
    (void)enterEditor.window;
    YMNameFieldFixture *enterField = InstallNameFixture(enterEditor);
    __block NSUInteger enterSubmits = 0, enterEnds = 0;
    enterEditor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)error;
        enterSubmits++;
        Check([value.name isEqualToString:@"Entered"], "insertNewline reaches normalized gate");
        return YES;
    };
    enterEditor.endHandler = ^(BOOL accepted) {
        Check(accepted, "insertNewline accepted");
        enterEnds++;
    };
    enterField.fixtureEditor.fixtureMarked = NO;
    enterField.stringValue = @"  Entered  ";
    Check([enterEditor control:enterField textView:enterField.fixtureEditor
        doCommandBySelector:@selector(insertNewline:)] == YES, "insertNewline handled when clear");
    Check(enterSubmits == 1 && enterEnds == 1, "insertNewline submits through the same gate");
}

static void EditorPixelNote(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Note" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeCreate draft:draft];
    (void)editor.window;

    void (^assertNote)(NSUInteger, BOOL, NSUInteger, NSUInteger) =
        ^(NSUInteger width, BOOL hiDPI, NSUInteger logicH, NSUInteger scale) {
            for (NSButton *button in editor.resolutionButtons) {
                button.state = (button.tag == (NSInteger)width) ? NSControlStateValueOn : NSControlStateValueOff;
            }
            editor.hiDPIButton.state = hiDPI ? NSControlStateValueOn : NSControlStateValueOff;
            [editor refreshPixelNote];
            NSString *note = editor.pixelNote.stringValue;
            NSString *logic = [NSString stringWithFormat:@"%lu × %lu", (unsigned long)width, (unsigned long)logicH];
            NSString *pixels = [NSString stringWithFormat:@"%lu × %lu",
                                (unsigned long)(width * scale), (unsigned long)(logicH * scale)];
            Check([note containsString:logic], "pixel note includes logical size");
            Check([note containsString:pixels], "pixel note includes render size");
        };

    assertNote(1920, NO, 1080, 1);
    assertNote(1920, YES, 1080, 2);
    assertNote(2560, NO, 1440, 1);
    assertNote(2560, YES, 1440, 2);
}

static YMSavedDisplayProfileRow *Row(NSUInteger ordinal, NSString *name, BOOL canStart) {
    return [[YMSavedDisplayProfileRow alloc] initWithOrdinal:ordinal name:name
        detail:@"1920 × 1080" message:@"" starting:NO canStart:canStart canEdit:canStart];
}

static void SavedRowsUseIdentity(void) {
    YMSavedDisplayProfilesView *view = [[YMSavedDisplayProfilesView alloc] initWithFrame:NSMakeRect(0, 0, 700, 220)];
    __block NSUInteger chosen = 0;
    view.onStart = ^(NSUInteger ordinal) { chosen = ordinal; };
    [view updateRows:@[Row(1, @"same", YES), Row(2, @"same", YES)] revealOrdinal:nil];
    YMSavedDisplayProfileRowView *first = view.rowsByOrdinal[@1];
    [view updateRows:@[Row(2, @"same", YES), Row(1, @"same", YES)] revealOrdinal:nil];
    Check(view.rowsByOrdinal[@1] == first, "unchanged identity retains row view");
    [view.rowsByOrdinal[@2].startButton performClick:nil];
    Check(chosen == 2, "same names and reorder do not change target");
    [view updateRows:@[Row(2, @"same", NO)] revealOrdinal:nil];
    Check(!view.rowsByOrdinal[@2].startButton.enabled, "disabled state is represented");
    [view updateRows:@[] revealOrdinal:nil];
    Check(view.hidden, "zero saved rows hides complete section");
}

static BOOL FramesOverlap(NSRect a, NSRect b) {
    return NSIntersectsRect(NSInsetRect(a, 0.5, 0.5), NSInsetRect(b, 0.5, 0.5));
}

static void AssertRowLayout(YMSavedDisplayProfilesView *view, const char *scenario) {
    Check(!view.hasAmbiguousLayout, scenario);
    for (YMSavedDisplayProfileRowView *row in view.rowsByOrdinal.allValues) {
        Check(!row.hasAmbiguousLayout, scenario);
        NSRect iconInRow = [row.iconView convertRect:row.iconView.bounds toView:row];
        NSRect nameInRow = [row.nameLabel convertRect:row.nameLabel.bounds toView:row];
        NSRect detailInRow = [row.detailLabel convertRect:row.detailLabel.bounds toView:row];
        NSRect startInRow = [row.startButton convertRect:row.startButton.bounds toView:row];
        NSRect editInRow = [row.editButton convertRect:row.editButton.bounds toView:row];
        Check(NSContainsRect(row.bounds, startInRow), "start button stays inside row");
        Check(NSContainsRect(row.bounds, editInRow), "edit button stays inside row");
        Check(!FramesOverlap(nameInRow, startInRow), "name does not overlap start");
        Check(!FramesOverlap(nameInRow, editInRow), "name does not overlap edit");
        Check(!FramesOverlap(editInRow, startInRow), "edit does not overlap start");
        // Catch trailing-packed label frames (icon left, name hugging the buttons).
        // Allow a few pt for NSTextField alignment-rect insets around the 10pt gutter.
        CGFloat nameAfterIcon = NSMinX(nameInRow) - NSMaxX(iconInRow);
        CGFloat detailAfterIcon = NSMinX(detailInRow) - NSMaxX(iconInRow);
        Check(nameAfterIcon >= 4.0 && nameAfterIcon <= 14.0,
              "name label leading edge follows icon by ~10pt");
        Check(detailAfterIcon >= 4.0 && detailAfterIcon <= 14.0,
              "detail label leading edge follows icon by ~10pt");
        Check(NSMinX(editInRow) - NSMinX(nameInRow) > 80.0,
              "name stays near icon rather than trailing against edit");
        // Catch full-width frames that still draw glyphs on the trailing edge.
        Check(row.nameLabel.alignment == NSTextAlignmentLeft,
              "name label uses explicit left text alignment");
        Check(row.detailLabel.alignment == NSTextAlignmentLeft,
              "detail label uses explicit left text alignment");
        Check(row.messageLabel.alignment == NSTextAlignmentLeft,
              "message label uses explicit left text alignment");
    }
}

static NSWindow *SavedListWindow(CGFloat width) {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, width, 400)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:YES];
    return window;
}

static YMSavedDisplayProfilesView *EmbedSavedList(NSWindow *window) {
    YMSavedDisplayProfilesView *view = [[YMSavedDisplayProfilesView alloc] initWithFrame:NSZeroRect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:20],
        [view.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-20],
        [view.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:20],
        [view.heightAnchor constraintGreaterThanOrEqualToConstant:220]
    ]];
    return view;
}

static void AssertViewportHeight(YMSavedDisplayProfilesView *view, CGFloat minH, CGFloat maxH,
                                 const char *scenario) {
    CGFloat height = NSHeight(view.scrollView.frame);
    Check(height + 0.5 >= minH && height - 0.5 <= maxH, scenario);
}

static BOOL RowHasActiveWidthConstraint(YMSavedDisplayProfilesView *view,
                                        YMSavedDisplayProfileRowView *row) {
    for (NSLayoutConstraint *constraint in view.rowsStack.constraints) {
        if ((constraint.firstItem == row || constraint.secondItem == row) &&
            constraint.firstAttribute == NSLayoutAttributeWidth &&
            constraint.secondAttribute == NSLayoutAttributeWidth &&
            constraint.active) {
            return YES;
        }
    }
    return NO;
}

static void AssertButtonsPinnedTrailing(YMSavedDisplayProfilesView *view, const char *scenario) {
    CGFloat stackWidth = NSWidth(view.rowsStack.bounds);
    Check(stackWidth > 200, "rows stack has usable width");
    for (YMSavedDisplayProfileRowView *row in view.rowsByOrdinal.allValues) {
        Check(fabs(NSWidth(row.bounds) - stackWidth) < 1.0, scenario);
        Check(RowHasActiveWidthConstraint(view, row), "row keeps width constraint to stack");
        NSRect startInStack = [row.startButton convertRect:row.startButton.bounds toView:view.rowsStack];
        Check(stackWidth - NSMaxX(startInStack) < 12.0, "start button stays trailing after layout");
    }
}

static void AssertVisibleRowButtonsReachable(YMSavedDisplayProfilesView *view, const char *scenario) {
    NSRect visible = view.scrollView.documentVisibleRect;
    for (YMSavedDisplayProfileRowView *row in view.rowsByOrdinal.allValues) {
        NSRect rowInDoc = [row convertRect:row.bounds toView:view.scrollView.documentView];
        // Only fully visible rows: partially clipped rows may hide vertically-centered buttons.
        if (!NSContainsRect(visible, rowInDoc)) continue;
        NSRect startInDoc = [row.startButton convertRect:row.startButton.bounds
                                                  toView:view.scrollView.documentView];
        NSRect editInDoc = [row.editButton convertRect:row.editButton.bounds
                                                toView:view.scrollView.documentView];
        Check(NSContainsRect(visible, startInDoc), scenario);
        Check(NSContainsRect(visible, editInDoc), scenario);
        Check(NSContainsRect(rowInDoc, startInDoc), "start button stays inside visible row");
        Check(NSContainsRect(rowInDoc, editInDoc), "edit button stays inside visible row");
    }
}

static void SavedRowsReorderKeepsWidth(void) {
    NSWindow *window = SavedListWindow(760);
    YMSavedDisplayProfilesView *view = EmbedSavedList(window);
    [view updateRows:@[Row(1, @"Alpha Profile With A Long Name", YES),
                       Row(2, @"Beta Profile With A Long Name", YES)]
        revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    AssertButtonsPinnedTrailing(view, "initial order fills row width");
    YMSavedDisplayProfileRowView *first = view.rowsByOrdinal[@1];
    [view updateRows:@[Row(2, @"Beta Profile With A Long Name", YES),
                       Row(1, @"Alpha Profile With A Long Name", YES)]
        revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(view.rowsByOrdinal[@1] == first, "reorder keeps row identity");
    AssertButtonsPinnedTrailing(view, "reorder keeps row width and trailing actions");
    AssertRowLayout(view, "reorder layout 760pt");
}

static void SavedRowsViewportRange(void) {
    NSWindow *window = SavedListWindow(760);
    YMSavedDisplayProfilesView *view = EmbedSavedList(window);

    [view updateRows:@[Row(1, @"Only", YES)] revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    AssertViewportHeight(view, 56, 56, "one row viewport is 56pt");
    AssertVisibleRowButtonsReachable(view, "one row action buttons visible");

    [view updateRows:@[Row(1, @"One", YES), Row(2, @"Two", YES)] revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    CGFloat twoHeight = NSHeight(view.scrollView.frame);
    Check(twoHeight > 56 + 0.5 && twoHeight < 184 - 0.5, "two rows use natural height inside 56…184");
    AssertViewportHeight(view, 56, 184, "two rows viewport stays in 56…184");

    [view updateRows:@[Row(1, @"One", YES), Row(2, @"Two", YES), Row(3, @"Three", YES)]
        revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    CGFloat threeHeight = NSHeight(view.scrollView.frame);
    Check(threeHeight > twoHeight + 0.5, "three rows grow above two-row height");
    AssertViewportHeight(view, 56, 184, "three rows viewport stays in 56…184");

    NSString *errorMessage =
        @"启动失败：显示拓扑暂时不可用，请稍后重试。详细原因已写入日志，可再次点击启动。";
    YMSavedDisplayProfileRow *errorRow =
        [[YMSavedDisplayProfileRow alloc] initWithOrdinal:1 name:@"Error Only"
            detail:@"1920 × 1080" message:errorMessage starting:NO canStart:YES canEdit:YES];
    [view updateRows:@[errorRow] revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    CGFloat errorHeight = NSHeight(view.scrollView.frame);
    Check(errorHeight > 56 + 0.5, "error row grows viewport above base row height");
    AssertViewportHeight(view, 56, 184, "error row viewport stays in 56…184");
    AssertVisibleRowButtonsReachable(view, "error row action buttons visible");

    NSMutableArray<YMSavedDisplayProfileRow *> *many = [NSMutableArray array];
    for (NSUInteger index = 1; index <= 30; index++) {
        [many addObject:Row(index, [NSString stringWithFormat:@"P%lu", (unsigned long)index], YES)];
    }
    [view updateRows:many revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    AssertViewportHeight(view, 184, 184, "long list clamps viewport to 184pt");
    AssertVisibleRowButtonsReachable(view, "long list visible rows keep action buttons reachable");

    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(view.collapsed && view.scrollView.hidden, "collapse hides viewport");
    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(!view.collapsed && !view.scrollView.hidden, "expand shows viewport");
    AssertViewportHeight(view, 184, 184, "re-expand restores clamped long-list viewport");
    AssertVisibleRowButtonsReachable(view, "re-expand keeps visible action buttons reachable");
}

static NSArray<YMSavedDisplayProfileRow *> *ManyRows(NSUInteger count) {
    NSMutableArray<YMSavedDisplayProfileRow *> *rows = [NSMutableArray array];
    for (NSUInteger index = 1; index <= count; index++) {
        [rows addObject:Row(index, [NSString stringWithFormat:@"P%lu", (unsigned long)index], YES)];
    }
    return rows;
}

static void SavedRowsViewportAfterCollapseDataChange(void) {
    NSWindow *window = SavedListWindow(760);
    YMSavedDisplayProfilesView *view = EmbedSavedList(window);

    [view updateRows:@[Row(1, @"Only", YES)] revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];
    AssertViewportHeight(view, 56, 56, "start with one-row viewport");

    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(view.collapsed, "collapse before growing while hidden");
    [view updateRows:ManyRows(30) revealOrdinal:nil];
    Check(view.collapsed, "growth while collapsed keeps collapsed");
    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(!view.collapsed, "manual expand after growth");
    AssertViewportHeight(view, 184, 184, "manual expand after 1→30 uses clamped height");

    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(view.collapsed, "collapse before shrinking while hidden");
    [view updateRows:@[Row(1, @"Only", YES)] revealOrdinal:nil];
    Check(view.collapsed, "shrink while collapsed keeps collapsed");
    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(!view.collapsed, "manual expand after shrink");
    AssertViewportHeight(view, 56, 56, "manual expand after 30→1 uses one-row height");

    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(view.collapsed, "collapse before reveal growth");
    [view updateRows:ManyRows(30) revealOrdinal:@30];
    [window.contentView layoutSubtreeIfNeeded];
    Check(!view.collapsed, "reveal expands after growth while collapsed");
    AssertViewportHeight(view, 184, 184, "reveal after 1→30 uses clamped height");
    NSRect target = [view.rowsByOrdinal[@30] convertRect:view.rowsByOrdinal[@30].bounds
                                                  toView:view.scrollView.documentView];
    Check(NSIntersectsRect(target, view.scrollView.documentVisibleRect),
          "reveal after growth shows failed row");

    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    Check(view.collapsed, "collapse before reveal shrink");
    [view updateRows:@[Row(1, @"Only", YES)] revealOrdinal:@1];
    [window.contentView layoutSubtreeIfNeeded];
    Check(!view.collapsed, "reveal expands after shrink while collapsed");
    AssertViewportHeight(view, 56, 56, "reveal after 30→1 uses one-row height");
}

static void SavedRowsCollapseScrollAndLayout(void) {
    NSMutableArray<YMSavedDisplayProfileRow *> *rows = [NSMutableArray array];
    NSString *longName = [@"N" stringByPaddingToLength:60 withString:@"x" startingAtIndex:0];
    for (NSUInteger index = 1; index <= 30; index++) {
        NSString *name = (index == 15) ? longName : [NSString stringWithFormat:@"Profile %lu", (unsigned long)index];
        NSString *message = (index == 30) ? @"启动失败，可稍后重试。" : @"";
        [rows addObject:[[YMSavedDisplayProfileRow alloc] initWithOrdinal:index name:name
            detail:@"1920 × 1080" message:message starting:NO canStart:YES canEdit:YES]];
    }

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1000, 400)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:YES];
    YMSavedDisplayProfilesView *view = [[YMSavedDisplayProfilesView alloc] initWithFrame:NSZeroRect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:20],
        [view.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-20],
        [view.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:20],
        [view.heightAnchor constraintGreaterThanOrEqualToConstant:220]
    ]];
    [view updateRows:rows revealOrdinal:nil];
    [window.contentView layoutSubtreeIfNeeded];

    YMSavedDisplayProfileRowView *mid = view.rowsByOrdinal[@15];
    Check(mid != nil, "middle row exists before scroll fixture");
    NSRect midRect = [mid convertRect:mid.bounds toView:view.scrollView.documentView];
    [view.scrollView.documentView scrollRectToVisible:midRect];
    [window.contentView layoutSubtreeIfNeeded];
    NSPoint before = view.scrollView.contentView.bounds.origin;
    Check(!NSEqualPoints(before, NSZeroPoint), "fixture records a non-zero scroll origin");

    [view toggleCollapsed:nil];
    for (NSUInteger pass = 0; pass < 40; pass++) [view updateRows:rows revealOrdinal:nil];
    Check(view.collapsed, "periodic refresh preserves collapse");

    [view toggleCollapsed:nil];
    [window.contentView layoutSubtreeIfNeeded];
    [view.scrollView.contentView scrollToPoint:before];
    [view.scrollView reflectScrolledClipView:view.scrollView.contentView];
    for (NSUInteger pass = 0; pass < 40; pass++) [view updateRows:rows revealOrdinal:nil];
    Check(NSEqualPoints(before, view.scrollView.contentView.bounds.origin), "periodic refresh preserves scroll");

    [view.scrollView.contentView scrollToPoint:NSMakePoint(0, 500)];
    [view.scrollView reflectScrolledClipView:view.scrollView.contentView];
    NSPoint jagged = view.scrollView.contentView.bounds.origin;
    Check(fabs(jagged.y - 500.0) < 1.0, "fixture can park at non-aligned offset 500");
    for (NSUInteger pass = 0; pass < 40; pass++) [view updateRows:rows revealOrdinal:nil];
    Check(NSEqualPoints(jagged, view.scrollView.contentView.bounds.origin),
          "ordinary refresh preserves non-aligned scroll offset");

    [view toggleCollapsed:nil];
    [view updateRows:rows revealOrdinal:@30];
    [window.contentView layoutSubtreeIfNeeded];
    Check(!view.collapsed, "explicit failure reveals collapsed section");
    NSRect target = [view.rowsByOrdinal[@30] convertRect:view.rowsByOrdinal[@30].bounds
                                                  toView:view.scrollView.documentView];
    Check(NSIntersectsRect(target, view.scrollView.documentVisibleRect), "failed item is visible");

    for (NSString *appearanceName in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        window.appearance = [NSAppearance appearanceNamed:appearanceName];
        for (NSNumber *widthNumber in @[@760, @1000]) {
            CGFloat width = widthNumber.doubleValue;
            [window setFrame:NSMakeRect(0, 0, width, 400) display:NO];
            [window.contentView layoutSubtreeIfNeeded];
            char scenario[96];
            snprintf(scenario, sizeof(scenario), "layout %.0fpt %s", width, appearanceName.UTF8String);
            AssertRowLayout(view, scenario);
        }
    }
}

int main(void) {
    @autoreleasepool {
        // Hidden AppKit fixture: ActivationPolicyProhibited, never orderFront/activate.
        // Does not claim coverage of real hardware keyboards or input methods.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        DraftValidation();
        printf("PASS draft validation\n");
        EditorAcceptance();
        printf("PASS editor acceptance\n");
        EditorCancel();
        printf("PASS editor cancel\n");
        EditorRenameMode();
        printf("PASS editor rename mode\n");
        EditorCommandsAndMarkedText();
        printf("PASS editor commands and marked text\n");
        EditorPixelNote();
        printf("PASS editor pixel note\n");
        SavedRowsUseIdentity();
        printf("PASS saved rows use identity\n");
        SavedRowsCollapseScrollAndLayout();
        printf("PASS saved rows collapse scroll and layout\n");
        SavedRowsReorderKeepsWidth();
        printf("PASS saved rows reorder keeps width\n");
        SavedRowsViewportRange();
        printf("PASS saved rows viewport range\n");
        SavedRowsViewportAfterCollapseDataChange();
        printf("PASS saved rows viewport after collapse data change\n");
        return 0;
    }
}
