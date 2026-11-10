//
//  NewUIFeedback.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI

/// Errors in the new shell go through the same toast the rest of the app uses, so the error log
/// remains one tap away instead of dying in a print statement.
@MainActor
enum NewUIFeedback {
    static func present(_ error: Error) {
        guard let viewController = UIApplication.shared.topViewController() else { return }
        let toastView = ToastView(error: error)
        toastView.opensErrorLog = true
        toastView.show(in: viewController)
    }
}
