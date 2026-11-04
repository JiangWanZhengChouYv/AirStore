//
//  MachOSignature.swift
//  AirStore
//
//  The container's guest signing is invisible from the outside: the bundle looks the same whether the
//  signer rewrote the signature or decided there was nothing to do. Hashing the signature blob itself
//  is the only cheap way to tell those two apart from the console log.
//

import Foundation
import CryptoKit

enum MachOSignature
{
    private static let codeSignatureCommand: UInt32 = 0x1D
    private static let machO64Magic: UInt32 = 0xFEEDFACF

    /// SHA-256 of the bytes the `LC_CODE_SIGNATURE` command points at, or nil when the file is not a
    /// thin 64-bit Mach-O or carries no signature at all.
    static func digest(ofExecutableAt url: URL) -> String?
    {
        guard let data = try? Data(contentsOf: url), data.count > 32 else { return nil }

        func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        // A fat binary would need a slice walk; a guest is one arm64 slice by the time it is signed.
        guard uint32(at: 0) == machO64Magic, let commandCount = uint32(at: 16) else { return nil }

        var offset = 32
        for _ in 0..<commandCount
        {
            guard let command = uint32(at: offset), let commandSize = uint32(at: offset + 4), commandSize >= 8 else { return nil }

            if command == codeSignatureCommand,
               let dataOffset = uint32(at: offset + 8),
               let dataSize = uint32(at: offset + 12)
            {
                let start = Int(dataOffset)
                let end = start + Int(dataSize)
                guard start >= 0, end <= data.count, end > start else { return nil }
                return SHA256.hash(data: data.subdata(in: start..<end)).map { String(format: "%02x", $0) }.joined()
            }

            offset += Int(commandSize)
        }

        return nil
    }

}
