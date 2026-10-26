//
//  EnableJITOperation.swift
//  SideStore
//
//  Created by Magesh K on 23/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Combine
import UniformTypeIdentifiers
import CoreData
import StikJIT

enum SideJITServerErrorType: Error {
    case invalidURL
    case errorConnecting
    case deviceNotFound
    case other(String)
}

final class EnableJITOperation: BaseStandaloneOperation<StandaloneOperationContext, Bool>, @unchecked Sendable
{
    let installedApp: InstalledApp
    private let progressHandler: (@Sendable (Int64, String) -> Void)?

    init(installedApp: InstalledApp, context: StandaloneOperationContext,
         progressHandler: (@Sendable (Int64, String) -> Void)? = nil) throws {
        self.installedApp = installedApp
        self.progressHandler = progressHandler
        try super.init(context: context)
    }

    /// Progress and a human-readable stage travel together so the HUD can say what is slow,
    /// not just how far along it is.
    private func report(_ value: Int64, _ stage: String) {
        self.setProgress(value)
        self.progressHandler?(value, stage)
    }

    override func execute(parentProgress: Progress?) async throws -> Bool {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[EnableJITOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[EnableJITOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.report(10, NSLocalizedString("Finding the running app…", comment: ""))

        try await self.enableJIT(for: self.installedApp)
        self.report(100, NSLocalizedString("Done", comment: ""))
        return true
    }

    private func enableJIT(for installedApp: InstalledApp) async throws
    {
        let userdefaults = UserDefaults.standard
        let dbContext = self.context.dbBackgroundContext

        let (targetBundleId, appName, _) = await dbContext.perform {
            (installedApp.resignedBundleIdentifier, installedApp.name, installedApp.fileURL.path)
        }

        if #available(iOS 17, *), userdefaults.isSideJITServerEnabled {
            let sideJITURLString = await SideJITManager.shared.resolveServerURL()
            guard let serverURL = URL(string: sideJITURLString) else {
                throw OperationError.unableToConnectSideJIT
            }
            self.report(30, NSLocalizedString("Connecting to SideJITServer…", comment: ""))
            do {
                try await enableJITSideJITServer(serverURL: serverURL, bundleIdentifier: targetBundleId, appName: appName)
                self.report(90, NSLocalizedString("Finishing…", comment: ""))
                self.debugLog("JIT Enabled Successfully :3 (code made by Stossy11!)")
            } catch {
                if let serverError = error as? SideJITServerErrorType {
                    switch serverError {
                    case .invalidURL, .errorConnecting:
                        throw OperationError.unableToConnectSideJIT
                    case .deviceNotFound:
                        throw OperationError.unableToRespondSideJITDevice
                    case .other(let message):
                        if let startRange = message.range(of: "<p>"),
                           let endRange = message.range(of: "</p>", range: startRange.upperBound..<message.endIndex) {
                            let pContent = message[startRange.upperBound..<endRange.lowerBound]
                            self.debugLog(message + " + " + String(pContent))
                            throw OperationError.SideJITIssue(error: String(pContent))
                        } else {
                            self.debugLog(message)
                            throw OperationError.SideJITIssue(error: message)
                        }
                    }
                } else {
                    throw error
                }
            }
        } else {
            try await enableJITOnDevice(bundleIdentifier: targetBundleId, appName: appName,
                                       progress: { self.report($0, $1) })
        }
    }
}

/// Turns JIT on without leaving the phone. StikJIT needs the target process id: the plain
/// debugger attach cannot prepare executable regions on TXM devices, and the debug proxy's
/// process list is the only way to learn the id from another process.
func enableJITOnDevice(bundleIdentifier: String, appName: String, pid: UInt32? = nil,
                       progress: (@Sendable (Int64, String) -> Void)? = nil) async throws
{
    // The debug proxy cannot list processes until a DDI is mounted, so StikJIT mounts one first
    // and the pid lookup happens inside that flow. A pid supplied by a deep link skips the lookup.
    try await enableJITWithStikJIT(targetPID: pid, bundleIdentifier: bundleIdentifier,
                                   appName: appName, progress: progress)
}

func notifyJITSuccess(appName: String) async {
    #if !os(tvOS)
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("JIT Successfully Enabled", comment: "")
        content.subtitle = String(format: NSLocalizedString("JIT Enabled For %@", comment: ""), appName)
        content.sound = .default

        let request = UNNotificationRequest(identifier: "EnabledJIT", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        return
    }
    #endif

    // Toast ONLY when notifications are disabled or not authorized
    await MainActor.run {
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }).first {
            let toastView = ToastView(text: NSLocalizedString("JIT Successfully Enabled", comment: ""), detailText: appName)
            toastView.show(in: window)
        }
    }
}

