import AppKit
import Combine
import SwiftUI

// MARK: - Feed card surface

struct FeedCardSurfaceRepresentable: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> FeedCardSurfaceView {
        let view = FeedCardSurfaceView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: FeedCardSurfaceView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}

final class FeedCardSurfaceView: NSView {
    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Cover image (layer.contents)

struct RemoteCoverImageRepresentable: NSViewRepresentable {
    let image: NSImage?
    let failed: Bool
    var cornerRadius: CGFloat = 0
    var placeholderSystemImage = "play.rectangle"

    func makeNSView(context: Context) -> RemoteCoverImageLayerView {
        let view = RemoteCoverImageLayerView()
        view.cornerRadius = cornerRadius
        view.placeholderSystemImage = placeholderSystemImage
        view.updateDisplay(image: image, failed: failed)
        return view
    }

    func updateNSView(_ nsView: RemoteCoverImageLayerView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.placeholderSystemImage = placeholderSystemImage
        nsView.updateDisplay(image: image, failed: failed)
    }
}

final class RemoteCoverImageLayerView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    var placeholderSystemImage = "play.rectangle"

    private let placeholderIcon = NSImageView()
    private var displayedCGImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .trilinear

        placeholderIcon.imageScaling = .scaleProportionallyDown
        placeholderIcon.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.42)
        addSubview(placeholderIcon)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        placeholderIcon.frame = bounds
        layer?.cornerRadius = cornerRadius
    }

    func updateDisplay(image: NSImage?, failed: Bool) {
        if let image,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard displayedCGImage !== cgImage else { return }
            displayedCGImage = cgImage
            layer?.contents = cgImage
            placeholderIcon.isHidden = true
            return
        }

        displayedCGImage = nil
        layer?.contents = nil
        placeholderIcon.image = NSImage(
            systemSymbolName: failed ? "exclamationmark.triangle" : placeholderSystemImage,
            accessibilityDescription: nil
        )
        placeholderIcon.isHidden = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Avatar (layer-backed)

struct RemoteAvatarImageRepresentable: NSViewRepresentable {
    let image: NSImage?
    let size: CGFloat
    var foreground: NSColor = .secondaryLabelColor
    var background: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    var border: NSColor = NSColor.black.withAlphaComponent(0.06)

    func makeNSView(context: Context) -> RemoteAvatarImageLayerView {
        let view = RemoteAvatarImageLayerView(size: size)
        view.foreground = foreground
        view.avatarBackground = background
        view.borderColor = border
        view.updateDisplay(image: image)
        return view
    }

    func updateNSView(_ nsView: RemoteAvatarImageLayerView, context: Context) {
        nsView.foreground = foreground
        nsView.avatarBackground = background
        nsView.borderColor = border
        nsView.updateDisplay(image: image)
    }
}

final class RemoteAvatarImageLayerView: NSView {
    var avatarSize: CGFloat {
        didSet {
            guard avatarSize != oldValue else { return }
            needsLayout = true
        }
    }
    var foreground = NSColor.secondaryLabelColor
    var avatarBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    var borderColor = NSColor.black.withAlphaComponent(0.06)

    private let placeholderIcon = NSImageView()
    private var displayedCGImage: CGImage?

    init(size: CGFloat) {
        avatarSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .trilinear

        placeholderIcon.imageScaling = .scaleProportionallyDown
        addSubview(placeholderIcon)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let avatarBounds = CGRect(origin: .zero, size: NSSize(width: avatarSize, height: avatarSize))
        placeholderIcon.frame = avatarBounds.insetBy(dx: avatarSize * 0.23, dy: avatarSize * 0.23)
        layer?.backgroundColor = avatarBackground.cgColor
        layer?.cornerRadius = avatarSize / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = borderColor.cgColor
    }

    func updateDisplay(image: NSImage?) {
        if let image,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard displayedCGImage !== cgImage else { return }
            displayedCGImage = cgImage
            layer?.contents = cgImage
            placeholderIcon.isHidden = true
            return
        }

        displayedCGImage = nil
        layer?.contents = nil
        placeholderIcon.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
        placeholderIcon.contentTintColor = foreground
        placeholderIcon.isHidden = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

private extension NSColor {
    static let biliBlue = NSColor(red: 0, green: 174 / 255, blue: 236 / 255, alpha: 1)
}

// MARK: - Feed card title (layer-backed)

struct FeedCardTitleRepresentable: NSViewRepresentable, Equatable {
    let title: String
    let usesLargeFont: Bool
    let textWidth: CGFloat
    let areaHeight: CGFloat

