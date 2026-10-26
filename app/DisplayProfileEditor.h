#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, YMDisplayProfileEditorMode) {
    YMDisplayProfileEditorModeCreate,
    YMDisplayProfileEditorModeEdit,
    YMDisplayProfileEditorModeRename
};

@interface YMDisplayProfileDraft : NSObject <NSCopying>
@property(nonatomic, copy) NSString *name;
@property(nonatomic) NSUInteger width;
@property(nonatomic) BOOL hiDPI;
- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width hiDPI:(BOOL)hiDPI;
- (YMDisplayProfileDraft * _Nullable)normalizedCopyValidatingDisplaySettings:(BOOL)validateSettings
                                                                      error:(NSError * _Nullable * _Nullable)error;
@end

@interface YMDisplayProfileEditor : NSWindowController <NSTextFieldDelegate>
@property(nonatomic, readonly) YMDisplayProfileEditorMode mode;
@property(nonatomic, copy, nullable) BOOL (^submitHandler)(YMDisplayProfileDraft *draft, NSError * _Nullable * _Nullable error);
@property(nonatomic, copy, nullable) void (^endHandler)(BOOL accepted);
- (instancetype)initWithMode:(YMDisplayProfileEditorMode)mode draft:(YMDisplayProfileDraft *)draft;
- (void)beginSheetForWindow:(NSWindow *)parent;
- (void)submit:(nullable id)sender;
- (void)cancel:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
