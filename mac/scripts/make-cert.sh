#!/bin/sh
# Creates a self-signed code signing identity in a dedicated keychain.
#
# Why a stable identity: macOS ties the Microphone grant to the code signature. Ad-hoc signatures
# change on every build, so the grant would be asked for again after each rebuild.
#
# Why a dedicated keychain: a key in the login keychain makes codesign ask for the login password on
# every build. This keychain has a fixed password (not a secret: it only holds this local dev cert),
# so make-app.sh unlocks it and codesign never prompts.
set -eu
NAME="${1:-stt-thing-dev}"
KC="$HOME/Library/Keychains/stt-thing.keychain-db"
PASS="stt-thing"

if [ ! -f "$KC" ]; then
  security create-keychain -p "$PASS" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock timeout
fi
security unlock-keychain -p "$PASS" "$KC"
# codesign only finds identities in keychains on the user search list; append ours, keep the rest.
if ! security list-keychains -d user | grep -q "stt-thing.keychain-db"; then
  eval "security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') \"$KC\""
fi

if security find-identity -p codesigning "$KC" | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists in $KC"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:stt-thing 2>/dev/null
security import "$TMP/id.p12" -k "$KC" -P stt-thing -T /usr/bin/codesign
# Lets codesign use the key without a confirmation dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
echo "created identity '$NAME' in $KC"