    func makeCoordinator() -> FeedCardHoverCoordinator {
        FeedCardHoverCoordinator()
    }

    func makeNSView(context: Context) -> FeedCardTitleView {
        let view = FeedCardTitleView()
        context.coordinator.bind(to: view)
        view.apply(
            title: title,
            usesLargeFont: usesLargeFont,
            textWidth: textWidth,
            areaHeight: areaHeight
        )
        return view
    }

    func updateNSView(_ nsView: FeedCardTitleView, context: Context) {
        context.coordinator.bind(to: nsView)
        nsView.apply(
            title: title,
            usesLargeFont: usesLargeFont,
            textWidth: textWidth,
            areaHeight: areaHeight
        )
    }

    static func dismantleNSView(_ nsView: FeedCardTitleView, coordinator: FeedCardHoverCoordinator) {
        coordinator.teardown()
    }
}

final class FeedCardTitleView: NSView {
    private let textLayer = CATextLayer()
    private var isHovered = false
    private var usesLargeFont = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .left
        textLayer.isWrapped = true
        textLayer.truncationMode = .end
        layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        textLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        guard !FeedScrollActivity.isScrolling else { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateTextColor()
    }

    func apply(title: String, usesLargeFont: Bool, textWidth: CGFloat, areaHeight: CGFloat) {
        self.usesLargeFont = usesLargeFont
        let font = VideoCardLayout.titleNSFont(
            for: .feed(largeTypography: usesLargeFont, showsAuthor: true)
        )
        if (textLayer.string as? String) != title {
            textLayer.string = title
        }
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        updateTextColor()
        needsLayout = true
    }

