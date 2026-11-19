import SwiftUI

struct DanmakuSettingsOverlay: View {
    let settings: DanmakuSettings
    let onSettingsChange: (DanmakuSettings) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 20) {
                DanmakuSettingRow(
                    title: "显示区域",
                    valueLabel: DanmakuSettings.displayAreaLabel(settings.displayAreaPercent)
                ) {
                    DanmakuSteppedSlider(
                        stepCount: DanmakuSettings.displayAreaOptions.count,
                        selectedIndex: settings.displayAreaIndex,
                        onSelectedIndexChange: { index in
                            onSettingsChange(settings.withDisplayAreaIndex(index))
                        }
                    )
                }
                DanmakuSettingRow(
                    title: "不透明度",
                    valueLabel: "\(settings.opacityPercent)%"
                ) {
                    DanmakuContinuousSlider(
                        value: Double(settings.opacityPercent),
                        range: 10...100,
                        step: 5
                    ) { value in
                        onSettingsChange(settings.with(opacityPercent: Int(value.rounded())))
                    }
                }
                DanmakuSettingRow(
                    title: "弹幕字号",
                    valueLabel: "\(settings.fontSizePercent)%"
                ) {
                    DanmakuContinuousSlider(
                        value: Double(settings.fontSizePercent),
                        range: Double(DanmakuSettings.fontSizeRange.lowerBound)...Double(DanmakuSettings.fontSizeRange.upperBound),
                        step: 5
                    ) { value in
                        onSettingsChange(settings.with(fontSizePercent: Int(value.rounded())))
                    }
                }
                DanmakuSettingRow(
                    title: "弹幕速度",
                    valueLabel: settings.speedLevel.label
                ) {
                    DanmakuSteppedSlider(
                        stepCount: DanmakuSpeedLevel.allCases.count,
                        selectedIndex: settings.speedLevel.rawValue,
                        onSelectedIndexChange: { index in
                            onSettingsChange(settings.with(speedLevel: DanmakuSpeedLevel.fromIndex(index)))
                        }
                    )
                }
                DanmakuAvoidanceCapsule(selection: settings.avoidanceMode) { mode in
                    onSettingsChange(settings.with(avoidanceMode: mode))
                }
            }
            .padding(22)
            .frame(minWidth: 470, maxWidth: 470)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        }
        .zIndex(20)
    }
}

private struct DanmakuAvoidanceCapsule: View {
    let selection: DanmakuAvoidanceMode
    let onChange: (DanmakuAvoidanceMode) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("智能防遮挡")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DanmakuSettingsChrome.title)
                .frame(width: 116, alignment: .leading)

            DanmakuAvoidanceSwitch(selection: selection, onChange: onChange)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
    }
}

/// Three positions with the same inset white thumb / colored track proportions as a switch.
private struct DanmakuAvoidanceSwitch: View {
    let selection: DanmakuAvoidanceMode
    let onChange: (DanmakuAvoidanceMode) -> Void

    @State private var isPressed = false
    @State private var dragX: CGFloat?

    private let inset: CGFloat = 3
    private let modes = DanmakuAvoidanceMode.allCases

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(1, proxy.size.width - inset * 2)
            let segmentWidth = trackWidth / CGFloat(modes.count)
            let index = modes.firstIndex(of: selection) ?? 0
            let restingX = inset + CGFloat(index) * segmentWidth
            let thumbX = dragX.map {
                min(max($0 - segmentWidth / 2, inset), proxy.size.width - inset - segmentWidth)
            } ?? restingX

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(selection == .off
                        ? Color.black.opacity(0.22)
                        : Color(red: 0, green: 174 / 255, blue: 236 / 255))

                Capsule()
                    .fill(.white.opacity(isPressed ? 0.3 : 1))
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                    .frame(width: segmentWidth, height: proxy.size.height - inset * 2)
                    .offset(x: thumbX)
                    .animation(.smooth(duration: 0.35), value: thumbX)
                    .animation(.easeInOut(duration: 0.25), value: isPressed)

