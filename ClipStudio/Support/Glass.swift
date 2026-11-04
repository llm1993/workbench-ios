import SwiftUI

struct AmbientBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var body: some View {
        ZStack {
            Theme.background
            if !opaque {
                LinearGradient(colors: [Theme.accentSoft.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260).frame(maxHeight: .infinity, alignment: .top)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct GlassBar: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if opaque || contrast == .increased { Theme.surface }
            else { Rectangle().fill(.regularMaterial) }
        }.overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if opaque || contrast == .increased { shape.fill(Theme.surface) }
                else { shape.fill(.thinMaterial) }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.18 : 0.8), Theme.line],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.035), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func glassSurface(radius: CGFloat = 24) -> some View { modifier(GlassSurface(radius: radius)) }
    func panelSurface(radius: CGFloat = 20) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line.opacity(0.65), lineWidth: 0.5).allowsHitTesting(false) }
    }
}

struct GlassPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
