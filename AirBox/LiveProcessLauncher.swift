//
//  LiveProcessLauncher.swift
//  AirBox
//
//  A guest runs in the extension under PlugIns. The only way into an app's own extension is the request
//  API -- a url cannot reach it, and a second app cannot make the request at all, which is why the store
//  asks AirBox to do it. What is handed over is upstream's dictionary: which guest, whose data container,
//  the home the guest folders live under, and the scheme a guest opens to come back here.
//

import Foundation
import UIKit

@MainActor
enum LiveProcessLauncher
{
    enum LaunchError: LocalizedError
    {
        case missing

        var errorDescription: String?
        {
            switch self
            {
            case .missing:
                return "This AirBox carries no LiveProcess extension. Reinstall AirBox and choose Keep App Extensions (Use Main Profile)."
            }
        }
    }

    /// Kept while a request is up: an extension nobody holds a reference to goes away with it.
    private static var active: [NSExtension] = []

    private static var extensionIdentifier: String?
    {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugins.appendingPathComponent("LiveProcess.appex")) else { return nil }
        return bundle.bundleIdentifier
    }

    /// AirBox's own url scheme, which is what a guest opens to come back to the list.
    private static var hostScheme: String?
    {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first
    }

    static func run(_ guest: Guest) async throws
    {
        guard let identifier = extensionIdentifier else { throw LaunchError.missing }

        let appInfo = NSDictionary(contentsOf: guest.directory.appendingPathComponent("LCAppInfo.plist"))
        var userInfo: [String: Any] = [
            "selected": guest.directory.lastPathComponent,
            "lcHomePath": NSHomeDirectory(),
        ]
        if let scheme = hostScheme, !scheme.isEmpty
        {
            userInfo["hostUrlScheme"] = scheme
        }
        if let dataUUID = appInfo?["LCDataUUID"] as? String, !dataUUID.isEmpty
        {
            userInfo["selectedContainer"] = dataUUID
        }

        // The extension runs in a container of its own, so the folder is handed over as a bookmark rather
        // than as a path -- the box's own Documents is otherwise not readable from in there. This is the
        // same option value upstream passes (URL.BookmarkCreationOptions's security-scope bit).
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last,
           let bookmark = try? documents.bookmarkData(options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        {
            userInfo["bookmarks"] = [bookmark]
        }

        let item = NSExtensionItem()
        item.userInfo = userInfo

        // Left in the group as well, in case the request itself never reaches the extension: it waits two
        // seconds for one and then reads these instead. The engine picks them up on its own, but only if
        // this note is less than three seconds old, so it is written immediately before the request.
        if let defaults = AirBoxLogging.sharedDefaults
        {
            defaults.set("liveprocess", forKey: "LCLaunchExtensionScheme")
            defaults.set(guest.directory.lastPathComponent, forKey: "LCLaunchExtensionBundleID")
            defaults.set(Date(), forKey: "LCLaunchExtensionLaunchDate")
        }

        let ext = try NSExtension(identifier: identifier)
        ext.setRequestInterruptionBlock { _ in
            Task { @MainActor in
                AirBoxLogging.log("the extension stopped while running \(guest.name)")
                LiveProcessLauncher.forget(ext)
            }
        }
        ext.setRequestCancellationBlock { _, error in
            let reason = error?.localizedDescription ?? "no reason given"
            Task { @MainActor in
                AirBoxLogging.log("the request for \(guest.name) was cancelled: \(reason)")
                LiveProcessLauncher.forget(ext)
            }
        }

        active.append(ext)
        AirBoxLogging.log("asking \(identifier) to run \(guest.directory.lastPathComponent) "
                          + "(container \(userInfo["selectedContainer"] as? String ?? "left to LCAppInfo"))")

        _ = await ext.beginRequest(withInputItems: [item])
    }

    private static func forget(_ ext: NSExtension)
    {
        active.removeAll { $0 === ext }
    }
}
