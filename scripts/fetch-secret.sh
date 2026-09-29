#!/usr/bin/env bash
# AppRole-logs into OpenBao, reads the DNS provider credential, and renders it
# as a certbot credentials INI at a FIXED path. Certbot bakes this path into
# its renewal config, so it must be the same path every time (issue.sh and
# renew.sh both use this script, then delete the file when done).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"
load_env

INI_PATH="${ROOT_DIR}/.secrets/dns-credentials.ini"
ROLE_ID_FILE="${ROOT_DIR}/.secrets/role_id"
SECRET_ID_FILE="${ROOT_DIR}/.secrets/secret_id"

[[ -f "$ROLE_ID_FILE" && -f "$SECRET_ID_FILE" ]] \
    || die "AppRole credentials not found in .secrets/. Run 'make seed' first."

# --- AppRole login -------------------------------------------------------------
login_resp="$(curl -sf -X POST \
    -d "{\"role_id\":\"$(cat "$ROLE_ID_FILE")\",\"secret_id\":\"$(cat "$SECRET_ID_FILE")\"}" \
    "${OPENBAO_ADDR}/v1/auth/approle/login")" || {
    err "AppRole login request failed (bad role_id/secret_id, or OpenBao at ${OPENBAO_ADDR} is unreachable)."
    die "OpenBao was restarted, run 'make seed'"
}

client_token="$(jq -r '.auth.client_token // empty' <<<"$login_resp")"
if [[ -z "$client_token" ]]; then
    err "AppRole login did not return a token: $login_resp"
    die "OpenBao was restarted, run 'make seed'"
fi

# --- Read the secret -------------------------------------------------------------
secret_resp="$(curl -sf -H "X-Vault-Token: ${client_token}" "${OPENBAO_ADDR}/v1/${SECRET_PATH%%/*}/data/${SECRET_PATH#*/}")" \
    || die "Failed to read secret at ${SECRET_PATH} (policy/path mismatch?)."
data="$(jq -r '.data.data' <<<"$secret_resp")"
[[ "$data" != "null" ]] || die "No data found at ${SECRET_PATH}."

# --- Render the credentials INI, shaped by DNS_PLUGIN ---------------------------
case "$DNS_PLUGIN" in
    rfc2136)
        key_name="$(jq -r '.key_name' <<<"$data")"
        algorithm="$(jq -r '.algorithm' <<<"$data")"
        secret="$(jq -r '.secret' <<<"$data")"
        cat > "$INI_PATH" <<EOF
dns_rfc2136_server = ${DNS_RFC2136_SERVER}
dns_rfc2136_port = ${DNS_RFC2136_PORT}
dns_rfc2136_name = ${key_name}
dns_rfc2136_secret = ${secret}
dns_rfc2136_algorithm = ${algorithm}
EOF
        ;;
    cloudflare)
        api_token="$(jq -r '.api_token' <<<"$data")"
        cat > "$INI_PATH" <<EOF
dns_cloudflare_api_token = ${api_token}
EOF
        ;;
    *)
        die "Unknown DNS_PLUGIN: $DNS_PLUGIN (expected rfc2136 or cloudflare)"
        ;;
esac

chmod 600 "$INI_PATH"
log "Credentials rendered to ${INI_PATH} (DNS_PLUGIN=${DNS_PLUGIN})"
