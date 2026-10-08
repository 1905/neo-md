import MDCore

/// The live Render page. `PreviewWebView` loads it once and then drives it through JS:
/// `setBase(href)`, `update(html)`, `scrollToLine(n)`, `setAccent(hex)`, `setTypography(cssText)`.
/// On scroll (throttled to 100 ms) the page posts the source line at the top of the view
/// to the `visibleLine` message handler (body: Int).
enum Template {
    static let csp = "default-src 'none'; img-src mdv-asset: https: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'"

    static let page: String = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(csp)">
    <base href="mdv-asset://doc/">
    <style>
    \(HTMLTemplate.css)
    </style>
    <style id="typography">
    \(HTMLTemplate.typographyCSS(readingFont: "", scale: 1))
    </style>
    </head>
    <body>
    <article id="content"></article>
    <script>
    \(script)
    </script>
    </body>
    </html>
    """

    private static let script = #"""
    (function () {
      "use strict";
      var content = document.getElementById("content");

      function startLine(el) {
        var n = parseInt(el.getAttribute("data-sourcepos"), 10);
        return isNaN(n) ? 0 : n;
      }

      // The document folder as `mdv-asset://doc/<absolute path>/`. Relative links and
      // images in later `update` calls resolve against it.
      window.setBase = function (href) {
        document.querySelector("base").href = href;
      };

      window.update = function (html) {
        var y = window.scrollY;
        content.innerHTML = html;
        window.scrollTo(0, y);
      };

      window.scrollToLine = function (n) {
        var blocks = content.querySelectorAll("[data-sourcepos]");
        var target = null;
        for (var i = 0; i < blocks.length; i++) {
          if (startLine(blocks[i]) <= n) { target = blocks[i]; }
        }
        if (target) { target.scrollIntoView({ block: "start" }); }
        else { window.scrollTo(0, 0); }
      };

      window.setAccent = function (hex) {
        document.documentElement.style.setProperty("--accent", hex);
      };

      // Replaces the reading font and size rule (`HTMLTemplate.typographyCSS`).
      window.setTypography = function (cssText) {
        document.getElementById("typography").textContent = cssText;
      };

      // Source line of the first top-level block whose bottom is below the top of the view.
      function topVisibleLine() {
        var blocks = content.children;
        for (var i = 0; i < blocks.length; i++) {
          if (blocks[i].hasAttribute("data-sourcepos") && blocks[i].getBoundingClientRect().bottom > 0) {
            return startLine(blocks[i]);
          }
        }
        return 0;
      }

      function postVisibleLine() {
        var line = topVisibleLine();
        if (line > 0 && window.webkit && window.webkit.messageHandlers.visibleLine) {
          window.webkit.messageHandlers.visibleLine.postMessage(line);
        }
      }

      // Throttle to 100 ms, with a trailing call so the final position is always posted.
      var last = 0, timer = null;
      window.addEventListener("scroll", function () {
        var now = Date.now();
        var wait = 100 - (now - last);
        if (wait <= 0) {
          last = now;
          postVisibleLine();
        } else if (!timer) {
          timer = setTimeout(function () {
            timer = null;
            last = Date.now();
            postVisibleLine();
          }, wait);
        }
      }, { passive: true });
    })();
    """#
}
