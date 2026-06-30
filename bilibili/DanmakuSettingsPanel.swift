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

            VStack(spacing: 14) {
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
                        range: 50...170,
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
            }
            .padding(14)
            .frame(maxWidth: 300)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        }
        .zIndex(20)
    }
}

private struct DanmakuSettingRow<Slider: View>: View {
    let title: String
    let valueLabel: String
    @ViewBuilder let slider: () -> Slider

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))
                Text(valueLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.39, green: 0.39, blue: 0.4))
            }
            .frame(width: 58, alignment: .leading)

            slider()
                .frame(maxWidth: .infinity)
        }
        .frame(height: 38)
    }
}

private struct DanmakuSteppedSlider: View {
    let stepCount: Int
    let selectedIndex: Int
    let onSelectedIndexChange: (Int) -> Void

    @State private var dragFraction: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let maxIndex = max(0, stepCount - 1)
            let fraction = dragFraction ?? (maxIndex == 0 ? 0 : CGFloat(selectedIndex) / CGFloat(maxIndex))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.15))
                    .frame(height: 2.5)
                Capsule()
                    .fill(BiliTheme.pink)
                    .frame(width: max(0, proxy.size.width * fraction), height: 2.5)
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.6))
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, proxy.size.width * fraction - 6))
            }
            .frame(height: 28, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                        dragFraction = fraction
                        onSelectedIndexChange(Int((fraction * CGFloat(maxIndex)).rounded()))
                    }
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                        dragFraction = nil
                        onSelectedIndexChange(Int((fraction * CGFloat(maxIndex)).rounded()))
                    }
            )
        }
        .frame(height: 28)
    }
}

private struct DanmakuContinuousSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onValueChange: (Double) -> Void

    @State private var dragFraction: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let span = range.upperBound - range.lowerBound
            let fraction = dragFraction ?? CGFloat((value - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.15))
                    .frame(height: 2.5)
                Capsule()
                    .fill(BiliTheme.pink)
                    .frame(width: max(0, proxy.size.width * fraction), height: 2.5)
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.6))
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, proxy.size.width * fraction - 6))
            }
            .frame(height: 28, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                        dragFraction = fraction
                        let raw = range.lowerBound + Double(fraction) * span
                        let stepped = (raw / step).rounded() * step
                        onValueChange(stepped)
                    }
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                        dragFraction = nil
                        let raw = range.lowerBound + Double(fraction) * span
                        let stepped = (raw / step).rounded() * step
                        onValueChange(stepped)
                    }
            )
        }
        .frame(height: 28)
    }
}

private extension DanmakuSettings {
    func with(
        displayAreaPercent: Int? = nil,
        opacityPercent: Int? = nil,
        fontSizePercent: Int? = nil,
        speedLevel: DanmakuSpeedLevel? = nil
    ) -> DanmakuSettings {
        DanmakuSettings(
            displayAreaPercent: displayAreaPercent ?? self.displayAreaPercent,
            opacityPercent: opacityPercent ?? self.opacityPercent,
            fontSizePercent: fontSizePercent ?? self.fontSizePercent,
            speedLevel: speedLevel ?? self.speedLevel
        )
    }
}
