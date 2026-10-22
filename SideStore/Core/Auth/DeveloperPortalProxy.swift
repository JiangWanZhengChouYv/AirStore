//
//  DeveloperPortalProxy.swift
//  SideStore
//
//  Created by Magesh K on 2026-06-29.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import SideSign

public class DeveloperPortalProxy {
    public static let shared: DeveloperPortalProxy = DeveloperPortalProxyWithAuth()
    
    public static var currentDeviceType: ALTDeviceType {
        #if os(tvOS)
        return .tv
        #elseif os(visionOS)
        return .vision
        #elseif os(watchOS)
        return .watch
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #endif
    }
    
    fileprivate init() {}
    
    private func getSession() async throws -> ALTAppleAPISession {
        try await AuthManager.shared.getAuthenticatedSession()
    }

    /// Apple expires a free personal account's developer portal session within minutes. Renew it
    /// from the credentials already in the keychain and run the operation once more; the second
    /// attempt reads the new token through getSession(), so a caller never has to know the first
    /// one died. Without this, a background refresh that hits the expiry fails and tells the user
    /// to sign in again, which is not something they can act on at 3am.
    fileprivate func retryingOnExpiredSession<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as DeveloperPortalError {
            guard case .sessionExpired = error else { throw error }

            guard AuthManager.shared.hasStoredPassword else {
                debugLog("[DeveloperPortalProxy] Portal session expired and no password is stored to renew with.")
                throw error
            }

            debugLog("[DeveloperPortalProxy] Portal session expired, renewing and replaying once.")
            try await AuthManager.shared.renewPortalSession()
            return try await operation()
        }
    }

    private func getTeam(_ team: ALTTeam? = nil) async throws -> ALTTeam {
        if let team { return team }
        return try await AuthManager.shared.getAuthenticatedTeam()
    }
    
    public func fetchTeams(for account: ALTAccount) async throws -> [ALTTeam] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            return try await ALTAppleAPI.shared.fetchTeams(for: account, session: session)
        }
    }
    
    public func fetchCertificates(team: ALTTeam? = nil) async throws -> [ALTX509Certificate] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.fetchCertificates(for: team, session: session)
        }
    }
    
    @discardableResult
    public func createCertificate(machineName: String, type: CertificateType = .development, team: ALTTeam? = nil) async throws -> ALTCertificate {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.addCertificate(machineName: machineName, type: type, to: team, session: session)
        }
    }
    
    @discardableResult
    public func revokeCertificate(_ certificate: ALTX509Certificate, team: ALTTeam? = nil) async throws -> Bool {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.revokeCertificate(certificate, for: team, session: session)
        }
    }
    
    public func fetchDevices(for team: ALTTeam? = nil, types: ALTDeviceType = .all) async throws -> [ALTDevice] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.fetchDevices(for: team, types: types, session: session)
        }
    }
    
    @discardableResult
    public func registerDevice(name: String, identifier: String, type: ALTDeviceType = DeveloperPortalProxy.currentDeviceType, team: ALTTeam? = nil) async throws -> ALTDevice {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.registerDevice(name: name, identifier: identifier, type: type, team: team, session: session)
        }
    }

    @discardableResult
    public func updateDevice(_ device: ALTDevice, team: ALTTeam? = nil) async throws -> ALTDevice {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.updateDevice(device, team: team, session: session)
        }
    }

    @discardableResult
    public func disableDevice(_ device: ALTDevice, team: ALTTeam? = nil) async throws -> ALTDevice {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.disableDevice(device, team: team, session: session)
        }
    }

    @discardableResult
    public func deleteDevice(_ device: ALTDevice, team: ALTTeam? = nil) async throws -> Bool {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.deleteDevice(device, team: team, session: session)
        }
    }

    public func fetchAppIDs(team: ALTTeam? = nil) async throws -> [ALTAppID] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.fetchAppIDs(for: team, session: session)
        }
    }

    public func fetchAppIDs(for team: ALTTeam) async throws -> [ALTAppID] {
        try await self.fetchAppIDs(team: team)
    }

    @discardableResult
    public func addAppID(name: String, bundleIdentifier: String, team: ALTTeam? = nil) async throws -> ALTAppID {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.addAppID(withName: name, bundleIdentifier: bundleIdentifier, team: team, session: session)
        }
    }

    @discardableResult
    public func updateAppID(_ appID: ALTAppID, team: ALTTeam? = nil) async throws -> ALTAppID {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.updateAppID(appID, team: team, session: session)
        }
    }

    /// What this team may switch on for an App ID. Apple's own answer, so nothing here is guessed.
    public func fetchCapabilities(team: ALTTeam? = nil) async throws -> [DeveloperCapability] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.fetchCapabilities(for: team, session: session)
        }
    }

    @discardableResult
    public func setBundleIDCapabilities(_ capabilityIDs: [String], for appID: ALTAppID, team: ALTTeam? = nil) async throws -> Bool {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            try await ALTAppleAPI.shared.setBundleIDCapabilities(capabilityIDs, for: appID, team: team, session: session)
            return true
        }
    }

    @discardableResult
    public func deleteAppID(_ appID: ALTAppID, team: ALTTeam? = nil) async throws -> Bool {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.deleteAppID(appID, for: team, session: session)
        }
    }

    @discardableResult
    public func deleteAppID(_ appID: ALTAppID, for team: ALTTeam) async throws -> Bool {
        try await self.deleteAppID(appID, team: team)
    }

    public func fetchAppGroups(team: ALTTeam? = nil) async throws -> [ALTAppGroup] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.fetchAppGroups(for: team, session: session)
        }
    }

    public func fetchAppGroups(for team: ALTTeam) async throws -> [ALTAppGroup] {
        try await self.fetchAppGroups(team: team)
    }

    @discardableResult
    public func addAppGroup(name: String, groupIdentifier: String, team: ALTTeam? = nil) async throws -> ALTAppGroup {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.addAppGroup(name: name, groupIdentifier: groupIdentifier, team: team, session: session)
        }
    }

    @discardableResult
    public func updateAppGroup(_ group: ALTAppGroup, team: ALTTeam? = nil) async throws -> ALTAppGroup {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.updateAppGroup(group, team: team, session: session)
        }
    }

    @discardableResult
    public func assignAppID(_ appID: ALTAppID, to groups: [ALTAppGroup], team: ALTTeam? = nil) async throws -> ALTAppID {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.assign(appID, to: groups, team: team, session: session)
        }
    }

    @discardableResult
    public func assign(_ appID: ALTAppID, to groups: [ALTAppGroup], team: ALTTeam? = nil) async throws -> ALTAppID {
        try await self.assignAppID(appID, to: groups, team: team)
    }

    @discardableResult
    public func deleteAppGroup(_ group: ALTAppGroup, team: ALTTeam? = nil) async throws -> Bool {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.deleteAppGroup(group, team: team, session: session)
        }
    }

    public func listProvisioningProfiles(includeTeamProfiles: Bool = true, team: ALTTeam? = nil) async throws -> [ALTListedProvisioningProfile] {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.listProvisioningProfiles(includeTeamProfiles: includeTeamProfiles, for: team, session: session)
        }
    }

    public func downloadProvisioningProfile(for appID: ALTAppID, isTeamProfile: Bool = true, deviceType: ALTDeviceType = DeveloperPortalProxy.currentDeviceType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.downloadProvisioningProfile(for: appID, isTeamProfile: isTeamProfile, deviceType: deviceType, team: team, session: session)
        }
    }

    public func downloadProvisioningProfile(for appID: ALTAppID, isTeamProfile: Bool = true, type: ALTProfileType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.downloadProvisioningProfile(for: appID, isTeamProfile: isTeamProfile, type: type, team: team, session: session)
        }
    }

    public func downloadProvisioningProfile(profileID: String, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.downloadProvisioningProfile(profileID: profileID, team: team, session: session)
        }
    }

    public func createProvisioningProfile(name: String, appID: ALTAppID, certificateIDs: [String], deviceIDs: [String], team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            #if os(tvOS)
            let subPlatform: String? = "tvOS"
            #else
            let subPlatform: String? = nil
            #endif
            return try await ALTAppleAPI.shared.createProvisioningProfile(name: name, appID: appID, certificateIDs: certificateIDs, deviceIDs: deviceIDs, subPlatform: subPlatform, team: team, session: session)
        }
    }

    public func createProvisioningProfile(name: String, appID: ALTAppID, certificateIDs: [String], deviceIDs: [String] = [], type: ALTProfileType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.createProvisioningProfile(name: name, appID: appID, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team, session: session)
        }
    }

    public func updateProvisioningProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            #if os(tvOS)
            let subPlatform: String? = "tvOS"
            #else
            let subPlatform: String? = nil
            #endif
            return try await ALTAppleAPI.shared.updateProvisioningProfile(profileID: profileID, name: name, appIDId: appIDId, certificateIDs: certificateIDs, deviceIDs: deviceIDs, subPlatform: subPlatform, team: team, session: session)
        }
    }

    public func updateProvisioningProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String] = [], type: ALTProfileType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.updateProvisioningProfile(profileID: profileID, name: name, appIDId: appIDId, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team, session: session)
        }
    }

    @discardableResult
    public func deleteProvisioningProfile(profileID: String, team: ALTTeam? = nil) async throws -> Bool {
        try await retryingOnExpiredSession {
            let session = try await self.getSession()
            let team = try await self.getTeam(team)
            return try await ALTAppleAPI.shared.deleteProvisioningProfile(profileID: profileID, team: team, session: session)
        }
    }
}

