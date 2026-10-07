import Foundation

/// Shared Render styles and a script-free page for previews that cannot run JavaScript (Quick Look).
/// The app's live page (`Template.page` in NeoMD) embeds the same `css` and adds its own script.
public enum HTMLTemplate {
    /// All Render styles. Light and dark through `prefers-color-scheme`. Links and checkboxes use `var(--accent)`.
    /// The body content sits in an `<article>` element.
    public static let css: String = #"""
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --text: #1d1d1f;
      --text-2: #6e6e73;
      --text-3: #a1a1a6;
      --code-bg: #f3f3f1;
      --rule: #e8e8e6;
      --accent: #0a64d8;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1e1e1f;
        --text: #e8e8ea;
        --text-2: #98989d;
        --text-3: #636366;
        --code-bg: #2c2c2e;
        --rule: #38383a;
        --accent: #4c9bff;
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); }
    body {
      font: 15.5px/1.62 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased;
      padding: 48px 0 64px;
    }
    article { max-width: 720px; margin: 0 auto; padding: 0 40px; overflow-wrap: break-word; }
    body.split article { max-width: none; padding: 0 44px; font-size: 14.5px; }
    article > :first-child { margin-top: 0; }
    h1, h2, h3, h4, h5, h6 { color: var(--text); }
    h1 { font-size: 30px; line-height: 1.2; font-weight: 700; letter-spacing: -.01em; margin: 0 0 18px; }
    h2 { font-size: 21px; line-height: 1.3; font-weight: 650; margin: 34px 0 12px; }
    h3 { font-size: 12px; line-height: 1.4; font-weight: 650; letter-spacing: .07em; text-transform: uppercase; color: var(--text-2); margin: 26px 0 8px; }
    h4 { font-size: 16px; font-weight: 650; margin: 22px 0 8px; }
    h5 { font-size: 14px; font-weight: 650; margin: 20px 0 6px; }
    h6 { font-size: 13px; font-weight: 650; color: var(--text-2); margin: 20px 0 6px; }
    p { margin: 0 0 14px; }
    ul, ol { margin: 0 0 14px; padding-left: 20px; }
    li { margin: 3px 0; }
    li::marker { color: var(--text-3); }
    li > ul, li > ol { margin: 3px 0 0; }
    li > p { margin: 0 0 6px; }
    li:has(> input[type="checkbox"]) { list-style: none; margin-left: -20px; }
    input[type="checkbox"] { margin: 0 6px 0 0; vertical-align: -1px; accent-color: var(--accent); }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 650; }
    del { color: var(--text-2); }
    code {
      font-family: "SF Mono", Menlo, monospace; font-size: .86em;
      background: var(--code-bg); padding: 1px 5px; border-radius: 4px;
    }
    pre {
      font-family: "SF Mono", Menlo, monospace; font-size: 12.5px; line-height: 1.55;
      background: var(--code-bg); border-radius: 8px; padding: 14px 16px;
      white-space: pre-wrap; margin: 0 0 14px;
    }
    pre code { background: none; padding: 0; border-radius: 0; font-size: inherit; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 30px 0; }
    blockquote { margin: 0 0 14px; padding: 2px 0 2px 16px; border-left: 3px solid var(--rule); color: var(--text-2); }
    blockquote > :last-child { margin-bottom: 0; }
    table { display: block; overflow-x: auto; border-collapse: collapse; margin: 0 0 14px; font-size: 14px; line-height: 1.45; }
    th, td { border: 1px solid var(--rule); padding: 6px 12px; text-align: left; vertical-align: top; }
    th { background: var(--code-bg); font-weight: 600; }
    img { max-width: 100%; height: auto; }
    .meta { color: var(--text-2); }
    .error { color: var(--text-2); text-align: center; margin-top: 80px; }
    """#

    /// A full HTML page with the Render styles and `body` inside `<article>`.
    /// It has no `<script>`, and its Content-Security-Policy blocks every load except inline styles.
    public static func staticPage(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(css)
        </style>
        </head>
        <body>
        <article>
        \(body)
        </article>
        </body>
        </html>
        """
    }
}
