//
//  NewAppDetailView.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import CoreData

struct NewAppDetailView: View {
    @ObservedObject var app: StoreApp

    @StateObject private var progressObserver = InstallProgressObserver()

    private var tintColor: Color {
        Color(uiColor: app.tintColor ?? ThemeManager.shared.primaryColor)
    }

    private var installedApp: InstalledApp? {
        app.installedApp
    }

    private var latestVersion: AppVersion? {
        app.latestSupportedVersion
    }

    var body: some View {
        List {
            headerSection
            actionSection
            airBoxSection
            descriptionSection
            screenshotsSection
            permissionsSection
            versionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: app.iconURL)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.title3.bold())

                    Text(app.developerName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let subtitle = app.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let version = latestVersion {
                        Text(verbatim: "\(version.version) · \(Self.sizeString(version.size))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var actionSection: some View {
        Section {
            if progressObserver.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction = progressObserver.fractionCompleted {
                        ProgressView(value: fraction)
                            .tint(tintColor)
                    } else {
                        ProgressView()
                    }

                    Text(NSLocalizedString("Installing…", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                SwiftUI.Button(action: performPrimaryAction) {
                    Text(primaryActionTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tintColor)
            }
        }
    }

    @ViewBuilder
    private var airBoxSection: some View {
        if let latestVersion, !app.bundleIdentifier.hasSuffix(".AirBox") {
            Section {
                SwiftUI.Button {
                    guard let viewController = UIApplication.shared.topViewController() else { return }
                    ContainerInstallAction.run(version: latestVersion, appName: app.name, from: viewController)
                } label: {
                    Label(NSLocalizedString("Run in AirBox", comment: ""), systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } footer: {
                Text(NSLocalizedString("AirBox runs the app without installing it on the system, so it uses no App ID.", comment: ""))
            }
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if !app.localizedDescription.isEmpty {
            Section(NSLocalizedString("Description", comment: "")) {
                Text(app.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        if !app.allScreenshots.isEmpty {
            Section(NSLocalizedString("Screenshots", comment: "")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(app.allScreenshots, id: \.objectID) { screenshot in
                            RemoteImage(url: screenshot.imageURL)
                                .frame(width: 180, height: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        let permissions = app.permissions.sorted {
            $0.permission.localizedDisplayName.localizedStandardCompare($1.permission.localizedDisplayName) == .orderedAscending
        }

        if !permissions.isEmpty {
            Section(NSLocalizedString("Permissions", comment: "")) {
                ForEach(permissions, id: \.objectID) { permission in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: permission.permission.effectiveSymbolName)
                            .foregroundStyle(tintColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.permission.localizedDisplayName)
                                .font(.body)

                            if let usageDescription = permission.usageDescription {
                                Text(usageDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var versionsSection: some View {
        let entries = versionEntries

        if !entries.isEmpty {
            Section {
                AppVersionsCard(entries: entries, tintColor: tintColor) { version in
                    install(version)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private var versionEntries: [AppVersionsCard.Entry] {
        let installedVersion = installedApp
        return app.versions.map { version in
            AppVersionsCard.Entry(
                version: version,
                channel: version.channel,
                isInstalled: installedVersion?.matches(version) == true
            )
        }
    }

    private var primaryActionTitle: String {
        guard let installedApp else {
            return NSLocalizedString("Install", comment: "")
        }
        return installedApp.hasUpdate
            ? NSLocalizedString("Update", comment: "")
            : NSLocalizedString("Open", comment: "")
    }

    private func performPrimaryAction() {
        guard let viewController = UIApplication.shared.topViewController() else { return }

        if let installedApp {
            if installedApp.hasUpdate, let latestVersion {
                update(installedApp, to: latestVersion, presentingViewController: viewController)
            } else {
                UIApplication.shared.open(installedApp.openAppURL)
            }
            return
        }

        guard let latestVersion else { return }
        install(latestVersion)
    }

    private func install(_ version: AppVersion) {
        guard let viewController = UIApplication.shared.topViewController() else { return }

        // Choosing another version of an app that is already installed is an update, not a second
        // install; the UIKit page makes the same distinction.
        if let installedApp {
            guard !installedApp.matches(version) else { return }
            update(installedApp, to: version, presentingViewController: viewController)
            return
        }

        // Same rule as the UIKit detail page: container mode needs to offer itself before the
        // package is installed, because installing to the system spends an App ID slot.
        if UserDefaults.standard.isContainerModeEnabled {
            InstallAppDialog.present(storeApp: app, version: version, from: viewController) { [self] in
                performInstall(version, presentingViewController: viewController)
            }
            return
        }

        performInstall(version, presentingViewController: viewController)
    }

    private func performInstall(_ version: AppVersion, presentingViewController viewController: UIViewController) {
        let group = AppManager.shared.install(.app(version), presentingViewController: viewController) { result in
            DispatchQueue.main.async {
                progressObserver.track(nil)
                app.managedObjectContext?.refresh(app, mergeChanges: true)
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
            }
        }

        progressObserver.track(group.progress)
    }

    private func update(_ installedApp: InstalledApp, to version: AppVersion, presentingViewController viewController: UIViewController) {
        let progress = AppManager.shared.update(installedApp, to: version, presentingViewController: viewController) { result in
            DispatchQueue.main.async {
                progressObserver.track(nil)
                app.managedObjectContext?.refresh(app, mergeChanges: true)
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
            }
        }

        progressObserver.track(progress)
    }

    private static func sizeString(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
