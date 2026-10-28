//
//  BundleDelta.swift
//  SideStore
//
//  Applies AirStore's own bundle deltas so an update downloads what changed rather than the whole
//  package. Only reachable when the developer option is turned on.
//

import Foundation
import Compression
import CryptoKit

enum BundleDeltaError: Error, CustomStringConvertible
{
    case noBase(URL)
    case noPatchURL(URL)
    case badMagic(String)
    case truncated
    case inflateFailed
    case baseTooShort(offset: UInt64, length: UInt64, size: UInt64)
    case staleBase(cached: String, wants: String)
    case shortReassembly(produced: UInt64, expected: UInt64)
    case shaMismatch(expected: String, actual: String)
    case identity(String)
    
    var description: String
    {
        switch self
        {
        case .noBase(let url): return "no cached base at \(url.lastPathComponent)"
        case .noPatchURL(let url): return "no patch URL derived from \(url.absoluteString)"
        case .badMagic(let reason): return "stream header: \(reason)"
        case .truncated: return "stream is truncated"
        case .inflateFailed: return "patch body did not decompress"
        case .baseTooShort(let offset, let length, let size): return "patch wants \(length) bytes at offset \(offset) but the base is only \(size)"
        // Three separate failures used to share one sentence, and it cost a debugging round: the
        // phone's byte-perfect reassembly was reported the same way a stale baseline is.
        case .staleBase(cached: let cached, wants: let wants): return "phone is not on the build this patch was cut for: cached base is \(cached.prefix(12)), the patch wants \(wants.prefix(12))"
        case .shortReassembly(produced: let produced, expected: let expected): return "reassembly stopped at \(produced) bytes of \(expected)"
        case .shaMismatch(expected: let expected, actual: let actual): return "reassembled SHA-256 is \(actual.prefix(12)), expected \(expected.prefix(12))"
        case .identity(let reason): return "rebuilt bundle failed its identity check: \(reason)"
        }
    }
}

/*
 Two formats, both defined byte for byte in scripts/ci/make_patch.py.

 ASBU -- a deterministic serialization of an .app bundle: entries sorted by the UTF-8 bytes of their
 relative path, each carrying kind, path, one executable bit and its content. The executable bit is
 the only permission stored on purpose. CI packs the bundle out of the Xcode archive while the phone
 packs what its own unzip produced, so two trees that differ only in mode bits would hash differently
 for an app that did not actually change, and every delta would then fall back in silence.

 ASDP2 -- copy/insert instructions over a byte blob, deflated with raw zlib (COMPRESSION_ZLIB),
 because bsdiff would mean vendoring bzip2 into a target whose dependencies otherwise come from local
 packages. Copy offsets point into the cached base ASBU.

 Why the delta runs over the bundle stream instead of the .ipa: measured on two real packages, a
 delta over the compressed ipa costs 30.98% of the download while over the bundle stream it costs
 1.82% -- and between two consecutive develop builds it is 0.04% (12,819 bytes). Inside a zip a few
 kilobytes of change re-encode and shift everything after them so nothing looks reusable;
 uncompressed, most of a package really is unchanged and one instruction carries it.
*/
struct BundleDelta
{
    private static let asbuMagic = Array("ASBU".utf8)
    private static let asbuVersion: UInt8 = 1
    private static let patchMagic = Array("ASDP".utf8)
    private static let patchVersion: UInt8 = 2
    
    private static let asbuHeaderSize = 4 + 1 + 8           // magic, version, entry count
    private static let entryHeaderSize = 1 + 2 + 1 + 8      // kind, path length, executable bit, content length
    
    // magic, version, base SHA-256, target SHA-256, target length, deflated length, raw length
    private static let patchHeaderSize = 4 + 1 + 32 + 32 + 8 + 8 + 8
    private static let patchBaseOffset = 5
    private static let patchTargetOffset = 37
    private static let patchTargetLengthOffset = 69
    private static let patchDeflatedOffset = 77
    private static let patchRawLengthOffset = 85
    
    private enum Kind: UInt8 { case directory = 0, file = 1, symlink = 2 }
    
    private struct Entry
    {
        var kind: Kind
        var path: String
        var executable: Bool
        var size: UInt64
        var url: URL
    }
    
    //MARK: - where the base lives
    
    private static var cacheDirectory: URL
    {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("BundleDelta", isDirectory: true)
    }
    
