#import "PhysicalFocus.h"
#import "VDVirtualDisplay.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <os/log.h>

static NSString *const YMKeepFocusKey = @"YMKeepFocusOnPhysicalDisplays";
typedef AXError (*YMFocusWindowIDFunction)(AXUIElementRef, CGWindowID *);

static BOOL YMPointOnVirtualDisplay(CGPoint point) {
    CGDirectDisplayID displays[4];
    uint32_t count = 0;
    return CGGetDisplaysWithPoint(point, 4, displays, &count) == kCGErrorSuccess && count > 0
        && [VDVirtualDisplay isVirtualDisplay:displays[0]];
}
static BOOL YMAnyVirtualDisplayActive(void) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return NO;
    for (uint32_t index = 0; index < count; index++)
        if ([VDVirtualDisplay isVirtualDisplay:displays[index]]) return YES;
    return NO;
}
// The accessibility element for one CGWindowID of a process.
static AXUIElementRef YMCopyFocusAXWindow(pid_t pid, CGWindowID windowID) {
    static YMFocusWindowIDFunction getWindow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ getWindow = (YMFocusWindowIDFunction)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); });
    if (!getWindow) return NULL;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFArrayRef windows = NULL;
    AXUIElementRef found = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
        for (CFIndex index = 0; index < CFArrayGetCount(windows) && !found; index++) {
            AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, index);
            CGWindowID candidate = 0;
            if (getWindow(window, &candidate) == kAXErrorSuccess && candidate == windowID) found = (AXUIElementRef)CFRetain(window);
        }
        CFRelease(windows);
    }
    CFRelease(app);
    return found;
}
static CGRect YMAXFrame(AXUIElementRef window) {
    CGPoint origin = CGPointZero;
    CGSize size = CGSizeZero;
    AXValueRef value = NULL;
    if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, (CFTypeRef *)&value) == kAXErrorSuccess && value) { AXValueGetValue(value, kAXValueTypeCGPoint, &origin); CFRelease(value); }
    value = NULL;
    if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, (CFTypeRef *)&value) == kAXErrorSuccess && value) { AXValueGetValue(value, kAXValueTypeCGSize, &size); CFRelease(value); }
    return (CGRect){origin, size};
}

@interface YMPhysicalFocusGuard ()
@property(nonatomic, nullable) NSTimer *timer;
@property(nonatomic, nullable) NSSet<NSNumber *> *virtualWindowIDs;
@end

@implementation YMPhysicalFocusGuard
- (void)start {
    if (self.timer) return;
    __weak YMPhysicalFocusGuard *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf check]; }];
}
- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.virtualWindowIDs = nil;
}
- (void)check {
    if (![NSUserDefaults.standardUserDefaults boolForKey:YMKeepFocusKey] || !AXIsProcessTrusted() || !YMAnyVirtualDisplayActive()) {
        self.virtualWindowIDs = nil;
        return;
    }
    if (NSEvent.pressedMouseButtons) return; // mid-drag: decide after the drop
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableSet<NSNumber *> *now = [NSMutableSet set];
    NSMutableSet<NSNumber *> *arrivedPIDs = [NSMutableSet set];
    for (NSDictionary *window in list) {
        if ([window[(id)kCGWindowLayer] intValue] != 0) continue;
        pid_t pid = [window[(id)kCGWindowOwnerPID] intValue];
        if (pid == getpid()) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds) || bounds.size.height < 200) continue;
        if (!YMPointOnVirtualDisplay(CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)))) continue;
        NSNumber *ident = window[(id)kCGWindowNumber];
        [now addObject:ident];
        if (self.virtualWindowIDs && ![self.virtualWindowIDs containsObject:ident]) [arrivedPIDs addObject:@(pid)];
    }
    self.virtualWindowIDs = now;
    for (NSNumber *pid in arrivedPIDs) [self preferPhysicalWindowForPID:pid.intValue windows:list];
    [self rescueFocusedWindow];
}
// Make the app's frontmost window on a physical display its main window,
// without activating the app.
- (void)preferPhysicalWindowForPID:(pid_t)pid windows:(NSArray *)list {
    for (NSDictionary *window in list) { // front to back
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid || [window[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds) || bounds.size.height < 200) continue;
        if (YMPointOnVirtualDisplay(CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)))) continue;
        AXUIElementRef target = YMCopyFocusAXWindow(pid, [window[(id)kCGWindowNumber] unsignedIntValue]);
        if (!target) continue;
        AXUIElementSetAttributeValue(target, kAXMainAttribute, kCFBooleanTrue);
        CFRelease(target);
        return;
    }
}
- (void)rescueFocusedWindow {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front || front.processIdentifier == getpid()) return;
    AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
    AXUIElementRef window = NULL;
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef *)&window);
    CFRelease(app);
    if (!window) return;
    CGRect frame = YMAXFrame(window);
    if (!YMPointOnVirtualDisplay(CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)))) { CFRelease(window); return; }
    CGEventRef event = CGEventCreate(NULL);
    CGPoint pointer = event ? CGEventGetLocation(event) : CGPointZero;
    if (event) CFRelease(event);
    CGDirectDisplayID target = CGMainDisplayID();
    CGDirectDisplayID displays[4];
    uint32_t count = 0;
    if (CGGetDisplaysWithPoint(pointer, 4, displays, &count) == kCGErrorSuccess && count && ![VDVirtualDisplay isVirtualDisplay:displays[0]]) target = displays[0];
    CGRect bounds = CGDisplayBounds(target);
    CGSize fit = CGSizeMake(MIN(frame.size.width, bounds.size.width - 40), MIN(frame.size.height, bounds.size.height - 80));
    CGPoint place = CGPointMake(CGRectGetMidX(bounds) - fit.width / 2, MAX(CGRectGetMinY(bounds) + 40, CGRectGetMidY(bounds) - fit.height / 2));
    for (int attempt = 0; attempt < 3; attempt++) { // the first cross-display move is often clamped back
        AXValueRef position = AXValueCreate(kAXValueTypeCGPoint, &place);
        AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
        CFRelease(position);
        if (!CGSizeEqualToSize(fit, frame.size)) {
            AXValueRef size = AXValueCreate(kAXValueTypeCGSize, &fit);
            AXUIElementSetAttributeValue(window, kAXSizeAttribute, size);
            CFRelease(size);
        }
        if (CGRectContainsPoint(bounds, YMAXFrame(window).origin)) break;
    }
    os_log(OS_LOG_DEFAULT, "yomado: moved %{public}@'s focused window off a virtual display", front.localizedName ?: @"?");
    CFRelease(window);
}
@end
