//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        func attempt() async throws -> ALTAnisetteData {
            let provider = SideSign.AnisetteDataManager.shared
            let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
            let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
            let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

            // The rotation is driven here, not inside SideSign's failover: that helper throws only the
            // last error, so a run that timed out twice and ended on a 503 reported nothing but the
            // 503. Walking the list locally keeps every server's own error, and a pinned server
            // (rotation off) still hands its original error straight back.
            let orderedServers: [URL] = UserDefaults.standard.disableAnisetteRotation
                ? [servers[startIndex]]
                : Array(servers[startIndex...]) + Array(servers[..<startIndex])

            let onError: @Sendable (Error) async throws -> Bool = { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            }

            var failures: [(server: URL, error: Error)] = []
            for server in orderedServers {
                debugLog("[Anisette Failover] Attempting server [\(failures.count + 1)/\(orderedServers.count)]: \(server.absoluteString)...")
                do {
                    let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteData(
                        mode: .remote(server: server),
                        identifier: identifier,
                        existingAdiBlob: existingBlob,
                        headers: headers,
                        onError: onError
                    )

                    UserDefaults.standard.menuAnisetteURL = server.absoluteString
                    debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(server.absoluteString)")

                    if let freshBlob = newAdiBlob {
                        AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
                    }

                    return anisetteData
                } catch {
                    failures.append((server, error))
                    debugLog("[Anisette Failover] Server '\(server.absoluteString)' failed: \(error.localizedDescription)")
                }
            }

            if failures.count == 1, let failure = failures.first {
                throw failure.error
            }

            let details = failures
                .map { "• \($0.server.absoluteString) — \($0.error.localizedDescription)" }
                .joined(separator: "\n")
            throw OperationError.anisetteUnavailable(reason: details)
        }

        do {
            return try await attempt()
        } catch {
            // -45061 means the ADI identity in the Keychain was minted by a different server, and
            // every server now selected has its own. Dropping it makes the next attempt provision
            // a fresh machine against the current one. Needs proper testing.
            if error.localizedDescription.contains("-45061") {
                debugLog("[AnisetteProvider] Stored ADI identity is not valid for this server (-45061), provisioning a fresh one.")
                AnisetteConfigManager.shared.anisetteAdiBlob = nil
                AnisetteConfigManager.shared.anisetteIdentifier = nil
                return try await attempt()
            }
            
            // The rotation above already lists each server's own error; keep it rather than wrapping
            // it a second time. A bare URLSession failure still gets the friendly Anisette wording.
            if case OperationError.anisetteUnavailable = error { throw error }
            guard !(error is SideSign.AnisetteError) else { throw error }
            throw OperationError.anisetteUnavailable(reason: error.localizedDescription)
        }
    }
}
