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
    
    @KeychainItem(key: "signingCertificate")
    public var signingCertificate: Data?
    
    @KeychainItem(key: "signingCertificatePassword")
    public var signingCertificatePassword: String?
    
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
