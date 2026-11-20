//
//  Keychain.swift
//  AltStore
//
//  Created by Riley Testut on 6/4/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
private import KeychainAccess
import SideSign

@propertyWrapper
public struct KeychainItem<Value>
{
    public let key: String
    
    public var wrappedValue: Value? {
        get {
            switch Value.self
            {
            case is Data.Type: return try? Keychain.shared.keychain.getData(self.key) as? Value
            case is String.Type: return try? Keychain.shared.keychain.getString(self.key) as? Value
            default: return nil
            }
        }
        set {
            switch Value.self
            {
            case is Data.Type: Keychain.shared.keychain[data: self.key] = newValue as? Data
            case is String.Type: Keychain.shared.keychain[self.key] = newValue as? String
            default: break
            }
        }
    }
    
    public init(key: String)
    {
        self.key = key
    }
}

/// The four Apple ID slots, named so a caller can address one account's namespace without
/// touching `accountScope` (and therefore without switching the active Apple ID).
public enum AppleIDCredentialKey: String, Sendable
{
    case emailAddress = "appleIDEmailAddress"
    case password = "appleIDPassword"
    case adsid = "appleIDAdsid"
    case xcodeToken = "appleIDXcodeToken"
}

public class Keychain
{
    public static let shared = Keychain()
    
    fileprivate let keychain = KeychainAccess.Keychain(service: Bundle.Info.appbundleIdentifier)
                                            .accessibility(.afterFirstUnlock)
                                            .synchronizable(true)
    
