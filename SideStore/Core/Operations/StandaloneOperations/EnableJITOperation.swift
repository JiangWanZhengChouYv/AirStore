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

    init(installedApp: InstalledApp, context: StandaloneOperationContext) throws {
        self.installedApp = installedApp
        try super.init(context: context)
    }

    override func execute(parentProgress: Progress?) async throws -> Bool {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[EnableJITOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[EnableJITOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        try await self.enableJIT(for: self.installedApp)
        self.setProgress(100)
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
            self.setProgress(30)
            do {
                try await enableJITSideJITServer(serverURL: serverURL, bundleIdentifier: targetBundleId, appName: appName)
                self.setProgress(90)
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
                                       progress: { self.setProgress($0) })
        }
    }
}

/// Turns JIT on without leaving the phone. StikJIT needs the target process id: the plain
/// debugger attach cannot prepare executable regions on TXM devices, and the debug proxy's
/// process list is the only way to learn the id from another process.
func enableJITOnDevice(bundleIdentifier: String, appName: String, pid: UInt32? = nil,
                       progress: (@Sendable (Int64) -> Void)? = nil) async throws
{
    let targetPID: UInt32
    if let pid {
        targetPID = pid
    } else {
        do {
            targetPID = try await safeRunningProcessID(bundleIdentifier)
        } catch {
            throw OperationError.invalidParameters("Could not find \(appName) running. Open it, leave it in the background, then enable JIT again. (\(error.localizedDescription))")
        }
    }

    try await enableJITWithStikJIT(targetPID: Int32(targetPID), appName: appName, progress: progress)
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
private func enableJITWithStikJIT(targetPID: Int32, appName: String, progress: (@Sendable (Int64) -> Void)?) async throws
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

    // The DDI download needs network, so prepare before Cellular Refresh turns data off.
    progress?(15)
    let readiness = try await runOnStikJITQueue {
        StikJIT.prepareDevice(pairingFile: pairingFile, paths: ddiPaths, configuration: .default) { stage in
            switch stage
            {
            case .checkingReachability: progress?(20)
            case .checkingDDI: progress?(25)
            case .downloadingDDI(let fraction, let status):
                progress?(25 + Int64(fraction * 30.0))
                debugLog("[StikJIT] DDI \(Int(fraction * 100))%: \(status)")
            case .mountingDDI(let fraction):
                progress?(55 + Int64(fraction * 15.0))
            case .verifyingDDI: progress?(72)
            case .ready: progress?(78)
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

    await CellularRefreshManager.shared.turnOffDataIfNeeded()
    do
    {
        try await runOnStikJITQueue {
            try StikJIT.enableJIT(targetPID: targetPID,
                                  pairingFile: pairingFile,
                                  ddiPaths: ddiPaths,
                                  configuration: .default,
                                  script: .universal,
                                  forceScript: false,
                                  preparationProgress: { _ in },
                                  progress: { message in debugLog("[StikJIT] \(message)") })
        }
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
    }
    catch
    {
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
        throw OperationError.invalidParameters("StikJIT could not enable JIT: \(error.localizedDescription)")
    }

    progress?(100)
    await notifyJITSuccess(appName: appName)
}
