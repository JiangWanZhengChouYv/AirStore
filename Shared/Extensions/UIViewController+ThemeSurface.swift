//
//  UIViewController+ThemeSurface.swift
//  AltStore
//
//  Storyboard scenes paint themselves with the SettingsBackground asset, and nothing at runtime can
//  change an asset -- so the pages that show that surface state their own colour instead. The colour
//  itself is theme-aware (see `UIColor.settingsBackground`), which is why every one of these needs
//  only one call.
//

import UIKit

extension UIViewController
{
    /// Take over this page's surface colour and keep it current when the theme changes.
    func adoptThemeSurface()
    {
        self.view.backgroundColor = .settingsBackground
        // Idempotent: pages call this on every appearance, and a second registration would deliver
        // the same assignment twice.
        NotificationCenter.default.removeObserver(self, name: ThemeManager.themeDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(UIViewController.refreshThemeSurface),
                                               name: ThemeManager.themeDidChangeNotification, object: nil)
    }
}

extension UIViewController
{
    // @objc is only reachable from the selector above; selector-based observers need no removal since
    // iOS 9 zeroes the reference when the controller deallocates.
    @objc fileprivate func refreshThemeSurface()
    {
        self.view.backgroundColor = .settingsBackground
    }
}
