//
//  GitHub520Hosts.swift
//  SideStore
//
//  Fetches the host → IP list published by GitHub520, caches it, and feeds the loopback proxy.
//

import Foundation

final class GitHub520Hosts: @unchecked Sendable
{
    static let shared = GitHub520Hosts()

    private let defaults = UserDefaults.standard
    private let hostsKey = "io.airstore.github520.hosts"
    private let updatedAtKey = "io.airstore.github520.updatedAt"
    private let maximumAge: TimeInterval = 24 * 60 * 60

    private let sources = [
        "https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts",
        "https://gh-proxy.com/https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts",
        "https://raw.hellogithub.com/hosts"
    ]

    /// GitHub has moved release downloads from objects.githubusercontent.com to this host, which the
    /// GitHub520 list does not carry yet. The Fastly IP serves it and measured 1.9 MB/s here.
    private static let extraHosts = [
        "release-assets.githubusercontent.com": "185.199.109.133"
    ]

    private static func merging(_ fetched: [String: String]) -> [String: String]
    {
        // The published mapping wins when it has an entry for the same host.
        extraHosts.merging(fetched) { _, published in published }
    }

    private init() {}

    /// Called once at launch. Cached IPs start the proxy immediately; a stale or empty cache is
    /// refreshed in the background so the first download does not wait for it.
    func prepare()
    {
        let cached = self.defaults.dictionary(forKey: self.hostsKey) as? [String: String] ?? [:]
        let merged = GitHub520Hosts.merging(cached)
        if !merged.isEmpty
        {
            LocalGitHubProxy.shared.updateHosts(merged)
            debugLog("[GitHub520] Using \(merged.count) cached host mappings.")
        }

        let updatedAt = self.defaults.object(forKey: self.updatedAtKey) as? Date ?? .distantPast
        guard cached.isEmpty || Date().timeIntervalSince(updatedAt) > self.maximumAge else { return }

        Task.detached(priority: .utility) {
            await self.refresh()
        }
    }

    private func refresh() async
    {
        for source in self.sources
        {
            do
            {
                guard let url = URL(string: source) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData

                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { continue }

                let hosts = GitHub520Hosts.merging(GitHub520Hosts.parse(text))
                guard !hosts.isEmpty else { continue }

                self.defaults.set(hosts, forKey: self.hostsKey)
                self.defaults.set(Date(), forKey: self.updatedAtKey)
                LocalGitHubProxy.shared.updateHosts(hosts)
                debugLog("[GitHub520] Loaded \(hosts.count) host mappings from \(source).")
                return
            }
            catch
            {
                debugLog("[GitHub520] \(source) failed: \(error.localizedDescription)")
            }
        }
    }

    private static func parse(_ text: String) -> [String: String]
    {
        var result: [String: String] = [:]

        for line in text.split(whereSeparator: \.isNewline)
        {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { continue }

            let ip = fields[0]
            let host = fields[1].lowercased()

            let octets = ip.split(separator: ".")
            guard octets.count == 4, octets.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { continue }

            result[host] = ip
        }

        return result
    }
}
