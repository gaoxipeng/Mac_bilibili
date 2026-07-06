import AppKit
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
    let avatarSize: CGFloat
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
