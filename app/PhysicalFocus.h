#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keeps the person's work off virtual displays they can't see.
//
// 1. When a window arrives on a virtual display (dragged there or moved by an
//    agent), the app's front window on a physical display becomes its main
//    window again, without activating the app. Apps open new documents in
//    their last active window, so Chrome's next `open page.html` would
//    otherwise become a tab on the virtual display.
// 2. When the front app's focused window is on a virtual display, the person
//    just switched to it (Dock, Command-Tab, `open`, a notification) and can't
//    see it, so it moves to the physical display under the pointer.
//
// Off by default: `defaults write dev.chekusu.yomado YMKeepFocusOnPhysicalDisplays -bool true`.
// Checks once a second while a virtual display exists; skipped mid-drag.
// Needs Accessibility.
@interface YMPhysicalFocusGuard : NSObject
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
