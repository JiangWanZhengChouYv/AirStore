//
//  ContainerInstaller.swift
//  AirStore
//
//  Turns a source app into something AirBox can run: download the package, unpack it, rewrite the
//  executable so it can be dlopen'd, and drop it in the group AirBox reads. No App ID is registered,
//  nothing is installed on the system, and -- since the mode that works is JIT, which bypasses library
//  validation rather than asking the kernel to bless these bytes -- nothing is signed here.
//

import Foundation
import UIKit

enum ContainerInstallerError: LocalizedError
{
    case airBoxNotInstalled
    case airBoxNotAvailable
    case downloadFailed(String)
    case patcherRejected(String)

    var errorDescription: String? 
    {
        switch self
        {
        case .airBoxNotInstalled: return NSLocalizedString("AirBox is not installed. Install it before adding apps to it.", comment: "")
        case .airBoxNotAvailable: return NSLocalizedString("AirBox is not published for this build of AirStore.", comment: "")
        case .downloadFailed(let reason): return String(format: NSLocalizedString("The package could not be downloaded: %@", comment: ""), reason)
        case .patcherRejected(let reason): return String(format: NSLocalizedString("The app cannot run in AirBox: %@", comment: ""), reason)
        }
    }
}

@MainActor
final class ContainerInstaller
{
    static let shared = ContainerInstaller()

    /// Resigning appends the team identifier to the id a package carried, so neither stored id is a
    /// fixed string the store could rebuild -- and the running bundle is itself suffixed, which put a
    /// team id in the middle of the name nobody ever installs under. AirBox keeps one component in
    /// both fields, so that component is what identifies it.
    static func isAirBox(_ installedApp: InstalledApp) -> Bool
    {
        Self.isAirBoxIdentifier(installedApp.bundleIdentifier) || Self.isAirBoxIdentifier(installedApp.resignedBundleIdentifier)
    }

    private static func isAirBoxIdentifier(_ identifier: String) -> Bool
    {
        identifier.split(separator: ".").contains("AirBox")
    }

    /// The group both apps are actually signed with. The store's own signature is the only place that
    /// knows the final name; an installer may have suffixed it with the team id, and anything derived
    /// from the bundle id would name a group that does not exist on the device.
    private var sharedAppGroup: String? { Bundle.main.altstoreAppGroup }

