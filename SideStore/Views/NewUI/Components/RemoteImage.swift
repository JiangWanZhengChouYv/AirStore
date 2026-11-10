//
//  RemoteImage.swift
//  SideStore
//
//  Created by AirStore on 2026/11/10.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Nuke

/// Uses the same Nuke pipeline as the rest of the app, so a page built in SwiftUI warms the cache
/// the UIKit screens already use instead of downloading the same icon twice.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = try? await ImagePipeline.shared.image(for: url)
        }
    }
}
