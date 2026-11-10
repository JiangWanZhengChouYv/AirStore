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
            ScrollView {
                if searchQuery.isEmpty {
                    featuredSection

                    ForEach(orderedSources, id: \.objectID) { source in
                        sourceShelf(source)
                    }
                } else {
                    searchResults
                }
            }
            .refreshable {
                await refreshAllSources()
            }
            .navigationTitle(NSLocalizedString("Browse", comment: ""))
            .searchable(text: $searchText, prompt: Text(NSLocalizedString("Search Apps", comment: "")))
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
            .overlay {
                if searchQuery.isEmpty && !hasAnyVisibleApps {
                    ContentUnavailableView {
                        Label(NSLocalizedString("No Apps", comment: ""), systemImage: "square.grid.2x2")
                    } description: {
                        Text(NSLocalizedString("Add a source or pull down to refresh.", comment: ""))
                    }
                }
            }
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var orderedSources: [Source] {
        sources.sorted { lhs, rhs in
            if lhs.identifier == Source.altStoreIdentifier { return true }
            if rhs.identifier == Source.altStoreIdentifier { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var allVisibleApps: [StoreApp] {
        orderedSources.flatMap { visibleApps(in: $0) }
    }

    private var hasAnyVisibleApps: Bool {
        !allVisibleApps.isEmpty
    }

    private var featuredApps: [StoreApp] {
        let builtInApps = orderedSources
            .first(where: { $0.identifier == Source.altStoreIdentifier })
            .map { visibleApps(in: $0) } ?? []
        let candidates = builtInApps.isEmpty ? allVisibleApps : builtInApps
        return Array(candidates.prefix(6))
    }

    @ViewBuilder
    private var featuredSection: some View {
        if !featuredApps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("Featured", comment: ""))
                    .font(.title2.bold())
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(featuredApps, id: \.objectID) { app in
                            NavigationLink {
                                NewAppDetailView(app: app)
                            } label: {
                                NewFeaturedCard(app: app)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func sourceShelf(_ source: Source) -> some View {
        let apps = visibleApps(in: source)
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RemoteImage(url: source.effectiveIconURL)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text(source.displayName)
                        .font(.title3.bold())

                    Spacer()

                    NavigationLink {
                        NewSourceAppsView(source: source)
                    } label: {
                        Text(NSLocalizedString("See All", comment: ""))
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(apps.prefix(12), id: \.objectID) { app in
                            NavigationLink {
                                NewAppDetailView(app: app)
                            } label: {
                                NewShelfCard(app: app)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let apps = allVisibleApps
        if apps.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(apps, id: \.objectID) { app in
                    NavigationLink {
                        NewAppDetailView(app: app)
                    } label: {
                        NewAppRow(app: app)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 84)
                }
            }
            .padding(.top, 8)
        }
    }

    private func visibleApps(in source: Source) -> [StoreApp] {
        source.apps.filter { app in
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
        let query = searchQuery.localizedLowercase
        guard !query.isEmpty else { return true }
        if app.name.localizedLowercase.contains(query) { return true }
        if app.developerName.localizedLowercase.contains(query) { return true }
        return app.bundleIdentifier.localizedLowercase.contains(query)
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

private struct NewFeaturedCard: View {
    @ObservedObject var app: StoreApp

    var body: some View {
        let tint = Color(uiColor: app.tintColor ?? ThemeManager.shared.primaryColor)

        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    RemoteImage(url: app.iconURL)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                        }

                    Spacer()

                    Text(actionTitle)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()

                Text(app.name)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(app.subtitle ?? app.developerName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(16)
        }
        .frame(width: 320, height: 190)
    }

    private var actionTitle: String {
        guard let installedApp = app.installedApp else {
            return NSLocalizedString("Install", comment: "")
        }
        return installedApp.hasUpdate
            ? NSLocalizedString("Update", comment: "")
            : NSLocalizedString("Open", comment: "")
    }
}

private struct NewShelfCard: View {
    @ObservedObject var app: StoreApp

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: app.iconURL)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(app.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text(app.subtitle ?? app.developerName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(actionTitle)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
        }
        .frame(width: 132, alignment: .leading)
    }

    private var actionTitle: String {
        guard let installedApp = app.installedApp else {
            return NSLocalizedString("Install", comment: "")
        }
        return installedApp.hasUpdate
            ? NSLocalizedString("Update", comment: "")
            : NSLocalizedString("Open", comment: "")
    }
}

private struct NewSourceAppsView: View {
    let source: Source

    var body: some View {
        List {
            ForEach(sortedApps, id: \.objectID) { app in
                NavigationLink {
                    NewAppDetailView(app: app)
                } label: {
                    NewAppRow(app: app)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(source.displayName)
    }

    private var sortedApps: [StoreApp] {
        source.apps
            .filter { !$0.isPledgeRequired || !$0.isHiddenWithoutPledge || $0.isPledged }
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
}
