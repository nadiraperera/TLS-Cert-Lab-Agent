#!/usr/bin/env bash
# Brings the lab up from a clean checkout: checks prerequisites, generates
# local secrets/config the compose stack needs, starts containers, and waits
# for each of them to become healthy. Safe to re-run (idempotent) after a
# partial failure or a `teardown.sh` without `--purge`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"

# --- 1. Prerequisites -------------------------------------------------------
log "Checking prerequisites..."
missing=()
for cmd in docker curl jq openssl python3; do
    require_cmd "$cmd" >/dev/null || missing+=("$cmd")
done
if ! python3 -c "import venv" >/dev/null 2>&1; then
    missing+=("python3-venv (python3's venv module)")
fi
if ! docker compose version >/dev/null 2>&1; then
    missing+=("docker compose (v2 plugin)")
fi
if (( ${#missing[@]} > 0 )); then
    err "Missing prerequisites:"
    for m in "${missing[@]}"; do echo "  - $m" >&2; done
    die "Install these yourself (no sudo run on your behalf) and re-run setup.sh."
fi
log "All prerequisites present."

# --- 2. .env -----------------------------------------------------------------
if [[ ! -f .env ]]; then
    log "Creating .env from .env.example"
    cp .env.example .env
fi
# Always refresh HOST_UID/GID: .env is gitignored and machine-specific, and a
# stale value here is the #1 cause of BIND failing to read/write its mounts.
sed -i.bak "s/^HOST_UID=.*/HOST_UID=$(id -u)/" .env
sed -i.bak "s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env
rm -f .env.bak
load_env
log "HOST_UID=${HOST_UID} HOST_GID=${HOST_GID}"

# --- 3. Python venv for certbot ---------------------------------------------
if [[ ! -x .venv/bin/python ]]; then
    log "Creating venv at ./.venv"
    python3 -m venv .venv
fi
log "Installing/upgrading certbot + certbot-dns-rfc2136 in venv"
./.venv/bin/pip install -q --upgrade pip
./.venv/bin/pip install -q certbot certbot-dns-rfc2136

# --- 4. Pebble's test CA -----------------------------------------------------
mkdir -p pebble
if [[ ! -f pebble/pebble.minica.pem ]]; then
    log "Downloading Pebble's test root CA (pebble.minica.pem)"
    curl -sf -o pebble/pebble.minica.pem \
        https://raw.githubusercontent.com/letsencrypt/pebble/main/test/certs/pebble.minica.pem
fi

# --- 5. TSIG key --------------------------------------------------------------
if [[ ! -s bind/keys/certbot-key.key ]]; then
    log "Generating TSIG key 'certbot-key' (HMAC-SHA512) via tsig-keygen"
    docker run --rm --entrypoint tsig-keygen internetsystemsconsortium/bind9:9.18 \
        -a hmac-sha512 certbot-key > bind/keys/certbot-key.key
else
    log "TSIG key already exists, leaving it in place"
fi

# --- 6. Zone file from template ----------------------------------------------
if [[ ! -s bind/zones/db.lab.test ]]; then
    log "Seeding bind/zones/db.lab.test from template"
    sed -e "s/__BIND9_IP__/${BIND9_IP}/" -e "s/__NGINX_IP__/${NGINX_IP}/" \
        bind/config/db.lab.test.tmpl > bind/zones/db.lab.test
else
    log "Zone file already exists, leaving it in place"
fi

# --- 7. Placeholder cert so Nginx has something to load at startup ----------
if [[ ! -f nginx/certs/fullchain.pem || ! -f nginx/certs/privkey.pem ]]; then
    log "Generating self-signed placeholder cert for nginx"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=lab.test" \
        -addext "subjectAltName=DNS:lab.test,DNS:*.lab.test" \
        -keyout nginx/certs/privkey.pem \
        -out nginx/certs/fullchain.pem >/dev/null 2>&1
    chmod 644 nginx/certs/fullchain.pem
    chmod 600 nginx/certs/privkey.pem
else
    log "nginx/certs already has a cert, leaving it in place"
fi

# --- 8. Bring the stack up ----------------------------------------------------
log "docker compose up -d"
docker compose up -d

# --- 9. Wait for health -------------------------------------------------------
wait_healthy() {
    local name="$1" max_seconds="$2" waited=0
    until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" == "healthy" ]]; do
        waited=$((waited + 2))
        if (( waited >= max_seconds )); then
            err "$name did not become healthy within ${max_seconds}s"
            docker logs --tail 30 "$name" >&2 || true
            return 1
        fi
        sleep 2
    done
    log "$name is healthy"
}

wait_healthy labwf-openbao 60
wait_healthy labwf-bind9 60
wait_healthy labwf-nginx 60

log "Waiting for Pebble's management API (no built-in healthcheck; image has no shell)"
if wait_for_http "https://127.0.0.1:15000/roots/0" 60; then
    log "labwf-pebble is responding"
else
    err "Pebble did not respond within 60s"
    docker logs --tail 30 labwf-pebble >&2 || true
    exit 1
fi

log "All containers up and healthy."
log "Next: verify DNS with 'dig @127.0.0.1 -p 5353 lab.test SOA', then 'make seed'."
