#!/usr/bin/env python3
"""Converts docs/field-assist-vault-guide.md into the site page /field-assist/vault-guide/.

The Markdown is the source. After changing it, run this and commit the page with it:

    python3 -m pip install markdown        # once; any recent version
    python3 Scripts/build-vault-guide-page.py

The page records the SHA-256 of the Markdown it was converted from, and
Scripts/check-pages-site.py fails the deploy when the two disagree, so the page cannot quietly
fall behind the guide. The header and footer are taken from site/source/index.html, so they stay
whatever the rest of the site uses.
"""

import hashlib
import re
import sys
from pathlib import Path

try:
    import markdown
except ImportError:
    sys.exit("build-vault-guide-page: needs the 'markdown' package: python3 -m pip install markdown")

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "docs" / "field-assist-vault-guide.md"
PAGE = REPO / "site" / "field-assist" / "vault-guide" / "index.html"
SHELL = REPO / "site" / "source" / "index.html"
REPOSITORY = "https://github.com/straff2002/OpenGlasses/blob/main/"


def main():
    raw = SOURCE.read_bytes()
    lines = raw.decode("utf-8").split("\n")
    if not (lines[0].startswith("# ") and lines[2].startswith("*") and lines[2].endswith("*")):
        sys.exit("build-vault-guide-page: expected a '# title' line, a blank line, then an *italic* summary line")
    title, summary = lines[0][2:], lines[2].strip("*")

    # Links out of docs/ point at files the site does not publish; send them to the repository.
    body = "\n".join(lines[3:]).replace("](../", "](" + REPOSITORY)
    # A placeholder in angle brackets outside code would be read as an HTML tag and vanish.
    body = re.sub(r"<(?=[a-z][a-z ]*>)(?![^`\n]*`)", "&lt;", body)

    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists"],
                           extension_configs={"toc": {"toc_depth": "2-2"}})
    html = md.convert(body)
    html = html.replace("<table>", '<div class="table-scroll">\n<table>').replace("</table>", "</table>\n</div>")
    contents = "".join(f'\n  <li><a href="#{t["id"]}">{t["name"]}</a></li>' for t in md.toc_tokens)
    summary_html = markdown.markdown(summary)[3:-4]

    shell = SHELL.read_text(encoding="utf-8")
    header = re.search(r'<header class="site-header">.*?</header>', shell, re.S).group(0)
    footer = re.search(r'<footer class="site-footer">.*?</footer>', shell, re.S).group(0)
    header = header.replace('<a href="/field-assist/">', '<a href="/field-assist/" aria-current="page">')

    PAGE.parent.mkdir(parents=True, exist_ok=True)
    PAGE.write_text(f"""<!DOCTYPE html>
<html lang="en-NZ">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; base-uri 'none'; form-action 'none'">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>Vault guide · Field Assist · Avenkin</title>
<meta name="description" content="How to build a Field Assist vault from your own manuals, import it on the iPhone, test it and share it.">
<!-- Converted from docs/field-assist-vault-guide.md by Scripts/build-vault-guide-page.py. That file
     is the source: change the guide there and run the script again, rather than editing this page.
     source-sha256: {hashlib.sha256(raw).hexdigest()} -->
<link rel="stylesheet" href="/assets/site.css">
<link rel="icon" href="/assets/mark.svg" type="image/svg+xml">
</head>
<body>
<div class="stage compact">
{header}
<section class="page-hero">
  <p class="kicker">Field Assist guide</p>
  <h1>{title}</h1>
  <p class="lede">Turn your own manuals into a vault the assistant can search and cite.</p>
</section>
</div>
<main>
<div class="prose">
<p class="meta">{summary_html}</p>
<p class="meta">Also available as a <a href="/docs/field-assist-vault-guide.pdf">PDF</a>.</p>
<nav class="contents" aria-label="Contents">
<ol>{contents}
</ol>
</nav>
{html}
</div>
</main>
{footer}
</body>
</html>
""", encoding="utf-8")
    print(f"build-vault-guide-page: wrote {PAGE.relative_to(REPO)}")


if __name__ == "__main__":
    main()
