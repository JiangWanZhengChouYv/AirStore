//
//  NewSettingsView.swift
//  SideStore
//

import SwiftUI
import UIKit

/// Settings root for the SwiftUI shell. Sections, search results and navigation all come from
/// SettingsCatalog, so adding a row in one place makes it visible and searchable everywhere.
struct NewSettingsView: View {
    @State private var searchText = ""
    @State private var path = NavigationPath()
    @State private var activeAction: SettingsAction?

    private var isDebugEnabled: Bool {
        UserDefaults.standard.isDebugModeEnabled
    }

    private var visibleEntries: [SettingsEntry] {
        SettingsCatalog.entries.filter { !$0.requiresDebug || isDebugEnabled }
    }

    private var results: [SettingsEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return visibleEntries.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !searchText.isEmpty {
                    Section(NSLocalizedString("Search Results", comment: "")) {
                        ForEach(results) { entry in
                            settingsRow(entry)
                        }
                        if results.isEmpty {
                            Text(NSLocalizedString("No Settings Found", comment: ""))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(SettingsGroup.allCases) { group in
                        let entries = visibleEntries.filter { $0.group == group }
                        if !entries.isEmpty {
                            Section {
                                ForEach(entries) { entry in
                                    settingsRow(entry)
                                }
                            } header: {
                                Label(group.title, systemImage: group.symbol)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .navigationTitle(NSLocalizedString("Settings", comment: ""))
            .searchable(text: $searchText, prompt: NSLocalizedString("Search Settings", comment: ""))
            .navigationDestination(for: SettingsDestination.self) { destination in
                SettingsDestinationView(destination: destination)
            }
            .sheet(item: $activeAction) { action in
                SettingsActionView(action: action)
            }
        }
    }

    @ViewBuilder
    private func settingsRow(_ entry: SettingsEntry) -> some View {
        switch entry.kind {
        case .navigation(let destination):
            NavigationLink(value: destination) {
                SettingsGlassRow(title: entry.title, symbol: entry.symbol)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(Self.rowInsets)

        case .toggle(let key):
            SettingsGlassToggleRow(title: entry.title, symbol: entry.symbol, key: key)
                .listRowBackground(Color.clear)
                .listRowInsets(Self.rowInsets)

        case .action(let action):
            SwiftUI.Button {
                activeAction = action
            } label: {
                SettingsGlassRow(title: entry.title, symbol: entry.symbol)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(Self.rowInsets)
        }
    }

    private static let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
}

/// In-place actions from the classic screen. Existing managers and UserDefaults keys are reused;
/// nothing here creates a second source of truth for account or cache state.
struct SettingsActionView: View {
    let action: SettingsAction

    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @AppStorage("betaUdpatesTrack") private var betaTrack: String = "develop"

    var body: some View {
        NavigationStack {
            List {
                switch action {
                case .signIn:
                    Section {
                        SettingsPresentingHost { controller in
                            SwiftUI.Button(NSLocalizedString("Sign in with Apple ID", comment: "")) {
                                Task { @MainActor in
                                    do {
                                        _ = try await AuthManager.shared.signIn(presentingViewController: controller)
                                        message = NSLocalizedString("Signed in.", comment: "")
                                    } catch {
                                        message = error.localizedDescription
                                    }
                                }
                            }
                        }
                        .frame(height: 80)
                    }

                case .signOut:
                    Section {
                        SwiftUI.Button(NSLocalizedString("Sign Out", comment: ""), role: .destructive) {
                            Task { @MainActor in
                                await AuthManager.shared.signOut(
                                    keepCertificate: false,
                                    keepAnisetteData: false,
                                    keepAnisetteHeaders: false,
                                    keepSideSignHeaders: false
                                )
                                message = NSLocalizedString("Signed out.", comment: "")
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("You will no longer be able to install or refresh apps once you sign out.", comment: ""))
                    }

                case .clearCache:
                    Section {
                        SwiftUI.Button(NSLocalizedString("Clear Cache", comment: ""), role: .destructive) {
                            Task { @MainActor in
                                do {
                                    try await AppManager.shared.clearAppCache()
                                    message = NSLocalizedString("Cache cleared.", comment: "")
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("This will remove all temporary files as well as backups for uninstalled apps.", comment: ""))
                    }

                case .betaTrack:
                    Section {
                        Picker(NSLocalizedString("Beta Updates Track", comment: ""), selection: $betaTrack) {
                            ForEach(ReleaseTrackType.betaTracks, id: \.rawValue) { track in
                                Text(track.rawValue).tag(track.rawValue)
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("Enable Beta Updates to receive builds from this track.", comment: ""))
                    }

                case .sendFeedback:
                    Section {
                        SwiftUI.Button(NSLocalizedString("Open Issues", comment: "")) {
                            if let url = URL(string: "https://github.com/JiangWanZhengChouYv/AirStore/issues") {
                                UIApplication.shared.open(url)
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("Report a problem or suggest an improvement on GitHub.", comment: ""))
                    }

                case .howItWorks:
                    Section {
                        Text(NSLocalizedString("AirStore signs and refreshes apps on your device with your own Apple ID, using a local loopback VPN instead of a computer.", comment: ""))
                    }

                case .siriShortcuts:
                    Section {
                        SwiftUI.Button(NSLocalizedString("Open Shortcuts", comment: "")) {
                            if let url = URL(string: "shortcuts://") {
                                UIApplication.shared.open(url)
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("Add the refresh-apps shortcut in the Shortcuts app to refresh with Siri.", comment: ""))
                    }

                case .refreshAttempts:
                    Section {
                        Text(NSLocalizedString("The full refresh attempt history is available in the classic interface under Advanced → View Refresh Attempts.", comment: ""))
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button(NSLocalizedString("Done", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
