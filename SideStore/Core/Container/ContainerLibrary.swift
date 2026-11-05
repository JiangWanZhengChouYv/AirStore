//
//  ContainerLibrary.swift
//  AirStore
//
//  The store's view of what is running inside AirBox. AirBox owns those bundles, so it publishes a
//  listing into the group the two apps share and this reads it; asking for something back is a marker
//  file AirBox consumes when it next looks, because a sandbox will not open another app's container.
//

import UIKit

struct ContainerApp: Identifiable, Hashable
{
    let directoryName: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let iconFileURL: URL?

    var id: String { self.directoryName }
}

@MainActor
final class ContainerLibrary
{
    static let shared = ContainerLibrary()

    private var groupDirectory: URL?
    {
        guard let group = Bundle.main.altstoreAppGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    private var manifestDirectory: URL?
    {
        self.groupDirectory?.appendingPathComponent("ContainerApps", isDirectory: true)
    }

    private var deleteDirectory: URL?
    {
        self.groupDirectory?.appendingPathComponent("ContainerDelete", isDirectory: true)
    }

    /// The same group the inbox is in, as defaults rather than as files: this is the domain AirBox reads
    /// at startup, and it is the only place either app can leave a message for a process that has not
    /// started yet.
    private var sharedDefaults: UserDefaults?
    {
        guard let group = Bundle.main.altstoreAppGroup else { return nil }
        return UserDefaults(suiteName: group)
    }

    func apps() -> [ContainerApp]
    {
        let finder = FileManager.default
        guard let directory = self.manifestDirectory,
              let entries = try? finder.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }

        return entries.compactMap { url in
            guard url.pathExtension == "plist", let record = NSDictionary(contentsOf: url) else { return nil }

            let directoryName = url.deletingPathExtension().lastPathComponent
            let icon = (record["iconFileName"] as? String).map { directory.appendingPathComponent("\(directoryName)-\($0)") }

            return ContainerApp(directoryName: directoryName,
                                name: record["name"] as? String ?? directoryName,
                                bundleIdentifier: record["bundleIdentifier"] as? String,
                                version: record["version"] as? String,
                                iconFileURL: finder.fileExists(atPath: icon?.path ?? "") ? icon : nil)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes the request the next AirBox process will read, and returns whether it landed.
    ///
    /// The store cannot ask another app's extension to start, and a relaunch would drop the debugger --
    /// JIT *is* a debugger attached to one pid, so a process that comes up afterwards is not the one
    /// that was enabled. What works is the other order: write the request first, then let the store
    /// launch AirBox suspended and attach to it before its own main() runs. The process that resumes
    /// finds the request waiting and takes the guest over with JIT already on it.
    ///
    /// Only the directory name goes across. The engine resolves the data container itself, the same way
    /// it does upstream, and the store cannot read AirBox's sandbox to name it anyway.
    func stageLaunch(_ app: ContainerApp) -> Bool
    {
        guard let defaults = self.sharedDefaults else
        {
            debugLog("[ContainerLibrary] No shared group to write the launch request into")
            return false
        }
        defaults.set(app.directoryName, forKey: "ABLaunchGuest")
        debugLog("[ContainerLibrary] Staged \(app.directoryName) for the next AirBox launch")
        return true
    }

    func remove(_ app: ContainerApp)
    {
        guard let deletes = self.deleteDirectory else { return }
        let finder = FileManager.default
        try? finder.createDirectory(at: deletes, withIntermediateDirectories: true)
        finder.createFile(atPath: deletes.appendingPathComponent(app.directoryName).path, contents: nil)

        // AirBox rewrites the listing when it applies the deletion, but that is not yet -- dropping the
        // record now keeps the row from surviving the tap until either app is opened again. The listing
        // names every file for one guest after that guest's own folder name.
        if let manifest = self.manifestDirectory,
           let records = try? finder.contentsOfDirectory(at: manifest, includingPropertiesForKeys: nil)
        {
            for record in records where record.lastPathComponent.hasPrefix("\(app.directoryName).") ||
                                        record.lastPathComponent.hasPrefix("\(app.directoryName)-")
            {
                try? finder.removeItem(at: record)
            }
        }
    }
}
