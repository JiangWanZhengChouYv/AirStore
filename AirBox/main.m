//
//  main.m
//  AirBox
//
//  A guest has to be loaded before UIApplicationMain -- the engine takes over the process and the
//  guest's own main() runs there. So the only entry point that can do it is main itself, and the way
//  back to it is a fresh process: the list writes the chosen app's folder name here and exits, and the
//  next launch starts the guest instead of the list.
//

#import <UIKit/UIKit.h>
#import "AirBoxEngine.h"

static NSString *const ABPendingLaunchFile = @"PendingLaunch";

static NSString *ABDocumentsDirectory(void)
{
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

int main(int argc, char *argv[], char *envp[])
{
    @autoreleasepool
    {
        NSString *marker = [ABDocumentsDirectory() stringByAppendingPathComponent:ABPendingLaunchFile];
        NSString *name = [[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

        if (name.length > 0)
        {
            [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];

            NSString *bundle = [[ABDocumentsDirectory() stringByAppendingPathComponent:@"Applications"]
                                stringByAppendingPathComponent:name];
            if (![bundle.pathExtension isEqualToString:@"app"])
            {
                bundle = [bundle stringByAppendingPathExtension:@"app"];
            }
            return AirBoxRunGuest(bundle.fileSystemRepresentation, argc, argv, envp);
        }
    }

    return UIApplicationMain(argc, argv, nil, @"AirBoxDelegate");
}
