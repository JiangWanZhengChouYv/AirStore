//
//  View+GlassSurface.swift
//  AltStore
//
//  One place that decides "glass where the system has it, the material this view already used where
//  it does not". Six screens each carried their own `.background(<material>)` plus a corner radius,
//  and a per-screen `if #available` would drift the moment one of them is retuned -- so the shape is
//  passed in and used by both branches, which keeps the silhouette identical either way.
//

import SwiftUI

extension View
{
    /// - Parameter interactive: hands the surface to the system's own touch response (iOS 26+). The
    ///   glass then dips and springs back the way a tab bar item does. Nothing can imitate that from
    ///   the outside: two attempts (a tinted row, then a scaled pane driven by a drag gesture) either
    ///   looked static or stole the scroll, because a recognizer next to a scroll view has to win the
    ///   touch to report it.
    func glassSurface<S: Shape>(in shape: S, material: Material = .ultraThinMaterial, interactive: Bool = false) -> some View
    {
        GlassSurface(content: self, shape: shape, material: material, interactive: interactive)
    }
}

private struct GlassSurface<SurfaceShape: Shape>: View
{
    let content: AnyView
    let shape: SurfaceShape
    let material: Material
    let interactive: Bool

    init<Content: View>(content: Content, shape: SurfaceShape, material: Material, interactive: Bool)
    {
        self.content = AnyView(content)
        self.shape = shape
        self.material = material
        self.interactive = interactive
    }

    var body: some View
    {
        if #available(iOS 26.0, *)
        {
            self.content.glassEffect(self.interactive ? .regular.interactive() : .regular, in: self.shape)
        }
        else
        {
            self.content.background(self.material, in: self.shape)
        }
    }
}
