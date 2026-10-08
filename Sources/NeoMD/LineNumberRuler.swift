import AppKit

/// Line-number gutter for `MarkdownTextView`. One number per logical line,
/// drawn on the first line fragment of that line.
/// The numbers are `11 pt × EditorStyle.factor` with monospaced digits. The gutter grows
/// past its 56 pt minimum when the numbers need it (many lines or a large text size).
final class LineNumberRuler: NSRulerView {
    static let minWidth: CGFloat = 56
    static let leftPadding: CGFloat = 8
    static let rightPadding: CGFloat = 16

    private weak var textView: MarkdownTextView?
    /// Baseline offset inside a line fragment, taken from the last drawn line.
    /// Used for the empty last line, which has no glyph to measure.
    private var baselineOffset: CGFloat?

    init(textView: MarkdownTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = width

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
    override var requiredThickness: CGFloat { width }

    /// `max(56, digits × digit width + left and right padding)` for the line count and text size now.
    /// The digits use `EditorStyle.current.numberFont`: the editor family at the smaller gutter size.
    private var width: CGFloat {
        let digits = String(textView?.lineStarts.count ?? 1).count
        let digitWidth = EditorStyle.current.digitWidth
        return max(Self.minWidth, (CGFloat(digits) * digitWidth + Self.leftPadding + Self.rightPadding).rounded(.up))
    }

    /// Sets the gutter width if the line count or the text size changed it. The change runs on the
    /// next main-loop pass, because the scroll view re-tiles and this can be called during layout.
    /// Called by `MarkdownTextView` when the digit count of the line count or the typography changes.
    func updateThickness() {
        // The font can change without a width change (Menlo and SF Mono digits are the same width).
        needsDisplay = true
        guard width != ruleThickness else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let width = self.width
            if width != self.ruleThickness { self.ruleThickness = width }
        }
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Since macOS 14 views do not clip to bounds, and the ruler overlaps the
        // clip view, so `dirtyRect` can span the whole editor. Fill only the gutter.
        (textView?.backgroundColor ?? .textBackgroundColor).setFill()
        bounds.intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let lineCount = textView.lineStarts.count
        let current = textView.lineNumber(at: textView.selectedRange().location)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = textView.lineNumber(at: charIndex)
            guard textView.lineStart(ofLine: line) == charIndex else { return }   // a wrapped continuation
            let offset = layoutManager.location(forGlyphAt: glyphRange.location).y
            self.baselineOffset = offset
            self.drawNumber(line, baseline: fragment.minY + offset, current: line == current, in: textView)
        }

        // The empty line after a trailing newline (or an empty document).
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.height > 0, fragment.intersects(visible) {
                let offset = baselineOffset ?? layoutManager.defaultBaselineOffset(for: EditorStyle.font)
                drawNumber(lineCount, baseline: fragment.minY + offset, current: lineCount == current,
                           in: textView)
            }
        }
    }

    /// `baseline` is in text container coordinates.
    private func drawNumber(_ number: Int, baseline: CGFloat, current: Bool, in textView: NSTextView) {
        let font = EditorStyle.current.numberFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: current ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ]
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        let point = convert(NSPoint(x: 0, y: baseline + textView.textContainerOrigin.y), from: textView)
        label.draw(at: NSPoint(x: ruleThickness - Self.rightPadding - size.width, y: point.y - font.ascender),
                   withAttributes: attributes)
    }
}
