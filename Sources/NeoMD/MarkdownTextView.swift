import AppKit
import MDCore

/// Fonts, metrics and colours of the raw editor. Colours follow `mockup/base.css`.
/// Fonts and line height follow `Settings.editorFont` and `Settings.fontScale`.
enum EditorStyle {
    /// The size factor of the current text size step.
    static var factor: CGFloat { CGFloat(FontScale.factor(step: Settings.shared.fontScale)) }
    /// 13 pt at step 0.
    static var size: CGFloat { 13 * factor }
    static var font: NSFont { fonts().regular }
    static var boldFont: NSFont { fonts().bold }
    /// 21 pt at step 0.
    static var lineHeight: CGFloat { (size * 21 / 13).rounded() }
    static let topInset: CGFloat = 20

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    /// Changes when the editor font or the text size changes.
    static var typographyKey: String { "\(Settings.shared.editorFont)|\(Settings.shared.fontScale)" }

    /// Fonts for `typographyKey`. The editor reads them on every edit and redraw, so they are cached.
    private static var cache: (key: String, regular: NSFont, bold: NSFont)?

    private static func fonts() -> (regular: NSFont, bold: NSFont) {
        let key = typographyKey
        if let cache, cache.key == key { return (cache.regular, cache.bold) }
        let fonts: (regular: NSFont, bold: NSFont)
        if let regular = familyFont(bold: false) {
            // A family with no bold face keeps the regular face for bold text.
            fonts = (regular, familyFont(bold: true) ?? regular)
        } else {
            fonts = (.monospacedSystemFont(ofSize: size, weight: .regular),
                     .monospacedSystemFont(ofSize: size, weight: .bold))
        }
        cache = (key, fonts.regular, fonts.bold)
        return fonts
    }

