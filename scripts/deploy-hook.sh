#!/usr/bin/env bash
# Certbot --deploy-hook: installs the just-issued/renewed cert into nginx's
# cert directory atomically, validates the new config, and only reloads if
# validation passes. On failure, rolls the on-disk files back to whatever
# nginx is actually still serving (it never got reloaded, so it's still
# running on the old cert either way -- this just keeps disk and reality in
# sync for the next attempt). Certbot sets $RENEWED_LINEAGE for us.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"
load_env

[[ -n "${RENEWED_LINEAGE:-}" ]] || die "RENEWED_LINEAGE not set -- this script must be run by certbot as a --deploy-hook"

dest_dir="$CERT_DEST_DIR"
fullchain_dest="$dest_dir/fullchain.pem"
privkey_dest="$dest_dir/privkey.pem"

log "Deploying cert from $RENEWED_LINEAGE to $dest_dir"

# 1. Back up whatever is currently deployed, so we can roll back on failure.
[[ -f "$fullchain_dest" ]] && cp -p "$fullchain_dest" "$fullchain_dest.bak"
[[ -f "$privkey_dest" ]] && cp -p "$privkey_dest" "$privkey_dest.bak"

rollback() {
    err "Rolling back to previously deployed cert."
    [[ -f "$fullchain_dest.bak" ]] && mv "$fullchain_dest.bak" "$fullchain_dest"
    [[ -f "$privkey_dest.bak" ]] && mv "$privkey_dest.bak" "$privkey_dest"
}

# 2. Write new certs to temp files, then atomically rename into place.
install -m 644 "$RENEWED_LINEAGE/fullchain.pem" "$fullchain_dest.tmp"
install -m 600 "$RENEWED_LINEAGE/privkey.pem" "$privkey_dest.tmp"
mv -f "$fullchain_dest.tmp" "$fullchain_dest"
mv -f "$privkey_dest.tmp" "$privkey_dest"

# 3. Validate before touching the running server.
log "Testing nginx config: $NGINX_TEST_CMD"
if ! eval "$NGINX_TEST_CMD"; then
    rollback
    die "nginx -t failed against the new cert -- rolled back, NOT reloading."
fi

# 4. Only now, reload (graceful, zero-downtime).
log "Reloading nginx: $NGINX_RELOAD_CMD"
if ! eval "$NGINX_RELOAD_CMD"; then
    rollback
    die "nginx reload failed -- rolled back."
fi

rm -f "$fullchain_dest.bak" "$privkey_dest.bak"
log "Deploy successful."
