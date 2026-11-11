//
//  SettingsDestinationView.swift
//  SideStore
//

import SwiftUI
import UIKit

/// One mapping from a catalog destination to a page. A few existing settings pages need a
/// `presentingViewController` to show their alerts; the host below supplies a real controller
/// that is in the view hierarchy instead of a detached dummy.
struct SettingsDestinationView: View {
    let destination: SettingsDestination

    @ViewBuilder
    var body: some View {
        switch destination {
        case .appearance:
            AppearanceSettingsView()
        case .account:
            SettingsAccountPage()
        case .themePicker:
            ThemePickerView()
        case .userCustomizations:
            UserCustomizationsView()
        case .appIcon:
            SettingsAppIconPage()
        case .container:
            ContainerSettingsView()
        case .sources:
            SettingsSourcesPage()
        case .healthCheck:
            HealthCheckView()
        case .errorLog:
            SettingsInfoPage(
                title: NSLocalizedString("View Error Log", comment: ""),
                lines: [
                    NSLocalizedString("The full console log is available in the classic interface under Settings → Techy Things → View Error Log.", comment: "")
                ]
            )
        case .storageExplorer:
            StorageExplorerView()
        case .pairingFiles:
            PairingFileManagementView()
        case .wirelessPair:
            WirelessPairView()
        case .anisetteData:
            AnisetteDataView()
        case .connectionConfig:
            ConnectionConfigView()
        case .networkDiscovery:
            BonjourDiscoveryView()
        case .developerServices:
            SettingsPresentingHost { vc in
                DeveloperServicesView(presentingViewController: vc)
            }
        case .profiles:
            SettingsPresentingHost { vc in
                ProfileManagementView(presentingViewController: vc)
            }
        case .certificates:
            SettingsPresentingHost { vc in
                CertificatesView(presentingViewController: vc)
            }
        case .backupRestore:
            BackupAndRestoreView()
        case .sideJITServer:
            SideJITServerConfigView()
        case .sideSignConfiguration:
            SideSignConfigurationView()
        case .developerOptions:
            DeveloperOptionsView()
        case .experimentalFeatures:
            ExperimentalFeaturesView()
        case .credits:
            SettingsInfoPage(
                title: NSLocalizedString("Credits", comment: ""),
                lines: [
                    NSLocalizedString("Developers: AirStore Team", comment: ""),
                    NSLocalizedString("UI Designer: Fabian (thdev)", comment: ""),
                    NSLocalizedString("Asset Designer: Chris (LitRitt)", comment: ""),
                    NSLocalizedString("Built on SideStore and AltStore.", comment: "")
                ]
            )
        case .licenses:
            SettingsInfoPage(
                title: NSLocalizedString("Licenses", comment: ""),
                lines: [
                    NSLocalizedString("AirStore is open source. The full license and third-party notices ship with the repository.", comment: "")
                ]
            )
        }
    }
}

/// Bridges a SwiftUI settings page that needs a UIKit presenting controller.
struct SettingsPresentingHost<Content: View>: UIViewControllerRepresentable {
    let content: (UIViewController) -> Content

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let hosting = UIHostingController(rootView: content(container))
        container.addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        hosting.didMove(toParent: container)
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private struct SettingsAccountPage: View {
    var body: some View {
        List {
            Section {
                LabeledContent(
                    NSLocalizedString("Apple ID", comment: ""),
                    value: AuthManager.shared.currentAppleID ?? NSLocalizedString("Not signed in", comment: "")
                )
                LabeledContent(
                    NSLocalizedString("Status", comment: ""),
                    value: AuthManager.shared.isAuthenticated
                        ? NSLocalizedString("Signed in", comment: "")
                        : NSLocalizedString("Not signed in", comment: "")
                )
            }
        }
        .navigationTitle(NSLocalizedString("Account", comment: ""))
    }
}

private struct SettingsAppIconPage: View {
    @State private var message: String?

    var body: some View {
        List {
            if UIApplication.shared.supportsAlternateIcons {
                Section {
                    SwiftUI.Button(NSLocalizedString("Use Default Icon", comment: "")) {
                        UIApplication.shared.setAlternateIconName(nil) { error in
                            message = error == nil
                                ? NSLocalizedString("App icon reset.", comment: "")
                                : NSLocalizedString("Could not change the app icon.", comment: "")
                        }
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("Change App Icon", comment: ""))
    }
}

private struct SettingsSourcesPage: View {
    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("Sources are managed in Browse → Sources. The apps and news they provide appear everywhere in AirStore.", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("Sources", comment: ""))
    }
}

private struct SettingsInfoPage: View {
    let title: String
    let lines: [String]

    var body: some View {
        List {
            ForEach(lines, id: \.self) { line in
                Text(line)
            }
        }
        .navigationTitle(title)
    }
}
