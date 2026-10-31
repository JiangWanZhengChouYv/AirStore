//
//  GuestPatcher.m
//  AirStore
//
//  Mirrors the patch LiveContainer performs before signing a guest, without its app-model layer: the
//  same copy-delete-move dance, the same slice walk, and the same arm64e fixup. Tweak injection is off
//  on purpose -- AirBox does not ship TweakLoader, so asking for room for it would only fail.
//

#import "GuestPatcher.h"
#import "LCMachOUtils.h"

NSString *ABPrepareGuestBundle(NSString *appBundlePath)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [appBundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *executableName = info[@"CFBundleExecutable"];
    if (executableName.length == 0)
    {
        return @"The bundle has no CFBundleExecutable.";
    }

    NSString *executablePath = [appBundlePath stringByAppendingPathComponent:executableName];
    if (![fileManager fileExistsAtPath:executablePath])
    {
        return @"The bundle's executable is missing.";
    }

    // copy -> delete -> move before touching the bytes. Rewriting the file in place gets the process
    // killed by the code-signing monitor, which is why upstream does the same dance.
    NSString *backupPath = [appBundlePath stringByAppendingFormat:@"/%@.AirBoxPatchBackup", executableName];
    NSError *error = nil;
    [fileManager copyItemAtPath:executablePath toPath:backupPath error:&error];
    if (error == nil) { [fileManager removeItemAtPath:executablePath error:&error]; }
    if (error == nil) { [fileManager moveItemAtPath:backupPath toPath:executablePath error:&error]; }
    if (error != nil) { return error.localizedDescription; }

    __block BOOL hasARM64Slice = NO;
    __block BOOL isEncrypted = NO;

    NSString *parseError = LCParseMachO(executablePath.fileSystemRepresentation, false,
                                        ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if (header->cputype == CPU_TYPE_ARM64)
        {
            hasARM64Slice = YES;
            LCPatchExecSlice(path, header, false);
        }
        isEncrypted = isEncrypted || LCIsMachOEncrypted(header);
    });

    if (isEncrypted)
    {
        return @"The package is encrypted (an App Store build). A decrypted .ipa is required.";
    }
    if (parseError.length > 0)
    {
        return parseError;
    }
    if (!hasARM64Slice)
    {
        return @"The package has no arm64 slice.";
    }

    LCPatchAppBundleFixupARM64eSlice([NSURL fileURLWithPath:appBundlePath]);
    return nil;
}
