//
//  ContainerInstaller.swift
//  AirStore
//
//  Turns a source app into something AirBox can run: download the package, unpack it, rewrite the
//  executable so it can be dlopen'd, sign it with the certificate every guest shares, and drop it in
//  the group AirBox reads. No App ID is registered and nothing is installed on the system.
//

import Foundation
import UIKit
import SideSign

enum ContainerInstallerError: LocalizedError
{
    case airBoxNotInstalled
    case noCertificate
    case noProfileForAirBox
    case downloadFailed(String)
    case patcherRejected(String)

    var errorDescription: String? 
    {
        switch self
        {
        case .airBoxNotInstalled: return NSLocalizedString("AirBox is not installed. Install it before adding apps to it.", comment: "")
        case .noCertificate: return NSLocalizedString("No signing certificate is available.", comment: "")
        case .noProfileForAirBox: return NSLocalizedString("AirBox has no provisioning profile. Reinstall it from AirStore, then try again.", comment: "")
        case .downloadFailed(let reason): return String(format: NSLocalizedString("The package could not be downloaded: %@", comment: ""), reason)
        case .patcherRejected(let reason): return String(format: NSLocalizedString("The app cannot run in AirBox: %@", comment: ""), reason)
        }
    }
}

@MainActor
final class ContainerInstaller
{
    static let shared = ContainerInstaller()

    /// AirBox's bundle id is the store's with one more component -- the same rule the container app
    /// uses to find the shared group, so the two cannot disagree about where a package goes.
    static var airBoxBundleIdentifier: String { Bundle.Info.appbundleIdentifier + ".AirBox" }

    private var sharedContainerInbox: URL?
    {
        let groupIdentifier = "group." + Bundle.Info.appbundleIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return nil }
        return container.appendingPathComponent("ContainerInbox", isDirectory: true)
    }

    /// Returns the name of the guest that landed in AirBox's inbox.
    func addToAirBox(_ version: AppVersion, progress: Progress? = nil) async throws -> String
    {
        guard let inbox = self.sharedContainerInbox else { throw ContainerInstallerError.airBoxNotInstalled }
        guard let downloadURL = version.url else { throw ContainerInstallerError.downloadFailed("no download URL") }

        let workDirectory = FileManager.default.uniqueTemporaryURL()
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let packageURL = try await self.download(downloadURL, into: workDirectory, progress: progress)

        guard let bundleURL = try? FileManager.default.unzipAppBundle(at: packageURL, to: workDirectory) else {
            throw ContainerInstallerError.downloadFailed("the package is not a readable .ipa")
        }

        if let rejection = ABPrepareGuestBundle(appBundlePath: bundleURL.path)
        {
            throw ContainerInstallerError.patcherRejected(rejection)
        }

        try await self.sign(bundleURL)

        // The only keys AirBox reads today: it ships no TweakLoader, so injection stays off.
        let appInfo = ["dontInjectTweakLoader": true]
        let appInfoURL = bundleURL.appendingPathComponent("LCAppInfo.plist")
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0).write(to: appInfoURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleURL.path)

        let name = bundleURL.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let destination = inbox.appendingPathComponent(bundleURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path)
        {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: bundleURL, to: destination)

        await UIApplication.shared.open(URL(string: "airbox://import")!)
        return name
    }

    private func download(_ url: URL, into directory: URL, progress: Progress?) async throws -> URL
    {
        // Mirrors are tried in the same order downloads use everywhere else in the app; a mirror that
        // has not picked the build up answers with an error page, so anything but a zip is a miss.
        var lastError: Error?
        for candidate in url.downloadCandidates
        {
            do
            {
                let (fileURL, _) = try await URLSession.shared.download(from: candidate)
                let destination = directory.appendingPathComponent("App.ipa")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: fileURL, to: destination)

                guard (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0) ?? 0 > 1024 else {
                    throw ContainerInstallerError.downloadFailed("the file is too small to be a package")
                }
                progress?.completedUnitCount = 50
                return destination
            }
            catch
            {
                lastError = error
            }
        }
        throw ContainerInstallerError.downloadFailed(lastError?.localizedDescription ?? "no route answered")
    }

    /// Every guest is signed by AirBox's own profile: the bundle id in that profile is AirBox's, and the
    /// signer falls back to the first profile it was handed, which is exactly what a guest needs -- the
    /// same team as the process that will dlopen it.
    private func sign(_ bundleURL: URL) async throws
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext
        let request = InstalledApp.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), Self.airBoxBundleIdentifier)
        request.fetchLimit = 1

        guard let airBox = try? context.fetch(request).first, let profile = airBox.customProvisioningProfile else {
            throw ContainerInstallerError.noProfileForAirBox
        }
        guard let certificate = CertificateManager.shared.activeCertificate?.certificate,
              let databaseTeam = DatabaseManager.shared.activeTeam(in: context) else {
            throw ContainerInstallerError.noCertificate
        }

        // The Core Data team and the signer's team are different types; this is the same conversion
        // AuthManager performs before anything else touches the signer.
        let team = ALTTeam(identifier: databaseTeam.identifier, name: databaseTeam.name, type: databaseTeam.type)
        let signer = ALTSigner(team: team, certificate: certificate)
        try await signer.signApp(at: bundleURL, provisioningProfiles: [profile], progress: nil)
    }
}
