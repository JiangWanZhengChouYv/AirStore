//
//  AppearanceSettingsView.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI

/// The switch between the current interface and the SwiftUI rebuild. It only stores the choice:
/// the launch path reads it once, so applying it means a relaunch, same as a theme change.
struct AppearanceSettingsView: View {
    @AppStorage(UIStylePreferences.usesNewUIKey, store: UIStylePreferences.store) private var usesNewUI = false
    @State private var isShowingRestartAlert = false

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("New interface", comment: ""), isOn: $usesNewUI)
            } footer: {
                Text(NSLocalizedString("The new interface is still being rebuilt. Browse, My Apps and News arrive in later builds; turning it off brings back the current interface.", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("Appearance", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: usesNewUI) { _, _ in
            isShowingRestartAlert = true
        }
        .alert(NSLocalizedString("Restart Required", comment: ""), isPresented: $isShowingRestartAlert) {
            SwiftUI.Button(NSLocalizedString("Restart Now", comment: ""), role: .destructive) {
                exit(0)
            }
            SwiftUI.Button(NSLocalizedString("Later", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("The interface change takes effect after AirStore restarts.", comment: ""))
        }
    }
}