    /// Which account the four Apple ID slots below belong to, persisted so a relaunch reads the same
    /// namespace. nil means the original unscoped keys -- what a fresh install uses, what an upgrading
    /// install has, and what a sign-in writes before it knows who it is signing in as.
    public var accountScope: String?
    {
        get { UserDefaults.standard.string(forKey: Self.accountScopeKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.accountScopeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.accountScopeKey)
            }
        }
    }

    private static let accountScopeKey = "AirStoreActiveAccountScope"

    // Account-scoped, with the unscoped slot as a fallback. The fallback is what makes this invisible
    // to every install that already has credentials: nothing has to be migrated before it is read,
    // and a sign-in that has not learned its account identifier yet still lands somewhere useful.
    public var appleIDEmailAddress: String? {
        get { self.credential(for: "appleIDEmailAddress") }
        set { self.setCredential(newValue, for: "appleIDEmailAddress") }
    }

    public var appleIDPassword: String? {
        get { self.credential(for: "appleIDPassword") }
        set { self.setCredential(newValue, for: "appleIDPassword") }
    }

    public var appleIDAdsid: String? {
        get { self.credential(for: "appleIDAdsid") }
        set { self.setCredential(newValue, for: "appleIDAdsid") }
    }

    public var appleIDXcodeToken: String? {
        get { self.credential(for: "appleIDXcodeToken") }
        set { self.setCredential(newValue, for: "appleIDXcodeToken") }
    }
    
    /// The signing certificate belongs to one Apple ID, exactly like the credentials above: two
    /// accounts issue two certificates, and refreshing account B's app has to sign with B's. These
    /// keep the same "scoped slot, unscoped fallback" shape as the credentials so an upgrading
    /// install keeps working without a migration step.
    private func certificateCredential(for key: String) -> Data?
    {
        if let scope = self.accountScope, let scoped = try? self.keychain.getData("\(key).\(scope)")
        {
            return scoped
        }
        return try? self.keychain.getData(key)
    }

    private func setCertificateCredential(_ value: Data?, for key: String)
    {
        let target = self.accountScope.map { "\(key).\($0)" } ?? key
        if let value {
            try? self.keychain.set(value, key: target)
        } else {
            try? self.keychain.remove(target)
            try? self.keychain.remove(key)
        }
    }

    public var signingCertificate: Data? {
        get { self.certificateCredential(for: "signingCertificate") }
        set { self.setCertificateCredential(newValue, for: "signingCertificate") }
    }

    public var signingCertificatePassword: String? {
        get {
            let key = "signingCertificatePassword"
            if let scope = self.accountScope, let scoped = try? self.keychain.getString("\(key).\(scope)")
            {
                return scoped
            }
            return try? self.keychain.getString(key)
        }
        set {
            let key = "signingCertificatePassword"
            let target = self.accountScope.map { "\(key).\($0)" } ?? key
            if let newValue {
                try? self.keychain.set(newValue, key: target)
            } else {
                try? self.keychain.remove(target)
                try? self.keychain.remove(key)
            }
        }
    }

    /// One account's certificate, read without consulting or moving `accountScope`. Signing an app
    /// that belongs to a non-active account needs this, or it signs with the wrong team's certificate.
    public func signingCertificate(forAccount identifier: String) -> (data: Data, password: String?)?
    {
        guard !identifier.isEmpty else { return nil }
        if let data = try? self.keychain.getData("signingCertificate.\(identifier)")
        {
            return (data, try? self.keychain.getString("signingCertificatePassword.\(identifier)"))
        }
        // Not yet adopted from the unscoped slot: only safe to read while nothing else is scoped.
        if self.accountScope == nil, let data = try? self.keychain.getData("signingCertificate")
        {
            return (data, try? self.keychain.getString("signingCertificatePassword"))
        }
        return nil
    }

    /// Write one account's certificate without moving the active scope.
    public func setSigningCertificate(_ data: Data?, password: String?, forAccount identifier: String)
    {
        guard !identifier.isEmpty else { return }
        if let data
        {
            try? self.keychain.set(data, key: "signingCertificate.\(identifier)")
            if let password
            {
                try? self.keychain.set(password, key: "signingCertificatePassword.\(identifier)")
            }
        }
        else
        {
            try? self.keychain.remove("signingCertificate.\(identifier)")
            try? self.keychain.remove("signingCertificatePassword.\(identifier)")
        }
    }
    
    // TODO: mahee96: remove legacy keys in later versions after 0.6.4 coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificatePrivateKey")
    public var signingCertificatePrivateKey: Data?
    
    // TODO: mahee96: remove legacy keys in later versions after 0.6.4 coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificateSerialNumber")
    public var signingCertificateSerialNumber: String?
    
    @KeychainItem(key: "identifier")
    public var identifier: String?
    
    @KeychainItem(key: "adiPb")
    public var adiPb: String?

    @KeychainItem(key: "deviceUDID")
    public var deviceUDID: String?

    // MARK: - Dynamic Imported Certificates Storage

    public subscript(certificateSerial serial: String) -> Data? {
        get { try? self.keychain.getData("importedCert_" + serial) }
        set {
            if let data = newValue {
                try? self.keychain.set(data, key: "importedCert_" + serial)
            } else {
                try? self.keychain.remove("importedCert_" + serial)
            }
        }
    }
    
    private init()
    {
        self.migrateLegacyKeychainItems()
    }
    
    private func migrateLegacyKeychainItems()
    {
        let signingCertificateKey   = "signingCertificate"
        let privateKeyKey           = "signingCertificatePrivateKey"
        let serialNumberKey         = "signingCertificateSerialNumber"
        
        // 1. Check if signingCertificate contains data and is NOT a PKCS#12 archive
        guard let certData = try? self.keychain.getData(signingCertificateKey), !certData.isPKCS12 else { return }
        
        // 2. Check if we have the private key
        guard let privateKey = try? self.keychain.getData(privateKeyKey) else { return }
        
        // 3. Load the raw certificate and pair with private key
        guard let x509 = ALTX509Certificate(data: certData) else { return }
        let cert = ALTCertificate(x509: x509, privateKey: privateKey)
        
        // 4. Create PKCS12 data structure
        do {
            let p12Data = try cert.unencryptedP12Data()
            // 5. Store the new PKCS12 format in signingCertificate slot
            try self.keychain.set(p12Data, key: signingCertificateKey)
            try self.keychain.set("", key: "signingCertificatePassword")
            
            // 6. Clear legacy keys
            try self.keychain.remove(privateKeyKey)
            try self.keychain.remove(serialNumberKey)
            
            debugLog("[Keychain] Successfully migrated legacy certificate and private key to PKCS12 format and cleared legacy keys.")
        } catch {
            debugLog("[Keychain] Failed to migrate legacy certificate to PKCS12 format: \(error)")
        }
    }
    
    public func clearCertificates()
    {
        // Legacy
        self.signingCertificatePrivateKey = nil
        self.signingCertificateSerialNumber = nil

        self.signingCertificate = nil
        self.signingCertificatePassword = nil
        
        debugLog("[Keychain] Cleared signing certificate & private key from Keychain.")
    }
    
    /// The accounts that can actually be switched to. An Account row survives sign-out in Core Data,
    /// so the database alone cannot say which ones still have a password or token to use.
    ///
    /// An install that upgraded into per-account slots still has its only copy of the credentials in
    /// the unscoped slots: step 1 wrote a scoped copy on the *next* sign-in, not at launch. Adopt
    /// that copy into its owner's namespace on first read, otherwise the switcher stays empty until
    /// the user signs in once by hand -- and "Add Another Apple ID" would overwrite the only copy
    /// of the original account's credentials before it was ever saved.
    public func accountsWithCredentials(
        from identifiers: [String],
        appleIDsByIdentifier: [String: String] = [:]
    ) -> [String]
    {
        self.adoptUnscopedCredentials(identifiers: identifiers, appleIDsByIdentifier: appleIDsByIdentifier)
        return identifiers.filter { self.hasScopedCredentials(for: $0) }
    }

    private func hasScopedCredentials(for identifier: String) -> Bool
    {
        let email = try? self.keychain.getString("appleIDEmailAddress.\(identifier)")
        let password = try? self.keychain.getString("appleIDPassword.\(identifier)")
        let token = try? self.keychain.getString("appleIDXcodeToken.\(identifier)")
        return email != nil && (password != nil || token != nil)
    }

    private func hasUnscopedCredentials() -> Bool
    {
        guard let email = try? self.keychain.getString("appleIDEmailAddress"), !email.isEmpty else { return false }
        return (try? self.keychain.getString("appleIDPassword")) != nil
            || (try? self.keychain.getString("appleIDXcodeToken")) != nil
    }

    /// Only adopt when the unscoped credentials can be tied to a specific account: adsid is the
    /// account identifier Apple returned at sign-in, and the email is the Account row's appleID.
    /// Guessing "the currently active one" would hand one account's credentials to another.
    private func adoptUnscopedCredentials(identifiers: [String], appleIDsByIdentifier: [String: String])
    {
        guard self.hasUnscopedCredentials() else { return }

        let adsid = try? self.keychain.getString("appleIDAdsid")
        let email = try? self.keychain.getString("appleIDEmailAddress")
        let owner = identifiers.first { identifier in
            if identifier == adsid { return true }
            guard let email, let appleID = appleIDsByIdentifier[identifier] else { return false }
            return appleID.caseInsensitiveCompare(email) == .orderedSame
        }
        guard let owner, !self.hasScopedCredentials(for: owner) else { return }

        // adoptCredentials(for:) moves the scope to the account it just adopted. Listing accounts
        // must not switch accounts, so put the previous scope back.
        let scope = self.accountScope
        self.adoptCredentials(for: owner)
        self.accountScope = scope
        debugLog("[Keychain] Adopted the existing unscoped credentials for account \(owner).")
    }

    /// Signing in to a second account writes the new credentials before Apple says who they belong to.
    /// Drop the scope first so those writes land in the unscoped slots instead of overwriting the
    /// account that is currently active; `adoptCredentials(for:)` moves them afterwards.
    public func beginSignIn()
    {
        self.accountScope = nil
    }

    /// Copy the credentials that were just written to the unscoped slots into the namespace of the
    /// account that turned out to own them, and move the scope there.
    ///
    /// The unscoped copies are deliberately left in place. They are what a build without this change
    /// reads, so keeping them means an install can go back to an older package and still be signed in
    /// -- and `setCredential(nil)` clears both, so signing out still signs all the way out.
    public func adoptCredentials(for accountIdentifier: String)
    {
        guard !accountIdentifier.isEmpty else { return }

        let keys = ["appleIDEmailAddress", "appleIDPassword", "appleIDAdsid", "appleIDXcodeToken"]
        for key in keys
        {
            guard let value = try? self.keychain.getString(key), !value.isEmpty else { continue }
            try? self.keychain.set(value, key: "\(key).\(accountIdentifier)")
        }

        self.accountScope = accountIdentifier
        debugLog("[Keychain] Adopted sign-in credentials for account \(accountIdentifier).")
    }

    /// Read one account's credential directly from its namespace. Unlike the four public
    /// properties, this never consults or changes `accountScope`, so refreshing an app owned by
    /// another account can use its token while a different Apple ID stays active.
    public func credential(_ key: AppleIDCredentialKey, forAccount identifier: String) -> String?
    {
        guard !identifier.isEmpty else { return nil }
        if let scoped = try? self.keychain.getString("\(key.rawValue).\(identifier)") { return scoped }
        // An install that has not adopted its credentials yet only has the unscoped copy.
        if self.accountScope == nil { return try? self.keychain.getString(key.rawValue) }
        return nil
    }

    /// Write one account's namespaced credential without moving the active scope. Used when a
    /// portal session is renewed for an app that belongs to a non-active account.
    public func setCredential(_ key: AppleIDCredentialKey, value: String?, forAccount identifier: String)
    {
        guard !identifier.isEmpty else { return }
        let target = "\(key.rawValue).\(identifier)"
        if let value {
            try? self.keychain.set(value, key: target)
        } else {
            try? self.keychain.remove(target)
        }
    }

    private func credential(for key: String) -> String?
    {
        if let scope = self.accountScope, let scoped = try? self.keychain.getString("\(key).\(scope)")
        {
            return scoped
        }
        return try? self.keychain.getString(key)
    }

    private func setCredential(_ value: String?, for key: String)
    {
        let target = self.accountScope.map { "\(key).\($0)" } ?? key
        if let value {
            try? self.keychain.set(value, key: target)
        } else {
            try? self.keychain.remove(target)
            // Signing out has to actually sign out: an account-scoped slot still sits beside the
            // unscoped copy an upgrade left behind, and clearing only one of them leaves
            // isAuthenticated true with a password nobody can see.
            try? self.keychain.remove(key)
        }
    }

    public func clearSignInInfo(keepAnisetteData: Bool = true)
    {
        debugLog("[Keychain] Clearing sign-in info from Keychain (keepAnisetteData: \(keepAnisetteData))...")
        
        self.appleIDEmailAddress = nil
        self.appleIDPassword = nil
        self.appleIDAdsid = nil
        self.appleIDXcodeToken = nil
        self.accountScope = nil
        debugLog("[Keychain] Cleared Apple ID credentials & tokens (email, password, adsid, xcodeToken).")

        if !keepAnisetteData {
            self.adiPb = nil
            debugLog("[Keychain] Cleared Anisette ADI data (adiPb).")
        } else {
            debugLog("[Keychain] Preserved Anisette ADI data (adiPb).")
        }
        
        debugLog("[Keychain] Cleared sign-in info from Keychain.")
    }

    public func clearAll()
    {
        debugLog("[Keychain] Clearing all Keychain items related to this instance...")
        try? self.keychain.removeAll()
        debugLog("[Keychain] All Keychain items cleared.")
    }
}
