//
//  UIApplication+AppExtension.swift
//  DeltaCore
//
//  Created by Riley Testut on 6/14/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

public extension UIApplication
{
    // Cannot normally use UIApplication.shared from extensions, so we get around this by calling value(forKey:).
    class var altShared: UIApplication? {
        return UIApplication.value(forKey: "sharedApplication") as? UIApplication
    }
    
    var altKeyWindow: UIWindow? {
        return connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }
    
    /// Every window of every scene, including the ones that are not key: a sheet presented over a
    /// settings page is its own window, and anything that only looks at `altKeyWindow` leaves it --
    /// and every window opened afterwards -- with the colour it had when it was created.
    var altAllWindows: [UIWindow] {
        return connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
    }
    
    func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? altKeyWindow?.rootViewController
        if let nav = root as? UINavigationController {
            return topViewController(base: nav.visibleViewController ?? nav.topViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
}
