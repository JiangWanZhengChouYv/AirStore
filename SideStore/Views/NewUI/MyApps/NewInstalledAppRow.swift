//
//  NewInstalledAppRow.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI

struct NewInstalledAppRow: View {
    @ObservedObject var app: InstalledApp

    let progressFraction: Double?
    let onUpdate: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.storeApp?.iconURL)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(app.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .tint(Color.accentColor)
                }
            }

            Spacer(minLength: 8)

            if app.hasUpdate {
                SwiftUI.Button {
                    onUpdate?()
                } label: {
                    Text(NSLocalizedString("Update", comment: ""))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
