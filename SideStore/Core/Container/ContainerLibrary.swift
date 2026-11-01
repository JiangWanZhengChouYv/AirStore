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

    /// A guest is not started by AirBox's own process: it is started by the extension AirBox embeds, and
    /// that is the only shape the engine loads a guest's libraries in. Which guest travels through the
    /// group both apps share, and opening the extension's scheme is what picks it up.
    func launch(_ app: ContainerApp)
    {
        guard let group = Bundle.main.altstoreAppGroup, let handover = UserDefaults(suiteName: group) else
        {
            debugLog("[ContainerLibrary] No shared group to write the launch into")
            return
        }

        // The extension only takes this up within three seconds of it being written, so it has to be the
        // last thing before the open, and the folder name is what the engine looks the guest up by.
        handover.set("liveprocess", forKey: "LCLaunchExtensionScheme")
        handover.set(app.directoryName, forKey: "LCLaunchExtensionBundleID")
        handover.set(Date(), forKey: "LCLaunchExtensionLaunchDate")

        guard let encoded = app.directoryName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "liveprocess://livecontainer-launch?bundle-name=\(encoded)") else { return }

        debugLog("[ContainerLibrary] Handing \(app.directoryName) to the extension through \(group)")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
