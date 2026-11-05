//
//  AirBoxPrivate.h
//  AirBox
//
//  Two private shapes, both matching LiveContainer's own headers (LiveContainer/FoundationPrivate.h and
//  UIKitPrivate.h) so that what AirBox asks is the same request upstream asks.
//
//  NSExtension has no public declaration in the iOS SDK, and it is the only way to ask an app's own
//  extension to start.
//
//  Bringing *this* app back up is the other half, because a guest is taken over by the next process and
//  not this one. It is declared as a function rather than as the two private classes: naming those
//  classes in a message sends the linker looking for symbols no framework iOS ships, which is why
//  AirBoxRelaunch.m reaches them by name at runtime.
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

/// YES when a debugger is attached to this process. While Enable JIT is running that is exactly the
/// case, and it is the thing a relaunch request must not do: the debugger holds this pid.
FOUNDATION_EXPORT BOOL AirBoxIsBeingDebugged(void);

/// Asks FrontBoard to open this app's own bundle id again. Returns NO when the request could not even be
/// made; the completion carries FrontBoard's answer, which is where the caller either gives up this
/// process so the relaunched one takes the guest, or explains why it cannot.
FOUNDATION_EXPORT BOOL AirBoxAskToRelaunchSelf(void (^completion)(BOOL success, NSString *_Nullable reason));


