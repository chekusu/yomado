#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YMSavedDisplayProfileRow : NSObject
@property(nonatomic, readonly) NSUInteger ordinal;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *detail;
@property(nonatomic, copy, readonly) NSString *message;
@property(nonatomic, readonly) BOOL starting;
@property(nonatomic, readonly) BOOL canStart;
@property(nonatomic, readonly) BOOL canEdit;
- (instancetype)initWithOrdinal:(NSUInteger)ordinal name:(NSString *)name
                         detail:(NSString *)detail message:(NSString *)message
                       starting:(BOOL)starting canStart:(BOOL)canStart canEdit:(BOOL)canEdit;
@end

@interface YMSavedDisplayProfilesView : NSView
@property(nonatomic, copy, nullable) void (^onStart)(NSUInteger ordinal);
@property(nonatomic, copy, nullable) void (^onEdit)(NSUInteger ordinal);
@property(nonatomic, readonly) BOOL collapsed;
- (void)updateRows:(NSArray<YMSavedDisplayProfileRow *> *)rows
     revealOrdinal:(NSNumber * _Nullable)revealOrdinal;
- (void)toggleCollapsed:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
