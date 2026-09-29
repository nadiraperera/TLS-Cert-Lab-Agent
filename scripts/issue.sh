#!/usr/bin/env bash
# fetch-secret -> certbot certonly (DNS-01 via the configured plugin) ->
# deploy-hook installs the cert into nginx -> shred the credentials INI,
# even if certbot fails partway through.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"
load_env

INI_PATH="${ROOT_DIR}/.secrets/dns-credentials.ini"

cleanup() {
    if [[ -f "$INI_PATH" ]]; then
        if command -v shred >/dev/null 2>&1; then
            shred -u "$INI_PATH"
        else
            rm -f "$INI_PATH"
        fi
    fi
}
trap cleanup EXIT

"$SCRIPT_DIR/fetch-secret.sh"

case "$DNS_PLUGIN" in
    rfc2136)
        plugin_args=(--dns-rfc2136
                     --dns-rfc2136-credentials "$INI_PATH"
                     --dns-rfc2136-propagation-seconds 5)
        ;;
    cloudflare)
        plugin_args=(--dns-cloudflare
                     --dns-cloudflare-credentials "$INI_PATH"
                     --dns-cloudflare-propagation-seconds 30)
        ;;
    *)
        die "Unknown DNS_PLUGIN: $DNS_PLUGIN"
        ;;
esac

domain_args=()
IFS=',' read -ra domains <<< "$DOMAINS"
for d in "${domains[@]}"; do
    domain_args+=(-d "$d")
done

log "Requesting certificate for: ${domains[*]} via $ACME_SERVER"
export REQUESTS_CA_BUNDLE="${ROOT_DIR}/pebble/pebble.minica.pem"

set +e
output="$("$ROOT_DIR/.venv/bin/certbot" certonly \
    --config-dir "$ROOT_DIR/certbot/config" \
    --work-dir "$ROOT_DIR/certbot/work" \
    --logs-dir "$ROOT_DIR/certbot/logs" \
    --server "$ACME_SERVER" \
    "${plugin_args[@]}" \
    "${domain_args[@]}" \
    --non-interactive --agree-tos -m "$ACME_EMAIL" \
    --deploy-hook "$SCRIPT_DIR/deploy-hook.sh" 2>&1)"
status=$?
set -e
echo "$output"

if (( status != 0 )); then
    if grep -qi "accountDoesNotExist\|account does not exist" <<<"$output"; then
        err "Pebble does not recognize this certbot account (Pebble resets its state on every restart)."
        err "Fix: rm -rf certbot/config/{accounts,live,renewal,archive}/*  then re-run this script."
        err "(Clearing accounts/ alone is not enough: the renewal config pins a specific account ID"
        err " that only gets refreshed on an actual re-issuance, not a skipped 'not due yet' run.)"
    fi
    exit "$status"
fi

log "Certificate issued successfully."