    static func cacheURL(forBundleID bundleID: String) -> URL
    {
        // Identifiers are alphanumerics, "." and "-", but this string arrives from a source JSON, so
        // force it down to one safe path component regardless of what a source declares.
        let safe = String(bundleID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        return cacheDirectory.appendingPathComponent(safe + ".asbu")
    }
    
    /// The patch rides the same release as the package it applies to, found by convention so neither
    /// the feed schema nor CoreData has to carry another field: same release tag, same name, `.patch`
    /// instead of `.ipa`. Naming it after the version means the pair for every build stays on the
    /// release together, so a package can never be served with someone else's patch.
    static func patchURL(forPackageAt packageURL: URL) -> URL?
    {
        let marker = "/releases/download/"
        guard packageURL.host?.hasSuffix("github.com") == true,
              packageURL.pathExtension.lowercased() == "ipa",
              let range = packageURL.path.range(of: marker) else { return nil }
        
        // Past the marker a release URL has exactly two parts left: the tag it belongs to and the
        // asset itself. Anything else is not a package on a release, and inventing a URL from it
        // would only hide the fact that this build has no patch.
        let tail = packageURL.path[range.upperBound...].split(separator: "/")
        guard tail.count >= 2, let tag = tail.first, let fileName = tail.last else { return nil }
        
        guard var components = URLComponents(url: packageURL, resolvingAgainstBaseURL: false) else { return nil }
        let stem = String(fileName.dropLast(packageURL.pathExtension.count + 1))
        components.path = String(packageURL.path[..<range.upperBound]) + tag + "/" + stem + ".patch"
        return components.url
    }
    
    //MARK: - recording the base
    
    /// Pack an extracted bundle. Callers must do this **before signing**: the installed copy has our
    /// certificate, profile and code signatures written into it, and would never match what CI packs
    /// from its own archive.
    static func remember(bundleAt bundleURL: URL, forBundleID bundleID: String) throws
    {
        let fm = FileManager.default
        let destination = cacheURL(forBundleID: bundleID)
        let staging = destination.appendingPathExtension("writing")
        
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: staging)
        guard fm.createFile(atPath: staging.path, contents: nil), let out = FileHandle(forWritingAtPath: staging.path) else {
            throw BundleDeltaError.truncated
        }
        defer { try? out.close() }
        
        let entries = collectEntries(in: bundleURL)
        out.write(Data(asbuMagic) + Data([asbuVersion]) + littleEndian(UInt64(entries.count)))
        
        for entry in entries
        {
            let path = Data(entry.path.utf8)
            var header = Data([entry.kind.rawValue])
            header.append(UInt8(path.count & 0xFF))
            header.append(UInt8((path.count >> 8) & 0xFF))
            header.append(entry.executable ? 1 : 0)
            header.append(littleEndian(entry.size))
            out.write(header)
            out.write(path)
            
            switch entry.kind
            {
            case .directory:
                break
            case .symlink:
                let target = (try? fm.destinationOfSymbolicLink(atPath: entry.url.path)) ?? ""
                out.write(Data(target.utf8))
            case .file:
                guard let handle = FileHandle(forReadingAtPath: entry.url.path) else { throw BundleDeltaError.truncated }
                defer { try? handle.close() }
                var written: UInt64 = 0
                while written < entry.size
                {
                    guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { throw BundleDeltaError.truncated }
                    out.write(chunk)
                    written += UInt64(chunk.count)
                }
            }
        }
        try? out.close()
        
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        // Debug rather than verbose: whether a base exists is the one thing that decides if the next
        // update can be a delta, and it should be readable in the log without turning on extra output.
        debugLog("[BundleDelta] cached base for \(bundleID): \(entries.count) entries, \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
    }
    
    private static func collectEntries(in bundleURL: URL) -> [Entry]
    {
        let fm = FileManager.default
        let root = bundleURL.path
        
        guard let walker = fm.enumerator(at: bundleURL, includingPropertiesForKeys: nil, options: [],
                                         errorHandler: { url, _ in verboseLog("[BundleDelta] skipping unreadable entry \(url.lastPathComponent)") ; return true }) else { return [] }
        
        var entries: [Entry] = []
        for case let url as URL in walker
        {
            guard url.path.hasPrefix(root + "/") else { continue }
            let relative = String(url.path.dropFirst(root.count + 1))
            
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            // st_mode is mode_t (UInt16) on Darwin, so compare through Int32 rather than matching
            // S_IF* constants directly -- they are UInt16 and will not pattern-match an Int32.
            let fileType = Int32(info.st_mode & S_IFMT)
            
            if fileType == Int32(S_IFDIR)
            {
                entries.append(Entry(kind: .directory, path: relative, executable: true, size: 0, url: url))
            }
            else if fileType == Int32(S_IFLNK)
            {
                let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                entries.append(Entry(kind: .symlink, path: relative, executable: false, size: UInt64(target.utf8.count), url: url))
            }
            else if fileType == Int32(S_IFREG)
            {
                entries.append(Entry(kind: .file, path: relative, executable: (info.st_mode & 0o111) != 0, size: UInt64(info.st_size), url: url))
            }
            else
            {
                // Sockets, FIFOs and devices have no place in a bundle; skip rather than write
                // something the reader would misinterpret.
                verboseLog("[BundleDelta] skipping non-file entry \(relative)")
            }
        }
        
        return entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }
    
    //MARK: - rebuilding a package from a patch
    
    /// Apply the patch to the cached base, unpack the result under `directory`, and hand back the
    /// bundle. Throws for any reason at all -- callers treat that as "download the whole thing".
    static func restore(bundleID: String, fromPatchAt patchURL: URL, into directory: URL,
                        expectingVersion version: String?) throws -> URL
    {
        let fm = FileManager.default
        let baseURL = cacheURL(forBundleID: bundleID)
        guard fm.fileExists(atPath: baseURL.path) else { throw BundleDeltaError.noBase(baseURL) }
        
        let patch = try Data(contentsOf: patchURL)
        guard patch.count > littleEndianThreshold else { throw BundleDeltaError.truncated }
        guard Array(patch.prefix(4)) == patchMagic, patch[4] == patchVersion else {
            throw BundleDeltaError.badMagic("not ASDP2")
        }
        
        let baseSHA = patch[patchBaseOffset..<(patchBaseOffset + 32)]
        let targetSHA = patch[patchTargetOffset..<(patchTargetOffset + 32)]
        let targetLength = readU64(patch, patchTargetLengthOffset)
        let deflatedLength = Int(readU64(patch, patchDeflatedOffset))
        let rawBodyLength = Int(readU64(patch, patchRawLengthOffset))
        guard patch.count == patchHeaderSize + deflatedLength else { throw BundleDeltaError.truncated }
        
        // A stale or plain wrong base is normal (the user updated through a computer, or the rolling
        // release skipped a build), so this check has to be cheap and it has to fail loudly enough
        // that the caller falls back. The base is ~52 MB, so hash it once and reuse it for the message.
        let cachedBaseSHA = sha256(of: baseURL)
        guard cachedBaseSHA == baseSHA else {
            throw BundleDeltaError.staleBase(cached: hex(Data(cachedBaseSHA)), wants: hex(Data(baseSHA)))
        }
        
        let body = try inflate(Array(patch[patchHeaderSize..<patch.count]), toSize: rawBodyLength)
        
        let staging = directory.appendingPathComponent(".delta-\(UUID().uuidString).asbu")
        _ = fm.createFile(atPath: staging.path, contents: nil)
        guard let baseHandle = FileHandle(forReadingAtPath: baseURL.path),
              let out = FileHandle(forWritingAtPath: staging.path) else {
            throw BundleDeltaError.truncated
        }
        defer { try? baseHandle.close(); try? out.close() }
        
        let baseSize = UInt64(baseHandle.seekToEndOfFile())
        let instructionCount = Int(readU64(body, 0))
        
        // Literals follow the instruction table, so find where it ends first.
        var scan = 8
        for _ in 0..<instructionCount
        {
            scan += body[scan] == 0 ? 17 : 9
        }
        
        var digest = SHA256()
        var produced: UInt64 = 0
        var cursor = 8
        var literalAt = scan
        
        for _ in 0..<instructionCount
        {
            if body[cursor] == 0
            {
                let offset = readU64(body, cursor + 1)
                let length = readU64(body, cursor + 9)
                cursor += 17
                
                guard offset + length <= baseSize else { throw BundleDeltaError.baseTooShort(offset: offset, length: length, size: baseSize) }
                baseHandle.seek(toFileOffset: offset)
                let chunk = baseHandle.readData(ofLength: Int(length))
                guard chunk.count == length else { throw BundleDeltaError.truncated }
                
                out.write(chunk)
                digest.update(data: chunk)
                produced += length
            }
            else
            {
                let length = Int(readU64(body, cursor + 1))
                cursor += 9
                
                guard literalAt + length <= body.count else { throw BundleDeltaError.truncated }
                let chunk = body[literalAt..<(literalAt + length)]
                literalAt += length
                
                out.write(Data(chunk))
                digest.update(data: chunk)
                produced += UInt64(length)
            }
        }
        
        guard produced == targetLength else { throw BundleDeltaError.shortReassembly(produced: produced, expected: targetLength) }
        let actualSHA = hex(Data(digest.finalize()))
        guard actualSHA == hex(Data(targetSHA)) else { throw BundleDeltaError.shaMismatch(expected: hex(Data(targetSHA)), actual: actualSHA) }
        try? out.close()
        
        let bundle = try unpackASBU(at: staging, into: directory, expectingBundleID: bundleID, expectingVersion: version)
        try? fm.removeItem(at: staging)
        return bundle
    }
    
    //MARK: - unpack
    
    @discardableResult
    static func unpackASBU(at stream: URL, into directory: URL, expectingBundleID bundleID: String,
                           expectingVersion version: String?) throws -> URL
    {
        let fm = FileManager.default
        guard let handle = FileHandle(forReadingAtPath: stream.path) else { throw BundleDeltaError.truncated }
        defer { try? handle.close() }
        
        let header = handle.readData(ofLength: asbuHeaderSize)
        guard header.count == asbuHeaderSize, Array(header.prefix(4)) == asbuMagic else { throw BundleDeltaError.badMagic("not ASBU") }
        guard header[4] == asbuVersion else { throw BundleDeltaError.badMagic("unsupported ASBU version \(header[4])") }
        let entryCount = Int(readU64(header, 5))
        
        let bundleDirectory = directory.appendingPathComponent("SideStore.app")
        try? fm.removeItem(at: bundleDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        
        for _ in 0..<entryCount
        {
            let entryHeader = handle.readData(ofLength: entryHeaderSize)
            guard entryHeader.count == entryHeaderSize else { throw BundleDeltaError.truncated }
            guard let kind = Kind(rawValue: entryHeader[0]) else { throw BundleDeltaError.badMagic("unknown entry kind \(entryHeader[0])") }
            
            let pathLength = Int(entryHeader[1]) | (Int(entryHeader[2]) << 8)
            let executable = entryHeader[3] != 0
            let size = Int(readU64(entryHeader, 4))
            
            let pathData = handle.readData(ofLength: pathLength)
            guard pathData.count == pathLength, let relative = String(data: pathData, encoding: .utf8) else { throw BundleDeltaError.truncated }
            let content = size > 0 ? handle.readData(ofLength: size) : Data()
            guard content.count == size else { throw BundleDeltaError.truncated }
            
            let url = bundleDirectory.appendingPathComponent(relative)
            switch kind
            {
            case .directory:
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case .symlink:
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: String(decoding: content, as: UTF8.self)))
            case .file:
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = fm.createFile(atPath: url.path, contents: content)
                // 0755 where the source had any execute bit, 0644 elsewhere -- the same rule the
                // pack side derived, and what the installer needs for the main executable and dylibs.
                try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
        }
        
        guard let plist = FileManager.default.contents(atPath: bundleDirectory.appendingPathComponent("Info.plist").path),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            throw BundleDeltaError.identity("Info.plist is missing or unreadable")
        }
        guard (info["CFBundleIdentifier"] as? String) == bundleID else {
            throw BundleDeltaError.identity("bundle id is \(info["CFBundleIdentifier"] ?? "nil"), expected \(bundleID)")
        }
        if let version
        {
            // The feed's version string is the only thing tying these bytes to what the source
            // announced, since there is no ipa whose hash can be compared any more.
            guard (info["CFBundleShortVersionString"] as? String) == version else {
                throw BundleDeltaError.identity("version is \(info["CFBundleShortVersionString"] ?? "nil"), expected \(version)")
            }
        }
        return bundleDirectory
    }
    
