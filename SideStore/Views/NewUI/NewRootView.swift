//
//  NewRootView.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI

enum NewRootTab: Hashable {
    case news
    case browse
    case myApps
    case settings
}

@MainActor
final class NewRootRouter: ObservableObject {
    @Published var selectedTab: NewRootTab = .browse
    @Published var isPresentingSources = false
    @Published var pendingSourceURL: URL?
}

/// Hosts the SwiftUI shell and gives UIKit call sites (the launch toast, later deep links) a
/// selector to aim at. Only one of this and `TabBarController` is ever the root.
final class NewUIRootController: UIViewController {
    let router = NewRootRouter()

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        registerForDeepLinks()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDeepLinks()
    }

    /// Registered in init, not in viewDidLoad: the old shell exists before the splash finishes, and
    /// a cold launch from a file or deep link must not arrive at a view that has not subscribed yet.
    private func registerForDeepLinks() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleImportApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAddSource(_:)), name: AppDelegate.addSourceDeepLinkNotification, object: nil)
        center.addObserver(self, selector: #selector(handleOpenErrorLog(_:)), name: ToastView.openErrorLogNotification, object: nil)
    }

    @objc private func handleImportApp(_ notification: Notification) {
        router.selectedTab = .myApps
    }

    @objc private func handleAddSource(_ notification: Notification) {
        router.selectedTab = .browse
        router.pendingSourceURL = notification.userInfo?[AppDelegate.addSourceDeepLinkURLKey] as? URL
        router.isPresentingSources = true
    }

    @objc private func handleOpenErrorLog(_ notification: Notification) {
        router.selectedTab = .settings
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Without this the whole new shell reads from an empty default context: every @FetchRequest
        // (sources, installed apps, news) silently returns nothing while the old UI shows the data.
        let rootView = NewRootView(router: router)
            .environment(\.managedObjectContext, DatabaseManager.shared.viewContext)
        let hostingController = UIHostingController(rootView: rootView)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    @objc func presentSources() {
        router.selectedTab = .browse
        router.isPresentingSources = true
    }
}

struct NewRootView: View {
    @ObservedObject var router: NewRootRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NewNewsView()
                .tabItem { Label(NSLocalizedString("News", comment: ""), systemImage: "newspaper") }
                .tag(NewRootTab.news)

            NewBrowseView(router: router)
                .tabItem { Label(NSLocalizedString("Browse", comment: ""), systemImage: "square.grid.2x2") }
                .tag(NewRootTab.browse)

            NewMyAppsView()
                .tabItem { Label(NSLocalizedString("My Apps", comment: ""), systemImage: "square.stack.3d.up") }
                .tag(NewRootTab.myApps)

            NavigationStack {
                List {
                    NavigationLink(NSLocalizedString("Appearance", comment: "")) {
                        AppearanceSettingsView()
                    }
                }
                .navigationTitle(NSLocalizedString("Settings", comment: ""))
            }
            .tabItem { Label(NSLocalizedString("Settings", comment: ""), systemImage: "gearshape") }
            .tag(NewRootTab.settings)
        }
    }
}
