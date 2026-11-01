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
#import <stdio.h>
#import <string.h>

#import "LCSharedUtils.h"
#import "Tweaks.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end

@implementation LiveProcessHandler

static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;

+ (NSExtensionContext *)extensionContext
{
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo
{
    return retrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    CFRunLoopStop(CFRunLoopGetMain());
}

@end

extern int LiveContainerMain(int argc, char *argv[]);

/// Whether this process started at all, and what it was told to run, has to be readable from the store's
/// log: nothing here is on screen, and a request that never arrives is otherwise silent. Written straight
/// into the group's file rather than through stderr, because the stderr redirect is itself unproven.
static FILE *boxLog;

static void openBoxLog(void)
{
    if (boxLog) return;

    NSString *group = [LCSharedUtils appGroupID];
    if (!group.length) return;

    NSURL *directory = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
    if (!directory) return;

    boxLog = fopen([directory URLByAppendingPathComponent:@"airbox.log"].fileSystemRepresentation, "ae");
    if (boxLog) setvbuf(boxLog, NULL, _IONBF, 0);
}

static void traceLog(NSString *message)
{
    openBoxLog();
    if (!boxLog) return;

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS";
    });

    NSString *timestamp = [formatter stringFromDate:NSDate.date];
    fprintf(boxLog, "%s [LiveProcess] %s\n", timestamp.UTF8String, message.UTF8String);
}

static void pointStderrAtBoxLog(void)
{
    NSString *group = [LCSharedUtils appGroupID];
    if (!group.length) return;

    NSURL *directory = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
    if (!directory) return;

    freopen([directory URLByAppendingPathComponent:@"airbox.log"].fileSystemRepresentation, "a", stderr);
}

int LiveProcessMain(int argc, char *argv[])
{
    traceLog(@"started");
    pointStderrAtBoxLog();

    // NSExtensionMain brings up UIKit, which calls the UIApplicationMain below; the request has not
    // arrived yet, so wait for it -- but only for two seconds, because a request that never comes would
    // otherwise leave this process waiting with nothing on screen and nothing to say.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRun();

    // LP_HOME stays this process's own, because a binary the loader will not mmap from where it lies is
    // moved here first.
    setenv("LP_HOME_PATH", getenv("HOME"), 1);

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;

    if (appInfo)
    {
        traceLog([NSString stringWithFormat:@"the request arrived: %@", appInfo[@"selected"]]);

        // The paths come from another container, so they are only readable once the bookmark they were
        // wrapped in has been opened. Without this, LCAppInfo.plist is simply not there to read.
        for (NSData *data in appInfo[@"bookmarks"])
        {
            BOOL stale = false;
            NSError *error = nil;
            NSURL *opened = [NSURL URLByResolvingBookmarkData:data options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
            traceLog([NSString stringWithFormat:@"bookmark for %@: %@ (%@)", opened.path,
                      [opened startAccessingSecurityScopedResource] ? @"readable" : @"refused",
                      error.localizedDescription ?: @"no error"]);
        }

        NSString *hostHome = appInfo[@"lcHomePath"];
        if (hostHome.length)
        {
            setenv("LC_HOME_PATH", hostHome.fileSystemRepresentation, 1);
        }

        // The engine reads these out of our own defaults once it sees a live process, and swaps its
        // scheme for hostUrlScheme so that what the guest is told to open is the box.
        for (NSString *key in @[ @"selected", @"selectedContainer", @"hostUrlScheme", @"launchAppUrlScheme" ])
        {
            id value = appInfo[key];
            if (value)
            {
                [defaults setObject:value forKey:key];
            }
        }
    }
    else
    {
        // No request. The box left the same information in the group instead, which the engine reads for
        // itself -- provided this process is the one whose scheme it expects, and the note is fresh.
        NSString *group = [LCSharedUtils appGroupID];
        NSUserDefaults *shared = group.length ? [[NSUserDefaults alloc] initWithSuiteName:group] : nil;

        traceLog([NSString stringWithFormat:@"no request within 2s; the group says %@ in %@",
                  [shared stringForKey:@"LCLaunchExtensionBundleID"],
                  [shared stringForKey:@"LCHostHomePath"]]);

        NSString *hostHome = [shared stringForKey:@"LCHostHomePath"];
        if (hostHome.length)
        {
            setenv("LC_HOME_PATH", hostHome.fileSystemRepresentation, 1);
        }
    }

    traceLog([NSString stringWithFormat:@"handing to the engine: selected=%@ home=%s",
              [defaults stringForKey:@"selected"], getenv("LC_HOME_PATH")]);

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
