#ifndef YOMADO_INPUT_LEASE_POLICY_H
#define YOMADO_INPUT_LEASE_POLICY_H

#import <Foundation/Foundation.h>
#include <math.h>

// An agent that cannot work through background input (AX actions or
// per-process events) must borrow the shared mouse and keyboard. It asks the
// running app over distributed notifications; the person approves on the
// physical main display and a persistent notice stays visible until the lease
// is released, expires or is stopped.
static NSString *const YMInputLeaseObject = @"dev.chekusu.yomado";
static NSString *const YMInputLeaseRequestName = @"dev.chekusu.yomado.input.request";
static NSString *const YMInputLeaseReleaseName = @"dev.chekusu.yomado.input.release";
static NSString *const YMInputLeaseStatusName = @"dev.chekusu.yomado.input.status";
static NSString *const YMInputLeaseResponseName = @"dev.chekusu.yomado.input.response";
static NSString *const YMInputLeaseEndedName = @"dev.chekusu.yomado.input.ended";

static const NSTimeInterval YMInputLeaseDefaultSeconds = 120;
static const NSTimeInterval YMInputLeaseMinimumSeconds = 10;
static const NSTimeInterval YMInputLeaseMaximumSeconds = 600;
// An unanswered prompt is denied; nobody approves on an unattended Mac.
static const NSTimeInterval YMInputLeaseDecisionSeconds = 60;
static const NSUInteger YMInputLeaseAgentLength = 40;
static const NSUInteger YMInputLeaseReasonLength = 160;

// Timer callbacks are only for presentation and cleanup. State transitions
// must make their decision against the current deadline even when the run loop
// has delayed a timer. Missing dates fail closed while a state is pending.
static inline BOOL YMInputLeaseDeadlineExpired(NSDate *deadline, NSDate *now) {
    return !deadline || !now || [deadline compare:now] != NSOrderedDescending;
}

static inline NSTimeInterval YMInputLeaseClampSeconds(id requested) {
    if (![requested isKindOfClass:NSNumber.class]) return YMInputLeaseDefaultSeconds;
    double seconds = [requested doubleValue];
    if (!isfinite(seconds) || seconds <= 0) return YMInputLeaseDefaultSeconds;
    return MIN(MAX(round(seconds), YMInputLeaseMinimumSeconds), YMInputLeaseMaximumSeconds);
}

// Request text is shown in a trusted prompt. Collapse control characters and
// whitespace runs so a request cannot fake extra lines or buttons, then cap it.
static inline NSString *YMInputLeaseDisplayText(id text, NSUInteger maximum, NSString *fallback) {
    if (![text isKindOfClass:NSString.class]) return fallback;
    NSMutableString *clean = [NSMutableString string];
    __block BOOL pendingSpace = NO;
    [(NSString *)text enumerateSubstringsInRange:NSMakeRange(0, [(NSString *)text length])
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *piece, NSRange range, NSRange enclosing, BOOL *stop) {
            (void)range; (void)enclosing; (void)stop;
            unichar first = [piece characterAtIndex:0];
            BOOL blank = [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:first] ||
                [NSCharacterSet.controlCharacterSet characterIsMember:first] ||
                [NSCharacterSet.illegalCharacterSet characterIsMember:first];
            if (blank) { pendingSpace = clean.length > 0; return; }
            if (pendingSpace) [clean appendString:@" "];
            pendingSpace = NO;
            [clean appendString:piece];
        }];
    if (!clean.length) return fallback;
    if (clean.length <= maximum) return clean;
    NSRange keep = [clean rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maximum - 1)];
    return [[clean substringWithRange:keep] stringByAppendingString:@"…"];
}

// Top-right corner of the physical main display's visible frame, so the notice
// stays clear of the menu bar and of agent work on virtual displays.
static inline NSRect YMInputLeaseIndicatorFrame(NSRect visibleFrame, NSSize size, CGFloat margin) {
    CGFloat width = MIN(size.width, MAX(visibleFrame.size.width - 2 * margin, 0));
    CGFloat height = MIN(size.height, MAX(visibleFrame.size.height - 2 * margin, 0));
    return NSMakeRect(NSMaxX(visibleFrame) - margin - width, NSMaxY(visibleFrame) - margin - height, width, height);
}

static inline NSString *YMInputLeaseRemainingText(NSTimeInterval remaining) {
    NSInteger seconds = (NSInteger)ceil(MAX(remaining, 0));
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

#endif
