//
//  AuthManager.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign
import CoreData

/// The account *and the exact team* that installed the app being refreshed. An Apple ID can
/// belong to more than one team, and the provisioning profile has to come from the one that
/// actually signed the installed build.
public struct AuthAccountScope: Sendable {
    public let accountIdentifier: String
    public let teamIdentifier: String?

    public init(accountIdentifier: String, teamIdentifier: String?) {
        self.accountIdentifier = accountIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

/// Scopes every Developer Portal call made inside one app's pipeline to that app's owner.
/// Nil means "use the globally active account". A TaskLocal keeps the value per pipeline, so
/// concurrent refreshes of apps owned by different accounts cannot see each other's credentials,
/// and no global sign-in state is mutated.
public enum AuthAccountContext {
    @TaskLocal public static var scope: AuthAccountScope?
}

public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()
    
    private var portalProxy: DeveloperPortalProxyWithAuth {
        // The auth-aware subclass is installed over DeveloperPortalProxy.shared during boot, and every
        // call here needs it. There is no fallback that means anything -- without a proxy no sign-in
        // can proceed -- so this names what is actually in place instead of leaving a bare cast to
        // fail later inside whichever auth call touched it first.
        guard let proxy = DeveloperPortalProxy.shared as? DeveloperPortalProxyWithAuth else {
            fatalError("AuthManager needs DeveloperPortalProxy.shared to be DeveloperPortalProxyWithAuth, but it is \(type(of: DeveloperPortalProxy.shared)). The auth wrapper was never installed.")
        }
        return proxy
    }
    
    private init() {}
    
    // There is deliberately no global portal session any more. Every call rebuilds it from the
    // keychain for the account it is working for (see `AuthAccountContext`), and `TaskChainCoalescer`
    // keys the in-flight build by that account -- so two accounts can sign in, install and refresh at
    // the same time without one of them overwriting the other's token.

    public var isAuthenticated: Bool {
        let hasEmail = Keychain.shared.appleIDEmailAddress != nil
        let hasPassword = Keychain.shared.appleIDPassword != nil
        let hasToken = Keychain.shared.appleIDXcodeToken != nil
        return hasEmail && (hasPassword || hasToken)
    }
    
    public var currentAppleID: String? {
        get { Keychain.shared.appleIDEmailAddress }
        set { Keychain.shared.appleIDEmailAddress = newValue }
    }
    
    public var password: String? {
        get { Keychain.shared.appleIDPassword }
        set { Keychain.shared.appleIDPassword = newValue }
    }
    
    public var adsid: String? {
        get { Keychain.shared.appleIDAdsid }
        set { Keychain.shared.appleIDAdsid = newValue }
    }
    
    public var xcodeToken: String? {
        get { Keychain.shared.appleIDXcodeToken }
        set { Keychain.shared.appleIDXcodeToken = newValue }
    }
    
    public var hasStoredPassword: Bool {
        if let identifier = AuthAccountContext.scope?.accountIdentifier {
            return Keychain.shared.credential(.password, forAccount: identifier) != nil
        }
        return Keychain.shared.appleIDPassword != nil
    }
    
    public var hasStoredXcodeToken: Bool {
        return Keychain.shared.appleIDXcodeToken != nil
    }
    
    public func signOut(
        keepCertificate: Bool = false,
        keepAnisetteData: Bool = true,
        keepAnisetteHeaders: Bool = true,
        keepSideSignHeaders: Bool = true
    ) async {
        if !keepCertificate {
            debugLog("[AuthManager] Clearing signing certificate in cert manager and keychain.")
            CertificateManager.shared.clearActiveCertificate()
            debugLog("[AuthManager] Cleared signing certificate in cert manager and keychain.")

        } else {
            debugLog("[AuthManager] Preserved signing certificate in cert manager and keychain.")
        }
        debugLog("[AuthManager] Clearing account and team info in database.")
        await DatabaseManager.shared.deactivateActiveAccountAndTeam()
        debugLog("[AuthManager] Cleared account and team info in database.")

        debugLog("[AuthManager] Clearing sign-in info from keychain.")
        Keychain.shared.clearSignInInfo(keepAnisetteData: keepAnisetteData)
        debugLog("[AuthManager] Cleared sign-in info from keychain.")

        if !keepAnisetteHeaders {
            debugLog("[AuthManager] Resetting Anisette header customizations to defaults.")
            AnisetteConfigManager.shared.resetToDefaults()
        }

        if !keepSideSignHeaders {
            debugLog("[AuthManager] Resetting SideSign header customizations to defaults.")
            SideSignConfigManager.shared.resetToDefaults()
        }

        AnisetteDataManager.shared.clearCache()
    }
    
    /// Make another saved Apple ID the active one. Only the two places that say "who am I" change:
    /// the Core Data active account/team flags and the keychain scope. Nothing is signed out,
    /// nothing is re-signed, and no credentials are deleted -- every other account keeps its own
    /// credentials, certificate and session, which is what lets them refresh in parallel.
    /// This only decides the default for a new install and what Settings shows.
    public func switchAccount(to identifier: String) async throws
    {
        guard Keychain.shared.accountsWithCredentials(from: [identifier]).contains(identifier) else {
            throw AccountSwitchError.missingCredentials
        }

        try await DatabaseManager.shared.activateAccount(identifier: identifier)
        Keychain.shared.accountScope = identifier
        debugLog("[AuthManager] Switched the active Apple ID to \(identifier).")
    }

    @discardableResult
    public func getAuthenticatedSession() async throws -> ALTAppleAPISession {
        let accountIdentifier = AuthAccountContext.scope?.accountIdentifier
        // The coalescer key used to be a constant. Two concurrent refreshes of apps owned by
        // different accounts would then share one session and send the wrong token to a portal
        // request -- the same class of mismatch as mixing a new token with a cached old team.
        let coalesceKey = "apple_auth_session|\(accountIdentifier ?? "active")"
        return try await TaskChainCoalescer.shared.coalesce(key: coalesceKey) {
            let adsid: String?
            let xcodeToken: String?
            if let accountIdentifier {
                adsid = Keychain.shared.credential(.adsid, forAccount: accountIdentifier)
                xcodeToken = Keychain.shared.credential(.xcodeToken, forAccount: accountIdentifier)
            } else {
                adsid = self.adsid
                xcodeToken = self.xcodeToken
            }
            guard let adsid, let xcodeToken else {
                debugLog("[AuthManager] No stored tokens found for \(accountIdentifier ?? "the active account").")
                throw OperationError.notAuthenticated
            }
            let anisetteData = try await AnisetteProvider.fetch()   // one time pass
            let xcodeVersion = await AnisetteConfigManager.shared.resolvedXcodeVersion()

            let session = ALTAppleAPISession(
                dsid: adsid,
                authToken: xcodeToken,
                anisetteData: anisetteData,
                xcodeVersion: xcodeVersion
            )
            return session
        }
    }

    /// Apple expires the Developer portal session of a free personal account within minutes. The
    /// password is already in the keychain, so renew without UI: no verification handler means
    /// SideSign throws `requiresTwoFactorAuthentication` rather than waiting for a code nobody is
    /// around to type, and the caller keeps the error.
    ///
    /// The token is written straight into the keychain, which is where getAuthenticatedSession()
    /// reads it from. That is what lets a retrying caller pick the new token up without touching
    /// the coalesced session path below.
    public func renewPortalSession() async throws {
        let accountIdentifier = AuthAccountContext.scope?.accountIdentifier
        let appleID: String?
        let password: String?
        if let accountIdentifier {
            appleID = Keychain.shared.credential(.emailAddress, forAccount: accountIdentifier)
            password = Keychain.shared.credential(.password, forAccount: accountIdentifier)
        } else {
            appleID = currentAppleID
            password = self.password
        }
        guard let appleID, let password else {
            debugLog("[AuthManager] renewPortalSession: no stored credentials to renew with.")
            throw OperationError.notAuthenticated
        }

        let anisetteData = try await AnisetteProvider.fetch()
        let xcodeVersion = await AnisetteConfigManager.shared.resolvedXcodeVersion()
        
        // A background renewal has nobody to type a code, so it still fails fast. In the foreground
        // the sign-in UI can ask, which is the difference between a dead end and a retry.
        let twoFactorPrompt: SignInFlowHandler? = await MainActor.run {
            guard UIApplication.shared.applicationState == .active,
                  let presenter = UIApplication.shared.topViewController() else { return nil }
            return SignInFlowHandler(presentingViewController: presenter)
        }
        
        let verificationHandler: DeveloperPortal.VerificationHandler? = twoFactorPrompt.map { prompt in
            { (request: TwoFactorRequest) in
                try await prompt.verificationCode(for: request)
            }
        }
        
        let session: ALTAppleAPISession
        do {
            (_, session) = try await portalProxy.signIn(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData,
                xcodeVersion: xcodeVersion,
                verificationHandler: verificationHandler
            )
        } catch let error as DeveloperPortalError {
            // "Sign in again" is what the user has to do, and the raw SideSign sentence does not say so.
            if case .requiresTwoFactorAuthentication = error {
                throw OperationError.twoFactorRequired
            }
            throw error
        }

        if let accountIdentifier {
            // Renewal must land back in the owning account's namespace; writing through
            // self.adsid would put the new token on whichever account is currently active.
            Keychain.shared.setCredential(.adsid, value: session.dsid, forAccount: accountIdentifier)
            Keychain.shared.setCredential(.xcodeToken, value: session.authToken, forAccount: accountIdentifier)
        } else {
            self.adsid = session.dsid
            self.xcodeToken = session.authToken
        }
        debugLog("[AuthManager] Renewed the Developer portal session without user interaction.")
    }

    public func getAuthenticatedTeam() async throws -> ALTTeam {
        if let scope = AuthAccountContext.scope {
            return try await self.resolveTeam(for: scope)
        }
        // Never cache the team. A sign-in swaps the active account/team while the "Resign
        // SideStore" screen is still up, and an install started from that screen used to pair the
        // NEW account's portal token with the OLD account's cached team -- Apple then answered
        // "Unable to find a team with the given Team ID ...". Reading Core Data each time keeps
        // the team and the keychain session on the same account.
        return try await self.resolveActiveTeam()
    }

    /// The exact team that signed the installed app. It is deliberately not `isActiveTeam`:
    /// that flag belongs to whichever account the user last switched to.
    private func resolveTeam(for scope: AuthAccountScope) async throws -> ALTTeam {
        try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            if let teamIdentifier = scope.teamIdentifier {
                let teamRequest = Team.fetchRequest() as NSFetchRequest<Team>
                teamRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(Team.identifier), teamIdentifier)
                teamRequest.fetchLimit = 1
                if let dbTeam = try? context.fetch(teamRequest).first {
                    return ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
                }
            }

            // Older installations have no team recorded; fall back to the owning account.
            let request = Account.fetchRequest() as NSFetchRequest<Account>
            request.predicate = NSPredicate(
                format: "%K == %@",
                #keyPath(Account.identifier), scope.accountIdentifier
            )
            request.fetchLimit = 1
            guard let account = try? context.fetch(request).first,
                  let dbTeam = account.teams.first(where: { $0.isActiveTeam }) ?? account.teams.first
            else {
                throw OperationError.notAuthenticated
            }
            return ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
        }
    }

    private func resolveActiveTeam() async throws -> ALTTeam {
        try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            guard let dbTeam = DatabaseManager.shared.activeTeam(in: context) else {
                throw OperationError.notAuthenticated
            }
            return ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
        }
    }
    
    @discardableResult
    func signIn(
        presentingViewController: UIViewController? = nil,
        skipDeviceRegistration: Bool = false,
        skipCertificateProvisioning: Bool = false,
        skipResign: Bool = false,
        skipHowTos: Bool = false
    ) async throws -> SignInResult {
        let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let signInFlowHandler = SignInFlowHandler(presentingViewController: presentingViewController)
        let context = StandaloneOperationContext(
            steps: .signIn,
            dbBackgroundContext: dbBackgroundContext
        )
        
        let signInOperation = try SignInOperation(
            context: context,
            signInHandler: signInFlowHandler,
            anisetteServerHandler: signInFlowHandler,
            skipDeviceRegistration: skipDeviceRegistration,
            skipCertificateProvisioning: skipCertificateProvisioning,
            skipResign: skipResign,
            skipHowTos: skipHowTos
        )
        return try await signInOperation.execute()
    }
    
    
    // Developer Portal Operations
    public func signIn(appleID: String, 
                       password: String, 
                       anisetteData: ALTAnisetteData, 
                       xcodeVersion: String, 
                       machinePassword: String? = nil,
                       accountRepairHandler: DeveloperPortal.AccountRepairHandler = DeveloperPortal.defaultAccountRepairHandler,
                       verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> (ALTAccount, ALTAppleAPISession) 
    {
        return try await self.portalProxy.signIn(
            appleID: appleID, 
            password: password, 
            anisetteData: anisetteData, 
            xcodeVersion: xcodeVersion, 
            machinePassword: machinePassword,
            accountRepairHandler: accountRepairHandler, 
            verificationHandler: verificationHandler
        )
    }
}

fileprivate extension DatabaseManager {
    //TODO: this is not clean, but for now this should be fine, ie we should later make this proper async instead of blocking
    func deactivateActiveAccountAndTeam() async {
        guard self.isStarted else {
            debugLog("[AuthManager] DatabaseManager is not started. Skipping CoreData active account/team deactivation.")
            return
        }
        let bgContext = self.persistentContainer.newBackgroundContext()
        await bgContext.perform {
            if let account = self.activeAccount(in: bgContext) {
                account.isActiveAccount = false
            }
            if let team = self.activeTeam(in: bgContext) {
                team.isActiveTeam = false
            }
            do {
                try bgContext.save()
            } catch {
                debugLog("[AuthManager] Failed to save CoreData context when deactivating active account and team: \(error)")
            }
        }
        
        await self.viewContext.perform {
            self.viewContext.processPendingChanges()
            self.viewContext.refreshAllObjects()
        }
    }
}
