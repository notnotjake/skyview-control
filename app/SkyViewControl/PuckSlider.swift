import SwiftUI

/// Large capsule slider: a gradient track with a milky-white puck dragged
/// along it. A thin top-lit rim stroke lifts the capsule off the black
/// background.
///
/// Dragging is relative — the puck moves with the finger's travel from
/// wherever the touch starts, so grabbing the track away from the puck
/// doesn't jump the value.
struct PuckSlider: View {
    @Binding var value: Double
    var label: String
    var stops: [Gradient.Stop]
    /// Embeds a power button in the track's left end, with the puck's range
    /// starting just right of it — the gradient starts there too. Tapping
    /// the button slides the value to zero or back to where it last was;
    /// dragging the puck out of its range on the left docks it onto the
    /// button with a thunk. Zero means off; on-values start at
    /// `minimumValue`.
    var hasPowerWell = false
    /// Fires a detent tick when a drag crosses a multiple of this.
    var detentStep: Double? = nil
    /// The haptic played at each detent crossing.
    var detentFeedback: SensoryFeedback = .selection

    /// Also the diameter of the circular buttons that share a row with the
    /// slider.
    static let height: CGFloat = 52
    /// Smallest on value; dragging below it docks the puck onto the well.
    static let minimumValue = 0.05
    private static let puckInset: CGFloat = 5
    /// Space between the power well and the start of the puck's range.
    private static let wellGap: CGFloat = 8
    /// The puck is drawn a touch smaller than the well: its milky fill
    /// blooms against the dark track, so equal frames read as a bigger
    /// knob.
    private static let puckShrink: CGFloat = 2

    @State private var dragStartValue: Double?
    @State private var isDragging = false
    @State private var edgeHaptic = 0
    @State private var dockThunk = 0
    @State private var softTap = 0
    @State private var hardTap = 0
    @State private var detentTick = 0
    /// Where a power-on tap returns the puck to; tracks the latest on
    /// value so dragging into the dock and tapping restores this level.
    @State private var restoreValue = 0.0

    /// Puck parked on the power well: hide the puck, tint the well.
    private var isDocked: Bool { hasPowerWell && value == 0 }

    private var minValue: Double { hasPowerWell ? Self.minimumValue : 0 }

    var body: some View {
        GeometryReader { geometry in
            let wellSize = Self.height - Self.puckInset * 2
            let puckSize = wellSize - Self.puckShrink
            let rangeStart = hasPowerWell
                ? Self.puckInset + wellSize + Self.wellGap
                : Self.puckInset
            let rangeEnd = geometry.size.width - Self.puckInset - puckSize
            let travel = rangeEnd - rangeStart

            ZStack(alignment: .leading) {
                track(
                    rangeStartFraction: hasPowerWell
                        ? rangeStart / max(geometry.size.width, 1)
                        : 0
                )
                // Off reads as the light draining out of the track.
                .opacity(isDocked ? 0.4 : 1)
                .animation(.easeOut(duration: 0.2), value: isDocked)
                if hasPowerWell {
                    powerWell(size: wellSize)
                        .offset(x: Self.puckInset)
                }
                if isDocked {
                    Text("Lamp is Off")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        // Centered in the dimmed track right of the well.
                        .frame(width: max(geometry.size.width - rangeStart, 0))
                        .offset(x: rangeStart)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                puck(size: puckSize)
                    .offset(x: puckOffset(
                        rangeStart: rangeStart,
                        travel: travel,
                        wellSize: wellSize,
                        puckSize: puckSize
                    ))
                    .opacity(isDocked ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: isDocked)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                                isDragging = true
                            }
                        }
                        let proposed = (dragStartValue ?? value)
                            + gesture.translation.width / travel * (1 - minValue)
                        guard hasPowerWell else {
                            applyDragValue(min(max(proposed, 0), 1))
                            return
                        }
                        // A little hysteresis around the range edge so the
                        // puck doesn't flutter in and out of the dock.
                        let dockBelow = minValue - (1 - minValue) * 14 / travel
                        if isDocked {
                            if proposed >= minValue {
                                softTap &+= 1
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    value = min(proposed, 1)
                                }
                            }
                        } else if proposed < dockBelow {
                            dockThunk &+= 1
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                value = 0
                            }
                        } else {
                            applyDragValue(min(max(proposed, minValue), 1))
                        }
                    }
                    .onEnded { gesture in
                        dragStartValue = nil
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                            isDragging = false
                        }
                        // A stationary touch on the power well is a tap on
                        // it. Routing taps through the drag gesture (rather
                        // than a competing tap gesture on the well) keeps
                        // drags that start on the well working normally.
                        if hasPowerWell,
                           abs(gesture.translation.width) < 6,
                           abs(gesture.translation.height) < 6,
                           gesture.startLocation.x <= Self.puckInset + wellSize {
                            togglePower()
                        }
                    }
            )
        }
        .frame(height: Self.height)
        .onChange(of: value) { _, newValue in
            if newValue >= minValue {
                restoreValue = newValue
            }
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: edgeHaptic)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: dockThunk)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: softTap)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: hardTap)
        .sensoryFeedback(detentFeedback, trigger: detentTick)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            let proposed = value + (direction == .increment ? step : -step)
            value = min(max(proposed, minValue), 1)
        }
        .accessibilityActions {
            if hasPowerWell {
                Button("Toggle power") { togglePower() }
            }
        }
    }

    /// A drag-driven value change, with the edge stop and detent ticks.
    private func applyDragValue(_ newValue: Double) {
        guard newValue != value else { return }
        if newValue == 0 || newValue == 1 {
            edgeHaptic &+= 1
        } else if let step = detentStep,
                  Int(floor(newValue / step + 1e-9))
                      != Int(floor(value / step + 1e-9)) {
            detentTick &+= 1
        }
        value = newValue
    }

    private func puckOffset(
        rangeStart: CGFloat,
        travel: CGFloat,
        wellSize: CGFloat,
        puckSize: CGFloat
    ) -> CGFloat {
        if isDocked {
            return Self.puckInset + (wellSize - puckSize) / 2
        }
        let fraction = (value - minValue) / (1 - minValue)
        return rangeStart + travel * fraction
    }

    /// Off: slide to zero, leading with the prominent tap. On: slide back
    /// to the last position, leading with the subtle tap — the pairs ramp
    /// the way the light does.
    private func togglePower() {
        if value > 0 {
            hardTap &+= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                softTap &+= 1
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                value = 0
            }
        } else {
            softTap &+= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                hardTap &+= 1
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                value = restoreValue >= minValue ? restoreValue : 0.65
            }
        }
    }

    private func track(rangeStartFraction: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    stops: remappedStops(from: rangeStartFraction),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(edgeHighlight)
    }

    /// Compresses the stops so the ramp spans the puck's range instead of
    /// the whole capsule; left of the range the first color holds, keeping
    /// the well's corner of the track flat.
    private func remappedStops(from fraction: CGFloat) -> [Gradient.Stop] {
        guard fraction > 0 else { return stops }
        return stops.map {
            Gradient.Stop(
                color: $0.color,
                location: fraction + $0.location * (1 - fraction)
            )
        }
    }

    /// Thin top-lit rim: bright along the upper edge, nearly gone at the
    /// sides, faintly returning at the bottom — reads as light catching a
    /// raised edge.
    private var edgeHighlight: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.35), location: 0),
                        .init(color: .white.opacity(0.06), location: 0.35),
                        .init(color: .white.opacity(0.04), location: 0.7),
                        .init(color: .white.opacity(0.16), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }

    /// Glass power button sunk into the track's left end. Dragging the
    /// puck out of its range docks it here — the puck fades out while the
    /// track dims and labels itself off.
    private func powerWell(size: CGFloat) -> some View {
        Image(systemName: "power")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white.opacity(isDocked ? 0.95 : 0.85))
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
            .animation(.easeOut(duration: 0.2), value: isDocked)
    }

    /// Milky-white puck that lets the track color bleed through: a
    /// translucent normal-blend base keeps it reading as white (and carries
    /// the shadow), while an overlay-blend white layer on top pulls the
    /// gradient's hue up into it.
    private func puck(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.35))
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
            Circle()
                .fill(.white)
                .blendMode(.overlay)
        }
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.7), lineWidth: 0.75)
        }
        .frame(width: size, height: size)
        .scaleEffect(isDragging ? 1.05 : 1)
    }
}

