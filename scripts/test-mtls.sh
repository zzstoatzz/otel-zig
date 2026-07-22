#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/otel-zig-mtls.XXXXXX")"
mtls_pid=""
ca_pid=""

cleanup() {
  if [[ -n "$mtls_pid" ]]; then
    kill "$mtls_pid" 2>/dev/null || true
    wait "$mtls_pid" 2>/dev/null || true
  fi
  if [[ -n "$ca_pid" ]]; then
    kill "$ca_pid" 2>/dev/null || true
    wait "$ca_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

read -r mtls_port ca_port < <(python3 - <<'PY'
import socket

ports = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    ports.append(sock.getsockname()[1])
    sock.close()
print(*ports)
PY
)

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$work/ca.key" -out "$work/ca.crt" -subj "/CN=otel-zig test CA" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$work/server.key" -out "$work/server.csr" -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$work/server.csr" \
  -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -copy_extensions copy -out "$work/server.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$work/client.key" -out "$work/client.csr" -subj "/CN=otel-zig client" \
  -addext "extendedKeyUsage=clientAuth" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$work/client.csr" \
  -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -copy_extensions copy -out "$work/client.crt" >/dev/null 2>&1

python3 "$root/src/test/mtls_server.py" \
  --port "$mtls_port" --cert "$work/server.crt" --key "$work/server.key" --ca "$work/ca.crt" &
mtls_pid=$!
python3 "$root/src/test/mtls_server.py" \
  --port "$ca_port" --cert "$work/server.crt" --key "$work/server.key" &
ca_pid=$!

ready=false
for _ in {1..50}; do
  if python3 - "$mtls_pid" "$ca_pid" "$mtls_port" "$ca_port" <<'PY'
import os
import socket
import sys

for port in map(int, sys.argv[3:]):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
            pass
    except OSError:
        raise SystemExit(1)
for pid in map(int, sys.argv[1:3]):
    os.kill(pid, 0)
PY
  then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  echo "TLS test servers did not become ready" >&2
  exit 1
fi

python3 - "$mtls_port" "$work/ca.crt" <<'PY'
import ssl
import sys
import urllib.request

context = ssl.create_default_context(cafile=sys.argv[2])
request = urllib.request.Request(
    f"https://localhost:{sys.argv[1]}", data=b"missing-client-certificate", method="POST"
)
try:
    urllib.request.urlopen(request, context=context, timeout=1)
except (OSError, ssl.SSLError):
    pass
else:
    raise SystemExit("mTLS test server accepted a client without a certificate")
PY

OTEL_ZIG_MTLS_TEST_ENDPOINT="https://localhost:$mtls_port" \
OTEL_ZIG_MTLS_TEST_CA="$work/ca.crt" \
OTEL_ZIG_MTLS_TEST_CERT="$work/client.crt" \
OTEL_ZIG_MTLS_TEST_KEY="$work/client.key" \
OTEL_ZIG_CA_TEST_ENDPOINT="https://localhost:$ca_port" \
OTEL_ZIG_CA_TEST_CA="$work/ca.crt" \
  zig build test
