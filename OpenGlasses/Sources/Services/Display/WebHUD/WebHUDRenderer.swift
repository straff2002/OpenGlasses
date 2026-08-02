import Foundation

/// Plan BP — pure `HUDScreen`-payload → single-file HTML page for the Ray-Ban Display
/// **Web App** surface (600×600 built-in web view, entitlement-free enrollment).
///
/// Platform constraints baked in:
/// - Additive display: **black = transparent**, so the page is pure-black with
///   high-contrast light-on-black text only. No photos, no gradients.
/// - Focus indicator is amber weight+outline — high contrast, deliberately NOT cyan
///   (house rule).
/// - D-pad arrives as plain keyboard events (▲▼/Enter) — focus model is ordinary DOM nav.
/// - Exactly one URL registers; the auth token rides the URL hash (`#t=<token>`), which
///   never appears in HTTP requests or server logs — the page JS forwards it as a query
///   parameter on `hud.json` fetches only.
/// - Self-contained: inline CSS/JS, no build step, **no external fetches** (the poll hits
///   a relative URL only).
enum WebHUDRenderer {

    enum Mode: Equatable {
        /// Static export: the payload is inlined; no polling (the dev-harness/desktop loop).
        case inline(WebHUDPayload)
        /// Live mirror: poll a relative `hud.json` and re-render on renderKey change.
        case polling(intervalSeconds: Int)
    }

    /// The one render function. Both modes share the same client-side `render(payload)`,
    /// so the poll path adds no second layout implementation.
    static func page(mode: Mode) -> String {
        let inlineJSON: String
        let pollInterval: Int
        switch mode {
        case .inline(let payload):
            // `</` must not close our script tag; JSON stays valid with the escape.
            inlineJSON = String(decoding: payload.jsonData(), as: UTF8.self)
                .replacingOccurrences(of: "</", with: "<\\/")
            pollInterval = 0
        case .polling(let seconds):
            inlineJSON = "null"
            pollInterval = max(1, seconds)
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=600, initial-scale=1">
        <meta name="mrbd-web-app-capable" content="yes">
        <title>OpenGlasses HUD</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { width: 600px; height: 600px; background: #000; color: #fff;
          font-family: -apple-system, 'Helvetica Neue', sans-serif; overflow: hidden; }
        #hud { padding: 28px; height: 100%; overflow-y: auto; }
        .title { font-size: 34px; font-weight: 700; margin-bottom: 18px; }
        .line { font-size: 28px; line-height: 1.35; margin-bottom: 10px; }
        .line.secondary { color: #c8c8c8; }
        .line.meta { font-size: 22px; color: #a0a0a0; }
        .item { font-size: 28px; padding: 10px 14px; margin-top: 10px;
          border: 2px solid #666; border-radius: 10px; outline: none; }
        .item.primary { border-color: #fff; font-weight: 600; }
        .item:focus { border-color: #ffb000; color: #ffb000; border-width: 3px; }
        .glyph { display: inline-block; min-width: 1.4em; }
        #empty { color: #808080; font-size: 26px; padding-top: 240px; text-align: center; }
        </style>
        </head>
        <body>
        <div id="hud"></div>
        <script>
        const INLINE_PAYLOAD = \(inlineJSON);
        const POLL_SECONDS = \(pollInterval);
        const GLYPHS = { none: "", info: "(i)", success: "[OK]", warning: "[!]", error: "[X]",
          navigation: "\u{2192}", hazard: "[!]", calendar: "[\u{25A4}]", location: "[\u{2302}]",
          reminder: "[\u{2022}]", message: "[\u{2709}]" };
        let lastKey = null;

        function render(payload) {
          if (payload && payload.renderKey === lastKey) { return; }
          lastKey = payload ? payload.renderKey : null;
          const hud = document.getElementById("hud");
          hud.textContent = "";
          if (!payload || (!payload.title && payload.lines.length === 0 && payload.items.length === 0)) {
            const empty = document.createElement("div");
            empty.id = "empty";
            empty.textContent = "\u{2014}";
            hud.appendChild(empty);
            return;
          }
          if (payload.title) {
            const el = document.createElement("div");
            el.className = "title";
            el.textContent = payload.title;   // textContent everywhere: markup-proof
            hud.appendChild(el);
          }
          for (const line of payload.lines) {
            const el = document.createElement("div");
            el.className = "line " + line.emphasis;
            const glyph = GLYPHS[line.icon] || "";
            if (glyph) {
              const g = document.createElement("span");
              g.className = "glyph";
              g.textContent = glyph;
              el.appendChild(g);
            }
            el.appendChild(document.createTextNode(line.text));
            hud.appendChild(el);
          }
          payload.items.forEach((item, index) => {
            const el = document.createElement("div");
            el.className = "item " + item.style;
            el.tabIndex = index + 1;
            el.textContent = (index + 1) + ". " + item.label;
            hud.appendChild(el);
          });
          const first = hud.querySelector(".item");
          if (first) { first.focus(); }
        }

        // D-pad: arrows move focus across items; Enter is a read-only no-op in v1.
        document.addEventListener("keydown", (event) => {
          const items = Array.from(document.querySelectorAll(".item"));
          if (items.length === 0) { return; }
          const index = items.indexOf(document.activeElement);
          if (event.key === "ArrowDown") {
            items[Math.min(items.length - 1, index + 1)].focus();
            event.preventDefault();
          } else if (event.key === "ArrowUp") {
            items[Math.max(0, index - 1)].focus();
            event.preventDefault();
          } else if (event.key === "Enter") {
            event.preventDefault();   // mirror is read-only; actions live on the phone
          }
        });

        function token() {
          const match = location.hash.match(/[#&]t=([^&]+)/);
          return match ? match[1] : "";
        }

        async function poll() {
          try {
            const response = await fetch("hud.json?t=" + encodeURIComponent(token()),
                                         { cache: "no-store" });
            if (response.ok) { render(await response.json()); }
          } catch (_) { /* transient — keep the last frame */ }
        }

        if (INLINE_PAYLOAD !== null) {
          render(INLINE_PAYLOAD);
        } else {
          poll();
          setInterval(poll, POLL_SECONDS * 1000);
        }
        </script>
        </body>
        </html>
        """
    }
}
