#import <Foundation/Foundation.h>
#include <stdio.h>
#import "InputLeasePolicy.h"

static NSUInteger failures = 0;
static NSUInteger checks = 0;

static void Check(BOOL condition, NSString *description) {
    ++checks;
    if (condition) return;
    ++failures;
    fprintf(stderr, "FAIL: %s\n", description.UTF8String);
}

static void DurationFixtures(void) {
    Check(YMInputLeaseClampSeconds(nil) == YMInputLeaseDefaultSeconds, @"missing duration uses the default");
    Check(YMInputLeaseClampSeconds(@"300") == YMInputLeaseDefaultSeconds, @"string duration uses the default");
    Check(YMInputLeaseClampSeconds(@(NAN)) == YMInputLeaseDefaultSeconds, @"NaN duration uses the default");
    Check(YMInputLeaseClampSeconds(@(-5)) == YMInputLeaseDefaultSeconds, @"negative duration uses the default");
    Check(YMInputLeaseClampSeconds(@(1)) == YMInputLeaseMinimumSeconds, @"short duration is raised to the minimum");
    Check(YMInputLeaseClampSeconds(@(INFINITY)) == YMInputLeaseDefaultSeconds, @"infinite duration uses the default");
    Check(YMInputLeaseClampSeconds(@(86400)) == YMInputLeaseMaximumSeconds, @"long duration is capped");
    Check(YMInputLeaseClampSeconds(@(90.4)) == 90, @"duration rounds to whole seconds");
}

static void DeadlineFixtures(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
    NSDate *expiredLease = [NSDate dateWithTimeIntervalSince1970:999];
    NSDate *expiredPrompt = [NSDate dateWithTimeIntervalSince1970:998];
    NSDate *current = [NSDate dateWithTimeIntervalSince1970:1001];
    Check(YMInputLeaseDeadlineExpired(expiredLease, now),
          @"an expired lease deadline must be treated as ended by status transitions");
    Check(!YMInputLeaseDeadlineExpired(current, now),
          @"a current lease deadline remains active");
    Check(YMInputLeaseDeadlineExpired(expiredPrompt, now),
          @"an expired prompt deadline must reject a late approval");
    Check(YMInputLeaseDeadlineExpired(nil, now),
          @"a missing pending deadline fails closed");
    Check(YMInputLeaseDeadlineExpired(now, now), @"the exact deadline is expired");
}

static void TextFixtures(void) {
    Check([YMInputLeaseDisplayText(nil, 40, @"fallback") isEqualToString:@"fallback"], @"missing text uses the fallback");
    Check([YMInputLeaseDisplayText(@42, 40, @"fallback") isEqualToString:@"fallback"], @"non-string text uses the fallback");
    Check([YMInputLeaseDisplayText(@" \n\t ", 40, @"fallback") isEqualToString:@"fallback"], @"blank text uses the fallback");
    Check([YMInputLeaseDisplayText(@"  Codex\n\n允许\tBlender  ", 40, @"x") isEqualToString:@"Codex 允许 Blender"],
          @"newlines, tabs and runs collapse to single spaces");
    NSString *hostile = [NSString stringWithFormat:@"a%Cb%Cc", (unichar)0x202E, (unichar)0x0007];
    Check([YMInputLeaseDisplayText(hostile, 40, @"x") isEqualToString:@"a b c"],
          @"control and bidi override characters cannot reshape the prompt");
    NSString *capped = YMInputLeaseDisplayText(@"abcdefghij", 5, @"x");
    Check([capped isEqualToString:@"abcd…"], @"long text is capped with an ellipsis");
    NSString *emoji = YMInputLeaseDisplayText(@"ab👩‍💻cd", 4, @"x");
    Check([emoji isEqualToString:@"ab👩‍💻…"] || [emoji isEqualToString:@"ab…"], @"capping never splits a composed character");
}

static void GeometryFixtures(void) {
    NSRect frame = YMInputLeaseIndicatorFrame(NSMakeRect(0, 0, 1920, 1055), NSMakeSize(330, 64), 12);
    Check(NSEqualRects(frame, NSMakeRect(1578, 979, 330, 64)), @"notice sits in the top-right corner of the visible frame");
    frame = YMInputLeaseIndicatorFrame(NSMakeRect(-2560, 200, 2560, 1415), NSMakeSize(330, 64), 12);
    Check(NSEqualRects(frame, NSMakeRect(-342, 1539, 330, 64)), @"negative screen origins keep the notice on that screen");
    frame = YMInputLeaseIndicatorFrame(NSMakeRect(0, 0, 200, 50), NSMakeSize(330, 64), 12);
    Check(frame.size.width == 176 && frame.size.height == 26 && frame.origin.x == 12, @"notice shrinks to fit a tiny screen");
    Check([YMInputLeaseRemainingText(119.2) isEqualToString:@"2:00"], @"remaining time rounds up");
    Check([YMInputLeaseRemainingText(-3) isEqualToString:@"0:00"], @"remaining time never goes negative");
    Check([YMInputLeaseRemainingText(600) isEqualToString:@"10:00"], @"ten minutes formats as 10:00");
}

int main(void) {
    @autoreleasepool {
        DurationFixtures();
        DeadlineFixtures();
        TextFixtures();
        GeometryFixtures();
        printf("Input lease policy: %lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
        return failures == 0 ? 0 : 1;
    }
}
