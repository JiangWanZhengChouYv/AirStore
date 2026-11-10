//
//  NewSourcesSheet.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import CoreData

private struct RecommendedSource: Identifiable, Sendable {
    let url: URL
    let name: String
    let iconURL: URL?

    var id: String { url.absoluteString }
}

struct NewSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @SwiftUI.FetchRequest private var sources: FetchedResults<Source>

    @State private var sourceURLText = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var didHandlePendingSourceURL = false
    @State private var recommendedSources: [RecommendedSource] = []
    @State private var isLoadingRecommended = false

    let pendingSourceURL: URL?
    let onPendingSourceHandled: () -> Void

    init(pendingSourceURL: URL?, onPendingSourceHandled: @escaping () -> Void) {
        self.pendingSourceURL = pendingSourceURL
        self.onPendingSourceHandled = onPendingSourceHandled
        _sources = SwiftUI.FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Source.name, ascending: true)],
            animation: .default
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedSources, id: \.objectID) { source in
                        sourceRow(source)
                            .swipeActions(edge: .trailing) {
                                if source.identifier != Source.altStoreIdentifier {
                                    SwiftUI.Button(role: .destructive) {
                                        remove(source)
                                    } label: {
                                        Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                    }
                                }
                            }
                    }
                } header: {
                    Text(NSLocalizedString("Sources", comment: ""))
                }

                if isLoadingRecommended || !recommendedSources.isEmpty {
                    Section {
                        if isLoadingRecommended {
                            ProgressView()
                        }

                        ForEach(recommendedSources) { source in
                            HStack(spacing: 10) {
                                RemoteImage(url: source.iconURL)
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.body)
                                    Text(source.url.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                SwiftUI.Button(NSLocalizedString("Add", comment: "")) {
                                    addSource(source.url.absoluteString)
                                    recommendedSources.removeAll { $0.id == source.id }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text(NSLocalizedString("Recommended", comment: ""))
                    }
                }

                Section {
                    TextField(NSLocalizedString("Source URL", comment: ""), text: $sourceURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SwiftUI.Button {
                        addSource(sourceURLText)
                    } label: {
                        if isAdding {
                            ProgressView()
                        } else {
                            Text(NSLocalizedString("Add Source", comment: ""))
                        }
                    }
                    .disabled(isAdding || sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(NSLocalizedString("Add Source", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Sources", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button(NSLocalizedString("Done", comment: "")) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                handlePendingSourceURL()
                loadRecommendedSources()
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

    private func sourceRow(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(source.displayName)
                    .font(.headline)

                if source.identifier == Source.altStoreIdentifier {
                    Text(NSLocalizedString("Built-in", comment: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(source.apps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(source.sourceURL.absoluteString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let error = source.error {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func loadRecommendedSources() {
        guard recommendedSources.isEmpty, !isLoadingRecommended else { return }

        isLoadingRecommended = true
        AppManager.shared.updateKnownSources { result in
            guard case .success(let (defaults, _)) = result else {
                DispatchQueue.main.async {
                    isLoadingRecommended = false
                }
                return
            }

            let urls = defaults.prefix(6).compactMap(\.sourceURL)
            Task {
                var loaded: [RecommendedSource] = []
                await withTaskGroup(of: RecommendedSource?.self) { group in
                    for url in urls {
                        group.addTask {
                            await Self.previewRecommendedSource(url: url)
                        }
                    }
                    for await source in group {
                        if let source {
                            loaded.append(source)
                        }
                    }
                }

                let sorted = loaded.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                await MainActor.run {
                    recommendedSources = sorted
                    isLoadingRecommended = false
                }
            }
        }
    }

    /// Fetches a source into a throwaway context just to learn its name and icon; nothing is saved
    /// here, so a preview cannot leave a half-added source behind.
    private static func previewRecommendedSource(url: URL) async -> RecommendedSource? {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        guard let source = try? await AppManager.shared.fetchSource(sourceURL: url,
                                                                     managedObjectContext: context) else {
            return nil
        }

        return await context.perform {
            RecommendedSource(url: source.sourceURL,
                              name: source.name,
                              iconURL: source.effectiveIconURL)
        }
    }

    private func handlePendingSourceURL() {
        // onAppear can run again after an alert or a sheet dismissal; the link should be consumed once.
        guard !didHandlePendingSourceURL, let pendingSourceURL else { return }
        didHandlePendingSourceURL = true
        sourceURLText = pendingSourceURL.absoluteString
        onPendingSourceHandled()
        addSource(pendingSourceURL.absoluteString)
    }

    @MainActor
    private func addSource(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = NSLocalizedString("Enter a valid source URL.", comment: "")
            return
        }

        if sources.contains(where: { $0.sourceURL.absoluteString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) {
            errorMessage = NSLocalizedString("That source is already added.", comment: "")
            return
        }

        isAdding = true
        errorMessage = nil
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()

        Task {
            do {
                let fetchedSource = try await AppManager.shared.fetchSource(sourceURL: url, managedObjectContext: context)
                // fetchSource leaves the source in the context it was handed; saving is what puts
                // it in the store the view context reads from.
                try await context.performAsync {
                    try context.save()
                }
                let objectID = fetchedSource.objectID
                await MainActor.run {
                    // Pulling the row into the view context is what makes @FetchRequest show it
                    // immediately, instead of waiting for the next merge.
                    _ = try? DatabaseManager.shared.viewContext.existingObject(with: objectID)
                    isAdding = false
                    sourceURLText = ""
                }
            } catch {
                await MainActor.run {
                    isAdding = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func remove(_ source: Source) {
        guard let viewController = UIApplication.shared.topViewController() else { return }
        Task {
            do {
                try await AppManager.shared.remove(source, presentingViewController: viewController)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
