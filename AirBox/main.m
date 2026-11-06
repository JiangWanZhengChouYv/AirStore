//
//  main.m
//  AirBox
//
//  Two ways this process can begin. With no request pending it is an ordinary app: the list is the only
//  thing this entry point has to bring up. With a guest requested it belongs to the engine instead, and
//  that has to happen *here*, before UIKit, because the engine does not load a guest into a process that
//  is already running -- it dlopens the guest and jumps to its main().
//
//  The reason for the switch is measured rather than assumed: JIT is attached to one pid, and the
//  extension under PlugIns is a different process that never gets it (csops reported 0x22003305 with
//  CS_DEBUGGED clear in every LiveProcess launch). JIT is also the only mode that works at all, since it
//  bypasses library validation instead of asking the kernel to bless a guest signature.
//

#import <UIKit/UIKit.h>

#import "LCSharedUtils.h"

extern int LiveContainerMain(int argc, char *argv[]);

/// The file all three AirBox processes write into, which the store forwards into its own console log.
static NSURL *AirBoxGroupLogFile(void)
{
    NSString *group = [LCSharedUtils appGroupID];
    if (group.length == 0) { return nil; }
    return [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group]
            URLByAppendingPathComponent:@"airbox.log"];
}

/// One line written straight into that file. Redirecting stderr is not enough on its own -- the
/// extension's own entry point calls that redirect "unproven" -- and everything decided here happens
/// before the store's console logger exists, so the three lines that answer "did the takeover work"
/// are written directly instead of hoping they are captured.
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
    if (logFile)
    {
        freopen(logFile.fileSystemRepresentation, "a", stderr);
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *selected = [defaults stringForKey:@"selected"];

    if (selected.length == 0)
    {
        // The store stages the request in the shared group *before* it launches this app suspended and
        // attaches the debugger, so the request is waiting here by the time main() runs, and this is the
        // pid that has JIT. A relaunch of an already-running box would have had neither: the debugger,
        // and with it JIT, belongs to the process that dies.
        NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
        NSString *staged = [shared stringForKey:@"ABLaunchGuest"];
        if (staged.length > 0)
        {
            [shared removeObjectForKey:@"ABLaunchGuest"];
            [defaults setObject:staged forKey:@"selected"];
            selected = staged;
            AirBoxLogDirect(@"[AirBox] main: picked up the staged request for %@", staged);
        }
    }

    if (selected.length > 0)
    {
        AirBoxLogDirect(@"[AirBox] main: a guest was requested (%@), handing this process to the engine", selected);

        int result = LiveContainerMain(argc, argv);

        // The engine returns here only when the guest refused to start, and it leaves the reason in
        // "error" for the next, clean launch to show.
        NSString *reason = [defaults stringForKey:@"error"];
        AirBoxLogDirect(@"[AirBox] main: the engine came back with %d: %@", result, reason ?: @"no reason recorded");

        // Belt for the paths that bail before the engine clears the request itself: left in place, every
        // launch would try the same takeover again.
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];

        // Do not start the box in this process. By now the engine has repointed HOME at the guest's data
        // container, so the list reads the wrong folder (measured: "0 guests in …/Documents/Data/
        // Application/544EE85…/Applications"), preferences come from a different defaults domain -- the
        // interface even changes language -- and the guest looks deleted when nothing was deleted.
        // Upstream calls this state unrecoverable and exits; it also leaves the reason in "error", so the
        // next launch, in a clean process, is the one that can show it honestly.
        return result;
    }

    return UIApplicationMain(argc, argv, nil, @"AirBoxDelegate");
}
