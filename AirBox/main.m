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
#import <os/log.h>

#import "LCSharedUtils.h"

extern int LiveContainerMain(int argc, char *argv[]);

int main(int argc, char *argv[])
{
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
            os_log(OS_LOG_DEFAULT, "[AirBox] main: picked up the staged request for %{public}@", staged);
        }
    }

    if (selected.length > 0)
    {
        os_log(OS_LOG_DEFAULT, "[AirBox] main: a guest was requested (%{public}@), handing this process to the engine", selected);

        int result = LiveContainerMain(argc, argv);

        // The engine returns here only when the guest refused to start, and it leaves the reason in
        // "error" -- upstream treats that state as unrecoverable and exits. Falling through to the list
        // is the difference between a message and a vanished app, and the refusal AirBox actually hits
        // (no JIT) happens before the engine hooks anything, so the app is still sound.
        NSString *reason = [defaults stringForKey:@"error"];
        os_log(OS_LOG_DEFAULT, "[AirBox] main: the engine came back with %d: %{public}@",
               result, reason ?: @"no reason recorded");
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
    }

    return UIApplicationMain(argc, argv, nil, @"AirBoxDelegate");
}
