#!/usr/bin/env python3
"""Converts docs/field-assist-vault-guide.md into the site page /field-assist/vault-guide/ and,
with --pdf, into docs/field-assist-vault-guide.pdf.

The Markdown is the source. After changing it, run this and commit what it writes:

    python3 -m pip install markdown        # once; any recent version
    python3 Scripts/build-vault-guide-page.py --pdf

The PDF is printed by a local Google Chrome or Chromium running headless, so --pdf needs one
installed; without --pdf only the page is written.

The page records the SHA-256 of the Markdown it was converted from, and
Scripts/check-pages-site.py fails the deploy when the two disagree, so the page cannot quietly
fall behind the guide. The header and footer are taken from site/source/index.html, so they stay
whatever the rest of the site uses.
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import markdown
except ImportError:
    sys.exit("build-vault-guide-page: needs the 'markdown' package: python3 -m pip install markdown")

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "docs" / "field-assist-vault-guide.md"
PAGE = REPO / "site" / "field-assist" / "vault-guide" / "index.html"
SHELL = REPO / "site" / "source" / "index.html"
PDF = REPO / "docs" / "field-assist-vault-guide.pdf"
REPOSITORY = "https://github.com/straff2002/OpenGlasses/blob/main/"
SITE = "https://avenkin.com"

CHROME_CANDIDATES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
)

PRINT_CSS = """
@page { size: A4; margin: 18mm 17mm 20mm; }
* { box-sizing: border-box; }
html { font: 10.5pt/1.55 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #202B2D; }
body { margin: 0; }
a { color: #A4441A; text-decoration: none; }
.cover { border: 1.5pt solid #202B2D; padding: 16pt 20pt 14pt; margin: 0 0 20pt; }
.cover .kicker { margin: 0 0 6pt; font-size: 8pt; letter-spacing: 0.14em; text-transform: uppercase; color: #5B6668; }
.cover h1 { margin: 0 0 12pt; font-size: 23pt; line-height: 1.1; letter-spacing: -0.02em; }
.cover table { width: auto; border-collapse: collapse; font: 8.5pt/1.6 Menlo, Consolas, monospace; }
.cover td { padding: 0 14pt 0 0; border: 0; vertical-align: top; }
.cover td:first-child { color: #5B6668; letter-spacing: 0.08em; text-transform: uppercase; white-space: nowrap; }
h2 { margin: 24pt 0 8pt; padding-top: 14pt; border-top: 1.2pt solid #202B2D; font-size: 15pt; line-height: 1.25; break-after: avoid; }
h3 { margin: 16pt 0 4pt; font-size: 11.5pt; break-after: avoid; }
p, ul, ol { margin: 0 0 9pt; }
ul, ol { padding-left: 16pt; }
li { margin-bottom: 4pt; }
pre {
  margin: 0 0 10pt; padding: 10pt 12pt; background: #F1EEE7; border: 0.5pt solid #DDD8CE;
  border-left: 3pt solid #E77F47; font: 8pt/1.5 Menlo, Consolas, monospace;
  white-space: pre-wrap; overflow-wrap: anywhere; break-inside: avoid;
}
code { font: 0.88em Menlo, Consolas, monospace; background: #F1EEE7; padding: 0 3pt; border-radius: 2pt; overflow-wrap: anywhere; }
pre code { font: inherit; background: none; padding: 0; }
table { width: 100%; margin: 0 0 10pt; border-collapse: collapse; font-size: 9.5pt; }
th, td { padding: 5pt 8pt 5pt 0; border-bottom: 0.5pt solid #C9C4BA; text-align: left; vertical-align: top; }
th { font-size: 8pt; letter-spacing: 0.06em; text-transform: uppercase; color: #5B6668; }
tr { break-inside: avoid; }
blockquote { margin: 0 0 10pt; padding: 8pt 12pt; border-left: 3pt solid #E77F47; background: #F8F5EF; break-inside: avoid; }
blockquote p:last-child { margin-bottom: 0; }
"""


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
    plain_html = md.convert(body)
    html = plain_html.replace("<table>", '<div class="table-scroll">\n<table>').replace("</table>", "</table>\n</div>")
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

    if "--pdf" in sys.argv[1:]:
        write_pdf(title, summary, plain_html)


def write_pdf(title, summary, html):
    chrome = next((c for c in CHROME_CANDIDATES if (os.path.isfile(c) or shutil.which(c))), None)
    if chrome is None:
        sys.exit("build-vault-guide-page: --pdf needs Google Chrome or Chromium installed")

    # The summary line is "product · applies to … · licence · formats: …"; lay it out as the
    # cover's three labelled rows when it has that shape, and as one line when it does not.
    parts = [part.strip() for part in summary.split(" · ")]
    if len(parts) == 4 and parts[1].startswith("applies to ") and parts[3].startswith("formats: "):
        rows = (("Applies to", parts[1][len("applies to "):]), ("Licence", parts[2]),
                ("Formats", parts[3][len("formats: "):]))
        facts = "<table>" + "".join(f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in rows) + "</table>"
    else:
        facts = f"<p>{summary}</p>"

    # On paper a site-relative link goes nowhere, so make the few there are absolute.
    html = html.replace('href="/', f'href="{SITE}/')
    document = f"""<!DOCTYPE html>
<html lang="en-NZ">
<head>
<meta charset="utf-8">
<title>Field Assist Vault Guide</title>
<style>{PRINT_CSS}</style>
</head>
<body>
<div class="cover">
  <p class="kicker">Avenkin · Field Assist</p>
  <h1>{title}</h1>
  {facts}
</div>
{html}
</body>
</html>
"""
    with tempfile.TemporaryDirectory() as scratch:
        source = Path(scratch) / "guide.html"
        source.write_text(document, encoding="utf-8")
        printed = Path(scratch) / "guide.pdf"
        # Its own profile, so it neither needs nor disturbs a Chrome that is already open. Some
        # Chrome builds write the file and then never exit, so a timeout with the file in place
        # counts as done.
        command = [chrome, "--headless", "--disable-gpu", "--no-first-run", "--no-pdf-header-footer",
                   f"--user-data-dir={Path(scratch) / 'profile'}", f"--print-to-pdf={printed}",
                   source.as_uri()]
        try:
            subprocess.run(command, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            pass
        if not printed.is_file() or printed.stat().st_size == 0:
            sys.exit("build-vault-guide-page: Chrome did not produce a PDF")
        shutil.copyfile(printed, PDF)
    print(f"build-vault-guide-page: wrote {PDF.relative_to(REPO)}")


if __name__ == "__main__":
    main()
