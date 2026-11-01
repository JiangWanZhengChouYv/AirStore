//
//  AirBoxLogging.swift
//  AirBox
//
//  The store cannot see anything this app prints: it is a second app with a second container. So what
//  matters goes into one file in the group the store, this box and the extension share, and the store
//  reads back whatever is new and routes it into its own console log with [AirBox] in front of every
//  line (SideStore/Utils/iostreams/AirBoxLogRouter.swift). The extension writes into the same file by
//  handing it its stderr, which is how the engine's own output reaches the log too -- those lines carry
//  no timestamp of their own, so these do.
//

import Foundation

enum AirBoxLogging
{
    private static let lock = NSLock()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    /// The group's own defaults. A request is how a guest is normally asked for; this is where the same
    /// information goes so the extension can still find it if the request never reaches it.
    static var sharedDefaults: UserDefaults?
    {
        guard let group = LCSharedUtils.appGroupID(), !group.isEmpty, group != "Unknown" else { return nil }
        return UserDefaults(suiteName: group)
    }

    /// The file all three write into, named the way the store's router expects it.
    static var fileURL: URL?
    {
        guard let group = LCSharedUtils.appGroupID(), !group.isEmpty, group != "Unknown",
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }

        return directory.appendingPathComponent("airbox.log")
    }

    static func log(_ message: String)
    {
        // The store puts [AirBox] in front of every line it routes, so this only adds the time: the
        // routed line is written up to two seconds after it happened.
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"

        guard let url = fileURL else
        {
            NSLog("%@", line.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if !FileManager.default.fileExists(atPath: url.path)
        {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }

        guard let file = try? FileHandle(forUpdating: url) else { return }
        defer { try? file.close() }

        let fd = file.fileDescriptor
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        file.seekToEndOfFile()
        file.write(Data(line.utf8))
    }
}
