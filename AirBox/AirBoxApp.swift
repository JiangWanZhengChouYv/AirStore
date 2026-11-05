//
//  AirBoxApp.swift
//  AirBox
//
//  Runs other apps inside this process instead of installing them, so the free
//  developer account's three-app / ten-App-ID limits do not apply.
//

import SwiftUI

/// The list, hosted from a UIKit delegate because `main.m` has to be able to skip it entirely and
/// start a guest instead.
@objc(AirBoxDelegate)
final class AirBoxDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    private let store = GuestStore()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: GuestListView(store: self.store))
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool
    {
        // airbox://import -- how AirStore hands over a package once the two apps share a group.
        // airbox://launch?name=<directory> -- the same app asking to run a guest already here, because
        // only this process can make a request to the extension it embeds.
        switch url.host
        {
        case "import":
            Task { await self.store.importFromSharedInbox() }
            return true

        case "launch":
            guard let name = self.queryValue(for: url, key: "name"), !name.isEmpty else { return false }
            Task { await self.store.launch(named: name) }
            return true

        default:
            return false
        }
    }

    private func queryValue(for url: URL, key: String) -> String?
    {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }
}

struct GuestListView: View
{
    @ObservedObject var store: GuestStore

    var body: some View
    {
        NavigationStack
        {
            Group
            {
                if self.store.guests.isEmpty
                {
                    ContentUnavailableView("No apps yet",
                                           systemImage: "shippingbox",
                                           description: Text("Apps run inside AirBox, so they do not use an App ID or expire in seven days."))
                }
                else
                {
                    List(self.store.guests) { guest in
                        Button
                        {
                            self.store.launch(guest)
                        }
                        label:
                        {
                            VStack(alignment: .leading, spacing: 2)
                            {
                                Text(guest.name).font(.body).foregroundStyle(.primary)
                                Text(guest.bundleIdentifier ?? guest.directory.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AirBox")
            .toolbar
            {
                ToolbarItem(placement: .primaryAction)
                {
                    // Nothing is unpacked here on purpose: a guest has to be signed with the same
                    // certificate as AirBox, and the store app is the one holding it. This looks in the
                    // shared inbox for whatever it prepared.
                    Button
                    {
                        Task { await self.store.importFromSharedInbox() }
                    }
                    label:
                    {
                        Label("Add Apps", systemImage: "arrow.down.circle")
                    }
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
            .alert("Open From AirStore", isPresented: Binding(get: { self.store.launchError != nil },
                                                              set: { if !$0 { self.store.launchError = nil } }))
            {
                Button("OK", role: .cancel) {}
            }
            message:
            {
                // The engine's own words, which is the whole point: a refused guest used to produce no
                // message at all, so the tap looked like a hang and the log was the only evidence.
                Text(self.store.launchError ?? "")
            }
        }
        .task { await self.store.reload() }
        // The second alert goes on the stack rather than beside the other one: two alerts on the same
        // view fight over presentation and one of them never shows.
        .alert("Launch Failed", isPresented: Binding(get: { self.store.launchError != nil },
                                                     set: { if !$0 { self.store.launchError = nil } }))
        {
            Button("OK", role: .cancel) {}
        }
        message:
        {
            Text(self.store.launchError ?? "")
        }
    }
}
