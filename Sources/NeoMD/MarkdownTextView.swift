import AppKit
import MDCore

/// Fonts, metrics and colours of the raw editor. Colours follow `mockup/base.css`.
enum EditorStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    static let lineHeight: CGFloat = 21
    static let topInset: CGFloat = 20

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    /// `--md-mark`
    static let mark = dynamic(light: 0xa1a1a6, dark: 0x636366)
    /// `--md-head`
    static let head = dynamic(light: 0x1d1d1f, dark: 0xe8e8ea)
    /// `--md-code`
    static let code = dynamic(light: 0xb4305a, dark: 0xff7aa2)
    /// `--md-fence`
    static let fence = dynamic(light: 0x2f7d32, dark: 0x7fd17f)
    /// `color-mix(in srgb, var(--text) 4%, transparent)`
    static let currentLine = NSColor.labelColor.withAlphaComponent(0.04)

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255,
                           alpha: 1)
        }
    }

    /// Foreground colour for a token, or nil when the token keeps the text colour.
    static func color(for token: MarkdownToken) -> NSColor? {
        switch token {
        case .heading: return head
        case .headingMarker, .listMarker, .boldMarker: return mark
        case .codeSpan: return code
        case .fence, .hr: return fence
        case .link: return .controlAccentColor
        case .bold: return nil
        }
    }
}

/// Tells its owner when it has processed a text storage edit. At that point the
/// layout manager's character ranges match the new text, so temporary attributes
/// can be set on them.
final class HighlightLayoutManager: NSLayoutManager {
    var onProcessEditing: (() -> Void)?

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
        onProcessEditing?()
    }
}

/// The raw Markdown editor (TextKit 1).
///
/// Colouring: token colours are temporary attributes on the layout manager, so
/// they never enter undo. Bold weight (headings, `**bold**`) needs a font change,
/// which temporary attributes do not support; it is set on the text storage
/// while it processes an edit. That does not register undo either.
///
/// Create it with `MarkdownTextView.make()`. `keyDown(with:)` and
/// `drawInsertionPoint(in:color:turnedOn:)` stay overridable for the Vim mode.
class MarkdownTextView: NSTextView, NSTextStorageDelegate {
    /// UTF-16 offset of the first character of every logical line. Always starts with 0.
    /// If the text ends with a newline, the last entry is the text length (the empty last line).
    private(set) var lineStarts: [Int] = [0]
    /// Hash of the fence-like lines. When it changes, an edit may have opened or
    /// closed a fenced block, so the colouring runs to the end of the text.
    private var fenceFingerprint = 0
    private var pendingColors: (range: NSRange, spans: [HighlightSpan])?

    /// Builds a TextKit 1 stack with a `HighlightLayoutManager` and a text view on it.
    static func make() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = HighlightLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        return MarkdownTextView(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        usesRuler = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false

        font = EditorStyle.font
        textColor = .labelColor
        backgroundColor = .textBackgroundColor
        drawsBackground = true
        defaultParagraphStyle = EditorStyle.paragraphStyle
        typingAttributes = Self.baseAttributes
        textContainerInset = NSSize(width: 0, height: EditorStyle.topInset)

        textStorage?.delegate = self
        (layoutManager as? HighlightLayoutManager)?.onProcessEditing = { [weak self] in
            self?.applyPendingColors()
        }
    }

    private static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: EditorStyle.font,
        .paragraphStyle: EditorStyle.paragraphStyle,
        .foregroundColor: NSColor.labelColor,
    ]

    // MARK: - Lines

    /// 1-based logical line that contains the UTF-16 offset `index`.
    func lineNumber(at index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// One pass over the text: line starts and the fence fingerprint.
    private func rebuildLineIndex(_ text: NSString) {
        let length = text.length
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var starts = [0]
        var hasher = Hasher()
        buffer.withUnsafeBufferPointer { chars in
            var lineStart = 0
            for i in 0...length where i == length || chars[i] == 0x0A {
                Self.hashFenceLine(chars, start: lineStart, end: i, into: &hasher)
                if i < length { starts.append(i + 1) }
                lineStart = i + 1
            }
        }
        lineStarts = starts
        fenceFingerprint = hasher.finalize()
    }

    /// Adds a line to the hash if it looks like a fence: up to 3 spaces, then 3 or more
    /// backticks or tildes. The rest of the line decides open/close rules, so it goes in too.
    private static func hashFenceLine(_ chars: UnsafeBufferPointer<unichar>, start: Int, end: Int,
                                      into hasher: inout Hasher) {
        var i = start
        while i < end, i - start < 3, chars[i] == 0x20 { i += 1 }
        guard i < end, chars[i] == 0x60 || chars[i] == 0x7E else { return }
        let fenceChar = chars[i]
        var j = i
        while j < end, chars[j] == fenceChar { j += 1 }
        guard j - i >= 3 else { return }
        var restIsBlank = true
        var restHasBacktick = false
        for k in j..<end {
            let c = chars[k]
            if c != 0x20, c != 0x09, c != 0x0D { restIsBlank = false }
            if c == 0x60 { restHasBacktick = true }
        }
        // No offsets: typing elsewhere must not change the fingerprint.
        hasher.combine(fenceChar)
        hasher.combine(j - i)
        hasher.combine(restIsBlank)
        hasher.combine(restHasBacktick)
    }

    // MARK: - Colouring

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let text = textStorage.string as NSString
        let oldFingerprint = fenceFingerprint
        rebuildLineIndex(text)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true

        var lines = text.lineRange(for: editedRange)
        if fenceFingerprint != oldFingerprint {
            lines = NSRange(location: lines.location, length: text.length - lines.location)
        }
        let spans = MarkdownHighlighter.spans(in: text, lineRange: lines)

        // Attribute changes are allowed here (not character changes). They come before
        // attribute fixing, so font substitution still covers the bold font.
        textStorage.addAttributes(Self.baseAttributes, range: lines)
        for span in spans where span.token == .heading || span.token == .bold {
            textStorage.addAttribute(.font, value: EditorStyle.boldFont, range: span.range)
        }
        pendingColors = (lines, spans)
    }

    private func applyPendingColors() {
        guard let pending = pendingColors, let layoutManager else { return }
        pendingColors = nil
        guard NSMaxRange(pending.range) <= (textStorage?.length ?? 0) else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: pending.range)
        for span in pending.spans {
            guard let color = EditorStyle.color(for: span.token) else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: span.range)
        }
    }

    // MARK: - Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lineRect = currentLineRect(), lineRect.intersects(rect) else { return }
        EditorStyle.currentLine.setFill()
        lineRect.fill(using: .sourceOver)
    }

    /// Rect (view coordinates, full width) of the line fragments of the cursor's logical line.
    func currentLineRect() -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let location = min(selectedRange().location, text.length)
        var rect: NSRect
        if location == text.length, text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            layoutManager.ensureLayout(for: textContainer)
            rect = layoutManager.extraLineFragmentRect
            guard rect.height > 0 else { return nil }
        } else {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            rect = .null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                rect = rect.union(fragment)
            }
            guard !rect.isNull else { return nil }
        }
        rect.origin.x = 0
        rect.size.width = bounds.width
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The current line may have moved. Redraw the visible part; no layout here,
        // because this can run while the text storage is still editing.
        setNeedsDisplay(visibleRect)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}
