//
//  URL+Mirror.swift
//  Shared
//

import Foundation

public extension URL
{
    /// The same file served through jsDelivr instead of raw.githubusercontent.
    ///
    /// That host is blocked or crawling on a lot of the networks this app is used on, and it is what
    /// every source's icons, screenshots and screenshots' thumbnails point at. jsDelivr serves the
    /// identical file from edge nodes, which is the difference between an icon appearing and a blank
    /// square. Only that one host is rewritten: release assets and third-party hosts are not
    /// something jsDelivr proxies, and anything it cannot serve is left exactly as it was.
    var mirroredThroughCDN: URL
    {
        guard self.host?.lowercased() == "raw.githubusercontent.com" else { return self }

        // /OWNER/REPO/REF/PATH...  ->  cdn.jsdelivr.net/gh/OWNER/REPO@REF/PATH...
        // A branch name containing a slash cannot be told apart from the path, so those resolve to
        // a URL that 404s and the caller keeps whatever it had.
        let components = self.pathComponents.filter { $0 != "/" }
        guard components.count >= 4 else { return self }

        var mirror = URLComponents()
        mirror.scheme = "https"
        mirror.host = "cdn.jsdelivr.net"
        mirror.path = "/gh/\(components[0])/\(components[1])@\(components[2])/" + components[3...].joined(separator: "/")
        return mirror.url ?? self
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

    /// The same release asset through each route, best first. The origin sits second because it
    /// was faster than the fallbacks whenever it answered; the last-resort mirrors end the list.
    var releaseDownloadCandidates: [URL]
    {
        guard self.host?.lowercased() == "github.com", self.path.contains("/releases/download/") else {
            return [self]
        }

        let mirrored = URL.releaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
        let lastResort = URL.lastResortReleaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
        return mirrored + [self] + lastResort
    }
}
