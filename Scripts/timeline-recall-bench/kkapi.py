"""Minimal OpenAI client for the KK P0 benchmark. The key is read here and nowhere else; it never
reaches a log, a file or stdout. Error bodies are redacted before they are returned."""
import json, os, re, time, random, threading, urllib.request, urllib.error

BASE = os.path.dirname(os.path.abspath(__file__))
# A path to a file holding the key, set by whoever runs the benchmark. Never a file in this folder.
_KEY_PATH = os.environ.get("OPENAI_KEY_FILE", "")
_key_cache = None
_lock = threading.Lock()


def _key():
    global _key_cache
    with _lock:
        if _key_cache is None:
            if not _KEY_PATH:
                raise SystemExit("Set OPENAI_KEY_FILE to a file outside the repo that holds the key.")
            with open(_KEY_PATH, "r") as f:
                _key_cache = f.read().strip()
    return _key_cache


def _redact(text):
    return re.sub(r"sk-[A-Za-z0-9_\-]{4,}", "sk-REDACTED", text or "")


class APIError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {_redact(body)[:600]}")
        self.status = status
        self.body = _redact(body)


def post(path, body, max_attempts=8, timeout=180):
    url = "https://api.openai.com/v1" + path
    data = json.dumps(body).encode()
    attempt = 0
    while True:
        attempt += 1
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", "Bearer " + _key())
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = json.loads(resp.read().decode())
                return payload, time.time() - t0
        except urllib.error.HTTPError as e:
            status = e.code
            try:
                text = e.read().decode()
            except Exception:
                text = ""
            if (status == 429 or status >= 500) and attempt < max_attempts:
                time.sleep(min(60, 2 ** attempt + random.random() * 2))
                continue
            raise APIError(status, text)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt < max_attempts:
                time.sleep(min(60, 2 ** attempt + random.random() * 2))
                continue
            raise APIError(-1, _redact(str(e)))