extension [Gradient.Stop] {
    /// Dim-to-bright warm ramp for the brightness slider.
    static var brightness: [Gradient.Stop] {
        [
            .init(color: Color(red: 0.11, green: 0.09, blue: 0.08), location: 0),
            .init(color: Color(red: 0.45, green: 0.29, blue: 0.13), location: 0.45),
            .init(color: Color(red: 0.98, green: 0.78, blue: 0.48), location: 0.85),
            .init(color: Color(red: 1.0, green: 0.92, blue: 0.78), location: 1),
        ]
    }

    /// Dim-to-bright ramp for a single lamp channel in that channel's
    /// color.
    static func channel(peak: Color) -> [Gradient.Stop] {
        [
            .init(color: peak.mix(with: .black, by: 0.85), location: 0),
            .init(color: peak.mix(with: .black, by: 0.45), location: 0.55),
            .init(color: peak, location: 1),
        ]
    }

    /// Warm-to-cool ramp for the color temperature slider: ember red
    /// through candle amber, crossing neutral at the midpoint so the whole
    /// upper half reads blue, deepening to a strong sky blue at the end.
    static var colorTemperature: [Gradient.Stop] {
        [
            .init(color: Color(red: 1.0, green: 0.33, blue: 0.10), location: 0),
            .init(color: Color(red: 1.0, green: 0.62, blue: 0.26), location: 0.2),
            .init(color: Color(red: 1.0, green: 0.88, blue: 0.70), location: 0.38),
            .init(color: Color(red: 0.95, green: 0.96, blue: 1.0), location: 0.5),
            .init(color: Color(red: 0.45, green: 0.62, blue: 1.0), location: 0.72),
            .init(color: Color(red: 0.20, green: 0.38, blue: 0.95), location: 1),
        ]
    }
}

#Preview {
    @Previewable @State var brightness = 0.65
    @Previewable @State var temperature = 0.4
    return VStack(spacing: 24) {
        PuckSlider(
            value: $brightness,
            label: "Brightness",
            stops: .brightness,
            hasPowerWell: true,
            detentStep: 0.2
        )
        PuckSlider(value: $temperature, label: "Color temperature", stops: .colorTemperature)
    }
    .padding(.horizontal, 24)
    .frame(maxHeight: .infinity)
    .background(.black)
    .preferredColorScheme(.dark)
}
