import AppKit

/// Line-number gutter for `MarkdownTextView`. One number per logical line,
/// drawn on the first line fragment of that line.
final class LineNumberRuler: NSRulerView {
    static let width: CGFloat = 56
    static let rightPadding: CGFloat = 16

    private weak var textView: MarkdownTextView?
    /// Baseline offset inside a line fragment, taken from the last drawn line.
    /// Used for the empty last line, which has no glyph to measure.
    private var baselineOffset: CGFloat?

    init(textView: MarkdownTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.width

        let center = NotificationCenter.default
        textView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { Self.width }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        (textView?.backgroundColor ?? .textBackgroundColor).setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let starts = textView.lineStarts
        let current = textView.lineNumber(at: textView.selectedRange().location)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = textView.lineNumber(at: charIndex)
            guard starts[line - 1] == charIndex else { return }   // a wrapped continuation
            let offset = layoutManager.location(forGlyphAt: glyphRange.location).y
            self.baselineOffset = offset
            self.drawNumber(line, baseline: fragment.minY + offset, current: line == current, in: textView)
        }

        // The empty line after a trailing newline (or an empty document).
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.height > 0, fragment.intersects(visible) {
                let offset = baselineOffset ?? layoutManager.defaultBaselineOffset(for: EditorStyle.font)
                drawNumber(starts.count, baseline: fragment.minY + offset, current: starts.count == current,
                           in: textView)
            }
        }
    }

    /// `baseline` is in text container coordinates.
    private func drawNumber(_ number: Int, baseline: CGFloat, current: Bool, in textView: NSTextView) {
        let font = EditorStyle.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: current ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ]
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        let point = convert(NSPoint(x: 0, y: baseline + textView.textContainerOrigin.y), from: textView)
        label.draw(at: NSPoint(x: Self.width - Self.rightPadding - size.width, y: point.y - font.ascender),
                   withAttributes: attributes)
    }
}
