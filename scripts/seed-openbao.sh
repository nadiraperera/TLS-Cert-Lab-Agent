#!/usr/bin/env bash
# Seeds OpenBao with everything the agent needs and NOTHING more:
#   - the TSIG secret (KV v2, plays the role of a Cloudflare API token)
#   - an AppRole that can only read that one secret path
# Idempotent: safe to re-run any time, including after OpenBao's in-memory
# dev-mode state was wiped by a container restart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
cd "$ROOT_DIR"
load_env

POLICY_NAME="lab-dns-read"
ROLE_NAME="lab-dns-role"
KV_MOUNT="${SECRET_PATH%%/*}"                # "secret" out of "secret/dns/lab"
KV_SUBPATH="${SECRET_PATH#*/}"               # "dns/lab"
TSIG_KEY_FILE="bind/keys/certbot-key.key"

[[ -s "$TSIG_KEY_FILE" ]] || die "$TSIG_KEY_FILE not found. Run scripts/setup.sh first."

bao_api() {
    # bao_api METHOD PATH [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    local args=(-sf -X "$method" -H "X-Vault-Token: ${OPENBAO_ROOT_TOKEN}")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
    curl "${args[@]}" "${OPENBAO_ADDR}/v1/${path}"
}

log "Waiting for OpenBao at ${OPENBAO_ADDR}..."
wait_for_http "${OPENBAO_ADDR}/v1/sys/health?standbyok=true" 30 \
    || die "OpenBao is not reachable at ${OPENBAO_ADDR}. Is the stack up? (make setup)"

# --- 1. TSIG secret -> KV v2 --------------------------------------------------
log "Reading TSIG key from ${TSIG_KEY_FILE}"
tsig_algorithm="$(grep -oP 'algorithm\s+\K[^;]+' "$TSIG_KEY_FILE" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
tsig_secret="$(grep -oP 'secret\s+"\K[^"]+' "$TSIG_KEY_FILE")"
[[ -n "$tsig_algorithm" && -n "$tsig_secret" ]] || die "Could not parse $TSIG_KEY_FILE"

log "Writing secret to ${SECRET_PATH} (KV v2)"
payload=$(jq -n \
    --arg key_name "certbot-key" \
    --arg algorithm "$tsig_algorithm" \
    --arg secret "$tsig_secret" \
    '{data: {key_name: $key_name, algorithm: $algorithm, secret: $secret}}')
bao_api POST "${KV_MOUNT}/data/${KV_SUBPATH}" "$payload" >/dev/null

# --- 2. AppRole auth method ----------------------------------------------------
if bao_api GET "sys/auth" | jq -e '."approle/"' >/dev/null 2>&1; then
    log "AppRole auth method already enabled"
else
    log "Enabling AppRole auth method"
    bao_api POST "sys/auth/approle" '{"type":"approle"}' >/dev/null
fi

# --- 3. Least-privilege policy: read-only on this one KV path ----------------
log "Writing policy '${POLICY_NAME}' (read-only on secret/data/${KV_SUBPATH})"
policy_hcl="path \"${KV_MOUNT}/data/${KV_SUBPATH}\" {
  capabilities = [\"read\"]
}"
bao_api PUT "sys/policies/acl/${POLICY_NAME}" "$(jq -n --arg policy "$policy_hcl" '{policy: $policy}')" >/dev/null

# --- 4. AppRole role bound to that policy -------------------------------------
log "Writing AppRole role '${ROLE_NAME}'"
bao_api POST "auth/approle/role/${ROLE_NAME}" "$(jq -n --arg p "$POLICY_NAME" '{
    token_policies: $p,
    token_ttl: "15m",
    token_max_ttl: "30m",
    secret_id_num_uses: 0,
    token_num_uses: 0
}')" >/dev/null

# --- 5. Credentials for the agent: role_id (stable) + secret_id (fresh) ------
mkdir -p .secrets
chmod 700 .secrets

role_id="$(bao_api GET "auth/approle/role/${ROLE_NAME}/role-id" | jq -r '.data.role_id')"
secret_id="$(bao_api POST "auth/approle/role/${ROLE_NAME}/secret-id" '{}' | jq -r '.data.secret_id')"
[[ -n "$role_id" && "$role_id" != "null" ]] || die "Failed to read role_id"
[[ -n "$secret_id" && "$secret_id" != "null" ]] || die "Failed to generate secret_id"

printf '%s' "$role_id" > .secrets/role_id
printf '%s' "$secret_id" > .secrets/secret_id
chmod 600 .secrets/role_id .secrets/secret_id

log "AppRole credentials written to .secrets/role_id, .secrets/secret_id (chmod 600)"
log "Seed complete. certbot never sees the root token -- only fetch-secret.sh's AppRole login."