    private var sharedContainerInbox: URL?
    {
        guard let groupIdentifier = self.sharedAppGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return nil }
        return container.appendingPathComponent("ContainerInbox", isDirectory: true)
    }

    /// Returns the name of the guest that landed in AirBox's inbox.
    func addToAirBox(_ version: AppVersion, progress: Progress? = nil) async throws -> String
    {
        guard let downloadURL = version.url else { throw ContainerInstallerError.downloadFailed(NSLocalizedString("no download URL", comment: "")) }

        let workDirectory = FileManager.default.uniqueTemporaryURL()
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let packageURL = try await self.download(downloadURL, into: workDirectory, progress: progress)
        return try await self.deliver(packageURL: packageURL, workDirectory: workDirectory, progress: progress)
    }

    /// The same route for a package that is already on disk -- an .ipa imported from Files -- or for
    /// a URL the caller has not downloaded yet. Imported bundles are as much a guest as a source app.
    func addToAirBox(ipaAt url: URL, progress: Progress? = nil) async throws -> String
    {
        let workDirectory = FileManager.default.uniqueTemporaryURL()
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let packageURL: URL
        if url.isFileURL
        {
            packageURL = url
        }
        else
        {
            packageURL = try await self.download(url, into: workDirectory, progress: progress)
        }
        return try await self.deliver(packageURL: packageURL, workDirectory: workDirectory, progress: progress)
    }

    private func deliver(packageURL: URL, workDirectory: URL, progress: Progress?) async throws -> String
    {
        debugLog("[ContainerInstaller] Delivering \(packageURL.lastPathComponent) into \(self.sharedAppGroup ?? "no shared group")")

        guard let inbox = self.sharedContainerInbox else { throw ContainerInstallerError.airBoxNotInstalled }

        guard let bundleURL = try? FileManager.default.unzipAppBundle(at: packageURL, to: workDirectory) else {
            throw ContainerInstallerError.downloadFailed(NSLocalizedString("the package is not a readable .ipa", comment: ""))
        }
        progress?.completedUnitCount = 66

        if let rejection = ABPrepareGuestBundle(appBundlePath: bundleURL.path)
        {
            throw ContainerInstallerError.patcherRejected(rejection)
        }
        progress?.completedUnitCount = 72

        let name = bundleURL.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let destination = inbox.appendingPathComponent(bundleURL.lastPathComponent)

        // The engine refuses to start anything without a data container id, and the id is what gives
        // each app its own data directory. Re-adding an app keeps the id it had, so its data survives.
        var dataUUID = UUID().uuidString
        if let data = try? Data(contentsOf: destination.appendingPathComponent("LCAppInfo.plist")),
           let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let previous = propertyList as? [String: Any],
           let previousUUID = previous["LCDataUUID"] as? String
        {
            dataUUID = previousUUID
        }

        // AirBox ships no TweakLoader either, so both the injection and the load stay off.
        let appInfo: [String: Any] = [
            "dontInjectTweakLoader": true,
            "dontLoadTweakLoader": true,
            "LCDataUUID": dataUUID
        ]
        let appInfoURL = bundleURL.appendingPathComponent("LCAppInfo.plist")
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0).write(to: appInfoURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleURL.path)

        // The guest is delivered patched and **not signed**. That is deliberate: the mode that works
        // without a signature the kernel accepts is JIT, where the engine bypasses library validation
        // instead of asking the kernel to bless these bytes (LCBootstrap's init_bypassDyldLibValidation).
        // Signing here was the JITLess route, and every shape we tried -- bound Info.plist and resource
        // list, 4096-byte pages, the host's own identifier -- came back refused by fcntl(F_ADDFILESIGS_RETURN).
        // The digest is still logged, because "signed or not" is the one thing this delivery changes.
        let executableURL = self.executableURL(in: bundleURL)
        let digest = executableURL.flatMap { MachOSignature.digest(ofExecutableAt: $0) } ?? "none"
        debugLog("[ContainerInstaller] Delivering the guest unsigned, as JIT mode requires: executable seal \(digest)")

        // JIT mode is chosen by the engine on one condition: no certificate published. Builds before
        // this one wrote both keys into the group, so on a device that has ever added a guest they are
        // still there and the engine would keep taking the JITLess branch. Removing them is what
        // actually switches the device over.
        if let groupIdentifier = self.sharedAppGroup, let defaults = UserDefaults(suiteName: groupIdentifier)
        {
            let published = defaults.object(forKey: "LCCertificatePassword") != nil
            defaults.removeObject(forKey: "LCCertificateData")
            defaults.removeObject(forKey: "LCCertificatePassword")
            debugLog("[ContainerInstaller] \(groupIdentifier): certificate keys \(published ? "were published, now cleared" : "already absent")")
        }
        else
        {
            debugLog("[ContainerInstaller] No app group to clear the certificate keys from")
        }
        progress?.completedUnitCount = 94

        if FileManager.default.fileExists(atPath: destination.path)
        {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: bundleURL, to: destination)
        debugLog("[ContainerInstaller] \(destination.lastPathComponent) is in the inbox")
        progress?.completedUnitCount = 100

        await UIApplication.shared.open(URL(string: "airbox://import")!)
        return name
    }

    /// Downloads the companion AirBox package into a temporary directory the caller owns. Same route
    /// and mirrors as an app package, so a blocked GitHub costs nothing new.
    func downloadAirBox(progress: Progress?) async throws -> URL
    {
        guard let url = AirBoxInstaller.packageURL else { throw ContainerInstallerError.airBoxNotAvailable }

        let directory = FileManager.default.uniqueTemporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do
        {
            return try await self.download(url, into: directory, progress: progress)
        }
        catch
        {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
                let destination = directory.appendingPathComponent("App.ipa")
                try? FileManager.default.removeItem(at: destination)
                try await self.download(candidate, to: destination, progress: progress)

                guard (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0) ?? 0 > 1024 else {
                    throw ContainerInstallerError.downloadFailed(NSLocalizedString("the file is too small to be a package", comment: ""))
                }
                progress?.completedUnitCount = 60
                return destination
            }
            catch
            {
                lastError = error
            }
        }
        throw ContainerInstallerError.downloadFailed(lastError?.localizedDescription ?? NSLocalizedString("no route answered", comment: ""))
    }

    /// A download of its own rather than `URLSession.download(from:)`, because the button needs to show
    /// bytes arriving: the task's own `progress` is polled while the file is in flight, and the result
    /// is moved into place inside the completion handler, where the temporary file still exists.
    private func download(_ url: URL, to destination: URL, progress: Progress?) async throws
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: URLRequest(url: url)) { location, response, error in
                if let error
                {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location,
                      let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    continuation.resume(throwing: ContainerInstallerError.downloadFailed(NSLocalizedString("the server did not send a package", comment: "")))
                    return
                }
                do
                {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume()
                }
                catch
                {
                    continuation.resume(throwing: error)
                }
            }

            let monitor = Task {
                // Only ever move forward: the stages after the download also write to this Progress,
                // and a late wake-up must not drag the bar back.
                while task.state != .completed
                {
                    let downloaded = Int64(task.progress.fractionCompleted * 60)
                    if let progress, downloaded > progress.completedUnitCount
                    {
                        progress.completedUnitCount = downloaded
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if let progress, progress.completedUnitCount < 60
                {
                    progress.completedUnitCount = 60
                }
            }
            _ = monitor
            task.resume()
        }
    }

    private func executableURL(in bundleURL: URL) -> URL?
    {
        guard let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let name = info["CFBundleExecutable"] as? String else { return nil }
        return bundleURL.appendingPathComponent(name)
    }
}