                HStack(spacing: 0) {
                    ForEach(modes) { mode in
                        Text(mode.label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(mode == selection ? DanmakuSettingsChrome.title : .white.opacity(0.92))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, inset)
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isPressed = true
                        dragX = value.location.x
                        select(at: value.location.x, segmentWidth: segmentWidth)
                    }
                    .onEnded { value in
                        select(at: value.location.x, segmentWidth: segmentWidth)
                        dragX = nil
                        isPressed = false
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("智能防遮挡")
            .accessibilityValue(selection.label)
            .accessibilityAdjustableAction { direction in
                let index = modes.firstIndex(of: selection) ?? 0
                switch direction {
                case .increment: onChange(modes[min(index + 1, modes.count - 1)])
                case .decrement: onChange(modes[max(index - 1, 0)])
                @unknown default: break
                }
            }
        }
    }

    private func select(at x: CGFloat, segmentWidth: CGFloat) {
        let index = min(modes.count - 1, max(0, Int((x - inset) / max(1, segmentWidth))))
        guard modes[index] != selection else { return }
        withAnimation(.smooth(duration: 0.35)) {
            onChange(modes[index])
        }
    }
}

private struct DanmakuSettingRow<Slider: View>: View {
    let title: String
    let valueLabel: String
    @ViewBuilder let slider: () -> Slider

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DanmakuSettingsChrome.title)
                Text(valueLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DanmakuSettingsChrome.value)
            }
            .frame(width: 116, alignment: .leading)

            slider()
                .accessibilityLabel(title)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
    }
}

private enum DanmakuSettingsChrome {
    /// Primary label on the frosted card.
    static let title = Color(red: 0.14, green: 0.15, blue: 0.16)
    /// Secondary value — darker than the old light gray, softer than pure white.
    static let value = Color(red: 0.30, green: 0.33, blue: 0.36)
}

private struct DanmakuSteppedSlider: View {
    let stepCount: Int
    let selectedIndex: Int
    let onSelectedIndexChange: (Int) -> Void

    var body: some View {
        let lastIndex = max(0, stepCount - 1)
        DanmakuContinuousSlider(
            value: Double(selectedIndex),
            range: 0...Double(max(1, lastIndex)),
            step: 1
        ) { value in
            onSelectedIndexChange(min(lastIndex, Int(value.rounded())))
        }
        .disabled(lastIndex == 0)
    }
}

private struct DanmakuContinuousSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onValueChange: (Double) -> Void

    private var binding: Binding<Double> {
        Binding(get: { value }, set: onValueChange)
    }

    var body: some View {
        Slider(value: binding, in: range, step: step)
            .tint(Color(red: 0, green: 174 / 255, blue: 236 / 255))
            .environment(\.colorScheme, .light)
            .allowsHitTesting(false)
            .overlay {
                GeometryReader { geometry in
                    // Keep the input area and its coordinate space the same
                    // size as the native control. The knob stays inside it.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    let inset: CGFloat = 10
                                    let travel = max(1, geometry.size.width - 2 * inset)
                                    let fraction = Double(min(1, max(0, (drag.location.x - inset) / travel)))
                                    let steps = (fraction * (range.upperBound - range.lowerBound) / step).rounded()
                                    let next = min(range.upperBound, range.lowerBound + steps * step)
                                    if next != value { onValueChange(next) }
                                }
                        )
                        .accessibilityHidden(true)
                }
            }
    }
}

private extension DanmakuSettings {
    func with(
        displayAreaPercent: Int? = nil,
        opacityPercent: Int? = nil,
        fontSizePercent: Int? = nil,
        speedLevel: DanmakuSpeedLevel? = nil,
        avoidanceMode: DanmakuAvoidanceMode? = nil
    ) -> DanmakuSettings {
        DanmakuSettings(
            displayAreaPercent: displayAreaPercent ?? self.displayAreaPercent,
            opacityPercent: opacityPercent ?? self.opacityPercent,
            fontSizePercent: fontSizePercent ?? self.fontSizePercent,
            speedLevel: speedLevel ?? self.speedLevel,
            avoidanceMode: avoidanceMode ?? self.avoidanceMode
        )
    }
}
