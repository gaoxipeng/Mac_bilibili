import AppKit
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
            .padding(22)
            .frame(maxWidth: 400)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
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
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DanmakuSettingsChrome.title)
                Text(valueLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DanmakuSettingsChrome.value)
            }
            .frame(width: 88, alignment: .leading)

            slider()
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

private enum DanmakuSliderColors {
    static let active = NSColor(red: 0, green: 174 / 255, blue: 236 / 255, alpha: 1)
}

private struct DanmakuSteppedSlider: NSViewRepresentable {
    let stepCount: Int
    let selectedIndex: Int
    let onSelectedIndexChange: (Int) -> Void

    func makeNSView(context: Context) -> DanmakuSliderNSView {
        let view = DanmakuSliderNSView()
        view.onValueChange = { value in
            onSelectedIndexChange(Int(value.rounded()))
        }
        view.configureStepped(stepCount: stepCount, selectedIndex: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: DanmakuSliderNSView, context: Context) {
        nsView.onValueChange = { value in
            onSelectedIndexChange(Int(value.rounded()))
        }
        nsView.configureStepped(stepCount: stepCount, selectedIndex: selectedIndex)
    }
}

private struct DanmakuContinuousSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onValueChange: (Double) -> Void

    func makeNSView(context: Context) -> DanmakuSliderNSView {
        let view = DanmakuSliderNSView()
        view.onValueChange = onValueChange
        view.configureContinuous(value: value, range: range, step: step)
        return view
    }

    func updateNSView(_ nsView: DanmakuSliderNSView, context: Context) {
        nsView.onValueChange = onValueChange
        nsView.configureContinuous(value: value, range: range, step: step)
    }
}

@MainActor
private final class DanmakuSliderNSView: NSView {
    var onValueChange: ((Double) -> Void)?

    private let slider = NSSlider()
    private var isProgrammaticUpdate = false
    private var stepSize: Double = 1
    private var snapsToIntegerValues = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        addSubview(slider)
        applyBlueTrackStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        slider.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureAppearance()
        applyBlueTrackStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureAppearance()
        applyBlueTrackStyle()
    }

    func configureStepped(stepCount: Int, selectedIndex: Int) {
        let maxIndex = max(0, stepCount - 1)
        isProgrammaticUpdate = true
        slider.minValue = 0
        slider.maxValue = Double(maxIndex)
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.doubleValue = Double(min(max(selectedIndex, 0), maxIndex))
        stepSize = 1
        snapsToIntegerValues = true
        isProgrammaticUpdate = false
        applyBlueTrackStyle()
    }

    func configureContinuous(value: Double, range: ClosedRange<Double>, step: Double) {
        isProgrammaticUpdate = true
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.doubleValue = min(max(value, range.lowerBound), range.upperBound)
        stepSize = step
        snapsToIntegerValues = false
        isProgrammaticUpdate = false
        applyBlueTrackStyle()
    }

    private func configureAppearance() {
        let aqua = NSAppearance(named: .aqua)
        appearance = aqua
        slider.appearance = aqua
    }

    private func applyBlueTrackStyle() {
        slider.trackFillColor = DanmakuSliderColors.active
        slider.needsDisplay = true
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard !isProgrammaticUpdate else { return }
        var value = sender.doubleValue
        if snapsToIntegerValues {
            value = min(max(value.rounded(), sender.minValue), sender.maxValue)
        } else if stepSize > 0 {
            let stepped = ((value - sender.minValue) / stepSize).rounded() * stepSize + sender.minValue
            value = min(max(stepped, sender.minValue), sender.maxValue)
        }
        if abs(sender.doubleValue - value) > 0.001 {
            isProgrammaticUpdate = true
            sender.doubleValue = value
            isProgrammaticUpdate = false
        }
        applyBlueTrackStyle()
        onValueChange?(value)
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
