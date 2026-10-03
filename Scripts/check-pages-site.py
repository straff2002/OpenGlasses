#!/usr/bin/env python3
"""Checks over the staged public site (Plan FZ, "Tests").

Run after Scripts/stage-pages-site.sh, against the tree it staged:

    Scripts/stage-pages-site.sh && python3 Scripts/check-pages-site.py [_site]

The stage script decides what may be published. This decides whether what was staged still keeps
the site's promises:

  legacy paths     every line of Scripts/site-legacy-paths.txt is present (FZ I1)
  third parties    no page or stylesheet loads anything from another site (FZ I4)
  outbound links   anchors leave the site only for an allowlisted host
  no steering      pages the iOS app links to carry no link to plans or licensing (FZ I5)
  internal links   every same-site link and fragment resolves in the staged tree
  sign-in page     nothing links to a fragment of the homepage, which would be read as a Meta
                   sign-in result and handed to the app
  script policy    every page under the site's Content-Security-Policy lists the SHA-256 of each
                   inline script it carries, so the sign-in hand-off is never silently blocked
  404, security    404.html and a well-formed .well-known/security.txt exist
  vault guide      the guide page was converted from the Markdown as it stands now

Standard library only. Exit status is nonzero on any failure, which stops the deploy.
"""

import base64
import datetime
import hashlib
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

REPO = Path(__file__).resolve().parent.parent

# Hosts an anchor may point at. Adding a host is a deliberate, reviewed change.
OUTBOUND_HOSTS = {
    "github.com",       # the source repository, its issues and private vulnerability reporting
    "avenkin.com",      # the site's own canonical address
    "testflight.apple.com",  # the public beta invitation
}

# privacy.html names each provider's own privacy policy, so its anchors are not held to the
# allowlist above. It is still held to every other check.
OUTBOUND_EXEMPT = {"privacy.html"}

# Pages the iOS app opens, or that App Review reaches from it. None may link to a purchase path.
APP_LINKED = ("privacy.html", "support.html", "docs/", "translations/")
PURCHASE_PATHS = ("/pricing", "/licensing")

# Attributes that make the browser fetch something, as opposed to anchors the reader follows.
RESOURCE_ATTRS = {
    "script": ("src",), "img": ("src", "srcset"), "source": ("src", "srcset"),
    "video": ("src", "poster"), "audio": ("src",), "iframe": ("src",), "embed": ("src",),
    "object": ("data",), "link": ("href",), "form": ("action",), "track": ("src",),
    "input": ("src",),
}

CSS_URL = re.compile(r"url\(\s*['\"]?([^'\")\s]+)", re.I)
CSS_IMPORT = re.compile(r"@import\s+(?:url\()?\s*['\"]?([^'\")\s;]+)", re.I)


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.anchors, self.resources, self.ids = [], [], set()
        self.inline_scripts, self.inline_styles, self.csp = [], [], None
        self._capture = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        if tag in ("a", "area") and a.get("href") is not None:
            self.anchors.append(a["href"])
        for attr in RESOURCE_ATTRS.get(tag, ()):
            if a.get(attr):
                self.resources.append((tag, a[attr]))
        if tag == "meta" and (a.get("http-equiv") or "").lower() == "content-security-policy":
            self.csp = a.get("content") or ""
        if tag == "script" and not a.get("src"):
            self._capture = ("script", [])
        if tag == "style":
            self._capture = ("style", [])

    def handle_data(self, data):
        if self._capture:
            self._capture[1].append(data)

    def handle_endtag(self, tag):
        if self._capture and tag == self._capture[0]:
            text = "".join(self._capture[1])
            (self.inline_scripts if tag == "script" else self.inline_styles).append(text)
            self._capture = None


def is_external(url):
    return bool(urlsplit(url).scheme in ("http", "https") or url.startswith("//"))


