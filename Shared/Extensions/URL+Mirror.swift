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
    /// Release assets go to this repository's Pages site first, then the measured proxies, then the
    /// origin. Raw files use jsDelivr first because it is the fast route for the small files sources
    /// normally point at; IPAs skip it because it refuses anything over 20 MB. Archives and other
    /// github.com downloads go straight through gh-proxy, then the origin.
    var downloadCandidates: [URL]
    {
        guard let host = self.host?.lowercased() else { return [self] }

        if host == "github.com", self.path.contains("/releases/download/")
        {
            let primary = URL.releaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
            let lastResort = URL.lastResortReleaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
            return Self.distinct([self.pagesURL] + primary + [self] + lastResort)
        }

        if host == "raw.githubusercontent.com" || (host == "github.com" && self.path.contains("/raw/"))
        {
            let cdn = self.mirroredThroughCDN
            let proxy = self.githubProxyURL
            if self.pathExtension.lowercased() == "ipa" {
                return Self.distinct([proxy, cdn, self])
            }
            return Self.distinct([cdn, proxy, self])
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
