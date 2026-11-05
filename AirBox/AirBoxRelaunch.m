//
//  AirBoxRelaunch.m
//  AirBox
//
//  Asking FrontBoard to bring this app's own bundle id back up, which is how a guest takes over the
//  next process instead of this one. Both classes are private, so they are looked up by name at
//  runtime: using the declarations in AirBoxPrivate.h as ordinary messages asks the linker for symbols
//  no framework iOS ships (measured here: "_OBJC_CLASS_$_LSApplicationWorkspace, referenced from: in
//  GuestStore.o"). This is the same shape as upstream's PrivClass() calls in LCSharedUtils.m, and for
//  the same reason.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "AirBoxPrivate.h"

BOOL AirBoxAskToRelaunchSelf(void (^completion)(BOOL success, NSString *_Nullable reason))
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    Class configurationClass = NSClassFromString(@"_LSOpenConfiguration");
    if (workspaceClass == nil || configurationClass == nil)
    {
        if (completion) { completion(NO, @"this iOS does not expose the launch workspace"); }
        return NO;
    }

    id (*readWorkspace)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    id workspace = readWorkspace(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    if (workspace == nil)
    {
        if (completion) { completion(NO, @"the launch workspace answered with nothing"); }
        return NO;
    }

    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if (![workspace respondsToSelector:openSelector])
    {
        if (completion) { completion(NO, @"the workspace does not answer openApplicationWithBundleIdentifier"); }
        return NO;
    }

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier.length == 0)
    {
        if (completion) { completion(NO, @"AirBox has no bundle identifier to ask for"); }
        return NO;
    }

    id configuration = [[configurationClass alloc] init];
    void (*sendOpen)(id, SEL, NSString *, id, void (^)(BOOL, NSError *)) =
        (void (*)(id, SEL, NSString *, id, void (^)(BOOL, NSError *)))objc_msgSend;

    sendOpen(workspace, openSelector, bundleIdentifier, configuration, ^(BOOL success, NSError *_Nullable error) {
        if (completion == nil) { return; }
        completion(success, success ? nil : (error.localizedDescription ?: @"FrontBoard gave no reason"));
    });
    return YES;
}
