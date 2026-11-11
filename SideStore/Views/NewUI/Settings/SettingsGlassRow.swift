//
//  SettingsGlassRow.swift
//  SideStore
//

import SwiftUI

/// Navigation-style settings row. Uses the shared glass surface so iOS 26 gets Liquid Glass and
/// 17.4–25 keeps the material fallback without a second code path here.
struct SettingsGlassRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String = "gearshape"
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: SettingsRowStyle.spacing) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: SettingsRowStyle.symbolSize, height: SettingsRowStyle.symbolSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(SettingsRowStyle.rowPadding)
        .glassSurface(in: SettingsRowStyle.shape, material: SettingsRowStyle.material)
    }
}

/// Toggle-style settings row bound to an existing UserDefaults key (the same keys the classic
/// settings screen writes), so switching shells never changes what a setting means.
struct SettingsGlassToggleRow: View {
    let title: String
    var symbol: String = "gearshape"
    var tint: Color = .accentColor
    let key: String

    @AppStorage private var isOn: Bool

    init(title: String, symbol: String = "gearshape", tint: Color = .accentColor, key: String) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.key = key
        _isOn = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        HStack(spacing: SettingsRowStyle.spacing) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: SettingsRowStyle.symbolSize, height: SettingsRowStyle.symbolSize)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(SettingsRowStyle.rowPadding)
        .glassSurface(in: SettingsRowStyle.shape, material: SettingsRowStyle.material)
    }
}
