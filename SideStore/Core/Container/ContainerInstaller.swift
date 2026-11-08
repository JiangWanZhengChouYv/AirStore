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
    case noCertificate
    case downloadFailed(String)
    case patcherRejected(String)

    var errorDescription: String? 
    {
        switch self
        {
        case .airBoxNotInstalled: return NSLocalizedString("AirBox is not installed. Install it before adding apps to it.", comment: "")
        case .airBoxNotAvailable: return NSLocalizedString("AirBox is not published for this build of AirStore.", comment: "")
        case .noCertificate: return NSLocalizedString("No signing certificate is available.", comment: "")
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

        // LiveContainer owns patching, signing and launching. The store hands it the untouched package
        // and its certificate; pre-patching here was the shell's mistake -- LC patches once at install
        // and again by revision at launch, and a bundle we had already rewritten confused both.
        let name = packageURL.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let destination = inbox.appendingPathComponent(name + ".ipa")
        if FileManager.default.fileExists(atPath: destination.path)
        {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: packageURL, to: destination)
        progress?.completedUnitCount = 80

        try self.shareCertificate()
        progress?.completedUnitCount = 94

        debugLog("[ContainerInstaller] \(destination.lastPathComponent) is in the inbox; asking AirBox to install it")
        progress?.completedUnitCount = 100

        let encoded = destination.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        await UIApplication.shared.open(URL(string: "airbox://install?url=\(encoded)")!)
        return name
    }

    /// LC reads its signing identity from these two group keys (LCUtils.certificateData / password), so
    /// the user never imports a certificate by hand: the store already holds one.
    private func shareCertificate() throws
    {
        guard let certificate = CertificateManager.shared.activeCertificate else {
            throw ContainerInstallerError.noCertificate
        }
        guard let groupIdentifier = self.sharedAppGroup,
              let defaults = UserDefaults(suiteName: groupIdentifier) else {
            throw ContainerInstallerError.airBoxNotInstalled
        }
        defaults.set(certificate.p12Data, forKey: "LCCertificateData")
        defaults.set(certificate.password ?? certificate.serialNumber, forKey: "LCCertificatePassword")
        // Size and origin only: this log is read back by the user, and neither the certificate nor its
        // password belongs in it.
        debugLog("[ContainerInstaller] Published \(certificate.p12Data.count) bytes of certificate into \(groupIdentifier)")
    }

    /// Downloads the companion AirBox package into a temporary directory the caller owns. Same route
    /// and mirrors as an app package, so a blocked GitHub costs nothing new.
    func downloadAirBox(from url: URL, progress: Progress?) async throws -> URL
    {

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
}
