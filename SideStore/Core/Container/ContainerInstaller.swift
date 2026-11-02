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
import CodeSignKit

enum ContainerInstallerError: LocalizedError
{
    case airBoxNotInstalled
    case airBoxNotAvailable
    case noCertificate
    case noProfileForAirBox
    case downloadFailed(String)
    case patcherRejected(String)

    var errorDescription: String? 
    {
        switch self
        {
        case .airBoxNotInstalled: return NSLocalizedString("AirBox is not installed. Install it before adding apps to it.", comment: "")
        case .airBoxNotAvailable: return NSLocalizedString("AirBox is not published for this build of AirStore.", comment: "")
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

        // Ahead of the signing, because the bundle's own resource list seals this file: written after,
        // the seal would describe a bundle that no longer matches what is on disk.
        let executableURL = self.executableURL(in: bundleURL)
        let digestBefore = executableURL.flatMap { MachOSignature.digest(ofExecutableAt: $0) } ?? "none"

        try await self.sign(bundleURL)

        let digestAfter = executableURL.flatMap { MachOSignature.digest(ofExecutableAt: $0) } ?? "none"
        debugLog("[ContainerInstaller] Signature blob \(digestBefore) -> \(digestAfter)\(digestBefore == digestAfter ? " (unchanged, the signer skipped it)" : "")")
        progress?.completedUnitCount = 94

        // iOS 26 refuses to load a guest without JITLess, and JITLess needs the certificate inside
        // AirBox. Upstream reaches these two keys through its settings screen; the store already holds
        // the same certificate, so it writes them itself and leaves the user with nothing to import.
        try self.shareCertificate()

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

    private func shareCertificate() throws
    {
        guard let certificate = CertificateManager.shared.activeCertificate else {
            throw ContainerInstallerError.noCertificate
        }
        guard let groupIdentifier = self.sharedAppGroup,
              let defaults = UserDefaults(suiteName: groupIdentifier) else {
            throw ContainerInstallerError.airBoxNotInstalled
        }

        // The two keys LCUtils and LCSharedUtils read on the other side. Same certificate, same
        // password: a guest signed with anything else would not load in a JITLess process.
        defaults.set(certificate.p12Data, forKey: "LCCertificateData")
        defaults.set(certificate.password ?? certificate.serialNumber, forKey: "LCCertificatePassword")

        // Size and origin only -- this log is something the user reads back to us, and neither the
        // certificate nor its password belongs in it.
        debugLog("[ContainerInstaller] Published \(certificate.p12Data.count) bytes of certificate into \(groupIdentifier) (password from \(certificate.password == nil ? "the serial number" : "the keychain"))")
    }

    /// Every guest is signed by AirBox's own profile: the bundle id in that profile is AirBox's, and the
    /// signer falls back to the first profile it was handed, which is exactly what a guest needs -- the
    /// same team as the process that will dlopen it.
    private func executableURL(in bundleURL: URL) -> URL?
    {
        guard let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let name = info["CFBundleExecutable"] as? String else { return nil }
        return bundleURL.appendingPathComponent(name)
    }

    /// A binary the guest carries, together with the bundle whose Info.plist and resources its signature
    /// has to bind. A framework belongs to its own .framework and the executable to the .app; a loose
    /// dylib under Frameworks/ belongs to neither, which is why Apple's signer leaves those unbound.
    private struct GuestBinary
    {
        let url: URL
        let bundle: URL?
    }

    /// Every Mach-O the guest bundle carries, in the order they have to be signed: nested things first,
    /// because the .app seals the bytes its frameworks end up with, so its resource list cannot be built
    /// before they are final. A package that arrives with no signature at all gives a signer nothing to
    /// point at, so the list is written out here rather than left to a traversal.
    private func guestBinaries(in bundleURL: URL) -> [GuestBinary]
    {
        let finder = FileManager.default
        var binaries = [GuestBinary]()

        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        for entry in (try? finder.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
        {
            switch entry.pathExtension
            {
            case "framework":
                let binary = entry.appendingPathComponent(entry.deletingPathExtension().lastPathComponent)
                if finder.fileExists(atPath: binary.path) { binaries.append(GuestBinary(url: binary, bundle: entry)) }
            case "dylib":
                binaries.append(GuestBinary(url: entry, bundle: nil))
            default:
                break
            }
        }

        if let executable = self.executableURL(in: bundleURL) { binaries.append(GuestBinary(url: executable, bundle: bundleURL)) }
        return binaries
    }

    /// The bundle's own resource list, written where a validator looks for it. Leaving it out is what the
    /// store did until now, and Apple's validator answers that shape -- for the file, not just the
    /// directory -- with "code has no resources but signature indicates they must be present".
    private func sealResources(in bundleURL: URL, executableName: String) -> (info: Data?, resources: Data?)
    {
        let info = try? Data(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
        do
        {
            let resources = try CodeResourcesBuilder(bundleURL: bundleURL, executableName: executableName).build()
            let directory = bundleURL.appendingPathComponent("_CodeSignature", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try resources.write(to: directory.appendingPathComponent("CodeResources"), options: .atomic)
            debugLog("[ContainerInstaller] Sealed \(bundleURL.lastPathComponent) with \(resources.count) bytes of resource list")
            return (info, resources)
        }
        catch
        {
            debugLog("[ContainerInstaller] Could not seal \(bundleURL.lastPathComponent): \(error.localizedDescription)")
            return (info, nil)
        }
    }

    private func sign(_ bundleURL: URL) async throws
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext

        // Right after AirBox itself is installed, its row may not have reached this context yet; a
        // guest added in that same breath would otherwise be told no profile exists.
        var profile: ALTProvisioningProfile?
        for attempt in 0..<6
        {
            if let airBox = InstalledApp.all(in: context).first { Self.isAirBox($0) }
            {
                // The cached copy is what carries the profile out of the install pipeline, and it is
                // missing when the pipeline has decided this app is the store itself.
                let cached = airBox.customProvisioningProfileURL
                debugLog("[ContainerInstaller] AirBox row \(airBox.bundleIdentifier) / \(airBox.resignedBundleIdentifier): cached profile \(cached?.lastPathComponent ?? "none")")

                if let found = airBox.customProvisioningProfile
                {
                    profile = found
                    break
                }
            }
            else
            {
                debugLog("[ContainerInstaller] No AirBox row among \(InstalledApp.all(in: context).count) installed apps")
            }
            if attempt < 5 { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        guard let profile else {
            throw ContainerInstallerError.noProfileForAirBox
        }
        guard let certificate = CertificateManager.shared.activeCertificate else {
            throw ContainerInstallerError.noCertificate
        }

        // The profile is read for the identifier it grants AirBox and deliberately *not* embedded. The
        // guest is then signed with that identifier and with **no entitlements at all**, which is exactly
        // what upstream does: zsign's own code reads `IsExecute() ? entitlements : ""`, and a guest has
        // been patched into a MH_DYLIB, so it carries none. Permissions belong to the process -- the
        // extension's profile already grants the memory limits, the group and get-task-allow -- and a
        // profile-backed key on a binary with no profile is what AMFI reports as an invalid signature.
        try? FileManager.default.removeItem(at: bundleURL.appendingPathComponent("embedded.mobileprovision"))

        let profileIdentifier = (profile.entitlements["application-identifier"] as? String) ?? ""
        let teamPrefix = String(profileIdentifier.prefix { $0 != "." })

        debugLog("[ContainerInstaller] Signing the guest as the box itself: \(profileIdentifier), no entitlements;"
                 + " the box's own profile carries \(profile.entitlements.keys.sorted())")

        let keyData = try certificate.certificate.unencryptedP12Data()
        let cms = CMSSigner(p12Data: keyData, password: "")

        // Strip first: a signature left in place covers the binary as it was before this app patched its
        // header, which dyld reports as an invalid signature.
        let binaries = self.guestBinaries(in: bundleURL)
        for binary in binaries
        {
            MachOSignature.stripSignature(ofExecutableAt: binary.url)
        }

        for binary in binaries
        {
            // Each bundle binds its own Info.plist and resource list; a loose dylib belongs to no bundle
            // and is signed the way Apple signs those -- with neither.
            let bindings = binary.bundle.map { self.sealResources(in: $0, executableName: binary.url.lastPathComponent) }
                ?? (info: nil, resources: nil)

            guard let data = try? Data(contentsOf: binary.url) else { continue }

            let signer = MachOSigner(binaryData: data,
                                     bundleIdentifier: profileIdentifier,
                                     teamIdentifier: teamPrefix,
                                     entitlementsXML: nil,
                                     infoPlistData: bindings.info,
                                     codeResourcesData: bindings.resources,
                                     cmsSigner: cms)
            do
            {
                let signed = try signer.sign()
                try signed.write(to: binary.url, options: .atomic)
                debugLog("[ContainerInstaller] Signed \(binary.url.lastPathComponent): \(MachOSignature.digest(ofExecutableAt: binary.url) != nil ? "ok" : "still unsigned")")
            }
            catch
            {
                debugLog("[ContainerInstaller] Signing \(binary.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }

        let unsigned = binaries.filter { MachOSignature.digest(ofExecutableAt: $0.url) == nil }
        debugLog("[ContainerInstaller] \(binaries.count) Mach-O files in the guest, still unsigned: \(unsigned.map { $0.url.lastPathComponent })")

        // Only the main executable is checked, not that list: MachOSignature reads thin Mach-Os, and
        // MeloNX's ffmpeg libraries are universal containers, so they are reported unsigned even when
        // they are signed. The executable is the one thing a wrong answer here would hide.
        guard let executableURL = self.executableURL(in: bundleURL),
              MachOSignature.digest(ofExecutableAt: executableURL) != nil else {
            throw ContainerInstallerError.patcherRejected(NSLocalizedString("the signer left the executable unsigned", comment: ""))
        }
    }
}
