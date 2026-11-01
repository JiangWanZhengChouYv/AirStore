//
//  main.m
//  LiveProcess
//
//  The process a guest actually runs in. Two things depend on it being a separate bundle rather than
//  another thread of AirBox: iOS hands an extension declared as XPCService/_ProcessType=App an app's
//  memory ceiling, and the engine only turns on the dlopen hook when its own url scheme reads
//  "liveprocess" -- without that hook the loader refuses the guest's libraries.
//  Needs proper testing on every iOS version AirStore claims to support.
//

#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "LCSharedUtils.h"
#import "Tweaks.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end

@implementation LiveProcessHandler

static NSExtensionContext *extensionContext;

+ (NSExtensionContext *)extensionContext
{
    return extensionContext;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    extensionContext = context;
    // The request carries nothing we need: which guest to run is already in the app group's defaults,
    // written by AirBox before it opened this scheme. This only stops the process waiting forever.
    CFRunLoopStop(CFRunLoopGetMain());
}

@end

extern int LiveContainerMain(int argc, char *argv[]);

/// AirBox's own url scheme, which is what a guest has to open to get back to the list.
static NSString *hostUrlScheme(void)
{
    // .../AirBox.app/PlugIns/LiveProcess.appex, so two steps back is the box itself.
    NSURL *hostURL = [[NSBundle.mainBundle.bundleURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSDictionary *info = [NSBundle bundleWithURL:hostURL].infoDictionary;
    NSArray *urlTypes = (NSArray *)info[@"CFBundleURLTypes"];
    NSArray *schemes = ((NSDictionary *)urlTypes.firstObject)[@"CFBundleURLSchemes"];
    return (NSString *)schemes.firstObject;
}

int LiveProcessMain(int argc, char *argv[])
{
    // NSExtensionMain brings up UIKit, which calls the UIApplicationMain below; until the context has
    // arrived the hand-over is not ours to read, so hold here for it.
    CFRunLoopRun();

    // LP_HOME stays this process's own, because a binary that the loader will not mmap from where it is
    // gets moved here first. Where the guests themselves are is not something this process can guess, so
    // the box writes its own home into the group each time it looks at the list, and that folder's
    // Documents/Applications is what the engine then reads. Left unset, the engine falls back to HOME.
    setenv("LP_HOME_PATH", getenv("HOME"), 1);

    NSString *group = [LCSharedUtils appGroupID];
    NSUserDefaults *shared = group.length ? [[NSUserDefaults alloc] initWithSuiteName:group] : nil;
    NSString *hostHome = [shared stringForKey:@"LCHostHomePath"];
    if (hostHome.length)
    {
        setenv("LC_HOME_PATH", hostHome.fileSystemRepresentation, 1);
    }

    NSString *scheme = hostUrlScheme();
    if (scheme)
    {
        // The engine swaps its own scheme for this one as soon as it notices a live process, so that
        // what the guest is told to open is the box rather than an extension nobody installed.
        [NSUserDefaults.standardUserDefaults setObject:scheme forKey:@"hostUrlScheme"];
    }

    return LiveContainerMain(argc, argv);
}

// UIKit's own main, reached through the hook below instead of the real one.
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName)
{
    return LiveProcessMain(argc, argv);
}

static void *(*orig_dlopen)(void *dyldApiInstancePtr, const char *path, int mode);

static void *hook_dlopen(void *dyldApiInstancePtr, const char *path, int mode)
{
    const char *uikitPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if (path && !strncmp(path, uikitPath, strlen(uikitPath)))
    {
        // Only this one load is intercepted, and the process is handed back to the real dlopen.
        performHookDyldApi("dlopen", 2, (void **)&orig_dlopen, orig_dlopen);
        return RTLD_MAIN_ONLY;
    }

    return orig_dlopen(dyldApiInstancePtr, path, mode);
}

int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[])
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    // The extension's decoder refuses classes it has no profile entry for, which includes the ones the
    // request arrives wrapped in before we ever get to look at them.
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"),
                                                     @selector(_validateAllowedClass:forKey:allowingInvocations:)),
                             (IMP)hook_do_nothing);
#pragma clang diagnostic pop

    performHookDyldApi("dlopen", 2, (void **)&orig_dlopen, hook_dlopen);

    int (*real_NSExtensionMain)(int argc, char *argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    return real_NSExtensionMain(argc, argv);
}
