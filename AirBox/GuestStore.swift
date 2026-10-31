//
//  GuestStore.swift
//  AirBox
//
//  Lists the prepared bundles under Documents/Applications and takes new ones from the shared inbox.
//  Preparing a package -- unpacking it, rewriting its Mach-O and signing it with the same certificate
//  AirBox runs under -- belongs to the store app, which already has a signer; AirBox only launches.
//

import Foundation

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

    /// The first loose icon file the bundle carries. Asset-catalog icons live inside `Assets.car`, which
    /// cannot be copied out as an image, so those guests show up without one.
    var iconFile: String?
    {
        guard let info = NSDictionary(contentsOf: self.directory.appendingPathComponent("Info.plist")),
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }

        let finder = FileManager.default
        for name in files
        {
            for (scale, ext) in [("@2x", "png"), ("@3x", "png"), ("", "png")]
            {
                let url = self.directory.appendingPathComponent(name + scale).appendingPathExtension(ext)
                if finder.fileExists(atPath: url.path) { return url.lastPathComponent }
            }
        }
        return nil
    }
}

@MainActor
final class GuestStore: ObservableObject
{
    @Published private(set) var guests: [Guest] = []
    @Published var lastError: String?
    @Published var launchError: String?

    /// A guest that cannot load does not say so on screen: the engine writes the reason into the standard
    /// defaults and exits, and the list is only running again on the next launch. Reading it back there is
    /// the difference between a crash and a message.
    private func takeLaunchError()
    {
        let defaults = UserDefaults.standard
        guard let error = defaults.string(forKey: "error") else { return }
        defaults.removeObject(forKey: "error")
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
        try? finder.createDirectory(at: directory, withIntermediateDirectories: true)
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

            if let iconFile = guest.iconFile,
               let icon = finder.contentsOfDirectory(at: guest.directory, includingPropertiesForKeys: nil)?
                            .first(where: { $0.lastPathComponent == iconFile }),
               let data = try? Data(contentsOf: icon)
            {
                record["iconFileName"] = iconFile
                try? data.write(to: directory.appendingPathComponent("\(guest.directory.lastPathComponent)-\(iconFile)"))
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

    /// The guest can only be loaded before UIApplicationMain, so asking for one means starting the
    /// process over: `main.m` reads this file and skips the list entirely.
    func launch(_ guest: Guest)
    {
        self.launch(directoryName: guest.directory.lastPathComponent)
    }

    func launch(directoryName: String)
    {
        let marker = self.documentsDirectory.appendingPathComponent("PendingLaunch")
        do
        {
            try directoryName.write(to: marker, atomically: true, encoding: .utf8)
            exit(0)
        }
        catch
        {
            self.lastError = error.localizedDescription
        }
    }
}