    private func updateTextColor() {
        textLayer.foregroundColor = (isHovered ? NSColor.biliBlue : NSColor.labelColor).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Feed card author row (layer-backed)

struct FeedCardAuthorRowRepresentable: NSViewRepresentable, Equatable {
    let name: String
    let avatarURL: URL?
    let avatarSize: CGFloat
    let avatarPixelLength: Int
    let nameFontSize: CGFloat
    let trailingText: String?
    let trailingFontSize: CGFloat
    let rowWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FeedCardAuthorRowView {
        let view = FeedCardAuthorRowView()
        context.coordinator.bind(to: view)
        context.coordinator.loadAvatar(
            url: avatarURL,
            pixelLength: avatarPixelLength,
            into: view
        )
        view.apply(
            name: name,
            avatarSize: avatarSize,
            nameFontSize: nameFontSize,
            trailingText: trailingText,
            trailingFontSize: trailingFontSize,
            rowWidth: rowWidth
        )
        return view
    }

    func updateNSView(_ nsView: FeedCardAuthorRowView, context: Context) {
        context.coordinator.bind(to: nsView)
        context.coordinator.loadAvatar(
            url: avatarURL,
            pixelLength: avatarPixelLength,
            into: nsView
        )
        nsView.apply(
            name: name,
            avatarSize: avatarSize,
            nameFontSize: nameFontSize,
            trailingText: trailingText,
            trailingFontSize: trailingFontSize,
            rowWidth: rowWidth
        )
    }

    static func dismantleNSView(_ nsView: FeedCardAuthorRowView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: FeedCardHoverCoordinator {
        private let loader = RemoteCoverImageLoader()
        private var imageObserver: AnyCancellable?
        private var avatarURL: URL?
        private var avatarPixelLength = 0

        func loadAvatar(url: URL?, pixelLength: Int, into view: FeedCardAuthorRowView) {
            guard avatarURL != url || avatarPixelLength != pixelLength else { return }
            avatarURL = url
            avatarPixelLength = pixelLength

            imageObserver = loader.$image
                .receive(on: DispatchQueue.main)
                .sink { image in
                    view.updateAvatar(image: image)
                }

            loader.primeFromMemoryCache(url: url, maxPixelLength: pixelLength)
            loader.load(url: url, maxPixelLength: pixelLength)
        }

        override func teardown() {
            imageObserver = nil
            loader.cancel()
            super.teardown()
        }
    }
}

final class FeedCardAuthorRowView: NSView {
    private let avatarView = RemoteAvatarImageLayerView(size: 26)
    private let nameLayer = CATextLayer()
    private let trailingLayer = CATextLayer()

    private var avatarSize: CGFloat = 26
    private var nameWidth: CGFloat = 0
    private var trailingWidth: CGFloat = 0
    private var showsTrailing = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(avatarView)

        for layer in [nameLayer, trailingLayer] {
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer.alignmentMode = .left
            layer.isWrapped = false
            layer.truncationMode = .end
            self.layer?.addSublayer(layer)
        }
        trailingLayer.alignmentMode = .right
        trailingLayer.isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func updateAvatar(image: NSImage?) {
        avatarView.updateDisplay(image: image)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        nameLayer.foregroundColor = (isHovered ? NSColor.biliBlue : NSColor.secondaryLabelColor).cgColor
    }

    func apply(
        name: String,
        avatarSize: CGFloat,
        nameFontSize: CGFloat,
        trailingText: String?,
        trailingFontSize: CGFloat,
        rowWidth: CGFloat
    ) {
        self.avatarSize = avatarSize
        avatarView.avatarSize = avatarSize

        let displayName = name.isEmpty ? "未知 UP 主" : name
        if (nameLayer.string as? String) != displayName {
            nameLayer.string = displayName
        }
        nameLayer.font = NSFont.systemFont(ofSize: nameFontSize)
        nameLayer.fontSize = nameFontSize
        nameLayer.foregroundColor = (isHovered ? NSColor.biliBlue : NSColor.secondaryLabelColor).cgColor

        if let trailingText, !trailingText.isEmpty {
            showsTrailing = true
            trailingLayer.isHidden = false
            if (trailingLayer.string as? String) != trailingText {
                trailingLayer.string = trailingText
            }
            trailingLayer.font = NSFont.systemFont(ofSize: trailingFontSize)
            trailingLayer.fontSize = trailingFontSize
            trailingLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
            trailingWidth = ceil((trailingText as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: trailingFontSize),
            ]).width)
        } else {
            showsTrailing = false
            trailingLayer.isHidden = true
            trailingWidth = 0
        }

        let spacing: CGFloat = 8
        let trailingGap: CGFloat = showsTrailing ? 8 : 0
        nameWidth = max(0, rowWidth - avatarSize - spacing - trailingGap - trailingWidth)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        avatarView.frame = NSRect(x: 0, y: (bounds.height - avatarSize) / 2, width: avatarSize, height: avatarSize)

        let textHeight = max(nameLayer.fontSize, trailingLayer.fontSize) * 1.2
        nameLayer.frame = CGRect(
            x: avatarSize + 8,
            y: (bounds.height - textHeight) / 2,
            width: nameWidth,
            height: textHeight
        )

        if showsTrailing {
            trailingLayer.frame = CGRect(
                x: bounds.width - trailingWidth,
                y: (bounds.height - textHeight) / 2,
                width: trailingWidth,
                height: textHeight
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        guard !FeedScrollActivity.isScrolling else { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

class FeedCardHoverCoordinator {
    private weak var view: (NSView & FeedCardHoverResettable)?
    private var scrollListenerID: UUID?

    func bind(to view: NSView & FeedCardHoverResettable) {
        guard self.view !== view else { return }
        self.view = view
        if scrollListenerID == nil {
            scrollListenerID = FeedScrollActivity.addListener { [weak view] scrolling in
                if scrolling {
                    view?.setHovered(false)
                }
            }
        }
    }

    @MainActor
    func teardown() {
        if let scrollListenerID {
            FeedScrollActivity.removeListener(scrollListenerID)
            self.scrollListenerID = nil
        }
        view = nil
    }
}

protocol FeedCardHoverResettable: AnyObject {
    func setHovered(_ hovered: Bool)
}

extension FeedCardTitleView: FeedCardHoverResettable {}
extension FeedCardAuthorRowView: FeedCardHoverResettable {}

// MARK: - Feed card stats row (layer-backed)

struct FeedCardStatsRowRepresentable: NSViewRepresentable, Equatable {
    let playCount: String
    let danmakuCount: String
    let likeCount: String?
    let iconSize: CGFloat
    let likeIconSize: CGFloat
    let fontSize: CGFloat
    let itemSpacing: CGFloat

    func makeNSView(context: Context) -> FeedCardStatsRowView {
        let view = FeedCardStatsRowView()
        view.apply(
            playCount: playCount,
            danmakuCount: danmakuCount,
            likeCount: likeCount,
            iconSize: iconSize,
            likeIconSize: likeIconSize,
            fontSize: fontSize,
            itemSpacing: itemSpacing
        )
        return view
    }

    func updateNSView(_ nsView: FeedCardStatsRowView, context: Context) {
        nsView.apply(
            playCount: playCount,
            danmakuCount: danmakuCount,
            likeCount: likeCount,
            iconSize: iconSize,
            likeIconSize: likeIconSize,
            fontSize: fontSize,
            itemSpacing: itemSpacing
        )
    }
}

final class FeedCardStatsRowView: NSView {
    private let playItem = FeedStatLayerItemView()
    private let danmakuItem = FeedStatLayerItemView()
    private let likeItem = FeedStatLayerItemView()

    private var configuredItemSpacing: CGFloat = 12
    private var showsLike = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(playItem)
        addSubview(danmakuItem)
        addSubview(likeItem)
        likeItem.isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(
        playCount: String,
        danmakuCount: String,
        likeCount: String?,
        iconSize: CGFloat,
        likeIconSize: CGFloat,
        fontSize: CGFloat,
        itemSpacing: CGFloat
    ) {
        configuredItemSpacing = itemSpacing
        showsLike = likeCount != nil

        let iconColor = NSColor.secondaryLabelColor
        let textColor = NSColor.secondaryLabelColor
        playItem.apply(
            icon: .play,
            value: playCount,
            iconSize: iconSize,
            iconColor: iconColor,
            textColor: textColor,
            fontSize: fontSize,
            symbolScale: 1
        )
        danmakuItem.apply(
            icon: .danmaku,
            value: danmakuCount,
            iconSize: iconSize,
            iconColor: iconColor,
            textColor: textColor,
            fontSize: fontSize,
            symbolScale: 1
        )
        if let likeCount {
            likeItem.isHidden = false
            likeItem.apply(
                icon: .like,
                value: likeCount,
                iconSize: likeIconSize,
                iconColor: iconColor,
                textColor: textColor,
                fontSize: fontSize,
                symbolScale: 1.04
            )
        } else {
            likeItem.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let rowHeight = bounds.height

        for item in [playItem, danmakuItem, likeItem] where !item.isHidden {
            let size = item.intrinsicContentSize
            let itemHeight = max(size.height, rowHeight)
            item.frame = NSRect(
                x: x,
                y: rowHeight - itemHeight,
                width: size.width,
                height: itemHeight
            )
            x += size.width + configuredItemSpacing
        }
    }

    override var intrinsicContentSize: NSSize {
        var width: CGFloat = 0
        let height = max(
            playItem.intrinsicContentSize.height,
            danmakuItem.intrinsicContentSize.height,
            showsLike ? likeItem.intrinsicContentSize.height : 0
        )
        let items = [playItem, danmakuItem] + (showsLike ? [likeItem] : [])
        for (index, item) in items.enumerated() where !item.isHidden {
            width += item.intrinsicContentSize.width
            if index > 0 {
                width += configuredItemSpacing
            }
        }
        return NSSize(width: width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class FeedStatLayerItemView: NSView {
    private let iconHost = NSView()
    private let textField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }()

    private var iconWidth: CGFloat = 0
    private var textWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var itemSpacing: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconHost.wantsLayer = true
        iconHost.layerContentsRedrawPolicy = .duringViewResize
        addSubview(iconHost)
        addSubview(textField)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(
        icon: BiliIcon,
        value: String,
        iconSize: CGFloat,
        iconColor: NSColor,
        textColor: NSColor,
        fontSize: CGFloat,
        symbolScale: CGFloat
    ) {
        let image = BiliRasterIconCache.image(
            icon: icon,
            size: iconSize,
            color: iconColor,
            symbolScale: symbolScale
        )
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            iconHost.layer?.contents = cgImage
        }
        iconWidth = iconSize

        if textField.stringValue != value {
            textField.stringValue = value
        }
        let font = NSFont.systemFont(ofSize: fontSize)
        textField.font = font
        textField.textColor = textColor

        let textSize = (value as NSString).size(withAttributes: [.font: font])
        textWidth = ceil(textSize.width)
        let textLineHeight = ceil(font.ascender - font.descender)
        contentHeight = max(iconSize, textLineHeight)
        itemSpacing = 4
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        let rowHeight = bounds.height
        iconHost.frame = NSRect(
            x: 0,
            y: (rowHeight - iconWidth) / 2,
            width: iconWidth,
            height: iconWidth
        )
        let textSize = textField.intrinsicContentSize
        textField.frame = NSRect(
            x: iconWidth + itemSpacing,
            y: (rowHeight - textSize.height) / 2,
            width: textWidth,
            height: textSize.height
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: iconWidth + itemSpacing + textWidth, height: contentHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
