//
//  AirBoxPrivate.h
//  AirBox
//
//  NSExtension has no public declaration in the iOS SDK, and it is the only way to ask an app's own
//  extension to start. The shape is LiveContainer's (LiveContainer/FoundationPrivate.h), copied so that
//  the request AirBox makes and the request upstream makes are the same request.
//

#include <Foundation/Foundation.h>

@interface NSExtension : NSObject

@property (nonatomic, strong, readwrite) NSArray *preferredLanguages;

+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)arg1;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *uuid, NSError *error))callback;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))callback;

@end
