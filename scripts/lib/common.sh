#!/usr/bin/env bash
# Shared helpers sourced by every script in scripts/. Not meant to be run
# directly.

# Resolve the repo root regardless of caller's cwd, so every script can be
# invoked as ./scripts/foo.sh from anywhere.
lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$lib_dir/../.." && pwd)"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[lab][warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[lab][error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "$1"; return 1; }
    return 0
}

load_env() {
    local env_file="${ROOT_DIR}/.env"
    [[ -f "$env_file" ]] || die "$env_file not found. Run scripts/setup.sh first."
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

# wait_for_http URL max_seconds [curl-extra-args...]
# Polls a URL until it responds (any status code counts as "up" -- callers
# that need a specific status should check separately).
wait_for_http() {
    local url="$1" max_seconds="$2"
    shift 2
    local waited=0
    until curl -sk -o /dev/null "$@" "$url"; do
        waited=$((waited + 2))
        if (( waited >= max_seconds )); then
            return 1
        fi
        sleep 2
    done
    return 0
}
