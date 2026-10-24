//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers
import MinimuxerCommon

public struct PairingFileMetadata: Sendable {
    public let exists: Bool
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
}

public struct PairingSyncSummary: Sendable {
    public var exported: [String] = []
    public var imported: [String] = []
    public var failed: [String] = []

    public var movedCount: Int {
        self.exported.count + self.imported.count
    }
}

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()

    private static let syncableFileNames = [
        AppConstants.Pairing.lockdownPairingFileName,
        AppConstants.Pairing.remotePairingFileName,
        AppConstants.Pairing.legacyPairingFileName
    ]

    static var supportedContentTypes: [UTType] {
        var types = AppConstants.Pairing.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml])
        return types
    }

    var activeProtocol: PairingProtocol {
        minimuxerPairingProtocol()
    }

    var persistedActiveProtocol: PairingProtocol? {
        get { UserDefaults.standard.activePairingProtocol }
        set { UserDefaults.standard.activePairingProtocol = newValue }
    }

    var preferredProtocol: PairingProtocol? {
        get { UserDefaults.standard.preferredPairingProtocol }
        set { UserDefaults.standard.preferredPairingProtocol = newValue }
    }

    nonisolated var sharedPairingDirectory: URL? {
        FileManager.default.altstoreSharedDirectory?.appendingPathComponent("Pairing", isDirectory: true)
    }

    nonisolated func pairingFileURL(for mode: PairingProtocol) -> URL {
        let fileName = mode == .rppairing ? AppConstants.Pairing.remotePairingFileName : AppConstants.Pairing.lockdownPairingFileName
        return FileManager.default.documentsDirectory.appendingPathComponent(fileName)
    }

    nonisolated func hasPairingFile(for mode: PairingProtocol) -> Bool {
        return FileManager.default.fileExists(atPath: pairingFileURL(for: mode).path)
    }

    nonisolated func hasPairingFile() -> Bool {
        guard !UserDefaults.standard.isPairingReset else { return false }
        if let target = preferredProtocol, hasPairingFile(for: target) {
            return true
        }
        if let mode = persistedActiveProtocol, hasPairingFile(for: mode) {
            return true
        }
        return false
    }

    nonisolated func metadata(for mode: PairingProtocol) -> PairingFileMetadata {
        let fileURL = pairingFileURL(for: mode)
        let path = fileURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return PairingFileMetadata(exists: false, size: 0, creationDate: nil, modificationDate: nil)
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let creation = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        let mod = attrs[.modificationDate] as? Date
        return PairingFileMetadata(exists: true, size: size, creationDate: creation, modificationDate: mod)
    }

    /// Reconciles the private copies with the shared App Group folder. The newer copy wins, so
    /// importing a file here immediately places it in the shared folder, and a file dropped there
    /// by another app shows up on the next launch.
    @discardableResult
    nonisolated func syncWithSharedDirectory() -> PairingSyncSummary {
        var summary = PairingSyncSummary()
        // No isPairingReset check here: the flag starts true on a fresh install, and a pairing file
        // placed in the shared folder before first launch is exactly what we want to pick up.
        // Resetting clears the shared copies too, so there is nothing stale to resurrect.
        guard let sharedDirectory = self.sharedPairingDirectory else {
            debugLog("[PairingFile] Shared app group unavailable; skipping sync.")
            return summary
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("[PairingFile] Failed to create shared folder: \(error)")
            return summary
        }

        for name in Self.syncableFileNames {
            let privateURL = fm.documentsDirectory.appendingPathComponent(name)
            let sharedURL = sharedDirectory.appendingPathComponent(name)
            let privateExists = fm.fileExists(atPath: privateURL.path)
            let sharedExists = fm.fileExists(atPath: sharedURL.path)

            switch (privateExists, sharedExists) {
            case (true, false):
                self.recordExport(named: name, from: privateURL, to: sharedURL, into: &summary)
            case (false, true):
                self.recordImport(named: name, from: sharedURL, to: privateURL, into: &summary)
            case (true, true):
                guard !Self.filesMatch(privateURL, sharedURL) else { continue }
                let privateDate = Self.modificationDate(of: privateURL) ?? .distantPast
                let sharedDate = Self.modificationDate(of: sharedURL) ?? .distantPast
                if sharedDate > privateDate {
                    self.recordImport(named: name, from: sharedURL, to: privateURL, into: &summary)
                } else if privateDate > sharedDate {
                    self.recordExport(named: name, from: privateURL, to: sharedURL, into: &summary)
                } else {
                    // Same timestamp but different bytes: keep the copy the app is actually using.
                    debugLog("[PairingFile] \(name) differs in both places with the same date; keeping the private copy.")
                }
            case (false, false):
                continue
            }
        }

        if !summary.exported.isEmpty || !summary.imported.isEmpty || !summary.failed.isEmpty {
            debugLog("[PairingFile] Shared sync: exported=\(summary.exported) imported=\(summary.imported) failed=\(summary.failed)")
        }
        return summary
    }

    @discardableResult
    nonisolated func exportAllPairingFilesToSharedDirectory() -> PairingSyncSummary {
        self.transferAllPairingFiles(copyingFromShared: false)
    }

    @discardableResult
    nonisolated func importAllPairingFilesFromSharedDirectory() -> PairingSyncSummary {
        self.transferAllPairingFiles(copyingFromShared: true)
    }

    private nonisolated func transferAllPairingFiles(copyingFromShared: Bool) -> PairingSyncSummary {
        var summary = PairingSyncSummary()
        guard let sharedDirectory = self.sharedPairingDirectory else {
            debugLog("[PairingFile] Shared app group unavailable.")
            return summary
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("[PairingFile] Failed to create shared folder: \(error)")
            return summary
        }

        for name in Self.syncableFileNames {
            let privateURL = fm.documentsDirectory.appendingPathComponent(name)
            let sharedURL = sharedDirectory.appendingPathComponent(name)
            if copyingFromShared {
                guard fm.fileExists(atPath: sharedURL.path) else { continue }
                self.recordImport(named: name, from: sharedURL, to: privateURL, into: &summary)
            } else {
                guard fm.fileExists(atPath: privateURL.path) else { continue }
                self.recordExport(named: name, from: privateURL, to: sharedURL, into: &summary)
            }
        }
        return summary
    }

    private nonisolated func recordExport(named name: String, from source: URL, to destination: URL, into summary: inout PairingSyncSummary) {
        if self.copyFile(from: source, to: destination) {
            summary.exported.append(name)
        } else {
            summary.failed.append(name)
        }
    }

    private nonisolated func recordImport(named name: String, from source: URL, to destination: URL, into summary: inout PairingSyncSummary) {
        if self.importFile(from: source, to: destination) {
            summary.imported.append(name)
        } else {
            summary.failed.append(name)
        }
    }

    private nonisolated func copyFile(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            debugLog("[PairingFile] Exported \(source.lastPathComponent) to the shared folder.")
            return true
        } catch {
            debugLog("[PairingFile] Failed to export \(source.lastPathComponent): \(error)")
            return false
        }
    }

    private nonisolated func importFile(from source: URL, to destination: URL) -> Bool {
        let data: Data
        let contents: String
        do {
            data = try Data(contentsOf: source)
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                debugLog("[PairingFile] Shared \(source.lastPathComponent) is not a readable string.")
                return false
            }
            contents = decoded
        } catch {
            debugLog("[PairingFile] Failed to read shared \(source.lastPathComponent): \(error)")
            return false
        }

        let parsed: any PairingFile
        do {
            parsed = try self.parse(content: contents)
        } catch {
            debugLog("[PairingFile] Shared \(source.lastPathComponent) is not a valid pairing file: \(error)")
            return false
        }

        do {
            try data.write(to: destination, options: .atomic)
            UserDefaults.standard.isPairingReset = false
            self.persistedActiveProtocol = parsed.mode
            debugLog("[PairingFile] Imported \(source.lastPathComponent) from the shared folder.")
            return true
        } catch {
            debugLog("[PairingFile] Failed to import \(source.lastPathComponent): \(error)")
            return false
        }
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    private nonisolated static func filesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsData = try? Data(contentsOf: lhs), let rhsData = try? Data(contentsOf: rhs) else {
            return false
        }
        return lhsData == rhsData
    }

    nonisolated func fetchPairingFile(for mode: PairingProtocol) -> String? {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path),
           let contents = try? String(contentsOf: fileURL), !contents.isEmpty 
        {
            return contents
        }
        return nil
    }

    nonisolated func fetchPairingFile(preferred: PairingProtocol? = nil) -> String? {
        guard !UserDefaults.standard.isPairingReset else { return nil }
        let targetPreferred = preferred ?? preferredProtocol
        if let targetPreferred, let contents = fetchPairingFile(for: targetPreferred) {
            return contents
        }
        if let persisted = persistedActiveProtocol {
            return fetchPairingFile(for: persisted)
        }
        return nil
    }
    
    @discardableResult
    nonisolated func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        try PairingFileParser.parse(content: content, preferred: preferred)
    }

    @discardableResult
    func savePairingFile(contents: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        let parsed = try parse(content: contents, preferred: preferred)
        let destinationURL = pairingFileURL(for: parsed.mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: destinationURL)
        }
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Saved \(parsed.mode.rawValue) pairing file to: \(destinationURL.path)")
        UserDefaults.standard.isPairingReset = false
        self.exportToSharedDirectory(fileName: destinationURL.lastPathComponent)
        return parsed
    }

    private nonisolated func exportToSharedDirectory(fileName: String) {
        guard let sharedDirectory = self.sharedPairingDirectory else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("[PairingFile] Failed to create shared folder: \(error)")
            return
        }
        let source = fm.documentsDirectory.appendingPathComponent(fileName)
        let destination = sharedDirectory.appendingPathComponent(fileName)
        _ = self.copyFile(from: source, to: destination)
    }

    func inspectPairingFile(from url: URL) throws -> (content: String, file: any PairingFile) {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let parsed = try parse(content: content, preferred: nil)
        return (content, parsed)
    }

    func importPairingFile(from url: URL, preferred: PairingProtocol? = nil) throws {
        let (content, _) = try inspectPairingFile(from: url)
        let parsed = try savePairingFile(contents: content, preferred: preferred)
        persistedActiveProtocol = parsed.mode
    }

    func deletePairingFile(for mode: PairingProtocol) {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
            debugLog("[PairingFile] Deleted \(mode.rawValue) pairing file: \(fileURL.path)")
        }
        if let sharedURL = self.sharedPairingDirectory?.appendingPathComponent(fileURL.lastPathComponent),
           fm.fileExists(atPath: sharedURL.path)
        {
            try? fm.removeItem(at: sharedURL)
        }
        if mode == persistedActiveProtocol {
            persistedActiveProtocol = nil
        }
    }

    func resetAllPairingFiles() {
        let fm = FileManager.default
        let files = [
            AppConstants.Pairing.lockdownPairingFileName,
            AppConstants.Pairing.remotePairingFileName,
            AppConstants.Pairing.legacyPairingFileName
        ]
        for name in files {
            let path = fm.documentsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
            if let sharedPath = self.sharedPairingDirectory?.appendingPathComponent(name),
               fm.fileExists(atPath: sharedPath.path)
            {
                try? fm.removeItem(at: sharedPath)
            }
        }
        UserDefaults.standard.isPairingReset = true
        persistedActiveProtocol = nil
        debugLog("[PairingFile] Reset all pairing files.")
    }
}
