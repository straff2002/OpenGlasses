#!/usr/bin/env bash
#
# Prove the signing tools take a key from a file and refuse one from the command line (W06.4).
#
# Not an XCTest: these are standalone `swift` scripts with no target, and the property under test
# is about argv and process behaviour, which a unit test in the app bundle cannot reach.
#
#   ./Scripts/tests/signing-key-handling.sh
#
# Every key here is minted on the spot into a temp directory and destroyed on exit. The negative
# cases deliberately put that throwaway key into a subprocess's argv — which is the thing being
# refused — so each of them also asserts that no output contains it. A test for "the key must not
# leak" that leaks the key would be worse than no test.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

ok()   { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# Assert a command failed AND that neither stream contains the key. `$key` is never printed by
# this function, only searched for.
refuses_inline_key() { # label key output_file exit_code
  local label="$1" key="$2" out="$3" code="$4"
  if [ "$code" = "0" ]; then
    bad "$label: exited 0 — the inline key was accepted"
    return
  fi
  if grep -qF -- "$key" "$out"; then
    bad "$label: the key appeared in the output"
    return
  fi
  if ! grep -q "passed on the command line" "$out"; then
    bad "$label: refused, but without saying why (no guidance in the message)"
    return
  fi
  ok "$label"
}

echo "Minting throwaway keys in $work"

# --- keygen writes a 0600 file and prints only the public half --------------------------------

swift "$repo_root/Scripts/skillpack-sign.swift" keygen "$work/pack-key.txt" > "$work/keygen.out" 2>&1
mode="$(stat -f '%OLp' "$work/pack-key.txt" 2>/dev/null || stat -c '%a' "$work/pack-key.txt")"
[ "$mode" = "600" ] && ok "keygen writes the key file with mode 0600" \
                    || bad "keygen wrote mode $mode, expected 600"

pack_key="$(grep -v '^#' "$work/pack-key.txt" | grep -v '^$' | tail -n 1)"
if grep -qF -- "$pack_key" "$work/keygen.out"; then
  bad "keygen printed the private key"
else
  ok "keygen prints the public half only"
fi

if ! swift "$repo_root/Scripts/skillpack-sign.swift" keygen "$work/pack-key.txt" >/dev/null 2>&1; then
  ok "keygen refuses to overwrite an existing key"
else
  bad "keygen overwrote an existing key file"
fi

# --- a pack to sign ---------------------------------------------------------------------------

mkdir -p "$work/pack"
printf '{"id":"fixture","name":"Fixture","version":"1"}\n' > "$work/pack/skillpack.json"
printf 'payload\n' > "$work/pack/notes.txt"
printf '{"packs":[]}\n' > "$work/index.json"

# --- skillpack-sign ---------------------------------------------------------------------------

signature="$(swift "$repo_root/Scripts/skillpack-sign.swift" sign-pack "$work/pack" \
  --key-file "$work/pack-key.txt" 2>/dev/null)"
if printf '%s' "$signature" | grep -Eq '^[A-Za-z0-9+/]{80,}={0,2}$'; then
  ok "skillpack-sign sign-pack --key-file <path> produces a signature"
else
  bad "skillpack-sign sign-pack --key-file <path> produced no usable signature"
fi

# Signatures are NOT compared byte for byte: CryptoKit's Curve25519 signing is randomized, so
# the same key over the same message produces a different signature every time. What matters is
# that the signature verifies against the public half of the key that was fed in — which is what
# the app does, and what the envelope check below actually tests.
stdin_signature="$(swift "$repo_root/Scripts/skillpack-sign.swift" sign-pack "$work/pack" \
  --key-file - < "$work/pack-key.txt" 2>/dev/null)"
if printf '%s' "$stdin_signature" | grep -Eq '^[A-Za-z0-9+/]{80,}={0,2}$'; then
  ok "skillpack-sign --key-file - reads the key from stdin"
else
  bad "skillpack-sign --key-file - produced no usable signature"
fi

set +e
swift "$repo_root/Scripts/skillpack-sign.swift" sign-pack "$work/pack" "$pack_key" \
  > "$work/inline1.out" 2>&1
refuses_inline_key "skillpack-sign refuses a key as a positional argument" \
  "$pack_key" "$work/inline1.out" "$?"

swift "$repo_root/Scripts/skillpack-sign.swift" sign-pack "$work/pack" --key-file "$pack_key" \
  > "$work/inline2.out" 2>&1
refuses_inline_key "skillpack-sign refuses a key behind --key-file" \
  "$pack_key" "$work/inline2.out" "$?"
set -e

catalog="$(swift "$repo_root/Scripts/skillpack-sign.swift" sign-catalog "$work/index.json" \
  --key-file "$work/pack-key.txt" 2>/dev/null)"
printf '%s' "$catalog" | grep -q '"signature"' \
  && ok "skillpack-sign sign-catalog --key-file <path> produces an envelope" \
  || bad "skillpack-sign sign-catalog produced no envelope"

# The real proof that a stdin-supplied key is the SAME key: sign the catalog with it and verify
# the envelope against the public half that keygen printed. The catalog envelope is used here
# rather than the pack signature because its message is simply the index bytes — no need to
# re-implement the pack's message construction inside the test and get it subtly wrong.
cat > "$work/verify-envelope.swift" <<'SWIFT'
import Foundation
import CryptoKit

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let publicKeyData = Data(base64Encoded: arguments[1]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
      let envelopeData = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
      let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: String],
      let payload = envelope["payload"].flatMap({ Data(base64Encoded: $0) }),
      let signature = envelope["signature"].flatMap({ Data(base64Encoded: $0) }) else {
    print("unverified"); exit(1)
}
print(publicKey.isValidSignature(signature, for: payload) ? "verified" : "unverified")
SWIFT

public_key="$(sed -n 's/^public  (embed in app):  //p' "$work/keygen.out")"
printf '%s' "$catalog" > "$work/catalog-path.json"
swift "$repo_root/Scripts/skillpack-sign.swift" sign-catalog "$work/index.json" \
  --key-file - < "$work/pack-key.txt" > "$work/catalog-stdin.json" 2>/dev/null

for source in path stdin; do
  result="$(swift "$work/verify-envelope.swift" "$public_key" "$work/catalog-$source.json" 2>/dev/null)"
  [ "$result" = "verified" ] \
    && ok "a catalog signed with the key from $source verifies against the public half" \
    || bad "a catalog signed with the key from $source did not verify"
done

# --- vaultpack-sign ---------------------------------------------------------------------------

mkdir -p "$work/vault"
printf '{"id":"fixture"}\n' > "$work/vault/pack.json"
printf '{"documents":[]}\n' > "$work/vault/manifest.json"

vault_signature="$(swift "$repo_root/Scripts/vaultpack-sign.swift" sign-pack "$work/vault" \
  --key-file "$work/pack-key.txt" 2>/dev/null)"
if printf '%s' "$vault_signature" | grep -Eq '^[A-Za-z0-9+/]{80,}={0,2}$'; then
  ok "vaultpack-sign sign-pack --key-file <path> produces a signature"
else
  bad "vaultpack-sign sign-pack --key-file <path> produced no usable signature"
fi

set +e
swift "$repo_root/Scripts/vaultpack-sign.swift" sign-pack "$work/vault" "$pack_key" \
  > "$work/inline3.out" 2>&1
refuses_inline_key "vaultpack-sign refuses a key as a positional argument" \
  "$pack_key" "$work/inline3.out" "$?"
set -e

# --- generate-field-license -------------------------------------------------------------------

swift "$repo_root/Scripts/generate-field-license.swift" keygen "$work/licence-key.txt" >/dev/null 2>&1
licence_key="$(grep -v '^#' "$work/licence-key.txt" | grep -v '^$' | tail -n 1)"

code="$(swift "$repo_root/Scripts/generate-field-license.swift" "Fixture Ltd" \
  --key-file "$work/licence-key.txt" 2>/dev/null)"
if printf '%s' "$code" | grep -Eq '^[A-Za-z0-9+/=]+\.[A-Za-z0-9+/=]+$'; then
  ok "generate-field-license --key-file <path> mints a code"
else
  bad "generate-field-license --key-file <path> minted nothing usable"
fi

stdin_code="$(swift "$repo_root/Scripts/generate-field-license.swift" "Fixture Ltd" \
  --key-file - < "$work/licence-key.txt" 2>/dev/null)"
if printf '%s' "$stdin_code" | grep -Eq '^[A-Za-z0-9+/=]+\.[A-Za-z0-9+/=]+$'; then
  ok "generate-field-license --key-file - reads the key from stdin"
else
  bad "generate-field-license --key-file - minted nothing usable"
fi

set +e
swift "$repo_root/Scripts/generate-field-license.swift" "Fixture Ltd" --key-file "$licence_key" \
  > "$work/inline4.out" 2>&1
refuses_inline_key "generate-field-license refuses a key behind --key-file" \
  "$licence_key" "$work/inline4.out" "$?"

# A key as the licensee name is the quiet failure worth catching: without the guard it does not
# error, it mints a licence issued to the key.
swift "$repo_root/Scripts/generate-field-license.swift" "$licence_key" \
  > "$work/inline5.out" 2>&1
refuses_inline_key "generate-field-license refuses a key in a positional argument" \
  "$licence_key" "$work/inline5.out" "$?"
set -e

# --- a permissive key file is warned about, not silently used ---------------------------------

cp "$work/pack-key.txt" "$work/loose-key.txt"
chmod 644 "$work/loose-key.txt"
swift "$repo_root/Scripts/skillpack-sign.swift" sign-pack "$work/pack" \
  --key-file "$work/loose-key.txt" > "$work/loose.out" 2>&1
if grep -q "readable beyond its owner" "$work/loose.out"; then
  ok "a world-readable key file is warned about"
else
  bad "a world-readable key file was used without a word"
fi

# --- result -----------------------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