    //MARK: - helpers
    
    /// Below this size a patch cannot even hold a header plus one instruction.
    private static let littleEndianThreshold = patchHeaderSize + 16
    
    private static func littleEndian(_ value: UInt64) -> Data
    {
        Data((0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) })
    }
    
    private static func readU64(_ data: Data, _ at: Int) -> UInt64
    {
        var value: UInt64 = 0
        for byte in 0..<8 { value |= UInt64(data[data.startIndex + at + byte]) << (8 * UInt64(byte)) }
        return value
    }
    
    private static func sha256(of url: URL) -> Data
    {
        var digest = SHA256()
        if let handle = FileHandle(forReadingAtPath: url.path)
        {
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { digest.update(data: chunk) }
        }
        return Data(digest.finalize())
    }
    
    private static func hex(_ data: Data) -> String
    {
        data.map { String(format: "%02x", $0) }.joined()
    }
    
    private static func inflate(_ source: [UInt8], toSize destinationSize: Int) throws -> Data
    {
        guard destinationSize > 0, let pointer = malloc(destinationSize) else { throw BundleDeltaError.inflateFailed }
        defer { free(pointer) }
        
        let written = source.withUnsafeBytes { sourceRaw -> Int in
            guard let base = sourceRaw.baseAddress else { return 0 }
            return compression_decode_buffer(pointer.assumingMemoryBound(to: UInt8.self), destinationSize,
                                             base.assumingMemoryBound(to: UInt8.self), source.count,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written == destinationSize else { throw BundleDeltaError.inflateFailed }
        return Data(bytes: pointer, count: destinationSize)
    }
}
