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
