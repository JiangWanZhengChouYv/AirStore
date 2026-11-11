//
//  NewMyAppsView.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import CoreData
import Combine
import UniformTypeIdentifiers

struct NewMyAppsView: View {
    private enum ActiveAlert: Identifiable {
        case removeApp(InstalledApp)
        case removeContainer(ContainerApp)
        case message(String)

        var id: String {
            switch self {
            case .removeApp(let app):
                return "app-\(app.objectID.uriRepresentation().absoluteString)"
            case .removeContainer(let app):
                return "container-\(app.id)"
            case .message(let message):
                return "message-\(message)"
            }
        }
    }

    @SwiftUI.FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \InstalledApp.name, ascending: true)],
        animation: .default
    )
    private var installedApps: FetchedResults<InstalledApp>

    @State private var searchText = ""
    @State private var containerApps: [ContainerApp] = []
    @State private var progressTick = 0
    @State private var activeAlert: ActiveAlert?
    @State private var isShowingFileImporter = false
    @StateObject private var importProgress = InstallProgressObserver()

    private let progressTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                if importProgress.isActive {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: importProgress.fractionCompleted ?? 0)
                            Text(NSLocalizedString("Installing…", comment: ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !updateApps.isEmpty {
                    Section {
                        ForEach(updateApps, id: \.objectID) { app in
                            installedRow(app)
                        }
                    } header: {
                        Text(NSLocalizedString("Updates", comment: ""))
                    }
                }

                if !activeApps.isEmpty {
                    Section {
                        ForEach(activeApps, id: \.objectID) { app in
                            installedRow(app)
                        }
                    } header: {
                        Text(NSLocalizedString("Active Apps", comment: ""))
                    }
                }

                if !inactiveApps.isEmpty {
                    Section {
                        ForEach(inactiveApps, id: \.objectID) { app in
                            installedRow(app)
                        }
                    } header: {
                        Text(NSLocalizedString("Inactive Apps", comment: ""))
                    }
                }

                if !visibleContainerApps.isEmpty {
                    Section {
                        ForEach(visibleContainerApps) { app in
                            containerRow(app)
                        }
                    } header: {
                        Text(NSLocalizedString("Apps in AirBox", comment: ""))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if installedApps.isEmpty && containerApps.isEmpty {
                    ContentUnavailableView {
                        Label(NSLocalizedString("No Installed Apps", comment: ""), systemImage: "square.stack.3d.up")
                    } description: {
                        Text(NSLocalizedString("Apps you install from Browse appear here.", comment: ""))
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text(NSLocalizedString("Search Apps", comment: "")))
            .navigationTitle(NSLocalizedString("My Apps", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SwiftUI.Button {
                        isShowingFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("Install App", comment: ""))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Button(action: refreshAll) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(NSLocalizedString("Refresh All", comment: ""))
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importIPA(from: url)
                case .failure(let error):
                    NewUIFeedback.present(error)
                }
            }
            .onAppear(perform: reloadContainerApps)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                reloadContainerApps()
            }
            .onReceive(progressTimer) { _ in
                progressTick &+= 1
            }
            .alert(item: $activeAlert) { alert in
                self.makeAlert(alert)
            }
        }
    }

    private var visibleApps: [InstalledApp] {
        installedApps.filter(matchesSearch)
    }

    private var updateApps: [InstalledApp] {
        visibleApps.filter { $0.isActive && $0.hasUpdate }
    }

    private var activeApps: [InstalledApp] {
        visibleApps.filter { $0.isActive && !$0.hasUpdate }
    }

    private var inactiveApps: [InstalledApp] {
        visibleApps.filter { !$0.isActive }
    }

    private var visibleContainerApps: [ContainerApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return containerApps }
        return containerApps.filter {
            $0.name.localizedLowercase.contains(query)
                || ($0.bundleIdentifier?.localizedLowercase.contains(query) ?? false)
        }
    }

    private func matchesSearch(_ app: InstalledApp) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return true }
        return app.name.localizedLowercase.contains(query)
            || app.bundleIdentifier.localizedLowercase.contains(query)
    }

    private func installedRow(_ app: InstalledApp) -> some View {
        SwiftUI.Button {
            if app.isActive {
                open(app)
            }
        } label: {
            NewInstalledAppRow(
                app: app,
                progressFraction: progressFraction(for: app),
                onUpdate: app.hasUpdate ? { update(app) } : nil
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if app.isActive {
                SwiftUI.Button {
                    open(app)
                } label: {
                    Label(NSLocalizedString("Open", comment: ""), systemImage: "arrow.up.forward.app")
                }

                SwiftUI.Button {
                    refresh(app)
                } label: {
                    Label(NSLocalizedString("Refresh", comment: ""), systemImage: "arrow.clockwise")
                }

                SwiftUI.Button {
                    enableJIT(app)
                } label: {
                    Label(NSLocalizedString("Enable JIT", comment: ""), systemImage: "bolt")
                }

            } else {
                SwiftUI.Button(role: .destructive) {
                    activeAlert = .removeApp(app)
                } label: {
                    Label(NSLocalizedString("Remove", comment: ""), systemImage: "trash")
                }
            }
        }
    }

    private func containerRow(_ app: ContainerApp) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconFileURL)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)

                if let version = app.version {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if availableUpdate(for: app) != nil {
                Text(NSLocalizedString("Update in AirBox", comment: ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            act(on: app)
        }
        .contextMenu {
            SwiftUI.Button {
                openInAirBox(app)
            } label: {
                Label(NSLocalizedString("Open in AirBox", comment: ""), systemImage: "shippingbox")
            }

            if let version = availableUpdate(for: app) {
                SwiftUI.Button {
                    guard let viewController = self.topViewController else { return }
                    ContainerInstallAction.run(version: version, appName: app.name, from: viewController)
                } label: {
                    Label(NSLocalizedString("Update in AirBox", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                }
            }

            SwiftUI.Button(role: .destructive) {
                activeAlert = .removeContainer(app)
            } label: {
                Label(NSLocalizedString("Remove from AirBox", comment: ""), systemImage: "trash")
            }
        }
    }

    private var topViewController: UIViewController? {
        UIApplication.shared.topViewController()
    }

    private func progressFraction(for app: InstalledApp) -> Double? {
        _ = progressTick

        let progress = AppManager.shared.refreshProgress(for: app) ?? AppManager.shared.installationProgress(for: app)
        guard let progress else { return nil }

        let fraction = progress.fractionCompleted
        guard fraction > 0, fraction < 1 else { return nil }
        return fraction
    }

    private func open(_ app: InstalledApp) {
        let url = app.openAppURL
        debugLog("[NewMyApps] Opening \(app.bundleIdentifier) via \(url.absoluteString)")
        UIApplication.shared.open(url) { success in
            guard !success else { return }
            NewUIFeedback.present(OperationError.openAppFailed(name: app.name))
        }
    }

    private func refresh(_ app: InstalledApp) {
        guard let viewController = topViewController else { return }
        _ = AppManager.shared.refresh([app], presentingViewController: viewController)
    }

    private func refreshAll() {
        let apps = installedApps.filter { $0.isActive }
        guard !apps.isEmpty, let viewController = topViewController else { return }
        _ = AppManager.shared.refresh(Array(apps), presentingViewController: viewController)
    }

    private func update(_ app: InstalledApp) {
        guard let version = app.storeApp?.latestSupportedVersion,
              let viewController = topViewController else { return }

        _ = AppManager.shared.update(app, to: version, presentingViewController: viewController) { result in
            DispatchQueue.main.async {
                app.managedObjectContext?.refresh(app, mergeChanges: true)
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
            }
        }
    }

    private func enableJIT(_ app: InstalledApp) {
        let hudID = "enable-jit-\(app.bundleIdentifier)"
        DownloadProgressHUD.shared.beginOperation(
            id: hudID,
            title: String(format: NSLocalizedString("Enabling JIT for %@…", comment: ""), app.name),
            subtitle: NSLocalizedString("Finding the running app…", comment: "")
        )

        AppManager.shared.enableJIT(for: app, progressHandler: { value, stage in
            Task { @MainActor in
                DownloadProgressHUD.shared.updateOperation(id: hudID, fraction: Double(value) / 100.0, subtitle: stage)
            }
        }) { result in
            DispatchQueue.main.async {
                DownloadProgressHUD.shared.end(id: hudID)
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
            }
        }
    }

    private func importIPA(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            NewUIFeedback.present(error)
            return
        }

        guard let viewController = topViewController else { return }
        InstallAppDialog.present(ipaURL: destination, from: viewController) { [self] in
            performImport(destination, presentingViewController: viewController)
        }
    }

    private func performImport(_ url: URL, presentingViewController viewController: UIViewController) {
        let group = AppManager.shared.install(.url(url), presentingViewController: viewController) { result in
            DispatchQueue.main.async {
                importProgress.track(nil)
                try? FileManager.default.removeItem(at: url)
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
            }
        }

        importProgress.track(group.progress)
    }

    private func reloadContainerApps() {
        containerApps = ContainerLibrary.shared.apps()
    }

    private func availableUpdate(for app: ContainerApp) -> AppVersion? {
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }

        let request = StoreApp.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(StoreApp.bundleIdentifier), bundleIdentifier)
        request.fetchLimit = 1

        let context = DatabaseManager.shared.viewContext
        guard let storeApp = (try? context.fetch(request))?.first,
              let version = storeApp.latestAvailableVersion,
              version.version != app.version else { return nil }
        return version
    }

    private func act(on app: ContainerApp) {
        // The same app can be in both places: installed on the system and copied into AirBox. The
        // user tapping it means "open the app", so prefer the system copy and leave AirBox as an
        // explicit choice in the context menu.
        if let bundleIdentifier = app.bundleIdentifier,
           let installedApp = installedApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            open(installedApp)
            return
        }

        if let version = availableUpdate(for: app) {
            guard let viewController = topViewController else { return }
            ContainerInstallAction.run(version: version, appName: app.name, from: viewController)
        } else {
            openInAirBox(app)
        }
    }

    private func openInAirBox(_ app: ContainerApp) {
        guard ContainerLibrary.shared.stageLaunch(app) else {
            activeAlert = .message(NSLocalizedString("AirStore could not reach the shared folder AirBox reads.", comment: ""))
            return
        }

        let context = DatabaseManager.shared.viewContext
        guard InstalledApp.all(in: context).contains(where: { ContainerInstaller.isAirBox($0) }) else {
            activeAlert = .message(NSLocalizedString("AirBox is not installed. Install it before opening apps in it.", comment: ""))
            return
        }

        guard let url = URL(string: "airbox://") else { return }
        UIApplication.shared.open(url)
    }

    private func remove(_ app: InstalledApp) {
        AppManager.shared.removeDeactivatedApp(app) { result in
            DispatchQueue.main.async {
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
            }
        }
    }

    private func removeContainer(_ app: ContainerApp) {
        ContainerLibrary.shared.remove(app)
        reloadContainerApps()
    }

    private func makeAlert(_ alert: ActiveAlert) -> Alert {
        switch alert {
        case .removeApp(let app):
            return Alert(
                title: Text(String(format: NSLocalizedString("Remove “%@” from AirStore?", comment: ""), app.name)),
                message: Text(NSLocalizedString("This will also erase any backup data for this app.", comment: "")),
                primaryButton: .destructive(Text(NSLocalizedString("Remove", comment: ""))) {
                    remove(app)
                },
                secondaryButton: .cancel()
            )

        case .removeContainer(let app):
            return Alert(
                title: Text(NSLocalizedString("Remove from AirBox?", comment: "")),
                message: Text(String(format: NSLocalizedString("%@ will stop running inside AirBox. Its data goes with it.", comment: ""), app.name)),
                primaryButton: .destructive(Text(NSLocalizedString("Remove", comment: ""))) {
                    removeContainer(app)
                },
                secondaryButton: .cancel()
            )

        case .message(let message):
            return Alert(title: Text(message), dismissButton: .default(Text(NSLocalizedString("OK", comment: ""))))
        }
    }
}
