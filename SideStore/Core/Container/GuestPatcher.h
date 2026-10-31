//
//  GuestPatcher.h
//  AirStore
//
//  The one piece of LiveContainer's engine the store side needs: rewriting a guest's executable so it
//  can be dlopen'd inside AirBox. Signing stays where it already lives, in SideSign.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns nil when the bundle's executable has been rewritten in place, or a message saying why it
/// could not be. Encrypted (App Store) binaries cannot be prepared, and a bundle without an arm64
/// slice cannot either.
NSString * _Nullable ABPrepareGuestBundle(NSString *appBundlePath) NS_SWIFT_NAME(ABPrepareGuestBundle(appBundlePath:));

NS_ASSUME_NONNULL_END
