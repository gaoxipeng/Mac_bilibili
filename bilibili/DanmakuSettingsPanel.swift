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
    }
}

private struct DanmakuSteppedSlider: View {
    let stepCount: Int
    let selectedIndex: Int
    let onSelectedIndexChange: (Int) -> Void

    private var maxIndex: Int { max(0, stepCount - 1) }

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(selectedIndex) },
                set: { onSelectedIndexChange(Int($0.rounded())) }
            ),
            in: 0...Double(maxIndex),
            step: 1,
            label: { EmptyView() },
            tick: { value in SliderTick(value) }
        )
        .labelsHidden()
        .tint(BiliTheme.pink)
    }
}

private struct DanmakuContinuousSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onValueChange: (Double) -> Void

    var body: some View {
        Slider(
            value: Binding(
                get: { value },
                set: { onValueChange($0) }
            ),
            in: range,
            step: step,
            label: { EmptyView() }
        )
        .labelsHidden()
        .tint(BiliTheme.pink)
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
