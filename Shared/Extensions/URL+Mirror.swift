//
//  URL+Mirror.swift
//  Shared
//

import Foundation

public extension URL
{
    /// The same file served through jsDelivr instead of GitHub.
    ///
    /// raw.githubusercontent is blocked or crawling on a lot of the networks this app is used on,
    /// and sources point every icon, screenshot and header at it. jsDelivr serves the identical
    /// file from edge nodes. `github.com/.../raw/...` is the same file behind another host, so it
    /// is rewritten too. Release assets and other hosts are left alone: jsDelivr does not proxy
    /// release assets, and its GitHub file limit is 20 MB.
    var mirroredThroughCDN: URL
    {
        let host = self.host?.lowercased()

        if host == "raw.githubusercontent.com"
        {
            // /OWNER/REPO/REF/PATH...  ->  cdn.jsdelivr.net/gh/OWNER/REPO@REF/PATH...
            // A branch name containing a slash cannot be told apart from the path, so those
            // resolve to a URL that 404s and the caller keeps whatever it had.
            let components = self.pathComponents.filter { $0 != "/" }
            guard components.count >= 4 else { return self }
            return Self.jsDelivrURL(owner: components[0], repo: components[1], ref: components[2], path: components[3...]) ?? self
        }

        if host == "github.com"
        {
            // /OWNER/REPO/raw/REF/PATH...  ->  cdn.jsdelivr.net/gh/OWNER/REPO@REF/PATH...
            let components = self.pathComponents.filter { $0 != "/" }
            guard components.count >= 5, components[2].lowercased() == "raw" else { return self }
            return Self.jsDelivrURL(owner: components[0], repo: components[1], ref: components[3], path: components[4...]) ?? self
        }

        return self
    }

    /// The same file through AirStore's own Cloudflare Worker.
    ///
    /// This is the first route for everything the app fetches from GitHub: it answers `no-store`, so
    /// the feed is never older than the branch, and it is a domain the project controls rather than a
    /// third-party proxy somebody else can throttle or take down. `release assets` map to `/dl/...`
    /// and raw files to `/gh/...`; the Worker only proxies this repository, so anything else stays on
    /// the ordinary path.
    var airstoreMirrorURL: URL?
    {
        guard let host = self.host?.lowercased() else { return nil }

        // /OWNER/REPO/releases/download/TAG/FILE  ->  /dl/OWNER/REPO/TAG/FILE
        if host == "github.com", self.path.contains("/releases/download/")
        {
            let components = self.pathComponents.filter { $0 != "/" }
            guard components.count >= 6, components[2] == "releases", components[3] == "download" else { return nil }
            return Self.mirrorURL(path: "/dl/\(components[0])/\(components[1])/\(components[4])/" + components[5...].joined(separator: "/"))
        }

        // /OWNER/REPO/REF/PATH...  ->  /gh/OWNER/REPO@REF/PATH...
        if host == "raw.githubusercontent.com"
        {
            let components = self.pathComponents.filter { $0 != "/" }
            guard components.count >= 4 else { return nil }
            return Self.mirrorURL(path: "/gh/\(components[0])/\(components[1])@\(components[2])/" + components[3...].joined(separator: "/"))
        }

        // /OWNER/REPO/raw/REF/PATH...  ->  /gh/OWNER/REPO@REF/PATH...
        if host == "github.com"
        {
            let components = self.pathComponents.filter { $0 != "/" }
            guard components.count >= 5, components[2].lowercased() == "raw" else { return nil }
            return Self.mirrorURL(path: "/gh/\(components[0])/\(components[1])@\(components[3])/" + components[4...].joined(separator: "/"))
        }

        return nil
    }

    private static func mirrorURL(path: String) -> URL?
    {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "as.mz0520.de5.net"
        components.path = path
        return components.url
    }

    /// The GitHub URL a Worker URL was built from. Nil for anything that is not one of ours.
    ///
    /// The Worker is the preferred route, not the only one: a bad deploy or a blocked domain must not
    /// leave the app unable to read its own feed. Turning the mirror URL back into the origin URL is
    /// what lets `downloadCandidates` fall through to GitHub and the public proxies.
    var mirroredOriginURL: URL?
    {
        guard self.host?.lowercased() == "as.mz0520.de5.net" else { return nil }

        let components = self.pathComponents.filter { $0 != "/" }

        if self.path == "/source/airstore-source.json" || self.path == "/airstore-source.json"
        {
            return URL(string: "https://raw.githubusercontent.com/\(Self.mirroredRepository)/develop-source/source/airstore-source.json")
        }

        if self.path == "/source/default-sources.json" || self.path == "/default-sources.json"
        {
            return URL(string: "https://raw.githubusercontent.com/\(Self.mirroredRepository)/develop/source/default-sources.json")
        }

        // /gh/OWNER/REPO@REF/PATH...
        if components.count >= 4, components[0] == "gh"
        {
            let owner = components[1]
            let repoAndRef = components[2].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard repoAndRef.count == 2 else { return nil }
            return Self.url(host: "raw.githubusercontent.com",
                            path: "/\(owner)/\(repoAndRef[0])/\(repoAndRef[1])/" + components[3...].joined(separator: "/"))
        }

        // /dl/OWNER/REPO/TAG/FILE...
        if components.count >= 5, components[0] == "dl"
        {
            return Self.url(host: "github.com",
                            path: "/\(components[1])/\(components[2])/releases/download/\(components[3])/" + components[4...].joined(separator: "/"))
        }

        return nil
    }

    /// The repository the Worker is allowed to proxy. Kept here so the reverse mapping and the feed
    /// URL cannot drift apart.
    private static let mirroredRepository = "JiangWanZhengChouYv/AirStore"

