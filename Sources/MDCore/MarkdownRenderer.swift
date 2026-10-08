import Foundation
import cmark_gfm
import cmark_gfm_extensions

public enum MarkdownRenderer {
    private static let registerExtensions: Void = {
        cmark_gfm_core_extensions_ensure_registered()
    }()

    private static let extensionNames = ["table", "strikethrough", "autolink", "tasklist"]

    /// Renders GitHub Flavored Markdown to an HTML body fragment and collects the heading outline.
    /// Raw HTML is never passed through (no `CMARK_OPT_UNSAFE`). Returns nil only if cmark returns NULL.
    public static func render(_ markdown: String) -> RenderResult? {
        _ = registerExtensions
        let options = CMARK_OPT_SOURCEPOS

        guard let parser = cmark_parser_new(options) else { return nil }
        defer { cmark_parser_free(parser) }

        for name in extensionNames {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        var source = markdown
        source.withUTF8 { bytes in
            guard bytes.count > 0 else { return }
            bytes.withMemoryRebound(to: CChar.self) { chars in
                cmark_parser_feed(parser, chars.baseAddress, chars.count)
            }
        }

        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }

        let outline = collectOutline(root)

        guard let htmlPtr = cmark_render_html(root, options, cmark_parser_get_syntax_extensions(parser)) else {
            return nil
        }
        defer { free(htmlPtr) }

        return RenderResult(html: String(cString: htmlPtr), outline: outline)
    }

    private static func collectOutline(_ root: UnsafeMutablePointer<cmark_node>) -> [OutlineItem] {
        guard let iter = cmark_iter_new(root) else { return [] }
        defer { cmark_iter_free(iter) }

        var items: [OutlineItem] = []
        var level = 0
        var line = 0
        var text: String? = nil   // non-nil while inside a heading

        while true {
            let event = cmark_iter_next(iter)
            if event == CMARK_EVENT_DONE { break }
            guard let node = cmark_iter_get_node(iter) else { continue }
            let type = cmark_node_get_type(node)

            if type == CMARK_NODE_HEADING {
                if event == CMARK_EVENT_ENTER {
                    level = Int(cmark_node_get_heading_level(node))
                    line = Int(cmark_node_get_start_line(node))
                    text = ""
                } else if event == CMARK_EVENT_EXIT, let heading = text {
                    items.append(OutlineItem(level: level, text: heading, line: line))
                    text = nil
                }
            } else if event == CMARK_EVENT_ENTER, text != nil,
                      type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE,
                      let literal = cmark_node_get_literal(node) {
                text? += String(cString: literal)
            }
        }
        return items
    }
}
