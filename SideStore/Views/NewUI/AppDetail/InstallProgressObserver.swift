//
//  InstallProgressObserver.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Combine

/// `Progress` is not an ObservableObject, so SwiftUI cannot follow it on its own. This wraps the
/// KVO that works and is shared by the new detail page and, later, My Apps.
@MainActor
final class InstallProgressObserver: ObservableObject {
    @Published private(set) var fractionCompleted: Double?
    @Published private(set) var isActive = false

    private var observation: NSKeyValueObservation?

    func track(_ progress: Progress?) {
        observation = nil

        guard let progress else {
            isActive = false
            fractionCompleted = nil
            return
        }

        isActive = true
        fractionCompleted = progress.fractionCompleted

        observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                self?.fractionCompleted = value
            }
        }
    }
}
