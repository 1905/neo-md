import AppKit

/// The 26 pt bar under the content. Left: `modeSlot` (Task 10 puts the Vim badge there). Right: info text.
@MainActor
final class StatusBar: NSView {
    static let height: CGFloat = 26

    /// Container for the Vim mode badge or command line. Hidden until Task 10 fills it.
    let modeSlot = NSStackView()
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
