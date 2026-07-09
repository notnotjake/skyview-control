import SwiftUI

/// Large preview of the lamp for the top of the main screen. When `glow` is
/// nil the lamp is off and renders as a neutral gray against the black app
/// background; a gradient here will later mirror the lamp's live color mix.
struct LampPreviewView: View {
    var glow: LinearGradient?

    var body: some View {
        ZStack {
            LampShape()
                .fill(Color(white: 0.16))

            if let glow {
                LampShape()
                    .fill(glow)
            }

            // Soft rim so the glass reads as a physical object, not a flat cutout.
            LampShape()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .black.opacity(0.15)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            LampShape()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .aspectRatio(LampShape.aspectRatio, contentMode: .fit)
    }
}

#Preview("Off") {
    LampPreviewView()
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
}

#Preview("Lit") {
    LampPreviewView(
        glow: LinearGradient(
            colors: [
                Color(red: 0.72, green: 0.85, blue: 0.98),
                Color(red: 0.90, green: 0.80, blue: 0.95),
                Color(red: 0.99, green: 0.87, blue: 0.78),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    )
    .padding(.horizontal, 80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
    .preferredColorScheme(.dark)
}
