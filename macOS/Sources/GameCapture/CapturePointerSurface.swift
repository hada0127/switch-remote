import AppKit
import SwiftUI

/// Receive native mouse-up events, including remote clicks with movement between
/// down/up that SwiftUI's tap recognizer may reject. Settings remain above this view.
struct CapturePointerSurface: NSViewRepresentable {
    let onClick: () -> Void
    func makeNSView(context: Context) -> CapturePointerView {
        let view = CapturePointerView()
        view.onClick = onClick
        return view
    }
    func updateNSView(_ view: CapturePointerView, context: Context) { view.onClick = onClick }
}

final class CapturePointerView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func viewDidMoveToWindow() { pressed = false }
}

/// Large targets for a desktop streamed to a phone; native focus/disabled behavior stays intact.
struct TouchSettingsButtonStyle: ButtonStyle {
    var selected = false
    var horizontalPadding: CGFloat = 18
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.font(28))
            .minimumScaleFactor(0.65)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 72)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15)))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

struct SettingsTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.font(30))
            .lineLimit(1).minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, minHeight: 80)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.white : Color.black.opacity(0.04))
            .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? Color.accentColor : Color.gray.opacity(0.2))
                    .frame(height: selected ? 5 : 1)
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

/// The stock popup bezel has a fixed small height even with a large font.
/// Keep native popup/menu semantics, but draw a matching 72-point control.
final class TouchPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: 72) }
}
final class TouchPopUpCell: NSPopUpButtonCell {
    override func draw(withFrame frame: NSRect, in view: NSView) {
        let box = frame.insetBy(dx: 1, dy: 1)
        NSColor.controlBackgroundColor.setFill()
        let outline = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppFonts.native(32),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: style
        ]
        let text = selectedItem?.title ?? ""
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(in: NSRect(x: frame.minX + 18, y: frame.midY - height / 2,
                                          width: max(0, frame.width - 78), height: height), withAttributes: attributes)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: frame.maxX - 43, y: frame.midY - 4))
        arrow.line(to: NSPoint(x: frame.maxX - 33, y: frame.midY + 6))
        arrow.line(to: NSPoint(x: frame.maxX - 23, y: frame.midY - 4))
        arrow.lineWidth = 3
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setStroke()
        arrow.stroke()
    }
}
