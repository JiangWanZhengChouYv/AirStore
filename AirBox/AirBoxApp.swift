//
//  AirBoxApp.swift
//  AirBox
//
//  Runs other apps inside this process instead of installing them, so the free
//  developer account's three-app / ten-App-ID limits do not apply. Stage 1: the
//  shell that imports packages and lists them. The loader lands next.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct AirBoxApp: App
{
    @StateObject private var store = GuestStore()

    var body: some Scene
    {
        WindowGroup {
            GuestListView(store: store)
                .onOpenURL { url in
                    // airbox://import — how AirStore hands over a package once the two apps share a group.
                    guard url.host == "import" else { return }
                    Task { await store.importFromSharedInbox() }
                }
        }
    }
}

struct GuestListView: View
{
    @ObservedObject var store: GuestStore
    @State private var isPickingPackage = false

    var body: some View
    {
        NavigationStack
        {
            Group
            {
                if self.store.packages.isEmpty
                {
                    ContentUnavailableView("No apps yet",
                                           systemImage: "shippingbox",
                                           description: Text("Add an unsigned .ipa. Apps run inside AirBox, so they do not use an App ID or expire in seven days."))
                }
                else
                {
                    List(self.store.packages) { package in
                        VStack(alignment: .leading, spacing: 2)
                        {
                            Text(package.name).font(.body)
                            Text(package.fileURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("AirBox")
            .toolbar
            {
                ToolbarItem(placement: .primaryAction)
                {
                    Button
                    {
                        self.isPickingPackage = true
                    }
                    label:
                    {
                        Label("Add App", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: self.$isPickingPackage,
                          allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .archive],
                          allowsMultipleSelection: false)
            { result in
                switch result
                {
                case .success(let urls): self.store.importPackage(at: urls[0])
                case .failure(let error): self.store.lastError = error.localizedDescription
                }
            }
            .alert("Import Failed", isPresented: Binding(get: { self.store.lastError != nil },
                                                         set: { if !$0 { self.store.lastError = nil } }))
            {
                Button("OK", role: .cancel) {}
            }
            message:
            {
                Text(self.store.lastError ?? "")
            }
        }
        .task { await self.store.reload() }
    }
}
