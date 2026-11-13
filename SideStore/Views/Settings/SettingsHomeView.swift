//
//  SettingsHomeView.swift
//  SideStore
//
//  The settings home is a SwiftUI surface hosted by SettingsViewController. The classic view
//  controller stays as the host so its storyboard segues, account state and alert flows keep
//  working; this file owns only the presentation: six groups, each one large pane of glass holding
//  many rows, instead of one inset table section per topic.
//

import SwiftUI
import UIKit

// MARK: - Actions and state

enum SettingsAction {
    case signIn
    case signOut
    case resolveAccount
    case changeAppIcon
    case theme
    case howItWorks
    case licenses
    case patreon
    case sendFeedback
    case social(SocialLink)
    case siriShortcut
    case betaTrack(String)
    case healthCheck
    case errorLog
    case storageExplorer
    case clearCache
    case refreshAttempts
    case developerOptions
    case experimentalFeatures
    case backupAndRestore
    case pairingFile
    case anisetteServers
    case connectionConfig
    case networkDiscovery
    case developerServices
    case profileManagement
    case certificates
    case container
    case sideJITServer
}

enum SocialLink: String {
    case github
    case mastodon
    case threads
    case twitter
}

final class SettingsRouter: ObservableObject {
    var perform: ((SettingsAction) -> Void)?

    func send(_ action: SettingsAction) {
        self.perform?(action)
    }
}

final class SettingsState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var appleID: String?
    @Published var teamName: String?
    @Published var teamType: String?
    @Published var versionText = ""

    func refresh() {
        self.isAuthenticated = AuthManager.shared.isAuthenticated
        self.appleID = AuthManager.shared.currentAppleID
        self.versionText = "\(Bundle.Info.activeBundleShortVersion) (\(Bundle.Info.activeBundleBuildVersion ?? ""))"

        Task { @MainActor [weak self] in
            guard let self else { return }
            let team = try? await AuthManager.shared.getAuthenticatedTeam()
            self.teamName = team?.name
            self.teamType = team?.type.localizedDescription
        }
    }
}

// MARK: - Rows

private enum RowKind {
    case link(SettingsAction?)
    case value(String, SettingsAction?)
    case toggle(Binding<Bool>)
    case menu(current: String, options: [String], select: (String) -> Void)
    case text(String)
}

private struct SettingsRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let kind: RowKind

    init(_ id: String, title: String, subtitle: String? = nil, symbol: String, tint: Color = .white, kind: RowKind) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.kind = kind
    }
}

private struct SettingsGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let rows: [SettingsRow]
}

// MARK: - Home

