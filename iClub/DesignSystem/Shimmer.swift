//
//  Shimmer.swift
//  iClub
//
//  Squelettes de chargement plutôt que des spinners plein écran : la structure
//  de l'écran reste lisible pendant le chargement.
//

import SwiftUI

/// Bloc de remplacement animé, calibré sur les surfaces de l'app.
struct SkeletonBlock: View {
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Brand.textSecondary.opacity(0.14))
            .frame(height: height)
            .shimmering()
    }
}

extension View {
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        guard active, !reduceMotion else { return AnyView(content) }

        return AnyView(
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                }
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        )
    }
}
