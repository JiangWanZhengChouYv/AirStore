//
//  GuestStore.swift
//  AirBox
//
//  Packages land in Documents/Packages and, once AirStore can hand them over, in the shared
//  container's inbox. Stage 1 only imports and lists them: unpacking and running is the loader's job,
//  and pretending otherwise here would be a list that cannot do what it says.
//

import Foundation

struct ImportedPackage: Identifiable
{
    let fileURL: URL

    var id: String { self.fileURL.lastPathComponent }
    var name: String { self.fileURL.deletingPathExtension().lastPathComponent }
}

@MainActor
final class GuestStore: ObservableObject
{
    @Published private(set) var packages: [ImportedPackage] = []
    @Published var lastError: String?

    /// `group.` + this app's bundle id without its own suffix, which is exactly how Build.xcconfig
    /// derives APP_GROUP_IDENTIFIER for the store app. Kept as a rule rather than a copied string so
    /// the two apps cannot drift apart.
    private var appGroupIdentifier: String?
    {
        guard var identifier = Bundle.main.bundleIdentifier else { return nil }
        if let suffix = identifier.range(of: ".AirBox", options: .backwards)
        {
            identifier = String(identifier[..<suffix.lowerBound])
        }
        return "group." + identifier
    }

    private var packagesDirectory: URL
    {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Packages", isDirectory: true)
    }

    private var sharedInboxDirectory: URL?
    {
        guard let identifier = self.appGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("ContainerInbox", isDirectory: true)
    }

    func reload() async
    {
        let directory = self.packagesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []

        self.packages = files
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(ImportedPackage.init(fileURL:))
    }

    /// Copy the picked package into our own container. The picker hands back a URL outside the
    /// sandbox, so it has to be opened for the duration of the copy.
    func importPackage(at url: URL)
    {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        do
        {
            try FileManager.default.createDirectory(at: self.packagesDirectory, withIntermediateDirectories: true)
            let destination = self.packagesDirectory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path)
            {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            Task { await self.reload() }
        }
        catch
        {
            self.lastError = error.localizedDescription
        }
    }

    /// Whatever AirStore left in the shared inbox before opening `airbox://import`.
    func importFromSharedInbox() async
    {
        guard let inbox = self.sharedInboxDirectory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension.lowercased() == "ipa"
        {
            self.importPackage(at: file)
            try? FileManager.default.removeItem(at: file)
        }
        await self.reload()
    }
}
