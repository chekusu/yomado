#import <Foundation/Foundation.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#import "LayoutPolicy.h"
#import "DiagnosticPrivacy.h"

static NSUInteger failures = 0;
static NSUInteger checks = 0;

static void Check(BOOL condition, NSString *description) {
    ++checks;
    if (condition) return;
    ++failures;
    fprintf(stderr, "FAIL: %s\n", description.UTF8String);
}

static NSMutableDictionary *Physical(double x, double y, double width) {
    return [@{@"isActive": @YES, @"isOnline": @YES, @"isVirtual": @NO,
              @"x": @(x), @"y": @(y), @"logicalWidth": @(width)} mutableCopy];
}

static void CheckEdge(NSArray *snapshot, NSNumber *expected, NSString *description) {
    NSNumber *actual = YMPhysicalRightEdge(snapshot);
    Check((expected == nil && actual == nil) ||
          (expected != nil && actual != nil && actual.doubleValue == expected.doubleValue), description);
}

static void LayoutFixtures(void) {
    CheckEdge(@[], nil, @"empty desktop has no physical right edge");
    CheckEdge(@[Physical(-3840, 0, 1920), Physical(-1600, 0, 1200)], @(-400),
              @"entirely negative desktop keeps its negative right edge");
    CheckEdge(@[Physical(0, 0, 1920), Physical(3000, 0, 2560)], @(5560),
              @"horizontal gaps count toward the desktop right edge");
    CheckEdge(@[Physical(-1920, -3000, 1920), Physical(0, 2500, 1600)], @(1600),
              @"vertical offsets do not alter horizontal placement");
    CheckEdge(@[Physical(0.5, 0, 100.25)], @(100.75), @"fractional coordinates stay precise");

    NSMutableDictionary *virtualDisplay = Physical(8000, 0, 1920);
    virtualDisplay[@"isVirtual"] = @YES;
    NSMutableDictionary *inactiveDisplay = Physical(10000, 0, 1920);
    inactiveDisplay[@"isActive"] = @NO;
    NSMutableDictionary *offlineDisplay = Physical(12000, 0, 1920);
    offlineDisplay[@"isOnline"] = @NO;
    NSArray *mixed = @[virtualDisplay, Physical(100, 800, 1920), inactiveDisplay, offlineDisplay];
    CheckEdge(mixed, @(2020), @"virtual, inactive, and offline displays are excluded");
    CheckEdge(@[virtualDisplay, inactiveDisplay, offlineDisplay], nil,
              @"no active online physical display returns nil");

    NSMutableArray *invalid = [NSMutableArray arrayWithArray:
        @[Physical(0, 0, 0), Physical(0, 0, -100), Physical(0, 0, NAN),
          Physical(0, 0, INFINITY), Physical(NAN, 0, 1920), Physical(INFINITY, 0, 1920),
          Physical(DBL_MAX, 0, DBL_MAX), @"not a display", @{}]];
    NSMutableDictionary *stringWidth = Physical(0, 0, 1920);
    stringWidth[@"logicalWidth"] = @"1920";
    [invalid addObject:stringWidth];
    NSMutableDictionary *missingVirtualFlag = Physical(0, 0, 1920);
    [missingVirtualFlag removeObjectForKey:@"isVirtual"];
    [invalid addObject:missingVirtualFlag];
    CheckEdge(invalid, nil, @"malformed fields, NaN, infinity, nonpositive width, and overflow are rejected");
    [invalid addObject:Physical(-2400, 0, 1920)];
    CheckEdge(invalid, @(-480), @"invalid entries do not hide a valid negative display edge");

    NSArray *before = [NSJSONSerialization JSONObjectWithData:
        [NSJSONSerialization dataWithJSONObject:mixed options:0 error:nil] options:NSJSONReadingMutableContainers error:nil];
    (void)YMPhysicalRightEdge(mixed);
    Check([mixed isEqual:before], @"layout policy leaves its source snapshot unchanged");

    Check([YMDesktopRightEdge(mixed) isEqual:@9920], @"new workspaces append after existing virtual displays too");
    Check(YMDesktopRightEdge(@[inactiveDisplay, offlineDisplay]) == nil, @"append ignores inactive and offline outputs");
    Check([YMDesktopRightEdge(@[Physical(-3840, 0, 1920)]) isEqual:@(-1920)], @"append preserves a negative desktop edge");
    Check([YMDesktopRightEdge(@[Physical(0, 0, NAN), Physical(0, 0, 1920)]) isEqual:@1920], @"append rejects invalid geometry");
    Check(YMDesktopRightEdge(@[Physical(DBL_MAX, 0, DBL_MAX)]) == nil, @"append rejects coordinate overflow");
    Check([mixed isEqual:before], @"multi-display append does not mutate the original arrangement");
}

