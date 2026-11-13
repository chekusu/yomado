#import <Foundation/Foundation.h>
#include <stdio.h>

// Include the implementation so this fixture can exercise the state
// transitions without starting the application or showing AppKit panels.
#import "InputLease.m"

static NSUInteger failures = 0;
static NSUInteger checks = 0;

static void Check(BOOL condition, NSString *description) {
    ++checks;
    if (condition) return;
    ++failures;
    fprintf(stderr, "FAIL: %s\n", description.UTF8String);
}

@interface YMInputLeaseDeadlineFixture : YMInputLeaseCenter
@property(nonatomic, copy) NSDictionary *lastReply;
@property(nonatomic) NSMutableArray<NSDictionary *> *replies;
@property(nonatomic, copy) NSString *shownRequestID;
@end

@implementation YMInputLeaseDeadlineFixture

- (void)respond:(NSString *)requestID status:(NSString *)status extra:(NSDictionary *)extra {
    NSMutableDictionary *reply = [extra mutableCopy];
    reply[@"requestID"] = requestID;
    reply[@"status"] = status;
    self.lastReply = reply;
    if (!self.replies) self.replies = [NSMutableArray array];
    [self.replies addObject:reply];
}

- (void)endActiveLeaseWithReason:(NSString *)reason {
    NSString *leaseID = self.activeLeaseID;
    if (leaseID) self.endedLeases[leaseID] = reason;
    self.activeLeaseID = nil;
    self.expiry = nil;
}

- (void)showIndicator {}
- (void)restorePreviousControls {}
- (void)showPromptForRequest:(NSString *)requestID agent:(NSString *)agent reason:(NSString *)reason
                     seconds:(NSTimeInterval)seconds {
    (void)agent; (void)reason; (void)seconds;
    self.shownRequestID = requestID;
}

@end

static void ExpiredLeaseStatusFixture(void) {
    YMInputLeaseDeadlineFixture *center = [YMInputLeaseDeadlineFixture new];
    center.endedLeases = [NSMutableDictionary dictionary];
    center.activeLeaseID = @"known-lease";
    center.expiry = [NSDate dateWithTimeIntervalSinceNow:-60];
    [center handleStatus:@{@"leaseID":@"known-lease"} requestID:@"status-request"];
    Check([center.lastReply[@"status"] isEqualToString:@"ended"],
          @"status ends an expired lease even when its timer has not fired");
    Check([center.lastReply[@"reason"] isEqualToString:@"expired"],
          @"status reports the synchronous lease expiry reason");
}

static void ExpiredPromptFixture(void) {
    YMInputLeaseDeadlineFixture *center = [YMInputLeaseDeadlineFixture new];
    center.promptRequestID = @"pending-request";
    center.promptAgent = @"fixture";
    center.promptDeadline = [NSDate dateWithTimeIntervalSinceNow:-60];
    center.promptSeconds = 10;
    [center finishPromptGranted:YES status:@"granted"];
    Check([center.lastReply[@"status"] isEqualToString:@"timeout"],
          @"approval rejects an expired prompt even when its timer has not fired");
    Check(center.activeLeaseID == nil, @"expired prompt never creates a lease");
}

static void ReleaseDeadlineFixtures(void) {
    YMInputLeaseDeadlineFixture *center = [YMInputLeaseDeadlineFixture new];
    center.endedLeases = [NSMutableDictionary dictionary];
    center.activeLeaseID = @"old-lease";
    center.expiry = [NSDate dateWithTimeIntervalSinceNow:-60];
    [center handleRelease:@{@"leaseID":@"old-lease"} requestID:@"late-release"];
    Check([center.lastReply[@"status"] isEqualToString:@"ended"] &&
          [center.lastReply[@"reason"] isEqualToString:@"expired"],
          @"a late release retains the expiry reason rather than reporting success");
    Check(center.activeLeaseID == nil, @"late release synchronously clears the expired lease");

    center.activeLeaseID = @"current-lease";
    center.expiry = [NSDate dateWithTimeIntervalSinceNow:60];
    [center handleStatus:@{@"leaseID":@"current-lease"} requestID:@"current-status"];
    Check([center.lastReply[@"status"] isEqualToString:@"active"], @"a current lease remains active");
    [center handleRelease:@{@"leaseID":@"current-lease"} requestID:@"current-release"];
    Check([center.lastReply[@"status"] isEqualToString:@"released"] &&
          [center.endedLeases[@"current-lease"] isEqualToString:@"released"],
          @"a release before expiry retains ordinary release behavior");
}

static void RequestDeadlineFixtures(void) {
    YMInputLeaseDeadlineFixture *center = [YMInputLeaseDeadlineFixture new];
    center.endedLeases = [NSMutableDictionary dictionary];
    center.activeLeaseID = @"old-lease";
    center.expiry = [NSDate dateWithTimeIntervalSinceNow:-60];
    [center handleRequest:@{} requestID:@"next-request"];
    Check([center.endedLeases[@"old-lease"] isEqualToString:@"expired"],
          @"a new request first expires a stale active lease");
    Check([center.lastReply[@"status"] isEqualToString:@"pending"] &&
          [center.shownRequestID isEqualToString:@"next-request"],
          @"a stale lease does not make a new request busy");

    center = [YMInputLeaseDeadlineFixture new];
    center.promptRequestID = @"old-request";
    center.promptDeadline = [NSDate dateWithTimeIntervalSinceNow:-60];
    [center handleRequest:@{} requestID:@"replacement-request"];
    Check(center.replies.count == 2 &&
          [center.replies.firstObject[@"requestID"] isEqualToString:@"old-request"] &&
          [center.replies.firstObject[@"status"] isEqualToString:@"timeout"],
          @"a new request responds to the expired prompt before responding to itself");
    Check([center.lastReply[@"status"] isEqualToString:@"pending"] &&
          [center.shownRequestID isEqualToString:@"replacement-request"],
          @"an expired prompt permits a new approval request");

    center = [YMInputLeaseDeadlineFixture new];
    center.activeLeaseID = @"current-lease";
    center.expiry = [NSDate dateWithTimeIntervalSinceNow:60];
    [center handleRequest:@{} requestID:@"blocked-request"];
    Check([center.lastReply[@"status"] isEqualToString:@"busy"] && center.shownRequestID == nil,
          @"a current lease still blocks a new approval request");
}

int main(void) {
    @autoreleasepool {
        ExpiredLeaseStatusFixture();
        ExpiredPromptFixture();
        ReleaseDeadlineFixtures();
        RequestDeadlineFixtures();
        printf("Input lease deadlines: %lu checks, %lu failures\n", (unsigned long)checks,
               (unsigned long)failures);
        return failures == 0 ? 0 : 1;
    }
}
