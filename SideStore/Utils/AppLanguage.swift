//
//  AppLanguage.swift
//  SideStore
//

import Foundation
import SwiftUI

/// In-app language override.
///
/// `Bundle.main.preferredLocalizations` reads `AppleLanguages` from the app's own defaults at
/// launch, so writing that key moves the whole app rather than only the strings we translate.
/// Takes effect on the next launch, which is why every caller has to prompt for a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Language names stay written in their own language: the entry you need has to be findable
    /// even when the rest of the screen is in a language you cannot read yet.
    var title: Text {
        switch self {
        case .system: Text("System Language")
        case .english: Text(verbatim: "English")
        case .simplifiedChinese: Text(verbatim: "简体中文")
        }
    }

    static var current: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.storageKey)

        switch self {
        case .system:
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        case .english, .simplifiedChinese:
            defaults.set([rawValue], forKey: Self.appleLanguagesKey)
        }

        // The user is one alert away from force-quitting the app.
        defaults.synchronize()
    }

    private static let storageKey = "AppLanguageOverride"
    private static let appleLanguagesKey = "AppleLanguages"
}