    /// `Settings.editorFont` at `size`, or nil if the setting is empty or the family is not installed.
    private static func familyFont(bold: Bool) -> NSFont? {
        let family = Settings.shared.editorFont
        guard !family.isEmpty else { return nil }
        return NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                         weight: bold ? 9 : 5, size: size)
    }

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
/// right after each edit, as its own attribute-only edit. That does not register undo either.
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
    /// Lines whose fonts must be set after the current edit; see `applyPendingFonts()`.
    private var pendingFontRange: NSRange?

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

        standardInsertionPointColor = insertionPointColor
        standardSelectedTextAttributes = selectedTextAttributes

        textStorage?.delegate = self
        (layoutManager as? HighlightLayoutManager)?.onProcessEditing = { [weak self] in
            self?.applyPendingColors()
        }
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: EditorStyle.font,
            .paragraphStyle: EditorStyle.paragraphStyle,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    // MARK: - Typography

    /// `EditorStyle.typographyKey` of the fonts on the text now.
    private var appliedTypographyKey = EditorStyle.typographyKey

    /// Puts the current editor font and line height on all of the text, then colours it again.
    /// Does nothing if the font and size did not change. One attribute-only edit
    /// (the `applyPendingFonts()` path): no undo, no cursor move.
    func applyTypography() {
        let key = EditorStyle.typographyKey
        guard key != appliedTypographyKey, let storage = textStorage else { return }
        appliedTypographyKey = key
        defaultParagraphStyle = EditorStyle.paragraphStyle
        typingAttributes = Self.baseAttributes
        let all = NSRange(location: 0, length: storage.length)
        pendingFontRange = all
        applyPendingFonts()
        pendingColors = (all, MarkdownHighlighter.spans(in: storage.string as NSString, lineRange: all))
        applyPendingColors()
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.updateThickness()
        setNeedsDisplay(visibleRect)
    }

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

    /// UTF-16 offset where the 1-based logical `line` starts; 0 if the line does not exist.
    func lineStart(ofLine line: Int) -> Int {
        line >= 1 && line <= lineStarts.count ? lineStarts[line - 1] : 0
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
        pendingColors = (lines, spans)

        // No storage attribute changes here: they grow `editedRange` past the typed
        // text, and NSTextView then puts the cursor at the end of the grown range
        // (the start of the next line). The font pass runs after the edit instead.
        if let pending = pendingFontRange {
            // A second edit before the pass ran: older offsets may have shifted.
            let location = min(pending.location, lines.location)
            pendingFontRange = NSRange(location: location, length: text.length - location)
        } else {
            pendingFontRange = lines
            // `didChangeText()` runs the pass for typing; this covers `string` and other
            // edits that do not go through it.
            DispatchQueue.main.async { [weak self] in self?.applyPendingFonts() }
        }
    }

    override func didChangeText() {
        applyPendingFonts()
        super.didChangeText()
    }

    /// Base attributes and the bold font on the lines of the last edits, as a
    /// separate attribute-only edit. It does not register undo and does not move the cursor.
    private func applyPendingFonts() {
        guard let pending = pendingFontRange, let storage = textStorage else { return }
        pendingFontRange = nil
        let text = storage.string as NSString
        let location = min(pending.location, text.length)
        let lines = text.lineRange(for: NSRange(location: location,
                                                length: min(NSMaxRange(pending), text.length) - location))
        let spans = MarkdownHighlighter.spans(in: text, lineRange: lines)
        storage.beginEditing()
        storage.addAttributes(Self.baseAttributes, range: lines)
        for span in spans where span.token == .heading || span.token == .bold {
            storage.addAttribute(.font, value: EditorStyle.boldFont, range: span.range)
        }
        storage.endEditing()
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
        guard let layoutManager, textContainer != nil, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let location = min(selectedRange().location, text.length)
        var rect: NSRect
        if Self.isOnEmptyLastLine(location, in: text) {
            guard let fragment = extraLineFragment() else { return nil }
            rect = fragment
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

    /// True when `location` is on the empty line after a trailing newline (or in an empty text).
    private static func isOnEmptyLastLine(_ location: Int, in text: NSString) -> Bool {
        location == text.length && (text.length == 0 || text.character(at: text.length - 1) == 0x0A)
    }

    /// The laid-out empty last line (`extraLineFragmentRect`), or nil when it has no height.
    private func extraLineFragment() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let fragment = layoutManager.extraLineFragmentRect
        return fragment.height > 0 ? fragment : nil
    }

    // MARK: - Vim

    /// Set by `EditorPane`. Weak: the pane owns both objects.
    weak var vimController: VimController?
    /// Caret colour and selection look of the standard (non-Vim) editor, restored when Vim leaves block mode.
    private var standardInsertionPointColor = NSColor.textColor
    private var standardSelectedTextAttributes: [NSAttributedString.Key: Any] = [:]

    private var showsBlockCursor: Bool { vimController?.showsBlockCursor ?? false }

    override func keyDown(with event: NSEvent) {
        // ⌘ shortcuts and marked (IME) text always take the standard path.
        if !event.modifierFlags.contains(.command), !hasMarkedText(),
           let vimController, vimController.handle(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// Called by `VimController` after a mode or command-line change.
    func vimStateDidChange() {
        insertionPointColor = showsBlockCursor ? .clear : standardInsertionPointColor
        let mode = vimController?.mode
        if vimController?.isEnabled == true, mode == .visual || mode == .visualLine {
            selectedTextAttributes = [.backgroundColor: VimStyle.visual.withAlphaComponent(0.3)]
        } else {
            selectedTextAttributes = standardSelectedTextAttributes
        }
        updateInsertionPointStateAndRestartTimer(true)
        setNeedsDisplay(visibleRect)
    }

    /// Block mode draws its own cursor in `draw(_:)`; the thin caret stays hidden.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard !showsBlockCursor else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    /// Standard block-cursor recipe: grow every invalidated rect by one cell so the wide cursor redraws.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if showsBlockCursor { rect.size.width += Self.spaceWidth }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    private static var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: EditorStyle.font]).width }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let vimController, vimController.showsBlockCursor else { return }
        let location = vimController.visualCursor ?? selectedRange().location
        guard let cursor = blockCursor(at: location) else { return }
        let (rect, grapheme, font) = cursor
        guard rect.intersects(dirtyRect) else { return }
        let color = vimController.visualCursor != nil ? VimStyle.visual : VimStyle.normal
        guard window?.firstResponder === self else {
            // Not focused: an outline, as in Terminal.
            color.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return
        }
        color.setFill()
        rect.fill()
        if let grapheme {
            NSAttributedString(string: grapheme, attributes: [.font: font, .foregroundColor: NSColor.textBackgroundColor])
                .draw(at: rect.origin)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, showsBlockCursor { setNeedsDisplay(visibleRect) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, showsBlockCursor { setNeedsDisplay(visibleRect) }
        return accepted
    }

    /// Block cursor rect (view coordinates) at a UTF-16 offset, one grapheme wide, or one
    /// space wide at a line end. Also the grapheme to draw on top (nil at a line end) and its font.
    private func blockCursor(at index: Int) -> (NSRect, String?, NSFont)? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let location = min(max(0, index), text.length)
        let metrics = EditorStyle.font
        var grapheme: String?
        var font = metrics
        let x: CGFloat, baseline: CGFloat
        var width = Self.spaceWidth

        if location < text.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = layoutManager.location(forGlyphAt: glyph)
            x = fragment.minX + point.x
            baseline = fragment.minY + point.y
            let char = text.character(at: location)
            if char != 0x0A, char != 0x0D {
                let range = text.rangeOfComposedCharacterSequence(at: location)
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                if bounds.width > 0 { width = bounds.width }
                grapheme = text.substring(with: range)
                font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? metrics
            }
        } else if Self.isOnEmptyLastLine(location, in: text) {
            guard let fragment = extraLineFragment() else { return nil }
            x = fragment.minX
            baseline = fragment.maxY + metrics.descender
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: text.length - 1)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let last = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            x = last.maxX
            baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
        }
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x + x, y: origin.y + baseline - metrics.ascender,
                          width: width, height: metrics.ascender - metrics.descender)
        return (rect, grapheme, font)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The current line may have moved. Redraw the visible part; no layout here,
        // because this can run while the text storage is still editing.
        setNeedsDisplay(visibleRect)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}
