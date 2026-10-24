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

    /// Public mirrors of github.com, in the order worth trying.
    ///
    /// jsDelivr refuses release assets, and release assets are what the app update actually
    /// downloads -- 28 MB from objects.githubusercontent.com, which on many networks never finishes.
    /// Measured from such a network: ghproxy.net answers in seconds, gh-proxy.com is slow but alive,
    /// ghfast.top was unreachable, and the origin itself did not connect at all.
    private static let releaseMirrors = [
        "https://ghproxy.net/",
        "https://gh-proxy.com/",
        "https://ghfast.top/"
    ]

    /// The same release asset through each mirror, best first, ending with the original URL so a
    /// network that reaches GitHub directly still works.
    var releaseDownloadCandidates: [URL]
    {
        guard self.host?.lowercased() == "github.com", self.path.contains("/releases/download/") else {
            return [self]
        }

        let mirrored = URL.releaseMirrors.compactMap { URL(string: $0 + self.absoluteString) }
        return mirrored + [self]
    }
}