struct SettingsHomeView: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject var state: SettingsState

    @AppStorage("isBackgroundRefreshEnabled") private var backgroundRefresh = false
    @AppStorage("isIdleTimeoutDisableEnabled") private var noIdleTimeout = true
    @AppStorage("isAppLimitDisabled") private var disableAppLimit = false
    @AppStorage("isBetaUpdatesEnabled") private var betaUpdates = false
    @AppStorage("betaUdpatesTrack") private var betaTrack = UserDefaults.defaultBetaUpdatesTrack

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ForEach(self.groups) { group in
                    SettingsGlassGroup(group: group, router: self.router)
                }

                Text("AirStore · " + self.state.versionText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 48)
        }
        .background(SettingsBackdrop())
        .onAppear { self.state.refresh() }
    }

    private var groups: [SettingsGroup] {
        let accountRows: [SettingsRow]
        if self.state.isAuthenticated {
            accountRows = [
                SettingsRow("account.name", title: NSLocalizedString("Name", comment: ""), symbol: "person.crop.circle", kind: .text(self.state.teamName ?? "—")),
                SettingsRow("account.email", title: NSLocalizedString("Email", comment: ""), symbol: "envelope", kind: .text(self.state.appleID ?? "—")),
                SettingsRow("account.type", title: NSLocalizedString("Type", comment: ""), symbol: "person.2", kind: .text(self.state.teamType ?? "—")),
                SettingsRow("account.actions", title: NSLocalizedString("Account Status", comment: ""), subtitle: NSLocalizedString("Check for pending account actions", comment: ""), symbol: "checkmark.shield", tint: .green, kind: .link(.resolveAccount)),
                SettingsRow("account.signout", title: NSLocalizedString("Sign Out", comment: ""), symbol: "rectangle.portrait.and.arrow.right", tint: .red, kind: .link(.signOut))
            ]
        } else {
            accountRows = [
                SettingsRow("account.signin", title: NSLocalizedString("Sign in with Apple ID", comment: ""), subtitle: NSLocalizedString("Sign in to download apps from AirStore.", comment: ""), symbol: "person.crop.circle.badge.plus", kind: .link(.signIn))
            ]
        }

        let appLimitAvailable = UserDefaults.standard.isCowExploitSupported || !ProcessInfo().sparseRestorePatched
        var refreshRows: [SettingsRow] = [
            SettingsRow("refresh.background", title: NSLocalizedString("Background Refresh", comment: ""), subtitle: NSLocalizedString("Refresh apps automatically when connected to Wi-Fi.", comment: ""), symbol: "arrow.triangle.2.circlepath", tint: .blue, kind: .toggle(self.$backgroundRefresh)),
            SettingsRow("refresh.idle", title: NSLocalizedString("Disable Idle Timeout", comment: ""), subtitle: NSLocalizedString("Keep the device awake during a refresh or install.", comment: ""), symbol: "moon.zzz", tint: .indigo, kind: .toggle(self.$noIdleTimeout)),
            SettingsRow("refresh.siri", title: NSLocalizedString("Allow Siri To Refresh Apps…", comment: ""), symbol: "waveform", tint: .purple, kind: .link(.siriShortcut))
        ]
        if appLimitAvailable {
            // The classic switch also resets the cached active-app limit; keep that side effect.
            let limitBinding = Binding<Bool>(
                get: { self.disableAppLimit },
                set: { newValue in
                    self.disableAppLimit = newValue
                    if UserDefaults.standard.activeAppsLimit != nil {
                        UserDefaults.standard.activeAppsLimit = InstalledApp.freeAccountActiveAppsLimit
                    }
                }
            )
            refreshRows.append(SettingsRow("refresh.limit", title: NSLocalizedString("Disable App Limit", comment: ""), symbol: "square.stack.3d.up.slash", tint: .orange, kind: .toggle(limitBinding)))
        }
        refreshRows.append(contentsOf: [
            SettingsRow("refresh.beta", title: NSLocalizedString("Enable Beta Updates", comment: ""), symbol: "testtube.2", tint: .pink, kind: .toggle(self.$betaUpdates)),
            SettingsRow("refresh.track", title: NSLocalizedString("Beta Updates Track", comment: ""), symbol: "flag", tint: .pink, kind: .menu(current: self.betaTrack, options: ReleaseTrackType.betaTracks.map(\.rawValue), select: { self.router.send(.betaTrack($0)) }))
        ])

        return [
            SettingsGroup(id: "account", title: NSLocalizedString("Account", comment: ""), symbol: "person.crop.circle.fill", tint: .blue, rows: accountRows),

            SettingsGroup(id: "appearance", title: NSLocalizedString("Appearance & Experience", comment: ""), symbol: "paintbrush.fill", tint: .purple, rows: [
                SettingsRow("appearance.icon", title: NSLocalizedString("Change App Icon", comment: ""), symbol: "app.badge", tint: .purple, kind: .link(.changeAppIcon)),
                SettingsRow("appearance.theme", title: NSLocalizedString("Theme & Customizations", comment: ""), subtitle: NSLocalizedString("Accent colour and app icon presets.", comment: ""), symbol: "swatchpalette", tint: .pink, kind: .link(.theme))
            ]),

            SettingsGroup(id: "refresh", title: NSLocalizedString("Refresh & Updates", comment: ""), symbol: "arrow.clockwise.circle.fill", tint: .cyan, rows: refreshRows),

            SettingsGroup(id: "connection", title: NSLocalizedString("Connection & Signing", comment: ""), symbol: "cable.connector", tint: .teal, rows: [
                SettingsRow("connection.pairing", title: NSLocalizedString("Pairing File Management", comment: ""), symbol: "doc.badge.gearshape", kind: .link(.pairingFile)),
                SettingsRow("connection.anisette", title: NSLocalizedString("Anisette Servers", comment: ""), symbol: "server.rack", kind: .link(.anisetteServers)),
                SettingsRow("connection.config", title: NSLocalizedString("Connection Config", comment: ""), symbol: "network", kind: .link(.connectionConfig)),
                SettingsRow("connection.discovery", title: NSLocalizedString("Network Discovery (mDNS)", comment: ""), symbol: "bonjour", kind: .link(.networkDiscovery)),
                SettingsRow("connection.portal", title: NSLocalizedString("Developer Portal Services", comment: ""), symbol: "building.2", kind: .link(.developerServices)),
                SettingsRow("connection.profiles", title: NSLocalizedString("Profile Management", comment: ""), symbol: "person.text.rectangle", kind: .link(.profileManagement)),
                SettingsRow("connection.certificates", title: NSLocalizedString("Certificate Management", comment: ""), symbol: "signature", kind: .link(.certificates)),
                SettingsRow("connection.container", title: NSLocalizedString("Container", comment: ""), symbol: "shippingbox", kind: .link(.container)),
                SettingsRow("connection.jit", title: NSLocalizedString("SideJITServer", comment: ""), symbol: "bolt.horizontal", kind: .link(.sideJITServer))
            ].filter { !($0.id == "connection.anisette" && UserDefaults.standard.useOnDeviceAnisette) }),

            SettingsGroup(id: "diagnostics", title: NSLocalizedString("Diagnostics & Storage", comment: ""), symbol: "wrench.and.screwdriver.fill", tint: .orange, rows: [
                SettingsRow("diag.health", title: NSLocalizedString("Health Check", comment: ""), symbol: "heart.text.square", tint: .green, kind: .link(.healthCheck)),
                SettingsRow("diag.log", title: NSLocalizedString("View Error Log", comment: ""), symbol: "doc.text.magnifyingglass", kind: .link(.errorLog)),
                SettingsRow("diag.storage", title: NSLocalizedString("Storage Explorer", comment: ""), symbol: "folder", kind: .link(.storageExplorer)),
                SettingsRow("diag.cache", title: NSLocalizedString("Clear Data Cache…", comment: ""), symbol: "trash", tint: .red, kind: .link(.clearCache)),
                SettingsRow("diag.attempts", title: NSLocalizedString("View Refresh Attempts", comment: ""), symbol: "clock.arrow.circlepath", kind: .link(.refreshAttempts)),
                SettingsRow("diag.backup", title: NSLocalizedString("Backup & Restore", comment: ""), symbol: "externaldrive", kind: .link(.backupAndRestore)),
                SettingsRow("diag.dev", title: NSLocalizedString("Developer Options", comment: ""), symbol: "hammer", kind: .link(.developerOptions)),
                SettingsRow("diag.experimental", title: NSLocalizedString("Experimental Features", comment: ""), symbol: "flask", kind: .link(.experimentalFeatures))
            ]),

            SettingsGroup(id: "about", title: NSLocalizedString("About & Support", comment: ""), symbol: "heart.circle.fill", tint: .pink, rows: [
                SettingsRow("about.how", title: NSLocalizedString("How it works", comment: ""), symbol: "questionmark.circle", kind: .link(.howItWorks)),
                SettingsRow("about.feedback", title: NSLocalizedString("Send Feedback", comment: ""), symbol: "envelope", kind: .link(.sendFeedback)),
                SettingsRow("about.licenses", title: NSLocalizedString("Licenses", comment: ""), symbol: "doc.plaintext", kind: .link(.licenses)),
                SettingsRow("about.github", title: NSLocalizedString("GitHub", comment: ""), symbol: "chevron.left.forwardslash.chevron.right", kind: .link(.social(.github))),
                SettingsRow("about.mastodon", title: NSLocalizedString("Mastodon", comment: ""), symbol: "bubble.left.and.bubble.right", kind: .link(.social(.mastodon))),
                SettingsRow("about.threads", title: NSLocalizedString("Threads", comment: ""), symbol: "at", kind: .link(.social(.threads))),
                SettingsRow("about.twitter", title: NSLocalizedString("Twitter", comment: ""), symbol: "bird", kind: .link(.social(.twitter)))
            ])
        ]
    }
}

