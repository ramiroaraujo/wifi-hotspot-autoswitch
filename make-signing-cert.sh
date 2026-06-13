#!/bin/bash
# Create a stable self-signed code-signing identity in the login keychain.
#
# Why: ad-hoc signing (codesign -s -) ties the Location Services grant to the
# binary's cdhash, so every rebuild revokes it. A stable identity makes the
# code-signing Designated Requirement identifier+cert based, so the Location
# grant survives rebuilds/updates. One-time: the first build after this will
# show a single "codesign wants to use a key" dialog — click "Always Allow".
set -euo pipefail

CERT_NAME="WifiAutoswitch Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
  echo "Signing identity already present: $CERT_NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = WifiAutoswitch Self-Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# macOS `security` cannot import OpenSSL-3 default PKCS12 (MAC verification
# fails). Use a password and the -legacy algorithms; fall back for LibreSSL.
PW="wifiautoswitch"
openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$PW" >/dev/null 2>&1 \
|| openssl pkcs12 -export -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$PW" >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign
echo "Imported '$CERT_NAME' into the login keychain."
