//
//  UIStylePreferences.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

enum UIStylePreferences {
    static let usesNewUIKey = "usesNewUI"

    /// Stored in the App Group rather than standard defaults: a self-update reinstalls the app and
    /// gives it a fresh container, and losing this key halfway through the rebuild is how a tester
    /// ends up back on the old interface without touching the switch.
    static var store: UserDefaults {
        guard let appGroup = Bundle.main.altstoreAppGroup,
              let defaults = UserDefaults(suiteName: appGroup) else {
            return .standard
        }
        return defaults
    }

    /// Default false: the refreshed interface is opt-in until its pages finish landing.
    static var usesNewUI: Bool {
        self.store.bool(forKey: self.usesNewUIKey)
    }

    static func migrateFromStandardIfNeeded() {
        let store = self.store
        guard store !== UserDefaults.standard else { return }
        guard store.object(forKey: self.usesNewUIKey) == nil,
              UserDefaults.standard.object(forKey: self.usesNewUIKey) != nil else { return }

        store.set(UserDefaults.standard.bool(forKey: self.usesNewUIKey), forKey: self.usesNewUIKey)
    }
}
