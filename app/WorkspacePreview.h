#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Live preview of yomado's virtual displays for the person sharing the Mac.
//
// A thin edge strip on the right of a physical screen shows one tab per
// running virtual display. Hovering expands it into live thumbnail cards;
// clicking a card opens a picture-in-picture panel that follows that display
// at full frame rate. Everything is view-only and non-activating: panels
// never take focus from the user's current app and never send input.
//
// Capture uses ScreenCaptureKit and needs the Screen Recording permission.
@interface YMWorkspacePreview : NSObject
@property(nonatomic, readonly) BOOL enabled;
- (void)setEnabled:(BOOL)enabled;
// displays: @[@{@"displayID": @(CGDirectDisplayID), @"name": NSString}], in display order.
- (void)updateDisplays:(NSArray<NSDictionary *> *)displays;
- (void)invalidate;
// Show a short ripple where an agent just acted. point is in global desktop
// coordinates (origin top-left of the main display, as CGDisplayBounds).
- (void)markPoint:(CGPoint)point;
// Display the person is currently controlling through the picture-in-picture
// panel ("接管"); agents should pause while this is set.
@property(nonatomic, readonly, nullable) NSNumber *takeoverDisplayID;
// The takeover input path, also reachable from --display tap/type for testing.
// tap presses (or focuses, for text) the accessibility element at a global point
// on a virtual display; type inserts text into the last focused text element.
- (NSDictionary *)tapAtGlobalPoint:(CGPoint)point secondary:(BOOL)secondary;
- (NSDictionary *)typeText:(NSString *)text;
- (NSDictionary *)scrollAtGlobalPoint:(CGPoint)point dx:(double)dx dy:(double)dy;
@end

NS_ASSUME_NONNULL_END
