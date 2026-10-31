//
//  DownloadAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import UniformTypeIdentifiers
import SideSign

final class DownloadAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    private(set) var app: AppProtocol

    private let appName: String
    private let bundleIdentifier: String
    private var sourceURL: URL?
    private let destinationURL: URL

    private let session = URLSession(configuration: .default)
    private let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeSegmentedDownloader: SegmentedDownloader?

    override func cancel() {
        super.cancel()
        self.activeSegmentedDownloader?.cancel()
        self.activeDownloadTask?.cancel()
    }

    init(app: AppProtocol, destinationURL: URL, context: InstallAppOperationContext) throws {
        self.app = app

        self.appName = app.name
        self.bundleIdentifier = context.bundleIdentifier
        self.sourceURL = app.url
        self.destinationURL = destinationURL

        try super.init(context: context)
    }

    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[DownloadAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[DownloadAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        defer {
            if FileManager.default.fileExists(atPath: self.temporaryDirectory.path) {
                do {
                    try FileManager.default.removeItem(at: self.temporaryDirectory)
                } catch {
                    debugLog("[DownloadAppOperation] Failed to remove DownloadAppOperation temporary directory: \(self.temporaryDirectory). \(error)")
                }
            }
        }
        
        if self.isCancelled { throw OperationError.cancelled }
        if let error = self.context.error { throw error }
        
        debugLog("[DownloadAppOperation] Downloading App: \(self.bundleIdentifier)")

        do {
            var appVersion: AppVersion?

            if let version = app as? AppVersion {
                appVersion = version
            } else if let storeApp = app as? StoreApp {
                guard let latestVersion = storeApp.latestAvailableVersion else {
                    throw OperationError.missingUpdate(appName: self.appName)
                }

                // Attempt to download latest _available_ version, and fall back to older versions if necessary.
                appVersion = latestVersion
            }

            if let appVersion {
                try self.verify(appVersion)
                
                // set release Track for install/update
                if let track = appVersion.releaseTrack {
                    self.context.releaseTrack = track
                }
            }

            return try await self.download(appVersion ?? app)
            
        } catch let error as VerificationError where error.code == .iOSVersionNotSupported {
            let handler = self.context.handler.unsupportedVersionHandler
            guard let storeApp = app.storeApp,
                  let latestSupportedVersion = storeApp.latestSupportedVersion,
                  case let version = latestSupportedVersion.version,
                  version != storeApp.installedApp?.version
            else {
                throw error
            }

            if let installedApp = storeApp.installedApp {
                // guard !installedApp.matches(latestSupportedVersion) else { return self.finish(.failure(error)) }
                guard installedApp.hasUpdate else {
                    throw error
                }
            }

            let localizedVersion = latestSupportedVersion.localizedVersion
            let shouldDownload = try await handler.resolveUnsupportediOSVersion(
                errorDescription: error.localizedDescription,
                appName: self.appName,
                compatibleVersion: localizedVersion
            )

            if shouldDownload {
                return try await self.download(latestSupportedVersion)
            } else {
                throw OperationError.cancelled
            }
        }
    }

    private func verify(_ version: AppVersion) throws {
        if let minOSVersion = version.minOSVersion, !ProcessInfo.processInfo.isOperatingSystemAtLeast(minOSVersion) {
            throw VerificationError.iOSVersionNotSupported(app: version, requiredOSVersion: minOSVersion)
        } else if let maxOSVersion = version.maxOSVersion, ProcessInfo.processInfo.operatingSystemVersion > maxOSVersion {
            throw VerificationError.iOSVersionNotSupported(app: version, requiredOSVersion: maxOSVersion)
        }
    }
    
    private func download(@Managed _ app: AppProtocol) async throws -> ALTApplication {
        guard let sourceURL = self.sourceURL else {
            // A card update reaches this when PipelineRunner swaps InstalledApp -> StoreApp because
            // the recorded bundle path is gone (which is what a self-update always does to it), and a
            // StoreApp reads its URL off the first entry of _versions. Two sources can both carry
            // com.SideStore.SideStore, so "which row did we get" is the whole question -- say it in
            // the error instead of making someone reproduce it under a debugger.
            let detail: String
            if let storeApp = app as? StoreApp
            {
                detail = "type=StoreApp source=\(storeApp.source?.identifier ?? "nil") versions=\(storeApp._versions.count) deleted=\(storeApp.isDeleted)"
            }
            else
            {
                detail = "type=\(type(of: app))"
            }
            throw OperationError.invalidParameters("Missing download URL for '\(self.appName)' (\(detail)).")
        }
        if let appVersion = app as? AppVersion {
            // All downloads go through this path, and `app` is
            // always an AppVersion if downloading from a source,
            // so context.appVersion != nil means downloading from source.
            self.context.appVersion = appVersion
        }

        // A mirror that has not picked up this build yet serves the previous one, which is a valid
        // file with the wrong bytes. Checking the hash per candidate sends those to the next route
        // instead of failing the install later.
        let expectedSHA256: String? = $app.perform { object in (object as? AppVersion)?.sha256 }
        let appVersion = app as? AppVersion

        let appBundle: ALTApplication

        // Only the store itself is cut into patches. Every other package on a release has no
        // counterpart asset, so asking for one is a guaranteed 404 on the way to the full download.
        if UserDefaults.standard.isIncrementalUpdateEnabled, let appVersion,
           self.context.bundleIdentifier == StoreApp.altstoreAppID,
           let baseTag = BundleDelta.cachedBaseTag(forBundleID: self.context.bundleIdentifier),
           let patchURL = BundleDelta.patchURL(forPackageAt: sourceURL, baseTag: baseTag)
        {
            do
            {
                appBundle = try await self.downloadViaDelta(patchURL: patchURL, appVersion: appVersion)
            }
            catch
            {
                // Everything from a missing base to a stale patch is normal -- the app was installed
                // from a computer, the rolling release skipped a build -- so a delta failure is not an
                // error the user sees, it is the old behaviour.
                debugLog("[DownloadAppOperation] Delta not usable for \(self.context.bundleIdentifier) (\(error)); downloading the full package")
                appBundle = try await self.downloadIPA(from: sourceURL, expectedSHA256: expectedSHA256)
            }
        }
        else
        {
            appBundle = try await self.downloadIPA(from: sourceURL, expectedSHA256: expectedSHA256)
        }

        if UserDefaults.standard.isIncrementalUpdateEnabled || BundleDelta.hasBaseline(forBundleID: self.context.bundleIdentifier)
        {
            // Cache the bundle as it was extracted, before this app re-signs it with the user's own
            // certificate -- signing rewrites the executable, drops in the provisioning profile and
            // regenerates _CodeSignature, and CI cuts its base from the published package's bytes.
            //
            // A cache that already exists is kept fresh even with the toggle off: the next patch is
            // cut against the build actually installed, so leaving the previous build's base behind
            // would cost one full download to the stale-base fallback.
            do {
                try BundleDelta.remember(bundleAt: appBundle.fileURL, forBundleID: self.context.bundleIdentifier)
            } catch {
                // A baseline that failed to be written looks exactly like a delta that failed to
                // apply from the outside, so say which one happened.
                debugLog("[DownloadAppOperation] Could not cache the update baseline for \(self.context.bundleIdentifier): \(error)")
            }
        }
        
        if self.context.bundleIdentifier == StoreApp.dolphinAppID, self.context.bundleIdentifier != appBundle.bundleIdentifier {
            // Manually update the app's bundle identifier to match the one specified in the source.
            // This allows people who previously installed the app to still update and refresh normally.
            try? appBundle.updateInfoPlist(with: [kCFBundleIdentifierKey as String: StoreApp.dolphinAppID])
        }
        
        let dependencies = try await self.downloadDependencies(for: appBundle)
        if !dependencies.isEmpty {
            self.debugLog("[DownloadAppOperation] Downloaded \(dependencies.count) dependencies for \(appBundle.name): \(dependencies.map(\.lastPathComponent))")
        }
        
        debugLog("[DownloadAppOperation] Moving extracted bundle from \(appBundle.fileURL.path) to destination \(self.destinationURL.path)")
        try FileManager.default.moveItem(at: appBundle.fileURL, to: self.destinationURL, shouldReplace: true)
        debugLog("[DownloadAppOperation] Moving bundle to destination succeeded")
        
        guard let movedAppBundle = ALTApplication(fileURL: self.destinationURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load moved app bundle at '\(self.destinationURL.lastPathComponent)'")
        }
        self.setProgress(100)
        return movedAppBundle
    }
    
    func downloadIPA(from sourceURL: URL, expectedSHA256: String? = nil) async throws -> ALTApplication {
        let fileURL: URL
        
        if sourceURL.isFileURL {
            fileURL = sourceURL
            self.setProgress(75)
        } else {
            // Regular app
            fileURL = try await downloadFile(from: sourceURL, expectedSHA256: expectedSHA256)
        }
        
        defer {
            if !sourceURL.isFileURL && FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]) else {
            throw OperationError.missingAppBundle(reason: "File does not exist at '\(fileURL.lastPathComponent)'")
        }
        
        try FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
        
        let appBundleURL: URL
        
        if resourceValues.isDirectory == true {
            // Directory, so assuming this is .app bundle.
            guard ALTApplication(fileURL: fileURL) != nil else {
                throw OperationError.missingAppBundle(reason: "Directory at '\(fileURL.lastPathComponent)' is not a valid bundle directory")
            }
            
            appBundleURL = self.temporaryDirectory.appendingPathComponent(fileURL.lastPathComponent)
            try FileManager.default.copyItem(at: fileURL, to: appBundleURL)
        } else {
            // File, so assuming this is a .ipa file.
            appBundleURL = try FileManager.default.unzipAppBundle(at: fileURL, toDirectory: self.temporaryDirectory)
            
            // Use context's temporaryDirectory to ensure .ipa isn't deleted before we're done installing.
            let ipaURL = self.context.temporaryDirectory.appendingPathComponent("App.ipa")
            try FileManager.default.copyItem(at: fileURL, to: ipaURL)
            
            self.context.ipaURL = ipaURL
        }
        
        guard let appBundle = ALTApplication(fileURL: appBundleURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load unzipped app bundle at '\(appBundleURL.lastPathComponent)'")
        }

        // perform cleanup of the temp files
        if !sourceURL.isFileURL && FileManager.default.fileExists(atPath: fileURL.path) {
            verboseLog("[DownloadAppOperation] Removing downloaded temp file at: \(fileURL.path)")
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                verboseLog("[DownloadAppOperation] Removing downloaded temp error: \(error)")
            }
        }

        return appBundle
    }
    
    /// Rebuild this package from the cached base plus the delta that sits beside it on the same
    /// release. Any doubt at all throws, and the caller answers by downloading the full package.
    private func downloadViaDelta(patchURL: URL, appVersion: AppVersion) async throws -> ALTApplication
    {
        let patchFile = try await self.downloadFile(from: patchURL, expectedSHA256: nil)
        defer { try? FileManager.default.removeItem(at: patchFile) }

        let directory = self.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let bundleURL = try BundleDelta.restore(bundleID: self.context.bundleIdentifier, fromPatchAt: patchFile,
                                                 into: directory, expectingVersion: appVersion.version)
        guard let appBundle = ALTApplication(fileURL: bundleURL) else {
            throw BundleDeltaError.identity("could not read \(bundleURL.lastPathComponent) as an app bundle")
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: patchFile.path)[.size] as? Int64) ?? 0
        debugLog("[DownloadAppOperation] Assembled \(appVersion.version) for \(self.context.bundleIdentifier) from a \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) delta")
        self.context.assembledFromDelta = true
        return appBundle
    }
    
    func downloadFile(from downloadURL: URL, expectedSHA256: String? = nil) async throws -> URL {
        debugLog("[DownloadAppOperation] download started: \(downloadURL)")

        let taskID = "\(self.bundleIdentifier)|\(downloadURL.absoluteString)"
        let hudName = self.appName
        await MainActor.run { DownloadProgressHUD.shared.begin(id: taskID, appName: hudName, url: downloadURL) }

        // Best measured route first, origin second, slow mirrors last; raw and archive URLs get
        // their own order. A dead candidate only costs the time it takes to fail, and the 20 s idle
        // timeout keeps a blocked origin from stalling.
        var lastError: Error?
        for candidate in downloadURL.downloadCandidates {
            await MainActor.run { DownloadProgressHUD.shared.setMirror(candidate.host ?? "", for: taskID) }

            do {
                let fileURL = try await self.downloadSegmented(candidate, taskID: taskID)
                if self.hashMatches(fileURL, expected: expectedSHA256)
                {
                    if candidate != downloadURL {
                        debugLog("[DownloadAppOperation] Downloaded through mirror \(candidate.host ?? "?") over multiple connections.")
                    }
                    self.setProgress(75)
                    await MainActor.run { DownloadProgressHUD.shared.end(id: taskID) }
                    return fileURL
                }
                try? FileManager.default.removeItem(at: fileURL)
                lastError = OperationError.missingAppBundle(reason: "stale copy on \(candidate.host ?? "?")")
            }
            catch is CancellationError {
                await MainActor.run { DownloadProgressHUD.shared.end(id: taskID) }
                throw CancellationError()
            }
            catch SegmentedDownloader.Failure.cancelled {
                await MainActor.run { DownloadProgressHUD.shared.end(id: taskID) }
                throw OperationError.cancelled
            }
            catch {
                // Ranges unavailable, or a mirror that dislikes 32 connections. One connection
                // still gets a chance before moving to the next candidate.
                lastError = error
                debugLog("[DownloadAppOperation] Segmented download failed via \(candidate.host ?? "?") (\(error.localizedDescription)); falling back to one connection.")
            }

            var resumeData: Data?

            for attempt in 0..<2 {
                do {
                    let fileURL = try await self.download(candidate, taskID: taskID, resumeData: resumeData)
                    if self.hashMatches(fileURL, expected: expectedSHA256)
                    {
                        if candidate != downloadURL {
                            debugLog("[DownloadAppOperation] Downloaded through mirror \(candidate.host ?? "?").")
                        }
                        self.setProgress(75)
                        await MainActor.run { DownloadProgressHUD.shared.end(id: taskID) }
                        return fileURL
                    }
                    try? FileManager.default.removeItem(at: fileURL)
                    lastError = OperationError.missingAppBundle(reason: "stale copy on \(candidate.host ?? "?")")
                    break   // A wrong file is not a dropped connection; there is nothing to resume.
                }
                catch {
                    lastError = error
                    if attempt == 1 { break }
                    // A dropped connection hands back the bytes it already has; resuming the same
                    // mirror once is the difference between retrying 28 MB and the last few.
                    resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    debugLog("[DownloadAppOperation] Download failed via \(candidate.host ?? "?"): \(error.localizedDescription)")
                    if resumeData == nil { break }
                    debugLog("[DownloadAppOperation] Resuming via \(candidate.host ?? "?") from saved data.")
                }
            }
        }

        await MainActor.run { DownloadProgressHUD.shared.end(id: taskID) }
        throw lastError ?? URLError(.badURL)
    }

    /// True when the bytes are the ones the source promised, or when the source promised nothing.
    private func hashMatches(_ fileURL: URL, expected: String?) -> Bool
    {
        guard let expected, !expected.isEmpty else { return true }
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else { return false }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash.caseInsensitiveCompare(expected) == .orderedSame else {
            debugLog("[DownloadAppOperation] Downloaded \(hash.prefix(12))… but the source says \(expected.prefix(12))…; moving to the next route.")
            return false
        }
        return true
    }

    private func downloadSegmented(_ downloadURL: URL, taskID: String) async throws -> URL {
        let destinationURL = self.temporaryDirectory.appendingPathComponent("segmented-\(UUID().uuidString).ipa")
        let downloader = SegmentedDownloader(url: downloadURL, destinationURL: destinationURL) { [weak self] received, total in
            guard let self else { return }
            if total > 0 {
                let fraction = Double(received) / Double(total)
                self.progress.completedUnitCount = Int64(fraction * 75.0)
            }
            Task { @MainActor in
                DownloadProgressHUD.shared.update(id: taskID, bytes: received, total: total)
            }
        }

        self.activeSegmentedDownloader = downloader
        defer {
            if self.activeSegmentedDownloader === downloader {
                self.activeSegmentedDownloader = nil
            }
        }
        try await downloader.download()
        return destinationURL
    }

    private func download(_ downloadURL: URL, taskID: String, resumeData: Data?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate(progress: self.progress, taskID: taskID) { result in
                continuation.resume(with: result)
            }
            let configuration = URLSessionConfiguration.default
            // Idle timeout, not total: slow-but-alive mirrors keep sending, while a blocked host
            // gives up in time for the next candidate.
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: downloadURL)
            }
            delegate.task = task
            self.activeDownloadTask = task
            task.resume()
        }
    }
    
    
    private func downloadDependencies(for appBundle: ALTApplication) async throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: appBundle.bundle.altstorePlistURL.path) else {
            return []
        }
        
        let data = try Data(contentsOf: appBundle.bundle.altstorePlistURL)
        let altstorePlist = try PropertyListDecoder().decode(AltStorePlist.self, from: data)
                    
        var dependencyURLs = Set<URL>()
        
        for dependency in altstorePlist.dependencies {
            let fileURL = try await self.download(dependency, for: appBundle)
            dependencyURLs.insert(fileURL)
        }
        
        return dependencyURLs
    }
    
    private func download(_ dependency: Dependency, for appBundle: ALTApplication) async throws -> URL {
        do {
            let (fileURL, _) = try await self.session.download(from: dependency.downloadURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            
            let path = dependency.path ?? dependency.preferredFilename
            let destinationURL = appBundle.fileURL.appendingPathComponent(path)
            
            let directoryURL = destinationURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            
            try FileManager.default.copyItem(at: fileURL, to: destinationURL, shouldReplace: true)
            return destinationURL
        } catch let error as NSError {
            let localizedFailure = String(format: NSLocalizedString("The dependency '%@' could not be downloaded.", comment: ""), dependency.preferredFilename)
            throw error.withLocalizedFailure(localizedFailure)
        }
    }
}


