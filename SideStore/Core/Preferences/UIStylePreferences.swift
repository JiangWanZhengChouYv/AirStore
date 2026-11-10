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

    /// Default false: the refreshed interface is opt-in until its pages finish landing.
    static var usesNewUI: Bool {
        UserDefaults.standard.bool(forKey: usesNewUIKey)
    }
}
