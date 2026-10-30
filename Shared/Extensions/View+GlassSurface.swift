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
    func glassSurface<S: Shape>(in shape: S, material: Material = .ultraThinMaterial) -> some View
    {
        GlassSurface(content: self, shape: shape, material: material)
    }
}

private struct GlassSurface<SurfaceShape: Shape>: View
{
    let content: AnyView
    let shape: SurfaceShape
    let material: Material

    init<Content: View>(content: Content, shape: SurfaceShape, material: Material)
    {
        self.content = AnyView(content)
        self.shape = shape
        self.material = material
    }

    var body: some View
    {
        if #available(iOS 26.0, *)
        {
            self.content.glassEffect(.regular, in: self.shape)
        }
        else
        {
            self.content.background(self.material, in: self.shape)
        }
    }
}
