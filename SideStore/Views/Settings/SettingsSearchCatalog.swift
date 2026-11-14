//
//  SettingsSearchCatalog.swift
//  SideStore
//
//  What lives inside each settings page, for the search field on the settings home.
//
//  The rows on the home screen are SwiftUI values, so they index themselves; the pages behind them are
//  arbitrary views and cannot be walked. This is that second level written down: the strings are the
//  same keys those pages already use, so searching "WireGuard" or "Keychain" finds the page that holds
//  it and the result opens that page.
//
//  Keep this beside the page: when a row is added to one of these screens, add its title here, or the
//  only way to reach it stays scrolling.
//

import Foundation

enum SettingsSearchCatalog
{
    /// Second-level entries, keyed by the home row that opens the page they live on.
    static let children: [String: [String]] = [
        "appearance.theme": [
            "Theme Manager",
            "App Language",
            "Anisette Client Configuration",
            "Reset adi.pb",
            "SideSign Client Configuration",
            "Export WireGuard Config",
            "Customize Extensions",
            "Default Import Mode",
            "Reset to Defaults"
        ],

        "connection.pairing": [
            "Import Pairing File",
            "Import / Replace File",
            "Delete Pairing File",
            "Active Protocol",
            "Preferred Protocol",
            "Clear Preferred Protocol",
            "Toggle Sensitive Information",
            "Reset Pairing Files?"
        ],

        "connection.anisette": [
            "Available Servers",
            "Server List URL",
            "Server Catalog Source",
            "Export Current",
            "Reset Catalog",
            "Enable Auto Rotation",
            "Auto Probe Servers",
            "Re-probe Now"
        ],

        "connection.config": [
            "Remote Endpoint",
            "WireGuard Server Parameters",
            "Auto Discovered from network",
            "User Configuration"
        ],

        "connection.container": [
            "Container Mode",
            "AirBox"
        ],

        "connection.jit": [
            "Enable SideJITServer",
            "Server Address",
            "Resolution Mode",
            "Test Connection (Ping)",
            "Refresh Device Cache (/re/)",
            "Check Version Info (/ver/)"
        ],

        "diag.dev": [
            "Operations Logging Control",
            "Export Database",
            "Clear Refresh Attempts",
            "Delete Database",
            "Clear Keychain Items",
            "Start EMProxy",
            "Stop EMProxy",
            "Timeout (ms)",
            "Import Account JSON",
            "Export Account JSON",
            "Dump Provisioning Profiles",
            "Replay Onboarding",
            "Reset Onboarding State"
        ],

        "diag.experimental": [
            "Wireless Pairing",
            "Cache Management",
            "Minimuxer"
        ],

        "diag.backup": [
            "Import Account",
            "Export Account",
            "Import Sources",
            "Export Sources"
        ],

        "diag.storage": [
            "App Storage Containers",
            "App Storage Used:",
            "Available Space:",
            "Total Space:"
        ],

        "diag.health": [
            "Core Requirements",
            "JIT Requirements",
            "Connection Configuration",
            "Active Network Interfaces"
        ],

        "connection.profiles": [
            "Provisioning Profiles",
            "Delete All Profiles on Portal"
        ],

        "connection.certificates": [
            "All Certificates",
            "Create Certificate",
            "Import Certificates",
            "Toggle Hide Sensitive Information",
            "Revoke",
            "Deactivate"
        ],

        "connection.portal": [
            "Developer Portal Services",
            "App IDs",
            "App Groups",
            "Provisioning Profiles",
            "Certificates",
            "Registered Devices"
        ]
    ]

    /// Resolved at display time so a Chinese phone shows — and matches — the Chinese title the page
    /// itself uses for the same key.
    static func title(for key: String) -> String
    {
        NSLocalizedString(key, comment: "settings search result")
    }
}
