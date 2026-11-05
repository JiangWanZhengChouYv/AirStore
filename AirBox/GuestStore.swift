//
//  GuestStore.swift
//  AirBox
//
//  Lists the prepared bundles under Documents/Applications and takes new ones from the shared inbox.
//  Preparing a package -- unpacking it, rewriting its Mach-O and signing it with the same certificate
//  AirBox runs under -- belongs to the store app, which already has a signer; AirBox only launches.
//

import Foundation
import UIKit

struct Guest: Identifiable
{
    let directory: URL
    let bundleIdentifier: String?

    var id: String { self.directory.lastPathComponent }
    var name: String
    {
        let info = self.directory.appendingPathComponent("Info.plist")
        let displayName = NSDictionary(contentsOf: info)?["CFBundleDisplayName"] as? String
        return displayName ?? self.directory.deletingPathExtension().lastPathComponent
    }
    var version: String?
    {
        NSDictionary(contentsOf: self.directory.appendingPathComponent("Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// The first loose icon file the bundle carries, located on disk. Asset-catalog icons live inside
    /// `Assets.car`, which cannot be copied out as an image, so those guests show up without one.
    var iconFileURL: URL?
    {
        guard let info = NSDictionary(contentsOf: self.directory.appendingPathComponent("Info.plist")),
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }

        let finder = FileManager.default
        for name in files
        {
            for suffix in ["@2x", "@3x", ""]
            {
                let url = self.directory.appendingPathComponent(name + suffix).appendingPathExtension("png")
                if finder.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

@MainActor
final class GuestStore: ObservableObject
{
    @Published private(set) var guests: [Guest] = []
    /// Anything the list shows as a failure is also written to the log the store routes, because the
    /// alert is gone by the time he can send me anything.
    @Published var lastError: String?
    {
        didSet
        {
            if let lastError = self.lastError { AirBoxLogging.log(lastError) }
        }
    }

    @Published var launchError: String?
    {
        didSet
        {
            if let launchError = self.launchError { AirBoxLogging.log("the guest refused to load: \(launchError)") }
        }
    }

    /// The name to show while a launch is in flight. Opening a guest means this app goes away and comes
    /// back as something else, which without a card on screen is indistinguishable from a hang.
    @Published private(set) var launchingGuestName: String?

    /// A guest that cannot load has to say so on screen, or the tap looks like nothing happened and the
    /// only proof is a log he has to fight a frozen app to send. The engine writes its reason into this
    /// app's own defaults before it hands the process back, so the message is here when the list comes
    /// up again.
    private func takeLaunchError()
    {
        guard let error = UserDefaults.standard.string(forKey: "error") else { return }
        UserDefaults.standard.removeObject(forKey: "error")
        self.launchError = error
    }

    /// The group the engine resolved for this process. An installer may suffix the declared group
    /// with the team id, so the name in the signature is the only one that is guaranteed to exist --
    /// the store writes to the equivalent group on its side.
    private var appGroupIdentifier: String?
    {
        guard let identifier = LCSharedUtils.appGroupID(), !identifier.isEmpty, identifier != "Unknown" else { return nil }
        return identifier
    }

    private var sharedDefaults: UserDefaults?
    {
        guard let identifier = self.appGroupIdentifier else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    private var documentsDirectory: URL
    {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var applicationsDirectory: URL
    {
        self.documentsDirectory.appendingPathComponent("Applications", isDirectory: true)
    }

    private var sharedDirectory: URL?
    {
        guard let identifier = self.appGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    private var sharedInboxDirectory: URL?
    {
        self.sharedDirectory?.appendingPathComponent("ContainerInbox", isDirectory: true)
    }

    /// What AirBox holds, published for the store to show. The guest bundles live in AirBox's own
    /// container, which the store's sandbox cannot read, so this listing -- one plist plus the loose
    /// icon per guest, keyed by directory name -- is the only thing the store can see.
    private var sharedManifestDirectory: URL?
    {
        self.sharedDirectory?.appendingPathComponent("ContainerApps", isDirectory: true)
    }

    /// Deletions the store asked for, one empty file per guest, consumed the next time AirBox runs.
    private var sharedDeleteDirectory: URL?
    {
        self.sharedDirectory?.appendingPathComponent("ContainerDelete", isDirectory: true)
    }

    func reload() async
    {
        try? FileManager.default.createDirectory(at: self.applicationsDirectory, withIntermediateDirectories: true)
        self.applyPendingDeletions()

        let entries = (try? FileManager.default.contentsOfDirectory(at: self.applicationsDirectory,
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []

        self.guests = entries
            .filter { $0.pathExtension == "app" }
            .compactMap { url in
                guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Info.plist").path) else { return nil }
                let identifier = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
                return Guest(directory: url, bundleIdentifier: identifier)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        self.takeLaunchError()

        self.sharedDefaults?.set(NSHomeDirectory(), forKey: "LCHostHomePath")

        // The two facts the extension is asked with, in the log the store routes: how many guests there
        // are, and which folder it will be told to load from.
        AirBoxLogging.log("\(self.guests.count) guests in \(self.applicationsDirectory.path); "
                          + "group \(self.appGroupIdentifier ?? "none")")

        self.publish()
    }

    private func applyPendingDeletions()
    {
        let finder = FileManager.default
        guard let directory = self.sharedDeleteDirectory,
              let requested = try? finder.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }

        for marker in requested
        {
            // Named exactly like the guest's folder, extension included, because that is the name the
            // store knows it by.
            let name = marker.lastPathComponent
            try? finder.removeItem(at: self.applicationsDirectory.appendingPathComponent(name))
            try? finder.removeItem(at: marker)
        }
    }

    /// Rewritten from scratch every time, so a guest that went away by any route stops being listed.
    private func publish()
    {
        let finder = FileManager.default
        guard let directory = self.sharedManifestDirectory else { return }
        try? finder.removeItem(at: directory)
        try? finder.createDirectory(at: directory, withIntermediateDirectories: true)

        for guest in self.guests
        {
            var record: [String: Any] = [
                "directoryName": guest.directory.lastPathComponent,
                "name": guest.name
            ]
            if let bundleIdentifier = guest.bundleIdentifier { record["bundleIdentifier"] = bundleIdentifier }
            if let version = guest.version { record["version"] = version }

            if let icon = guest.iconFileURL, let data = try? Data(contentsOf: icon)
            {
                record["iconFileName"] = icon.lastPathComponent
                try? data.write(to: directory.appendingPathComponent("\(guest.directory.lastPathComponent)-\(icon.lastPathComponent)"))
            }

            (record as NSDictionary).write(to: directory.appendingPathComponent("\(guest.directory.lastPathComponent).plist"), atomically: true)
        }
    }

    /// Whatever the store app left in the shared inbox: already unpacked, patched and signed bundles.
    func importFromSharedInbox() async
    {
        defer { Task { await self.reload() } }
        guard let inbox = self.sharedInboxDirectory else { return }

        let entries = (try? FileManager.default.contentsOfDirectory(at: inbox,
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        for entry in entries where entry.pathExtension == "app"
        {
            let destination = self.applicationsDirectory.appendingPathComponent(entry.lastPathComponent)
            do
            {
                try FileManager.default.createDirectory(at: self.applicationsDirectory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path)
                {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: entry, to: destination)
            }
            catch
            {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// What the store asks for, by the folder name it was shown in the listing the box publishes.
    func launch(named directoryName: String) async
    {
        if self.guests.isEmpty { await self.reload() }

        guard let guest = self.guests.first(where: { $0.directory.lastPathComponent == directoryName }) else
        {
            self.lastError = "Nothing named \(directoryName) is inside AirBox."
            return
        }

        self.launch(guest)
    }

    /// A guest does not run in this process as it stands: it runs in the *next* one. The engine cannot
    /// load a guest into a process that is already up -- it dlopens the binary and jumps to its main() --
    /// and JIT is attached per pid, so the extension under PlugIns is out (measured: CS_DEBUGGED clear in
    /// every LiveProcess). So write the request where the engine reads it, ask FrontBoard to bring this
    /// bundle id back, and die: the process that comes up runs main.m, sees the request, and hands itself
    /// over with JIT already on it.
    func launch(_ guest: Guest)
    {
        guard self.launchingGuestName == nil else
        {
            // Five taps on a silent button is five processes spun up and thrown away, which is what the
            // log looked like last time. One request at a time.
            AirBoxLogging.log("a launch is already pending, ignoring the tap on \(guest.name)")
            return
        }

        self.launchingGuestName = guest.name

        let defaults = UserDefaults.standard
        defaults.set(guest.directory.lastPathComponent, forKey: "selected")

        let appInfo = NSDictionary(contentsOf: guest.directory.appendingPathComponent("LCAppInfo.plist"))
        if let dataUUID = appInfo?["LCDataUUID"] as? String, !dataUUID.isEmpty
        {
            defaults.set(dataUUID, forKey: "selectedContainer")
        }
        // No synchronize() and no wait: the values live in cfprefsd, not in this process, so the next one
        // reads them even though this one is about to be killed.

        AirBoxLogging.log("requested \(guest.name) for the next launch of this process "
                          + "(container \(appInfo?["LCDataUUID"] as? String ?? "left to the engine"))")

        AirBoxAskToRelaunchSelf { success, reason in
            guard success else
            {
                DispatchQueue.main.async
                {
                    self.failLaunch(guest, reason: "AirBox could not ask to restart itself: \(reason ?? "no reason given")")
                }
                return
            }

            // Dying is the request. The relaunched process is the one that takes the guest over, and
            // staying alive would only mean two boxes on the same pending launch. FrontBoard answers on a
            // thread of its own, and SIGKILL does not care which one.
            AirBoxLogging.log("restart accepted, giving up this process so the next one loads \(guest.name)")
            raise(SIGKILL)
        }
    }

    private func failLaunch(_ guest: Guest, reason: String)
    {
        UserDefaults.standard.removeObject(forKey: "selected")
        UserDefaults.standard.removeObject(forKey: "selectedContainer")
        self.launchingGuestName = nil
        self.launchError = "AirBox could not open \(guest.name): \(reason)"
    }
}
