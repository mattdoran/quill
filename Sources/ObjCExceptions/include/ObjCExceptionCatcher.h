#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Swift cannot catch an NSException; one that reaches it aborts the process.
+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