class DeveloperPortalProxyWithAuth: DeveloperPortalProxy {
    fileprivate override init() {
        super.init()
    }

    func fetchAccount(session: ALTAppleAPISession) async throws -> ALTAccount {
        try await ALTAppleAPI.shared.fetchAccount(session: session)
    }

    func signIn(appleID: String, 
                password: String, 
                anisetteData: ALTAnisetteData, 
                xcodeVersion: String, 
                machinePassword: String? = nil,
                accountRepairHandler: DeveloperPortal.AccountRepairHandler = DeveloperPortal.defaultAccountRepairHandler,
                verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> (ALTAccount, ALTAppleAPISession) 
    {
        ALTAppleAPI.shared.anisetteResyncHandler = { sim in
            try await SideSign.AnisetteDataManager.shared.resyncHeaders(sim: sim)
        }
        ALTAppleAPI.shared.anisetteDataRefreshHandler = {
            do {
                return try await SideSign.AnisetteDataManager.shared.refreshHeaders()
            } catch {
                // On-device anisette has no server to re-mint from, so regenerate locally.
                return try await AnisetteProvider.fetch()
            }
        }

        let authSession = try await ALTAppleAPI.shared.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteData,
            xcodeVersion: xcodeVersion,
            machinePassword: machinePassword,
            accountRepairHandler: accountRepairHandler,
            verificationHandler: verificationHandler
        )
        return (authSession.account, authSession.session)
    }
}
