//
//  SettingsRowStyle.swift
//  SideStore
//

import SwiftUI

/// The visual reference has not been provided yet. Every settings row reads its shape and material
/// from here so colours, radii and materials can be tuned in one place once the design lands.
enum SettingsRowStyle {
    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    static let material: Material = .ultraThinMaterial
    static let spacing: CGFloat = 12
    static let symbolSize: CGFloat = 26
    static let rowPadding: CGFloat = 12
}