static void PrivacyFixtures(void) {
    NSMutableDictionary *device = [@{@"serialNumber": @12345678, @"displayID": @8,
                                      @"x": @(-1920), @"logicalWidth": @1920} mutableCopy];
    NSMutableArray *nested = [NSMutableArray arrayWithArray:
        @[device, @{@"deeper": @[@{@"serialNumber": @87654321, @"isActive": @YES}]},
          @"serialNumber", @17, NSNull.null]];
    NSMutableDictionary *raw = [@{@"serialNumber": @11111111, @"before": nested,
                                  @"during": @[@{@"serialNumber": @22222222, @"displayID": @9}],
                                  @"after": @{@"serialNumber": @33333333, @"main": @YES}} mutableCopy];
    NSData *before = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingSortedKeys error:nil];
    NSDictionary *redacted = YMRedactedDiagnostics(raw);
    Check(redacted[@"serialNumber"] == nil && redacted[@"after"][@"serialNumber"] == nil &&
          redacted[@"during"][0][@"serialNumber"] == nil &&
          redacted[@"before"][0][@"serialNumber"] == nil &&
          redacted[@"before"][1][@"deeper"][0][@"serialNumber"] == nil,
          @"serial keys are removed throughout nested dictionaries and arrays");
    Check([redacted[@"before"][0][@"displayID"] isEqual:@8] &&
          [redacted[@"before"][0][@"x"] isEqual:@(-1920)] &&
          [redacted[@"before"][2] isEqual:@"serialNumber"] &&
          [redacted[@"before"][3] isEqual:@17] && redacted[@"before"][4] == NSNull.null,
          @"recovery fields and ordinary scalar values are preserved");
    NSData *after = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingSortedKeys error:nil];
    Check([before isEqualToData:after] && [device[@"serialNumber"] isEqual:@12345678],
          @"redaction does not modify the original mutable input");
    device[@"displayID"] = @99;
    [nested addObject:@{@"serialNumber": @44444444}];
    Check([redacted[@"before"][0][@"displayID"] isEqual:@8] && [redacted[@"before"] count] == 5,
          @"returned container tree is independent of later source mutations");
    Check([YMRedactedDiagnostics(@[@{@"serialNumber": @1, @"kept": @2}]) isEqual:@[@{@"kept": @2}]],
          @"array roots are redacted");
    Check(YMRedactedDiagnostics(NSNull.null) == NSNull.null && YMRedactedDiagnostics(nil) == nil,
          @"null and nil roots remain unchanged");
}

static NSDictionary *Output(unsigned displayID, BOOL active, BOOL isVirtual, BOOL mirrored, unsigned serial) {
    return @{@"displayID": @(displayID), @"isActive": @(active), @"isVirtual": @(isVirtual),
             @"isInMirrorSet": @(mirrored), @"vendorID": @1552, @"modelNumber": @44, @"serialNumber": @(serial)};
}

static void OutputFixtures(void) {
    NSArray *targets = YMPhysicalOutputTargets(@[Output(9, YES, NO, NO, 7), Output(3, YES, NO, NO, 8),
                                                  Output(12, YES, YES, NO, 0), Output(5, NO, NO, NO, 9)]);
    Check([[targets valueForKey:@"displayID"] isEqualToArray:(@[@3, @9])],
          @"only active physical outputs are targets, sorted by ID");
    Check(YMPhysicalOutputTargets(@[Output(3, YES, NO, YES, 8)]) == nil, @"a mirrored physical output refuses");
    Check(YMPhysicalOutputTargets(@[Output(3, YES, YES, YES, 0)]).count == 0, @"a mirrored virtual display is ignored");
    Check(YMPhysicalOutputTargets(@[(NSDictionary *)(id)@"bad"]) == nil, @"a malformed snapshot refuses");
    Check(![YMPhysicalOutputTargets(@[Output(3, YES, NO, NO, 8)])
              isEqualToArray:YMPhysicalOutputTargets(@[Output(3, YES, NO, NO, 99)])],
          @"a reused display ID with another serial is a different target");
    Check([YMPhysicalOutputTargets(@[Output(3, YES, NO, NO, 8), Output(12, YES, YES, NO, 0)])
              isEqualToArray:YMPhysicalOutputTargets(@[Output(12, YES, YES, NO, 0), Output(3, YES, NO, NO, 8)])],
          @"snapshot order does not change the targets");

    Check(YMOutputRestoreStepFor(0, 0, 0) == YMOutputRestoreDone, @"all targets active finishes at once");
    Check(YMOutputRestoreStepFor(1, 0, 30) == YMOutputRestoreWait, @"a dark connected target keeps waiting");
    Check(YMOutputRestoreStepFor(1, 0, 60) == YMOutputRestoreGiveUp, @"automatic retries stop after a minute");
    Check(YMOutputRestoreStepFor(0, 1, 2) == YMOutputRestoreWait, @"an offline target gets a few seconds");
    Check(YMOutputRestoreStepFor(0, 1, 5) == YMOutputRestoreDone, @"an unplugged target does not block recovery");
    Check(YMOutputRestoreStepFor(1, 1, 10) == YMOutputRestoreWait, @"an unplugged target does not end the wait for another");
    Check(!YMRestoreDeadlineReached(59.99), @"layout recovery remains retryable before the deadline");
    Check(YMRestoreDeadlineReached(60), @"layout recovery stalls at the deadline");
    Check(YMRestoreDeadlineReached(INFINITY), @"non-finite recovery elapsed time fails closed at the deadline");
}

int main(void) {
    @autoreleasepool {
        LayoutFixtures();
        PrivacyFixtures();
        OutputFixtures();
        if (failures) {
            fprintf(stderr, "%lu of %lu policy checks failed.\n", (unsigned long)failures, (unsigned long)checks);
            return 1;
        }
        printf("Passed %lu policy checks; no displays or GUI were accessed.\n", (unsigned long)checks);
        return 0;
    }
}