extension DownloadAppOperation {
    struct AltStorePlist: Decodable {
        private enum CodingKeys: String, CodingKey {
            case dependencies = "ALTDependencies"
        }

        var dependencies: [Dependency]
    }
    
    struct Dependency: Decodable {
        var downloadURL: URL
        var path: String?
        
        var preferredFilename: String {
            let preferredFilename = self.path.map { ($0 as NSString).lastPathComponent } ?? self.downloadURL.lastPathComponent
            return preferredFilename
        }
        
        init(from decoder: Decoder) throws {
            enum CodingKeys: String, CodingKey {
                case downloadURL
                case path
            }
            
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            let urlString = try container.decode(String.self, forKey: .downloadURL)
            let path = try container.decodeIfPresent(String.self, forKey: .path)
            
            guard let downloadURL = URL(string: urlString) else {
                throw DecodingError.dataCorruptedError(forKey: .downloadURL, in: container, debugDescription: "downloadURL is not a valid URL.")
            }
            
            self.downloadURL = downloadURL
            self.path = path
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress
    let taskID: String
    weak var task: URLSessionDownloadTask?
    private var lastLoggedPercent: Int = -1
    private var lastLogTime: CFAbsoluteTime = 0
    private var continuation: ((Result<URL, Error>) -> Void)?
    private var hasResumed = false
    private let lock = NSLock()
    
    init(progress: Progress, taskID: String, completion: @escaping (Result<URL, Error>) -> Void) {
        self.progress = progress
        self.taskID = taskID
        self.continuation = completion
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            self.progress.completedUnitCount = Int64(fraction * 75.0)
            let percent = Int(fraction * 100.0)
            let now = CFAbsoluteTimeGetCurrent()
            if percent != self.lastLoggedPercent && (now - self.lastLogTime >= 0.3 || percent == 100) {
                self.lastLoggedPercent = percent
                self.lastLogTime = now
                let reportedBytes = totalBytesWritten
                let reportedTotal = totalBytesExpectedToWrite
                let identifier = self.taskID
                Task { @MainActor in DownloadProgressHUD.shared.update(id: identifier, bytes: reportedBytes, total: reportedTotal) }
                debugLog("[DownloadAppOperation] Download transfer: \(percent)% (\(ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)))")
            }
        } else {
            let mbWritten = Double(totalBytesWritten) / (1024.0 * 1024.0)
            let estimatedFraction = min(0.95, mbWritten / 100.0)
            self.progress.completedUnitCount = Int64(estimatedFraction * 75.0)
            let percent = Int(estimatedFraction * 100.0)
            let now = CFAbsoluteTimeGetCurrent()
            if percent != self.lastLoggedPercent && (now - self.lastLogTime >= 0.3 || percent == 100) {
                self.lastLoggedPercent = percent
                self.lastLogTime = now
                let reportedBytes = totalBytesWritten
                let identifier = self.taskID
                Task { @MainActor in DownloadProgressHUD.shared.update(id: identifier, bytes: reportedBytes, total: 0) }
                debugLog("[DownloadAppOperation] Download transfer: \(percent)% (\(ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)))")
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        defer { session.finishTasksAndInvalidate() }
        let url = downloadTask.originalRequest?.url ?? location
        if let resp = downloadTask.response as? HTTPURLResponse {
            debugLog("[DownloadAppOperation] downloadFile: completed with status \(resp.statusCode) at \(location.path)")
            // A mirror that has not picked up a brand new release asset answers with an error page,
            // often as 200 + text/html. Anything but a 2xx binary has to count as a dead route so
            // the loop moves on and the origin gets its turn.
            guard (200..<300).contains(resp.statusCode) else {
                finish(with: .failure(URLError(.badServerResponse, userInfo: [NSURLErrorKey: url])))
                return
            }
            if let mime = resp.mimeType?.lowercased(), mime.contains("html") {
                finish(with: .failure(URLError(.cannotDecodeContentData, userInfo: [NSURLErrorKey: url])))
                return
            }
        }
        let tempDestination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try FileManager.default.moveItem(at: location, to: tempDestination)
            finish(with: .success(tempDestination))
        } catch {
            finish(with: .failure(error))
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            session.invalidateAndCancel()
            finish(with: .failure(error))
        }
    }
    
    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation?(result)
        continuation = nil
    }
}
