import SwiftUI

struct GhostCursorOverlayView: View {
    @ObservedObject var store: GhostCursorStore
    let screenFrame: CGRect

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(store.renderStates(for: screenFrame)) { state in
                    GhostCursorGlyph(state: state)
                        .position(localPosition(for: state.point, canvasHeight: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .background(Color.clear)
    }

    private func localPosition(for globalPoint: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: globalPoint.x - screenFrame.minX,
            y: canvasHeight - (globalPoint.y - screenFrame.minY)
        )
    }
}

private struct GhostCursorGlyph: View {
    let state: GhostCursorRenderState

    private var debugLabelsEnabled: Bool {
        AppSettings.ghostCursorDebugLabelsEnabled
    }

    private var hotspotColor: Color {
        switch state.confidence {
        case .exact:
            return Color.accentColor.opacity(0.92)
        case .inferred:
            return Color.accentColor.opacity(0.72)
        case .coarse:
            return Color.white.opacity(0.58)
        }
    }

    var body: some View {
        ZStack {
            if state.pulseOpacity > 0.001 {
                Circle()
                    .stroke(hotspotColor.opacity(Double(state.pulseOpacity)), lineWidth: 1.4)
                    .frame(width: state.pulseRadius * 2, height: state.pulseRadius * 2)
            }

            Circle()
                .fill(hotspotColor)
                .frame(width: 5.5, height: 5.5)

            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.97))
                .shadow(color: .black.opacity(0.38), radius: 2.2, x: 0, y: 1)
                .offset(x: -8, y: -10)
                .scaleEffect(state.scale, anchor: .topLeading)

            if debugLabelsEnabled, let label = state.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
                    .offset(y: 28)
            }
        }
        .frame(width: 74, height: 74)
    }
}