@available(iOS 17, *)
func enableJITSideJITServer(serverURL: URL, bundleIdentifier: String, appName: String) async throws {
    let udid: String
    do {
        await CellularRefreshManager.shared.turnOffDataIfNeeded()
        udid = try await safeFetchUDID()
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
    } catch {
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
        throw error
    }

    let serverURLWithUDID = serverURL.appendingPathComponent(udid)
    let fullURL = serverURLWithUDID.appendingPathComponent(bundleIdentifier)

    debugLog("[EnableJITOperation] Requesting JIT from SideJITServer at: \(fullURL)")
    let (data, _) = try await URLSession.shared.data(from: fullURL)

    guard let dataString = String(data: data, encoding: .utf8) else {
        debugLog("[EnableJITOperation] SideJITServer returned non-UTF8 response data (size: \(data.count) bytes)")
        throw SideJITServerErrorType.other("Invalid response data")
    }

    debugLog("[EnableJITOperation] SideJITServer response: '\(dataString)'")

    let cleanString = dataString.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\n\r\t "))

    if cleanString.contains("Enabled JIT for") {
        await notifyJITSuccess(appName: appName)
    } else {
        let errorType: SideJITServerErrorType = cleanString.contains("Could not find device")
            ? .deviceNotFound
            : .other(cleanString)
        throw errorType
    }
}

private let stikJITQueue = DispatchQueue(label: "io.airstore.stikjit", qos: .userInitiated)

