import SwiftUI

/// Liquid Glass on macOS 26 and later, frosted material before that.
extension View {
    @ViewBuilder
    func glass(_ radius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: .rect(cornerRadius: radius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.08)))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(macOS 26, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: .capsule)
        } else {
            self.background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
    }

    @ViewBuilder
    func glassGroup(spacing: CGFloat = 10) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// Capsule glass button. `prominent` tints it with the accent.
struct GlassPill: ButtonStyle {
    var prominent = false
    var small = false
    var tint: Color = Palette.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, small ? 9 : 12).padding(.vertical, small ? 3 : 5)
            .glassCapsule(tint: prominent ? tint.opacity(0.85) : nil)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct GlassIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(width: 22, height: 22)
            .glassCapsule()
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}
