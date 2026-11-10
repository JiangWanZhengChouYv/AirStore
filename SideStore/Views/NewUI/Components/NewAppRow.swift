//
//  NewAppRow.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI

struct NewAppRow: View {
    @ObservedObject var app: StoreApp

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconURL)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(app.developerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if app.installedApp != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(NSLocalizedString("Installed", comment: ""))
            }
        }
        .padding(.vertical, 2)
    }
}
