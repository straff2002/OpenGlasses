#!/usr/bin/env python3
"""The reference tokenizer as a line server, for the Mac retrieval runner (Plan KQ P1).

Usage: python tokenize_server.py <model-dir>

Reads one JSON string per line on stdin and writes one JSON list of token ids per line on stdout
(special tokens included, as the model expects). The runner can't link `swift-transformers` (it is
a plain `swiftc` build), and P0 measured the two tokenizers identical on every test text.
"""

import json
import sys

from transformers import AutoTokenizer


def main():
    tokenizer = AutoTokenizer.from_pretrained(sys.argv[1])
    out = sys.stdout
    for line in sys.stdin:
        text = json.loads(line)
        out.write(json.dumps(tokenizer(text, add_special_tokens=True)["input_ids"]) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
