#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const YMDisplayTopologyErrorDomain;
/// Privacy-safe context on mode-setting failures: display role, CGError and
/// scalar mode properties only. No device identifiers or retained mode tokens.
FOUNDATION_EXPORT NSString *const YMDisplayTopologyDiagnosticsKey;

/// In-memory only. Display identities and retained CoreGraphics mode objects are
/// never persisted. Removing a member is useful when an owned screen is closed.
/// Once an unrelated change is observed, recovery with this snapshot remains
/// read-only, including subsequent retries; take a fresh snapshot for new work.
@interface YMDisplayTopologySnapshot : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, id> *> *displays;
- (nullable YMDisplayTopologySnapshot *)snapshotByExcludingDisplayID:(CGDirectDisplayID)displayID;
@end

/// Injectable transaction boundary. Tests use synthetic inventories and never
/// access WindowServer. Mode tokens are retained objects owned by each snapshot.
/// Error 4 may include a complete identity inventory under "displayInventory"
/// while current mode metadata is pending; partial data never grants admission.
@protocol YMDisplayTopologyBackend <NSObject>
- (nullable NSArray<NSDictionary<NSString *, id> *> *)readDisplaysWithError:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)modeForDisplay:(CGDirectDisplayID)displayID
    width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI error:(NSError **)error;
- (BOOL)beginConfiguration:(NSError **)error;
- (BOOL)setMirrorOfDisplay:(CGDirectDisplayID)displayID toDisplay:(CGDirectDisplayID)targetID error:(NSError **)error;
- (BOOL)setModeOfDisplay:(CGDirectDisplayID)displayID token:(id)modeToken error:(NSError **)error;
- (BOOL)setOriginOfDisplay:(CGDirectDisplayID)displayID x:(int32_t)x y:(int32_t)y error:(NSError **)error;
- (BOOL)commitConfiguration:(NSError **)error;
- (void)cancelConfiguration;
/// Waits between independent reads; production pumps the current run loop.
- (void)waitForNextObservation;
@property(nonatomic, readonly) NSUInteger reconfigurationGeneration;
@end

/// Serialize capture/configuration/recovery calls on one operation queue. A GUI
/// must keep its normal main AppKit event loop running during these bounded
/// operations so display notifications can refresh process-local mode caches.
@interface YMDisplayTopology : NSObject
- (instancetype)init;
- (instancetype)initWithBackend:(id<YMDisplayTopologyBackend>)backend NS_DESIGNATED_INITIALIZER;
- (nullable YMDisplayTopologySnapshot *)captureSnapshotWithError:(NSError **)error;
/// Call after creation, before allowing any application into the new display.
/// A failed result grants no admission. The owner must destroy ONLY its newly
/// created display and then call restoreAndVerifySnapshot:excludingDisplayID:.
- (BOOL)configureAndVerifyNewDisplay:(CGDirectDisplayID)displayID
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                             hiDPI:(BOOL)hiDPI
                          baseline:(YMDisplayTopologySnapshot *)baseline
                             error:(NSError **)error;
/// Excludes a just-removed owned ID while waiting for asynchronous removal.
/// Unknown/re-enumerated outputs and unrelated user changes prevent writes.
/// Later calls on the same snapshot only verify a manual recovery. Unsupported recovery is an
/// error, never success with a warning. Pass 0 when no ID needs exclusion.
- (BOOL)restoreAndVerifySnapshot:(YMDisplayTopologySnapshot *)snapshot
            excludingDisplayID:(CGDirectDisplayID)displayID
                         error:(NSError **)error;
- (BOOL)verifySnapshot:(YMDisplayTopologySnapshot *)snapshot error:(NSError **)error;
/// Restores only the caller's recreated extended outputs to their saved origins.
/// The full fresh baseline must still match. Other output modes, main status,
/// mirror relationships and positions are pinned and verified unchanged.
- (BOOL)positionOwnedDisplays:(NSDictionary<NSNumber *, NSDictionary *> *)origins
                     baseline:(YMDisplayTopologySnapshot *)baseline error:(NSError **)error;
/// Fresh read-only admission check, including mirror roots and followers.
- (BOOL)isExtendedTarget:(CGDirectDisplayID)displayID
                  width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI;
@end

NS_ASSUME_NONNULL_END
