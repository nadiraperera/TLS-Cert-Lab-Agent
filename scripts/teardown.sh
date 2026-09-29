#!/usr/bin/env bash
# Stops the lab. With --purge, also wipes all generated local state (venv,
# secrets, certbot state, TSIG key, zone file, certs) so the next setup.sh
# starts from a truly clean slate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"

purge=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

log "docker compose down"
docker compose down

if (( purge )); then
    log "Purging generated state (.venv, .secrets, certbot/, bind keys/zones, certs, pebble CA)"
    rm -rf .venv .secrets certbot bind/keys/* bind/zones/* nginx/certs/*.pem pebble/pebble.minica.pem
    mkdir -p .secrets
    chmod 700 .secrets
    touch bind/keys/.gitkeep bind/zones/.gitkeep .secrets/.gitkeep
    log "Purge complete."
fi
