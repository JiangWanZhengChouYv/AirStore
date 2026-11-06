//
//  LogRetention.swift
//  SideStore
//
//  Both log piles -- Documents/ConsoleLogs and Documents/WidgetLogs -- gain a file every rotation and
//  nothing has ever removed one, so a year of daily opens is a year of text files sitting in the one
//  place iOS counts against this app's own storage. Keep the newest few and drop the rest.
//
//  Deliberately silent: WidgetLogManager is compiled into the app *and* the widget extension, and the two
//  have different logging entry points. Callers that can log, report the count themselves.
//

import Foundation

enum LogRetention
{
    static let keep = 10

    @discardableResult
    static func prune(in directory: URL, named prefix: String) -> Int
    {
        let finder = FileManager.default
        guard let entries = try? finder.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: [.contentModificationDateKey],
                                                            options: [.skipsHiddenFiles]) else { return 0 }

        let logs = entries.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
        guard logs.count > keep else { return 0 }

        // Newest first, by when the writing stopped rather than by the name: the two piles stamp their
        // filenames in different formats, and a rotation that happens twice in one second would otherwise
        // tie.
        let sorted = logs.sorted { (left, right) in
            modified(left) > modified(right)
        }

        var removed = 0
        for stale in sorted.dropFirst(keep) where (try? finder.removeItem(at: stale)) != nil
        {
            removed += 1
        }
        return removed
    }

    private static func modified(_ url: URL) -> Date
    {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }
}