private func runOnStikJITQueue<T>(_ work: @escaping () throws -> T) async throws -> T
{
    try await withCheckedThrowingContinuation { continuation in
        stikJITQueue.async {
            do
            {
                continuation.resume(returning: try work())
            }
            catch
            {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// StikJIT talks to the device over the Remote Pairing tunnel and prepares each executable region
/// through its universal script. The synchronous framework calls run on one serial queue, as the
/// integration guide requires.
private func enableJITWithStikJIT(targetPID: UInt32?, bundleIdentifier: String, appName: String,
                                  progress: (@Sendable (Int64, String) -> Void)?) async throws
{
    let pairingFile = PairingFileManager.shared.pairingFileURL(for: .rppairing)
    guard FileManager.default.fileExists(atPath: pairingFile.path) else {
        throw OperationError.invalidParameters(NSLocalizedString("JIT on iOS 17.4 and later needs a Remote Pairing file. Import PairingFile_RemoteRP.plist in Settings > Advanced > Pairing File Management.", comment: ""))
    }

    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let ddiDirectory = library.appendingPathComponent("StikJIT", isDirectory: true)
    do
    {
        try FileManager.default.createDirectory(at: ddiDirectory, withIntermediateDirectories: true)
    }
    catch
    {
        throw OperationError.invalidParameters("Could not create the StikJIT DDI folder: \(error.localizedDescription)")
    }
    let ddiPaths = DDIPaths.default(in: ddiDirectory)

    // StikJIT's own downloader only knows github.com, which redirects to raw.githubusercontent and
    // is blocked on a lot of these networks. Fetch through the app's mirrors first; if this fails,
    // StikJIT still gets its own attempt below.
    progress?(10, NSLocalizedString("Preparing the developer disk image…", comment: ""))
    do
    {
        try await StikJITDDI.prefetch(paths: ddiPaths) { fraction, status in
            progress?(10 + Int64(fraction * 15.0), status)
        }
    }
    catch
    {
        debugLog("[StikJIT] DDI prefetch failed: \(error); letting StikJIT try its own download")
    }

    let readiness = try await runOnStikJITQueue {
        StikJIT.prepareDevice(pairingFile: pairingFile, paths: ddiPaths, configuration: .default) { stage in
            switch stage
            {
            case .checkingReachability:
                progress?(25, NSLocalizedString("Checking the device…", comment: ""))
            case .checkingDDI:
                progress?(27, NSLocalizedString("Checking the developer disk image…", comment: ""))
            case .downloadingDDI(let fraction, let status):
                progress?(27 + Int64(fraction * 25.0), status)
                debugLog("[StikJIT] DDI \(Int(fraction * 100))%: \(status)")
            case .mountingDDI(let fraction):
                progress?(52 + Int64(fraction * 20.0), NSLocalizedString("Mounting the developer disk image…", comment: ""))
            case .verifyingDDI:
                progress?(73, NSLocalizedString("Verifying the developer disk image…", comment: ""))
            case .ready:
                progress?(78, NSLocalizedString("Developer disk image ready", comment: ""))
            }
        }
    }

    switch readiness
    {
    case .ready:
        break
    case .unreachable(let reason), .preparationFailed(let reason):
        throw OperationError.invalidParameters("StikJIT could not prepare the device: \(reason)")
    }

    // With the DDI mounted the debug proxy can answer, so this is the first point where the
    // process list is reliable. A pid from a deep link is used as-is.
    // Attaching to a process that iOS has already suspended in the background cannot work: the
    // script resumes it, it stops again before reaching a breakpoint, and the registers come back
    // empty. Launching it suspended puts the debugger in place before the app's own startup check.
    let resolvedPID: Int32
    var launchedSuspended = false
    if let targetPID
    {
        resolvedPID = Int32(targetPID)
        progress?(80, NSLocalizedString("Using the PID from the link", comment: ""))
    }
    else
    {
        progress?(79, String(format: NSLocalizedString("Restarting %@ suspended…", comment: ""), appName))
        let pid: UInt32
        do
        {
            pid = try await safeLaunchAppSuspended(bundleIdentifier)
            launchedSuspended = true
            progress?(80, String(format: NSLocalizedString("Restarted %@ suspended (PID %lld)", comment: ""), appName, Int64(pid)))
        }
        catch let launchError
        {
            progress?(79, String(format: NSLocalizedString("Finding %@…", comment: ""), appName))
            do
            {
                pid = try await safeRunningProcessID(bundleIdentifier)
                progress?(80, String(format: NSLocalizedString("Found %@ (PID %lld)", comment: ""), appName, Int64(pid)))
            }
            catch
            {
                throw OperationError.invalidParameters("Could not restart \(appName) suspended or find it running. (\(launchError.localizedDescription) / \(error.localizedDescription))")
            }
        }
        resolvedPID = Int32(pid)
    }

    progress?(83, NSLocalizedString("Turning off cellular data…", comment: ""))
    await CellularRefreshManager.shared.turnOffDataIfNeeded()
    do
    {
        try await runOnStikJITQueue {
            progress?(85, NSLocalizedString("Enabling JIT…", comment: ""))
            try StikJIT.enableJIT(targetPID: resolvedPID,
                                  pairingFile: pairingFile,
                                  ddiPaths: ddiPaths,
                                  configuration: .default,
                                  script: .universal,
                                  forceScript: false,
                                  preparationProgress: { _ in },
                                  progress: { message in
                                      debugLog("[StikJIT] \(message)")
                                      progress?(85, message)
                                  })
        }
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
    }
    catch
    {
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
        if launchedSuspended
        {
            // The app is sitting suspended with nothing attached to it; killing it lets the user
            // open it again instead of finding a frozen icon.
            try? await killProcess(UInt32(resolvedPID))
        }
        throw OperationError.invalidParameters("StikJIT could not enable JIT: \(error.localizedDescription)")
    }

    progress?(100, NSLocalizedString("Done", comment: ""))
    await notifyJITSuccess(appName: appName)
}

private struct DDIFile: Sendable
{
    let name: String
    let destination: String
}

/// Brings the DDI in through the app's GitHub mirrors. StikJIT would otherwise download it from
/// github.com itself, which redirects to raw.githubusercontent and fails on blocked networks.
private enum StikJITDDI
{
    static var usesCryptex: Bool
    {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
    }

    static func prefetch(paths: DDIPaths,
                         progress: @escaping @Sendable (Double, String) -> Void) async throws
    {
        let directory = usesCryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
        var files =
        [
            DDIFile(name: "BuildManifest.plist", destination: paths.manifestPath),
            DDIFile(name: "Image.dmg", destination: paths.imagePath),
            DDIFile(name: "Image.dmg.trustcache", destination: paths.trustcachePath)
        ]
        if usesCryptex
        {
            files.append(DDIFile(name: "Image.dmg.cryptex_info", destination: paths.cryptexInfoPath))
            files.append(DDIFile(name: "Image.dmg.root_hash", destination: paths.rootHashPath))
        }
        else
        {
            // A leftover cryptex layout makes StikJIT reject a personalized DDI that is otherwise fine.
            for path in [paths.cryptexInfoPath, paths.rootHashPath]
            {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let missing = files.filter { !isUsable($0.destination) }
        guard !missing.isEmpty else { return }

        let imageDirectory = URL(fileURLWithPath: paths.imagePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let base = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/\(directory)/"
        for (index, file) in missing.enumerated()
        {
            guard let url = URL(string: base + file.name) else { throw URLError(.badURL) }

            try await download(url, to: file.destination) { fraction in
                let overall = (Double(index) + fraction) / Double(missing.count)
                let status = String(format: NSLocalizedString("Downloading DDI %@… (%d%%)", comment: ""),
                                    file.name, Int32(fraction * 100))
                progress(overall, status)
            }
        }
    }

    private static func isUsable(_ path: String) -> Bool
    {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private static func download(_ url: URL, to destination: String,
                                 progress: @escaping @Sendable (Double) -> Void) async throws
    {
        var lastError: Error?
        for candidate in url.downloadCandidates
        {
            do
            {
                let temporaryURL = try await DDIDownloadDelegate.download(candidate, progress: progress)
                let destinationURL = URL(fileURLWithPath: destination)
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination)
                {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                return
            }
            catch
            {
                lastError = error
                debugLog("[StikJIT] DDI download from \(candidate.absoluteString) failed: \(error)")
            }
        }
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }
}

private final class DDIDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable
{
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let lock = NSLock()
    private var didResume = false

    private init(progress: @escaping @Sendable (Double) -> Void,
                 continuation: CheckedContinuation<URL, Error>)
    {
        self.progress = progress
        self.continuation = continuation
        super.init()
    }

    static func download(_ url: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DDIDownloadDelegate(progress: progress, continuation: continuation)
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64)
    {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL)
    {
        if let response = downloadTask.response as? HTTPURLResponse
        {
            guard (200..<300).contains(response.statusCode) else {
                self.finish(.failure(URLError(.badServerResponse)))
                return
            }
            if let mimeType = response.mimeType, mimeType.contains("html")
            {
                self.finish(.failure(URLError(.badServerResponse)))
                return
            }
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".ddi")
        do
        {
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            self.finish(.success(temporaryURL))
        }
        catch
        {
            self.finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if let error
        {
            self.finish(.failure(error))
        }
        else
        {
            self.finish(.failure(URLError(.unknown)))
        }
    }

    private func finish(_ result: Result<URL, Error>)
    {
        self.lock.lock()
        guard !self.didResume else
        {
            self.lock.unlock()
            return
        }
        self.didResume = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
