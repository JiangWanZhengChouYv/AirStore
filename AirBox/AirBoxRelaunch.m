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

// The iOS SDK declares none of this. The engine carries the same two lines in
// Dependencies/LiveContainer/LiveContainer/utils.h, and CS_DEBUGGED there is 0x10000000 -- which is the
// value the device log has been reporting against (flags 0x22003305 with CS_DEBUGGED clear).
#ifndef AirBoxCSDebugged
#define AirBoxCSDebugged 0x10000000
#endif

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#import "AirBoxPrivate.h"

BOOL AirBoxIsBeingDebugged(void)
{
    // The same question the engine asks before loading a guest, asked here before asking to be
    // relaunched. A debugger attached to this pid means Enable JIT is still running, and a relaunch
    // would kill exactly the process its script is reading -- which is how one tap ended up spinning
    // 39,575 unreadable stops.
    int flags = 0;
    if (csops(getpid(), 0, &flags, sizeof(flags)) != 0)
    {
        return NO;
    }
    return (flags & AirBoxCSDebugged) != 0;
}

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
