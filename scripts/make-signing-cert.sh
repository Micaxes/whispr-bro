#!/usr/bin/env bash
# make-signing-cert.sh — one-time: create and import a self-signed
# "whispr-bro dev" code-signing certificate into the login keychain.
#
# WHY: TCC (Accessibility / Input Monitoring / Microphone) keys grants to the
# app's code-signing identity. Ad-hoc signatures change every build, so every
# rebuild orphaned the grants (toggle shows ON but the new binary is denied).
# A stable self-signed cert makes grants survive rebuilds.
#
# The first codesign with the new key may pop ONE keychain dialog —
# click "Always Allow".

set -euo pipefail

NAME="whispr-bro dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists — nothing to do"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE"

# -legacy: OpenSSL 3.x defaults to PBES2/AES p12s that the macOS Security
# framework rejects ("MAC verification failed"); the legacy encoding imports
# cleanly. (LibreSSL /usr/bin/openssl lacks -legacy but emits the old
# encoding by default.)
if openssl pkcs12 -export -legacy -out "$TMP/identity.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:whisprbro -name "$NAME" 2>/dev/null; then
  :
else
  openssl pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:whisprbro -name "$NAME"
fi

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P whisprbro \
  -T /usr/bin/codesign

echo "imported. identities now:"
security find-identity -v -p codesigning
