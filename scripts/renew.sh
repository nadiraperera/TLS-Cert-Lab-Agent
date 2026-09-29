#!/usr/bin/env bash
# fetch-secret -> certbot renew (uses the renewal config saved by issue.sh,
# including the deploy-hook) -> delete the credentials INI, even on failure.
# --force passes --force-renewal through, for exercising the full renew +
# deploy-hook + reload path without waiting for the real expiry window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"
load_env

INI_PATH="${ROOT_DIR}/.secrets/dns-credentials.ini"

force_args=()
for arg in "$@"; do
    case "$arg" in
        --force) force_args+=(--force-renewal) ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

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

export REQUESTS_CA_BUNDLE="${ROOT_DIR}/pebble/pebble.minica.pem"

set +e
# --no-random-sleep-on-renew: certbot renew normally sleeps a random 0-300s
# in non-interactive mode to spread load on a real CA. We want this script
# deterministic and fast for a local lab.
output="$("$ROOT_DIR/.venv/bin/certbot" renew \
    --config-dir "$ROOT_DIR/certbot/config" \
    --work-dir "$ROOT_DIR/certbot/work" \
    --logs-dir "$ROOT_DIR/certbot/logs" \
    --non-interactive \
    --no-random-sleep-on-renew \
    "${force_args[@]}" 2>&1)"
status=$?
set -e
echo "$output"

if (( status != 0 )); then
    if grep -qi "accountDoesNotExist\|account does not exist" <<<"$output"; then
        err "Pebble does not recognize this certbot account (Pebble resets its state on every restart)."
        err "Fix: rm -rf certbot/config/{accounts,live,renewal,archive}/*  then run 'make issue' to re-issue from scratch."
        err "(Clearing accounts/ alone is not enough: the renewal config pins a specific account ID"
        err " that only gets refreshed on an actual re-issuance, not a skipped 'not due yet' run.)"
    fi
    exit "$status"
fi

log "Renewal check complete."
