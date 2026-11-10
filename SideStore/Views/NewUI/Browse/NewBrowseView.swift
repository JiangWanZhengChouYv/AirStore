//
//  NewBrowseView.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import CoreData

struct NewBrowseView: View {
    @ObservedObject var router: NewRootRouter

    @SwiftUI.FetchRequest private var sources: FetchedResults<Source>
    @State private var searchText = ""

    init(router: NewRootRouter) {
        self.router = router
        _sources = SwiftUI.FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Source.name, ascending: true)],
            animation: .default
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedSources, id: \.objectID) { source in
                    sourceSection(source)
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if !hasAnyVisibleApps {
                    ContentUnavailableView {
                        Label(NSLocalizedString("No Apps", comment: ""), systemImage: "square.grid.2x2")
                    } description: {
                        Text(NSLocalizedString("Add a source or pull down to refresh.", comment: ""))
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text(NSLocalizedString("Search Apps", comment: "")))
            .refreshable {
                await refreshAllSources()
            }
            .navigationTitle(NSLocalizedString("Browse", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SwiftUI.Button {
                        router.isPresentingSources = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("Add Source", comment: ""))
                }
            }
            .sheet(isPresented: $router.isPresentingSources) {
                NewSourcesSheet(pendingSourceURL: router.pendingSourceURL) {
                    router.pendingSourceURL = nil
                }
            }
        }
    }

    @ViewBuilder
    private func sourceSection(_ source: Source) -> some View {
        let apps = visibleApps(in: source)
        if !apps.isEmpty {
            Section {
                ForEach(apps, id: \.objectID) { app in
                    NavigationLink {
                        NewAppDetailView(app: app)
                    } label: {
                        NewAppRow(app: app)
                    }
                }
            } header: {
                sourceHeader(source)
            }
        }
    }

    private var orderedSources: [Source] {
        sources.sorted { lhs, rhs in
            if lhs.identifier == Source.altStoreIdentifier { return true }
            if rhs.identifier == Source.altStoreIdentifier { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var hasAnyVisibleApps: Bool {
        orderedSources.contains { !visibleApps(in: $0).isEmpty }
    }

    private func visibleApps(in source: Source) -> [StoreApp] {
        source.apps.filter { app in
            // The store's own entry and AirBox live in the built-in source and are just as much
            // part of it as third-party apps; the old Browse hid them, the new one does not.
            guard !app.isPledgeRequired || !app.isHiddenWithoutPledge || app.isPledged else { return false }
            return matchesSearch(app)
        }
        .sorted { lhs, rhs in
            switch (lhs.featuredSortID, rhs.featuredSortID) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func matchesSearch(_ app: StoreApp) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return true }
        if app.name.localizedLowercase.contains(query) { return true }
        if app.developerName.localizedLowercase.contains(query) { return true }
        return app.bundleIdentifier.localizedLowercase.contains(query)
    }

    private func sourceHeader(_ source: Source) -> some View {
        HStack(spacing: 8) {
            RemoteImage(url: source.effectiveIconURL)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(source.displayName)

            Spacer()

            if source.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(NSLocalizedString("This source could not be loaded.", comment: ""))
            }
        }
    }

    @MainActor
    private func refreshAllSources() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AppManager.shared.updateAllSources { result in
                if case .failure(let error) = result, !(error is CancellationError) {
                    NewUIFeedback.present(error)
                }
                continuation.resume()
            }
        }
    }
}
