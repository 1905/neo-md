import AppKit
import MDCore

/// The 26 pt bar under the content. Left: `modeSlot` with the Vim badge or command line. Right: info text.
@MainActor
final class StatusBar: NSView {
    static let height: CGFloat = 26

    /// Container for the Vim mode badge or command line. Hidden when Vim is off or the Render tab shows.
    let modeSlot = NSStackView()
    private let modeBadge = ModeBadge()
    private let commandLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")

    private static let lineFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        modeSlot.orientation = .horizontal
        modeSlot.spacing = 8
        modeSlot.isHidden = true
        commandLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandLabel.textColor = .labelColor
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeSlot.addArrangedSubview(modeBadge)
        modeSlot.addArrangedSubview(commandLabel)

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingHead
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [modeSlot, infoLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            modeSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            modeSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.leadingAnchor.constraint(greaterThanOrEqualTo: modeSlot.trailingAnchor, constant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Left slot: nil mode hides it. A command line (`:w`, `/foo`) replaces the badge while it is typed.
    func showVim(mode: VimMode?, commandLine: String?) {
        guard let mode else {
            modeSlot.isHidden = true
            return
        }
        modeSlot.isHidden = false
        if let commandLine {
            commandLabel.stringValue = commandLine
            commandLabel.isHidden = false
            modeBadge.isHidden = true
        } else {
            let badge = VimStyle.badge(for: mode)
            modeBadge.text = badge.text
            modeBadge.color = badge.color
            modeBadge.isHidden = false
            commandLabel.isHidden = true
        }
    }

    /// Right-side text, e.g. `1 103 lines · 92 KB · UTF-8`.
    var info: String {
        get { infoLabel.stringValue }
        set { infoLabel.stringValue = newValue }
    }

    /// Render tab text: line count (locale grouping), size, encoding.
    static func renderInfo(for text: String) -> String {
        let lines = lineFormatter.string(from: NSNumber(value: lineCount(text))) ?? "0"
        let size = sizeFormatter.string(fromByteCount: Int64(text.utf8.count))
        return "\(lines) lines · \(size) · UTF-8"
    }

    /// Raw and Split text: `Ln 23, Col 48 · UTF-8 · LF` (or `CRLF`).
    static func editorInfo(line: Int, column: Int, lineEnding: String) -> String {
        "Ln \(line), Col \(column) · UTF-8 · \(lineEnding == "\r\n" ? "CRLF" : "LF")"
    }

    /// 1-based column: grapheme clusters from `lineStart` to `location` (UTF-16 offsets), plus 1.
    static func column(in text: NSString, lineStart: Int, location: Int) -> Int {
        let start = min(max(0, lineStart), text.length)
        let end = min(max(start, location), text.length)
        return text.substring(with: NSRange(location: start, length: end - start)).count + 1
    }

    /// Number of lines. A trailing newline does not start a new line. Empty text has 0 lines.
    static func lineCount(_ text: String) -> Int {
        var count = 0
        var last: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A { count += 1 }
            last = byte
        }
        if !text.isEmpty && last != 0x0A { count += 1 }
        return count
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Vim mode badge: white `SF Mono` 11 pt bold text on a rounded mode-colour fill (`.mode` in the mockup).
@MainActor
final class ModeBadge: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var color: NSColor = VimStyle.normal { didSet { needsDisplay = true } }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.white])
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedText.size()
        return NSSize(width: ceil(size.width) + 14, height: ceil(size.height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let size = attributedText.size()
        attributedText.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