// MARK: - Glass group

private struct SettingsGlassGroup: View {
    let group: SettingsGroup
    let router: SettingsRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: self.group.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(self.group.tint)
                    .frame(width: 26, height: 26)
                    .background(self.group.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(self.group.title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.bottom, 10)

            ForEach(self.group.rows) { row in
                if row.id != self.group.rows.first?.id {
                    Divider().overlay(Color.white.opacity(0.12))
                }
                SettingsRowView(row: row, router: self.router)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct SettingsRowView: View {
    let row: SettingsRow
    let router: SettingsRouter

    /// The whole row is the tap target; only toggles and menus keep their own control.
    private var rowAction: SettingsAction? {
        switch self.row.kind {
        case .link(let action): return action
        case .value(_, let action): return action
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let action = self.rowAction {
                SwiftUI.Button {
                    self.router.send(action)
                } label: {
                    self.content
                }
                .buttonStyle(.plain)
            } else {
                self.content
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var content: some View {
        HStack(spacing: 14) {
            Image(systemName: self.row.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(self.row.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.row.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                if let subtitle = self.row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer(minLength: 8)

            self.accessory
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch self.row.kind {
        case .link:
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 24, height: 36)
        case .value(let value, _):
            self.valueLabel(value)
        case .text(let value):
            self.valueLabel(value)
        case .toggle(let binding):
            SwiftUI.Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Color(uiColor: ThemeManager.shared.primaryColor))
        case .menu(let current, let options, let select):
            SwiftUI.Menu {
                ForEach(options, id: \.self) { option in
                    SwiftUI.Button {
                        select(option)
                    } label: {
                        if option == current {
                            SwiftUI.Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            } label: {
                self.valueLabel(current)
            }
        }
    }

    private func valueLabel(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            if case .menu = self.row.kind {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Backdrop

/// Glass needs something behind it to refract. A flat colour makes the panes read as grey plastic,
/// so the page carries a soft wash of the current theme colour instead.
private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .settingsBackground).ignoresSafeArea()

            GeometryReader { geometry in
                Circle()
                    .fill(Color(uiColor: ThemeManager.shared.primaryColor).opacity(0.42))
                    .frame(width: geometry.size.width * 0.9)
                    .blur(radius: 90)
                    .offset(x: -geometry.size.width * 0.35, y: -60)

                Circle()
                    .fill(Color.purple.opacity(0.22))
                    .frame(width: geometry.size.width * 0.8)
                    .blur(radius: 110)
                    .offset(x: geometry.size.width * 0.5, y: geometry.size.height * 0.55)
            }
            .ignoresSafeArea()
        }
    }
}
