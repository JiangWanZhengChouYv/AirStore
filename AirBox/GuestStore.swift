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
}

@MainActor
final class GuestStore: ObservableObject
{
    @Published private(set) var guests: [Guest] = []
    @Published var lastError: String?

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

    private var sharedInboxDirectory: URL?
    {
        guard let identifier = self.appGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("ContainerInbox", isDirectory: true)
    }

    func reload() async
    {
        try? FileManager.default.createDirectory(at: self.applicationsDirectory, withIntermediateDirectories: true)

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
        let marker = self.documentsDirectory.appendingPathComponent("PendingLaunch")
        do
        {
            try guest.directory.deletingPathExtension().lastPathComponent.write(to: marker, atomically: true, encoding: .utf8)
            exit(0)
        }
        catch
        {
            self.lastError = error.localizedDescription
        }
    }
}
