#!/usr/bin/env bash
# Generates throwaway TLS material for the live TLS integration suites (tags
# :integration_grpc_tls and :integration_bolt_tls). Output: OUT dir (default
# /tmp/arcadic-grpc-tls):
#   ca.{key,crt}        the trusted CA (pass ca.crt as the *_CACERT env)
#   server.{key,crt}    the server cert (SANs: localhost, 127.0.0.1, ::1) + chain
#   untrusted.{key,crt} a SECOND CA — must NOT be trusted by the client (fail-closed probe)
#   server.p12          PKCS12 keystore for the ArcadeDB server (gRPC needs the PEM pair;
#                       Bolt TLS wants arcadedb.ssl.keyStore/Password in PKCS12)
#   truststore.jks      JKS truststore with the CA (Bolt TLS also demands
#                       arcadedb.ssl.trustStore/Password — keytool required on PATH)
# Nothing here is a production credential; regenerate freely.
set -euo pipefail

OUT="${1:-/tmp/arcadic-grpc-tls}"
mkdir -p "$OUT"

# Trusted CA.
openssl genrsa -out "$OUT/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "$OUT/ca.key" -sha256 -days 2 \
  -subj "/CN=arcadic-grpc-test-ca" -out "$OUT/ca.crt"

# Server cert signed by the trusted CA, with the localhost SANs mint verifies.
openssl genrsa -out "$OUT/server.key" 2048 2>/dev/null
openssl req -new -key "$OUT/server.key" \
  -subj "/CN=localhost" -out "$OUT/server.csr"
cat > "$OUT/san.ext" <<'EOF'
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in "$OUT/server.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" \
  -CAcreateserial -days 2 -sha256 -extfile "$OUT/san.ext" -out "$OUT/server.crt" 2>/dev/null

# Keys stay in openssl 3's default PKCS#8 ("BEGIN PRIVATE KEY") — the gRPC plugin's JDK
# key factory rejects traditional PKCS#1 with "Neither RSA, DSA nor EC worked" (probed on
# CI 2026-08-23). The only server-side requirement is readability (see chmod below).

# Untrusted second CA (self-signed, disjoint).
openssl genrsa -out "$OUT/untrusted.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "$OUT/untrusted.key" -sha256 -days 2 \
  -subj "/CN=arcadic-grpc-UNTRUSTED-ca" -out "$OUT/untrusted.crt"

# Server keystore (PKCS12) + CA truststore (JKS) for the ArcadeDB server side —
# Bolt TLS requires BOTH (arcadedb.ssl.keyStore/keyStorePassword/trustStore/trustStorePassword).
KPW="${KEYSTORE_PASS:-arcadic-tls-test}"
openssl pkcs12 -export -out "$OUT/server.p12" -inkey "$OUT/server.key" -in "$OUT/server.crt" \
  -certfile "$OUT/ca.crt" -name localhost -passout pass:"$KPW"
rm -f "$OUT/truststore.jks"
keytool -importcert -alias ca -file "$OUT/ca.crt" -keystore "$OUT/truststore.jks" \
  -storepass "$KPW" -noprompt >/dev/null

# Only the artifacts the CONTAINER reads need relaxing — the ArcadeDB JVM runs as a
# non-root user, and root-owned 0600 files mounted read-only are unreadable in-container
# (server key: netty "could not find key file"; keystore: "Could not load resource").
# The CA private keys stay 0600 (nothing in-container reads them). Docker Desktop on
# macOS relaxes mount permissions, which masks this locally. Throwaway test material.
chmod 644 "$OUT"/server.key "$OUT"/server.p12 "$OUT"/truststore.jks

echo "TLS material in $OUT:" && ls -l "$OUT"
