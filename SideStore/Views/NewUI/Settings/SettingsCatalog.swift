//
//  SettingsCatalog.swift
//  SideStore
//

import Foundation

/// The six top-level groups. The classic settings screen hides twenty-odd rows behind "Advanced";
/// this is the single source of truth for the new shell's sections, search and navigation.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case account
    case appearance
    case apps
    case sources
    case developer
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return NSLocalizedString("Account", comment: "")
        case .appearance: return NSLocalizedString("Appearance & Themes", comment: "")
        case .apps: return NSLocalizedString("Apps & Refreshing", comment: "")
        case .sources: return NSLocalizedString("Sources & Updates", comment: "")
        case .developer: return NSLocalizedString("Developer", comment: "")
        case .about: return NSLocalizedString("About", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .appearance: return "paintbrush"
        case .apps: return "arrow.triangle.2.circlepath"
        case .sources: return "square.stack.3d.up"
        case .developer: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

/// Value-based navigation target. Both a section row and a search result append one of these to
/// the same NavigationPath, so "jump straight to the page" cannot drift from the grouped list.
enum SettingsDestination: Hashable {
    case appearance
    case account
    case themePicker
    case userCustomizations
    case appIcon
    case container
    case sources
    case healthCheck
    case errorLog
    case storageExplorer
    case pairingFiles
    case wirelessPair
    case anisetteData
    case connectionConfig
    case networkDiscovery
    case developerServices
    case profiles
    case certificates
    case backupRestore
    case sideJITServer
    case sideSignConfiguration
    case developerOptions
    case experimentalFeatures
    case credits
    case licenses
}

/// Rows that do something in place instead of pushing a page.
enum SettingsAction: Hashable, Identifiable {
    case signIn
    case signOut
    case clearCache
    case betaTrack
    case sendFeedback
    case howItWorks
    case siriShortcuts
    case refreshAttempts

    var id: Self { self }

    var title: String {
        switch self {
        case .signIn: return NSLocalizedString("Sign in with Apple ID", comment: "")
        case .signOut: return NSLocalizedString("Sign Out", comment: "")
        case .clearCache: return NSLocalizedString("Clear Cache", comment: "")
        case .betaTrack: return NSLocalizedString("Beta Updates Track", comment: "")
        case .sendFeedback: return NSLocalizedString("Send Feedback", comment: "")
        case .howItWorks: return NSLocalizedString("How it works", comment: "")
        case .siriShortcuts: return NSLocalizedString("Allow Siri To Refresh Apps…", comment: "")
        case .refreshAttempts: return NSLocalizedString("View Refresh Attempts", comment: "")
        }
    }
}

struct SettingsEntry: Identifiable {
    enum Kind {
        case navigation(SettingsDestination)
        case toggle(String)
        case action(SettingsAction)
    }

    let id: String
    let group: SettingsGroup
    let title: String
    let symbol: String
    let keywords: [String]
    let kind: Kind
    /// Mirrors the classic UI: diagnostics rows stay hidden until debug mode is on.
    var requiresDebug: Bool = false

    func matches(_ query: String) -> Bool {
        ([title] + keywords).joined(separator: " ").lowercased().contains(query)
    }
}

enum SettingsCatalog {
    /// Every action from the classic settings screen. Display text comes from Localizable.xcstrings;
    /// the keywords only exist here and cover both English and Chinese search terms.
    static let entries: [SettingsEntry] = [
        // MARK: Account
        .init(id: "signIn", group: .account, title: NSLocalizedString("Sign in with Apple ID", comment: ""), symbol: "person.badge.plus", keywords: ["登录", "苹果账号", "Apple ID", "Sign In", "认证"], kind: .action(.signIn)),
        .init(id: "account", group: .account, title: NSLocalizedString("Account", comment: ""), symbol: "person.crop.circle", keywords: ["账号", "账户", "姓名", "邮箱", "Name", "Email", "Type", "Version", "Apple ID"], kind: .navigation(.account)),
        .init(id: "signOut", group: .account, title: NSLocalizedString("Sign Out", comment: ""), symbol: "rectangle.portrait.and.arrow.right", keywords: ["退出登录", "登出", "注销", "Sign Out", "Log Out"], kind: .action(.signOut)),

        // MARK: Appearance & Themes
        .init(id: "appearance", group: .appearance, title: NSLocalizedString("Appearance", comment: ""), symbol: "paintbrush", keywords: ["外观", "界面", "新界面", "Appearance", "Interface", "New UI"], kind: .navigation(.appearance)),
        .init(id: "appIcon", group: .appearance, title: NSLocalizedString("Change App Icon", comment: ""), symbol: "app.badge", keywords: ["图标", "应用图标", "App Icon", "Icon"], kind: .navigation(.appIcon)),
        .init(id: "theme", group: .appearance, title: NSLocalizedString("Theme", comment: ""), symbol: "swatchpalette", keywords: ["主题", "配色", "颜色", "Theme", "Colour", "Color"], kind: .navigation(.themePicker)),
        .init(
            id: "userCustomizations", group: .appearance,
            title: NSLocalizedString("User Customizations", comment: ""),
            symbol: "slider.horizontal.3",
            keywords: ["自定义", "个性化", "Customizations", "Customize"],
            kind: .navigation(.userCustomizations)
        ),

        // MARK: Apps & Refreshing
        .init(id: "backgroundRefresh", group: .apps, title: NSLocalizedString("Background Refresh", comment: ""), symbol: "arrow.triangle.2.circlepath", keywords: ["后台刷新", "Background Refresh", "Refresh"], kind: .toggle("isBackgroundRefreshEnabled")),
        .init(id: "idleTimeout", group: .apps, title: NSLocalizedString("Disable Idle Timeout", comment: ""), symbol: "timer", keywords: ["空闲超时", "永不休眠", "Idle Timeout"], kind: .toggle("isIdleTimeoutDisableEnabled")),
        .init(
            id: "appLimit", group: .apps,
            title: NSLocalizedString("Disable App Limit", comment: ""),
            symbol: "square.stack.3d.up.slash",
            keywords: ["应用数量限制", "三个应用", "App Limit", "Active Apps Limit"],
            kind: .toggle("isAppLimitDisabled")
        ),
        .init(id: "siriShortcuts", group: .apps, title: NSLocalizedString("Allow Siri To Refresh Apps…", comment: ""), symbol: "mic", keywords: ["Siri", "快捷指令", "语音刷新", "Shortcuts"], kind: .action(.siriShortcuts)),
        .init(id: "refreshAttempts", group: .apps, title: NSLocalizedString("View Refresh Attempts", comment: ""), symbol: "clock.arrow.circlepath", keywords: ["刷新记录", "刷新尝试", "Refresh Attempts", "History"], kind: .action(.refreshAttempts)),
        .init(id: "container", group: .apps, title: NSLocalizedString("Container", comment: ""), symbol: "shippingbox", keywords: ["容器", "AirBox", "Container", "容器模式"], kind: .navigation(.container)),

        // MARK: Sources & Updates
        .init(id: "sources", group: .sources, title: NSLocalizedString("Sources", comment: ""), symbol: "square.stack.3d.down", keywords: ["源", "软件源", "添加源", "Sources", "Repos"], kind: .navigation(.sources)),
        .init(id: "betaUpdates", group: .sources, title: NSLocalizedString("Enable Beta Updates", comment: ""), symbol: "testtube.2", keywords: ["测试版", "开发版", "Beta", "Beta Updates"], kind: .toggle("isBetaUpdatesEnabled")),
        .init(id: "betaTrack", group: .sources, title: NSLocalizedString("Beta Updates Track", comment: ""), symbol: "eyedropper", keywords: ["通道", "更新通道", "开发版", "Track", "Channel", "Beta Track"], kind: .action(.betaTrack)),
        .init(
            id: "incrementalUpdates", group: .sources,
            title: NSLocalizedString("Incremental Updates", comment: ""),
            symbol: "square.and.arrow.down.on.square",
            keywords: ["增量更新", "补丁", "Incremental", "Delta", "Patch"],
            kind: .toggle("isIncrementalUpdateEnabled")
        ),

        // MARK: Developer
        .init(id: "healthCheck", group: .developer, title: NSLocalizedString("Health Check", comment: ""), symbol: "stethoscope", keywords: ["健康检查", "体检", "Health Check", "Diagnostics"], kind: .navigation(.healthCheck)),
        .init(id: "errorLog", group: .developer, title: NSLocalizedString("View Error Log", comment: ""), symbol: "doc.text.magnifyingglass", keywords: ["错误日志", "日志", "Error Log", "Console", "Log"], kind: .navigation(.errorLog)),
        .init(id: "storageExplorer", group: .developer, title: NSLocalizedString("Storage Explorer", comment: ""), symbol: "folder", keywords: ["存储", "文件浏览", "Storage Explorer", "Files"], kind: .navigation(.storageExplorer)),
        .init(id: "clearCache", group: .developer, title: NSLocalizedString("Clear Data Cache…", comment: ""), symbol: "trash", keywords: ["清除缓存", "清理缓存", "Clear Cache", "Cache"], kind: .action(.clearCache)),
        .init(id: "pairingFiles", group: .developer, title: NSLocalizedString("Pairing File Management", comment: ""), symbol: "cable.connector", keywords: ["配对文件", "Pairing File", "Pairing", "配对"], kind: .navigation(.pairingFiles)),
        .init(id: "wirelessPair", group: .developer, title: NSLocalizedString("Wireless Pairing", comment: ""), symbol: "wifi", keywords: ["无线配对", "Wireless Pair", "Remote Pairing"], kind: .navigation(.wirelessPair)),
        .init(id: "anisetteData", group: .developer, title: NSLocalizedString("Anisette Servers", comment: ""), symbol: "server.rack", keywords: ["Anisette", "服务器", "Anisette Servers", "ADI"], kind: .navigation(.anisetteData)),
        .init(id: "connectionConfig", group: .developer, title: NSLocalizedString("Connection Config", comment: ""), symbol: "network", keywords: ["连接配置", "Connection Config", "VPN", "Remote Server"], kind: .navigation(.connectionConfig)),
        .init(id: "networkDiscovery", group: .developer, title: NSLocalizedString("Network Discovery (mDNS)", comment: ""), symbol: "bonjour", keywords: ["网络发现", "mDNS", "Bonjour", "Network Discovery"], kind: .navigation(.networkDiscovery)),
        .init(id: "developerServices", group: .developer, title: NSLocalizedString("Developer Portal Services", comment: ""), symbol: "building.2", keywords: ["开发者服务", "App ID", "Developer Portal", "Services"], kind: .navigation(.developerServices)),
        .init(id: "profiles", group: .developer, title: NSLocalizedString("Profiles Management", comment: ""), symbol: "doc.badge.gearshape", keywords: ["描述文件", "Profiles", "Provisioning Profile"], kind: .navigation(.profiles)),
        .init(id: "certificates", group: .developer, title: NSLocalizedString("Certificate Management", comment: ""), symbol: "seal", keywords: ["证书", "Certificates", "Signing Certificate"], kind: .navigation(.certificates)),
        .init(id: "backupRestore", group: .developer, title: NSLocalizedString("Backup & Restore", comment: ""), symbol: "externaldrive", keywords: ["备份", "恢复", "Backup", "Restore"], kind: .navigation(.backupRestore)),
        .init(id: "sideJITServer", group: .developer, title: NSLocalizedString("SideJITServer", comment: ""), symbol: "bolt", keywords: ["JIT", "SideJITServer", "调试"], kind: .navigation(.sideJITServer)),
        .init(id: "sideSign", group: .developer, title: NSLocalizedString("SideSign Configuration", comment: ""), symbol: "signature", keywords: ["SideSign", "签名配置", "Signing"], kind: .navigation(.sideSignConfiguration)),
        .init(
            id: "verboseLogging", group: .developer,
            title: NSLocalizedString("Verbose Operations Logging", comment: ""),
            symbol: "text.alignleft",
            keywords: ["详细日志", "Verbose Logging", "Operations Log"],
            kind: .toggle("isVerboseOperationsLoggingEnabled")
        ),
        .init(id: "developerOptions", group: .developer, title: NSLocalizedString("Developer Options", comment: ""), symbol: "hammer", keywords: ["开发者选项", "Developer Options", "Debug"], kind: .navigation(.developerOptions), requiresDebug: true),
        .init(
            id: "experimentalFeatures", group: .developer,
            title: NSLocalizedString("Experimental Features", comment: ""),
            symbol: "flask",
            keywords: ["实验性功能", "Experimental Features", "Beta Features"],
            kind: .navigation(.experimentalFeatures), requiresDebug: true
        ),

        // MARK: About
        .init(id: "howItWorks", group: .about, title: NSLocalizedString("How it works", comment: ""), symbol: "questionmark.circle", keywords: ["怎么用", "原理", "How it works", "Help"], kind: .action(.howItWorks)),
        .init(id: "sendFeedback", group: .about, title: NSLocalizedString("Send Feedback", comment: ""), symbol: "envelope", keywords: ["反馈", "意见", "Send Feedback", "Contact", "Discord"], kind: .action(.sendFeedback)),
        .init(id: "credits", group: .about, title: NSLocalizedString("Credits", comment: ""), symbol: "heart", keywords: ["致谢", "开发者", "Credits", "Team", "Contributors"], kind: .navigation(.credits)),
        .init(id: "licenses", group: .about, title: NSLocalizedString("Licenses", comment: ""), symbol: "scroll", keywords: ["许可", "开源协议", "Licenses", "Open Source"], kind: .navigation(.licenses))
    ]
}
