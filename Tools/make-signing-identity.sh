#!/bin/bash
# One-time: creates a stable local code-signing identity ("WindowPet Dev")
# in your login keychain so TCC permissions (Accessibility, Microphone,
# Speech) survive rebuilds. Ad-hoc signatures change every build, which
# makes macOS silently drop your grants. Run me once:
#   bash Tools/make-signing-identity.sh
# then rebuild (Tools/make-app.sh) and re-grant permissions ONE last time.
set -euo pipefail
if security find-identity -v -p codesigning | grep -q "WindowPet Dev"; then
  echo "WindowPet Dev identity already exists — nothing to do."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=WindowPet Dev" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/wp.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -password pass:windowpet 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/wp.p12" -inkey "$TMP/key.pem" \
       -in "$TMP/cert.pem" -password pass:windowpet
security import "$TMP/wp.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P windowpet -A
security find-identity -v -p codesigning | grep "WindowPet Dev" && echo "Done — rebuild with Tools/make-app.sh."
