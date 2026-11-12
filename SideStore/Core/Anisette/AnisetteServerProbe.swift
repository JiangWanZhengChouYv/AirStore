//
//  AnisetteServerProbe.swift
//  SideStore
//
//  A quick reachability check for each Anisette server. It is deliberately cheap (a HEAD with a
//  short timeout) and only answers "does this host answer at all?" -- a server that answers 404 is
//  still reachable, one that never answers or returns 5xx is not.
//
//  The results are shown as green/red dots in the servers list, and reused at sign-in so a server
//  that just timed out is tried last instead of making the login wait on it again.

import Foundation

final class AnisetteServerProbe: ObservableObject {
    static let shared = AnisetteServerProbe()

    enum Status: String, Sendable {
        case unknown
        case checking
        case reachable
        case unreachable

        var isReachable: Bool { self == .reachable }
    }

    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var isProbing = false

    private static let resultsKey = "anisetteProbeResults"
    private static let dateKey = "anisetteProbeDate"
    private static let maxResultAge: TimeInterval = 30 * 60

    private init() {
        self.statuses = Self.loadCachedStatuses()
    }

    func status(for address: String) -> Status {
        self.statuses[address] ?? .unknown
    }

    /// All servers are checked in parallel, so one dead host cannot hold up the whole list.
    @MainActor
    func probe(addresses: [String]) async {
        let unique = Array(NSOrderedSet(array: addresses)) as? [String] ?? []
        guard !unique.isEmpty, !self.isProbing else { return }

        self.isProbing = true
        defer { self.isProbing = false }

        for address in unique {
            self.statuses[address] = .checking
        }

        await withTaskGroup(of: (String, Status).self) { group in
            for address in unique {
                group.addTask {
                    (address, await Self.check(address))
                }
            }

            for await (address, status) in group {
                self.statuses[address] = status
            }
        }

        Self.save(self.statuses)
    }

    private static func check(_ address: String) async -> Status {
        guard let url = URL(string: address), let scheme = url.scheme, scheme.hasPrefix("http") else {
            return .unreachable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            // A 4xx still means the host answered; only 5xx and transport failures mean "can't use it".
            return http.statusCode < 500 ? .reachable : .unreachable
        } catch {
            return .unreachable
        }
    }

    // MARK: - Results shared with the sign-in path

    /// Known-good servers first, known-bad last, original order preserved within each group.
    /// Stale or missing results leave the caller's order untouched.
    static func prioritized(_ servers: [URL]) -> [URL] {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: #keyPath(UserDefaults.anisetteAutoProbeEnabled)) == nil
                || defaults.bool(forKey: #keyPath(UserDefaults.anisetteAutoProbeEnabled)),
              let results = defaults.dictionary(forKey: resultsKey) as? [String: Bool],
              let date = defaults.object(forKey: dateKey) as? Date,
              Date().timeIntervalSince(date) < maxResultAge else {
            return servers
        }

        let good = servers.filter { results[$0.absoluteString] != false }
        let bad = servers.filter { results[$0.absoluteString] == false }
        return good + bad
    }

    private static func loadCachedStatuses() -> [String: Status] {
        let defaults = UserDefaults.standard
        guard let results = defaults.dictionary(forKey: resultsKey) as? [String: Bool],
              let date = defaults.object(forKey: dateKey) as? Date,
              Date().timeIntervalSince(date) < maxResultAge else {
            return [:]
        }
        return results.mapValues { $0 ? .reachable : .unreachable }
    }

    private static func save(_ statuses: [String: Status]) {
        var results: [String: Bool] = [:]
        for (address, status) in statuses where status == .reachable || status == .unreachable {
            results[address] = status.isReachable
        }
        UserDefaults.standard.set(results, forKey: resultsKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }
}