def main():
    site = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "_site").resolve()
    if not site.is_dir():
        sys.exit(f"check-pages-site: no staged site at {site}. Run Scripts/stage-pages-site.sh first.")

    failures = []

    def fail(where, message):
        failures.append(f"{where}: {message}")

    # --- legacy paths ---------------------------------------------------------------------------
    for line in (REPO / "Scripts" / "site-legacy-paths.txt").read_text().splitlines():
        rel = line.strip()
        if rel and not rel.startswith("#") and not (site / rel).is_file():
            fail(rel, "legacy path is missing from the staged site (FZ I1: these never move)")

    # --- parse every page -----------------------------------------------------------------------
    pages = {}
    for path in sorted(site.rglob("*.html")):
        page = Page()
        page.feed(path.read_text(encoding="utf-8"))
        pages[path.relative_to(site).as_posix()] = page

    def resolve(from_rel, url):
        """The staged file a same-site URL names, or None."""
        path = unquote(urlsplit(url).path)
        if not path:
            return site / from_rel
        target = (site / path.lstrip("/")) if path.startswith("/") else (site / from_rel).parent / path
        target = Path(*target.parts)  # leave .. to resolve() below
        target = target.resolve()
        if site != target and site not in target.parents:
            return None
        if target.is_dir():
            target = target / "index.html"
        return target if target.is_file() else None

    for rel, page in pages.items():
        # third-party loads
        for tag, value in page.resources:
            for url in (part.strip().split(" ")[0] for part in value.split(",")) if tag in ("img", "source") else (value,):
                if is_external(url):
                    fail(rel, f"<{tag}> loads from another site: {url}")
                elif not url.startswith(("data:", "mailto:")) and resolve(rel, url) is None:
                    fail(rel, f"<{tag}> names a file that is not staged: {url}")
        for css in page.inline_styles:
            for url in CSS_URL.findall(css) + CSS_IMPORT.findall(css):
                if is_external(url):
                    fail(rel, f"inline style loads from another site: {url}")

        # anchors
        for href in page.anchors:
            parts = urlsplit(href)
            if parts.scheme in ("mailto", "tel"):
                continue
            if is_external(href):
                host = (parts.hostname or "").lower()
                if rel not in OUTBOUND_EXEMPT and host not in OUTBOUND_HOSTS:
                    fail(rel, f"links to a host outside the allowlist: {href}")
                if host != "avenkin.com":
                    continue
                href = parts._replace(scheme="", netloc="").geturl() or "/"
                parts = urlsplit(href)
            elif parts.scheme:
                fail(rel, f"link with an unexpected scheme: {href}")
                continue

            if rel.startswith(APP_LINKED) or rel in APP_LINKED:
                target_path = "/" + unquote(parts.path).lstrip("/") if parts.path.startswith("/") else parts.path
                if any(target_path.startswith(p) or f"/{target_path}".startswith(p) for p in PURCHASE_PATHS):
                    fail(rel, f"a page the app links to must not link to a purchase path: {href}")

            target = resolve(rel, href)
            if target is None:
                fail(rel, f"broken link: {href}")
                continue
            target_rel = target.relative_to(site).as_posix()
            if parts.fragment:
                if target_rel == "index.html":
                    fail(rel, f"links to a fragment of the homepage, which it would hand to the app as a sign-in result: {href}")
                elif target_rel in pages and unquote(parts.fragment) not in pages[target_rel].ids:
                    fail(rel, f"fragment does not exist on {target_rel}: {href}")

        # script policy
        if page.csp is not None:
            allowed = set(re.findall(r"'sha256-([A-Za-z0-9+/=]+)'", page.csp))
            for script in page.inline_scripts:
                digest = base64.b64encode(hashlib.sha256(script.encode("utf-8")).digest()).decode()
                if digest not in allowed:
                    fail(rel, f"inline script is not allowed by the page's Content-Security-Policy; expected 'sha256-{digest}'")
            if page.inline_styles and "'unsafe-inline'" not in page.csp:
                fail(rel, "inline <style> would be blocked by the page's Content-Security-Policy")
        elif page.inline_scripts and rel == "index.html":
            fail(rel, "the homepage must carry a Content-Security-Policy that names its sign-in script")

    # --- stylesheets ----------------------------------------------------------------------------
    for path in sorted(site.rglob("*.css")):
        rel = path.relative_to(site).as_posix()
        css = path.read_text(encoding="utf-8")
        for url in sorted(set(CSS_URL.findall(css) + CSS_IMPORT.findall(css))):
            if is_external(url):
                fail(rel, f"stylesheet loads from another site: {url}")
            elif not url.startswith("data:") and resolve(rel, url) is None:
                fail(rel, f"stylesheet names a file that is not staged: {url}")

    # --- 404 and security.txt -------------------------------------------------------------------
    if not (site / "404.html").is_file():
        fail("404.html", "missing; the activation resolver relies on an HTML 404 for unknown keys")

    security = site / ".well-known" / "security.txt"
    if not security.is_file():
        fail(".well-known/security.txt", "missing")
    else:
        text = security.read_text()
        if not re.search(r"^Contact: \S+", text, re.M):
            fail(".well-known/security.txt", "has no Contact line")
        expires = re.search(r"^Expires: (\S+)", text, re.M)
        if not expires:
            fail(".well-known/security.txt", "has no Expires line")
        else:
            # A lapsed date makes the file invalid (RFC 9116) but must not stop the site, and with
            # it activation files, from publishing. So this warns and never fails.
            when = datetime.datetime.fromisoformat(expires.group(1).replace("Z", "+00:00"))
            left = (when - datetime.datetime.now(datetime.timezone.utc)).days
            if left < 60:
                print(f"check-pages-site: WARNING — site/.well-known/security.txt expires in {left} day(s); renew it.",
                      file=sys.stderr)

    # --- the vault guide page is the current Markdown ---------------------------------------------
    guide_page = site / "field-assist" / "vault-guide" / "index.html"
    guide_source = REPO / "docs" / "field-assist-vault-guide.md"
    if guide_page.is_file():
        recorded = re.search(r"source-sha256: ([0-9a-f]{64})", guide_page.read_text(encoding="utf-8"))
        current = hashlib.sha256(guide_source.read_bytes()).hexdigest()
        if not recorded or recorded.group(1) != current:
            fail("field-assist/vault-guide/index.html",
                 "is not the current docs/field-assist-vault-guide.md; run Scripts/build-vault-guide-page.py and commit the page")

    if failures:
        for line in failures:
            print(f"check-pages-site: {line}", file=sys.stderr)
        sys.exit(f"check-pages-site: FAIL — {len(failures)} problem(s) in the staged site.")
    print(f"check-pages-site: PASS — {len(pages)} page(s) checked.")


if __name__ == "__main__":
    main()