    private static func url(host: String, path: String) -> URL?
    {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        return components.url
    }

    /// gh-proxy.com's wrapper for any GitHub file.
    var githubProxyURL: URL?
    {
        guard let host = self.host?.lowercased(),
              ["github.com", "raw.githubusercontent.com", "codeload.github.com"].contains(host) else { return nil }
        return URL(string: "https://gh-proxy.com/" + self.absoluteString)
    }

    /// The same release asset published to this repository's GitHub Pages site.
    ///
    /// CI mirrors every develop package and patch onto the `pages` branch, flat by file name, so the
    /// version carried in the name is what keeps two builds apart. This is the only route that is
    /// neither GitHub's own origin nor a third-party proxy someone else has to keep alive.
    /// `github.com/OWNER/REPO/releases/download/TAG/FILE` -> `OWNER.github.io/REPO/FILE`.
    var pagesURL: URL?
    {
        guard self.host?.lowercased() == "github.com",
              let range = self.path.range(of: "/releases/download/") else { return nil }

        let head = self.path[..<range.lowerBound].split(separator: "/").filter { $0.isEmpty == false }
        let tail = self.path[range.upperBound...].split(separator: "/").filter { $0.isEmpty == false }
        guard head.count == 2, let name = tail.last, name.isEmpty == false, name.contains(".") else { return nil }

        var pages = URLComponents()
        pages.scheme = "https"
        // Hosts are case-insensitive but the owner is written with capitals in the remote URL, and a
        // mixed-case host in a URL nobody can read off a log is its own little bug. The repository
        // part stays as written: paths are case-sensitive.
        pages.host = "\(head[0].lowercased()).github.io"
        pages.path = "/\(head[1])/\(name)"
        return pages.url
    }

    /// Public mirrors of github.com, best first.
    ///
    /// jsDelivr refuses release assets (its GitHub file limit is 20 MB; this asset is 28 MB), so
    /// these are the routes the update actually has. Measured 2026-10-24 against the whole develop
    /// asset: gh-proxy.com 5.2 MB/s, ghfast.top 1.5 MB/s, ghproxy.net 0.09 MB/s (still 20 MB short
    /// after 90 s). The origin answered an 8 MB range at 4-5 MB/s but dropped a full attempt, and
    /// did not connect at all without a proxy on that line.
    private static let releaseMirrors = [
        "https://gh-proxy.com/"
    ]

    /// Tried only after the origin: alive, but measured slower than going straight to GitHub.
    private static let lastResortReleaseMirrors = [
        "https://ghfast.top/",
        "https://ghproxy.net/"
    ]

    /// Every route worth trying for a downloadable GitHub file, best first.
    ///
    /// AirStore's own Worker goes first everywhere it can: it is the only route that is neither
    /// GitHub's origin nor somebody else's proxy, and it never serves a cached feed. The public
    /// GitHub proxies stay behind it because the Worker itself is a single point of failure, and the
    /// Pages copy stays at the end for the day every proxy is down.
    var downloadCandidates: [URL]
    {
        guard let host = self.host?.lowercased() else { return [self] }

        if host == "as.mz0520.de5.net", let origin = self.mirroredOriginURL
        {
            // Worker first, then whatever the origin URL would have tried on its own. The Worker
            // appears again inside that list and `distinct` drops it, so the order stays self-first.
            return Self.distinct([self] + origin.downloadCandidates)
        }

        if host == "github.com", self.path.contains("/releases/download/")
        {
            let primary = URL.releaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
            let lastResort = URL.lastResortReleaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
            // Pages was tried first for a day and measured 31 KB/s for an 8 MB range on the
            // maintainer's line -- slower than the origin's 40 KB/s, and nowhere near what the same
            // file does through a proxy (3 MB/s). It stays at the end as another fallback rather
            // than as a speed play: when every proxy is down, the site still has the file.
            return Self.distinct([self.airstoreMirrorURL] + primary + [self] + lastResort + [self.pagesURL])
        }

        if host == "raw.githubusercontent.com" || (host == "github.com" && self.path.contains("/raw/"))
        {
            let mirror = self.airstoreMirrorURL
            let proxy = self.githubProxyURL
            let cdn = self.mirroredThroughCDN
            let ghfast = URL(string: "https://ghfast.top/" + self.absoluteString)
            if self.pathExtension.lowercased() == "json" {
                // A source's JSON is the control plane, so it has to be correct before it is fast.
                // The Worker and the live pass-through proxies answer with the current file; jsDelivr
                // drops to a fallback because it was measured serving a feed two builds old more than
                // fifteen minutes after a purge that answered "finished", and it ignores cache-busting
                // query strings. Icons and screenshots keep it further up: a stale picture costs
                // nothing, a stale feed makes the app swear there is no update.
                return Self.distinct([mirror, proxy, ghfast, cdn, self])
            }
            if self.pathExtension.lowercased() == "ipa" {
                return Self.distinct([mirror, proxy, cdn, self])
            }
            return Self.distinct([mirror, cdn, proxy, self])
        }

        if host == "codeload.github.com" || (host == "github.com" && self.path.contains("/archive/"))
        {
            return Self.distinct([self.githubProxyURL, self])
        }

        return [self]
    }

    private static func jsDelivrURL(owner: String, repo: String, ref: String, path: ArraySlice<String>) -> URL?
    {
        var mirror = URLComponents()
        mirror.scheme = "https"
        mirror.host = "cdn.jsdelivr.net"
        mirror.path = "/gh/\(owner)/\(repo)@\(ref)/" + path.joined(separator: "/")
        return mirror.url
    }

    private static func distinct(_ urls: [URL?]) -> [URL]
    {
        var seen = Set<String>()
        return urls.compactMap { $0 }.filter { seen.insert($0.absoluteString).inserted }
    }
}
