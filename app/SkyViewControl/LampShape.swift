import SwiftUI

/// The silhouette of the SkyView lamp's glass: taller than wide, a full dome up
/// top and softer rounding at the bottom — the "airplane window" look.
struct LampShape: InsettableShape {
    /// Natural width-to-height proportion of the real lamp glass.
    static let aspectRatio: CGFloat = 0.72

    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> LampShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let topRadius = rect.width * 0.5
        let bottomRadius = rect.width * 0.36
        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        .path(in: rect)
    }
}

#Preview {
    LampShape()
        .fill(Color(white: 0.22))
        .aspectRatio(LampShape.aspectRatio, contentMode: .fit)
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
}
