//
//  AirBoxLogRouter.swift
//  AirStore
//
//  AirBox and the extension it starts a guest in are separate processes, each with a container of its
//  own, so nothing they print can reach this app's console file by itself. Both append to one file in
//  the group all three share. This reads back only what is new and puts it through the store's own
//  logger with [AirBox] in front, which is what makes a single exported log cover the whole chain: the
//  hand-over here, the store's own signing lines, and the engine's output from inside the extension.
//

import Foundation

enum AirBoxLogRouter
{
    /// Past this size the shared file is emptied after a read. What was in it is already in the store's
    /// own log by then. A line written between the read and the emptying is lost, which for a log is an
    /// acceptable trade against the file never being bounded.
    private static let sizeLimit = 1_048_576

    private static let offsetKey = "AirBoxLogReadOffset"
    private static var timer: Timer?

    static func start()
    {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in drain() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func drain()
    {
        guard let directory = FileManager.default.altstoreSharedDirectory else { return }
        let url = directory.appendingPathComponent("airbox.log")
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? FileHandle(forUpdating: url) else { return }
        defer { try? file.close() }

        let fd = file.fileDescriptor
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        let size = Int(file.seekToEndOfFile())
        let readOffset = min(max(0, UserDefaults.standard.integer(forKey: offsetKey)), size)
        guard size > readOffset else { return }

        try? file.seek(toOffset: UInt64(readOffset))
        guard let data = try? file.readToEnd(), !data.isEmpty else { return }

        // Stop at the last whole line: a writer caught mid-append would otherwise be routed as two.
        guard let boundary = data.lastIndex(of: 0x0A) else { return }
        let consumed = data.subdata(in: data.startIndex..<(boundary + 1))
        UserDefaults.standard.set(readOffset + consumed.count, forKey: offsetKey)

        for line in String(decoding: consumed, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            debugLog("[AirBox] \(text)")
        }

        if size > Self.sizeLimit
        {
            try? file.truncate(atOffset: 0)
            UserDefaults.standard.set(0, forKey: offsetKey)
        }
    }
}
