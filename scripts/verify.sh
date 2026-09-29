#!/usr/bin/env bash
# Fetches Pebble's current issuing root (regenerated on every Pebble restart,
# so we always re-fetch rather than reusing a stale copy), uses it to make a
# real trust-validated HTTPS request against nginx, and prints the served
# cert's details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"
load_env

ROOT_CA="$(mktemp)"
trap 'rm -f "$ROOT_CA"' EXIT

log "Fetching Pebble's issuing root from https://localhost:15000/roots/0"
curl -skf https://localhost:15000/roots/0 -o "$ROOT_CA" \
    || die "Could not fetch Pebble's issuing root. Is the stack up? (make setup)"

log "Requesting https://${ZONE}:8443/ (--resolve, trusting only Pebble's issuing root)"
if ! curl -sS --cacert "$ROOT_CA" --resolve "${ZONE}:8443:127.0.0.1" "https://${ZONE}:8443/"; then
    die "HTTPS request failed trust validation against Pebble's issuing root."
fi
echo

log "Certificate details (openssl s_client):"
echo | openssl s_client -connect 127.0.0.1:8443 -servername "${ZONE}" -CAfile "$ROOT_CA" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -serial -dates -ext subjectAltName
