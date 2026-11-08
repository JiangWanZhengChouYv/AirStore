//
//  main.m
//  AirBox
//
//  AirBox is LiveContainer: the engine decides here whether this launch belongs to a guest or to the
//  box's own UI, exactly as upstream's main.c does. Nothing of our own is drawn.
//

#import <UIKit/UIKit.h>

#import "LCSharedUtils.h"

extern int LiveContainerMain(int argc, char *argv[]);

// The SDK declares neither; the engine carries the same two lines in its utils.h.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define AirBoxCSDebugged 0x10000000

static NSURL *AirBoxGroupLogFile(void)
{
    NSString *group = [LCSharedUtils appGroupID];
    if (group.length == 0) { return nil; }
    return [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group]
            URLByAppendingPathComponent:@"airbox.log"];
}

static void AirBoxLogDirect(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSURL *url = AirBoxGroupLogFile();
    if (!url) { return; }
    FILE *file = fopen(url.fileSystemRepresentation, "ae");
    if (!file) { return; }
    fprintf(file, "%s\n", line.UTF8String);
    fclose(file);
}

int main(int argc, char *argv[])
{
    NSURL *logFile = AirBoxGroupLogFile();
    if (logFile) { freopen(logFile.fileSystemRepresentation, "a", stderr); }

    int csFlags = 0;
    csops(getpid(), 0, &csFlags, sizeof(csFlags));
    AirBoxLogDirect(@"[AirBox] main: csops at launch = 0x%x (CS_DEBUGGED %@)", csFlags,
                    (csFlags & AirBoxCSDebugged) ? @"set" : @"clear");

    return LiveContainerMain(argc, argv);
}
