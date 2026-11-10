//
//  NewNewsView.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import CoreData

struct NewNewsView: View {
    @SwiftUI.FetchRequest private var newsItems: FetchedResults<NewsItem>

    @State private var selectedNews: NewsItem?
    @State private var isShowingNewsDetail = false

    init() {
        _newsItems = SwiftUI.FetchRequest(
            fetchRequest: NewsItem.sortedFetchRequest(for: nil),
            animation: .default
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(newsItems, id: \.objectID) { item in
                    row(for: item)
                }
            }
            .listStyle(.plain)
            .navigationTitle(NSLocalizedString("News", comment: ""))
            .refreshable {
                await refreshAllSources()
            }
            .overlay {
                if newsItems.isEmpty {
                    ContentUnavailableView {
                        Label(NSLocalizedString("No News", comment: ""), systemImage: "newspaper")
                    } description: {
                        Text(NSLocalizedString("News from your sources appears here.", comment: ""))
                    }
                }
            }
            .sheet(isPresented: $isShowingNewsDetail) {
                if let selectedNews {
                    NewsDetailView(item: selectedNews)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: NewsItem) -> some View {
        if let storeApp = item.storeApp {
            NavigationLink {
                NewAppDetailView(app: storeApp)
            } label: {
                content(for: item)
            }
        } else {
            SwiftUI.Button {
                handleTap(item)
            } label: {
                content(for: item)
            }
            .buttonStyle(.plain)
        }
    }

    private func content(for item: NewsItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.imageURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(uiColor: item.tintColor).opacity(0.35), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)

                Text(markdown(item.caption))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    Text(item.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let source = item.source {
                        Text(source.displayName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if item.externalURL != nil {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func handleTap(_ item: NewsItem) {
        if let externalURL = item.externalURL {
            UIApplication.shared.open(externalURL)
            return
        }

        selectedNews = item
        isShowingNewsDetail = true
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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

private struct NewsDetailView: View {
    @ObservedObject var item: NewsItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let imageURL = item.imageURL {
                        RemoteImage(url: imageURL, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Text(item.title)
                        .font(.title2.bold())

                    HStack(spacing: 8) {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let source = item.source {
                            Text(source.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(markdown(item.caption))
                        .font(.body)

                    if let externalURL = item.externalURL {
                        SwiftUI.Button {
                            UIApplication.shared.open(externalURL)
                        } label: {
                            Text(NSLocalizedString("Open", comment: ""))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle(item.title)
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

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
