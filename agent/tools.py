"""LangChain tools exposing the cert lab to the agent.

Design notes:
  - `invoke_certificate` runs certbot WITHOUT --deploy-hook on purpose --
    installing the cert into nginx is a separate, explicit tool
    (`deploy_certificate`) the agent must decide to call. This mirrors what
    certbot's hook would do, but keeps the step visible/controllable by the
    agent instead of happening silently inside certbot.
  - Secret handling is NOT exposed as an agent tool. `invoke_certificate`
    shells out to the already-hardened `scripts/fetch-secret.sh` (AppRole
    login, render INI, fixed path) and always shreds the INI afterwards in a
    finally block -- the agent can request a certificate, but never sees or
    handles the DNS credential itself.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess

from langchain_core.tools import tool

from config import (
    ACME_EMAIL,
    ACME_SERVER,
    CERTBOT_BIN,
    CERTBOT_CONFIG_DIR,
    CERTBOT_LOG_FILE,
    CERTBOT_LOGS_DIR,
    CERTBOT_WORK_DIR,
    CERT_DEST_DIR,
    DNS_PLUGIN,
    DOMAINS,
    LIVE_LINEAGE_DIR,
    NGINX_RELOAD_CMD,
    NGINX_TEST_CMD,
    PEBBLE_CA_BUNDLE,
    ROOT_DIR,
    SCRIPTS_DIR,
)

VALID_LOG_SOURCES = {"certbot", "bind9", "pebble", "nginx", "openbao"}
VALID_REVOKE_REASONS = {
    "unspecified", "keycompromise", "affiliationchanged", "superseded", "cessationofoperation",
}


def _certbot_base_args() -> list[str]:
    return [
        str(CERTBOT_BIN),
        "--config-dir", str(CERTBOT_CONFIG_DIR),
        "--work-dir", str(CERTBOT_WORK_DIR),
        "--logs-dir", str(CERTBOT_LOGS_DIR),
    ]


def _plugin_args(ini_path) -> list[str]:
    if DNS_PLUGIN == "rfc2136":
        return ["--dns-rfc2136", "--dns-rfc2136-credentials", str(ini_path),
                 "--dns-rfc2136-propagation-seconds", "5"]
    if DNS_PLUGIN == "cloudflare":
        return ["--dns-cloudflare", "--dns-cloudflare-credentials", str(ini_path),
                 "--dns-cloudflare-propagation-seconds", "30"]
    raise ValueError(f"Unknown DNS_PLUGIN: {DNS_PLUGIN}")


def _with_pebble_ca_env() -> dict:
    return {**os.environ, "REQUESTS_CA_BUNDLE": str(PEBBLE_CA_BUNDLE)}


def _diagnose(output: str) -> str:
    if re.search(r"accountDoesNotExist|account does not exist", output, re.I):
        return (
            "\n\nDIAGNOSIS: Pebble does not recognize this certbot account -- Pebble resets "
            "all of its state (including accounts) on every restart. Fix: delete "
            "certbot/config/{accounts,live,renewal,archive}/* then retry invoke_certificate."
        )
    if re.search(r"update failed: REFUSED", output, re.I):
        return (
            "\n\nDIAGNOSIS: BIND refused the DNS update. The TSIG key is scoped to only the "
            "_acme-challenge.<zone> TXT record -- check DOMAINS matches the zone, and that "
            "OpenBao's stored TSIG secret matches bind/keys/certbot-key.key (run 'make seed' "
            "if OpenBao was restarted)."
        )
    return ""


@tool
def invoke_certificate(force: bool = False) -> str:
    """Request (or renew) the lab certificate via ACME DNS-01 against Pebble.

    This does NOT install the certificate into nginx -- call deploy_certificate
    afterwards to do that. Safe to call when a valid certificate already
    exists: certbot will just report it's not due yet, unless force=True.

    Args:
        force: force re-issuance even if the current certificate isn't due
            for renewal yet (use this to test the renewal/deploy path).
    """
    ini_path = ROOT_DIR / ".secrets" / "dns-credentials.ini"
    try:
        fetch = subprocess.run(
            [str(SCRIPTS_DIR / "fetch-secret.sh")],
            cwd=ROOT_DIR, capture_output=True, text=True, timeout=30,
        )
        if fetch.returncode != 0:
            return f"fetch-secret.sh failed (exit {fetch.returncode}):\n{fetch.stdout}{fetch.stderr}"

        domain_args = []
        for d in DOMAINS:
            domain_args += ["-d", d]

        cmd = [
            *_certbot_base_args(), "certonly",
            "--server", ACME_SERVER,
            *_plugin_args(ini_path),
            *domain_args,
            "--non-interactive", "--agree-tos", "-m", ACME_EMAIL,
            "--no-random-sleep-on-renew",
        ]
        if force:
            cmd.append("--force-renewal")

        result = subprocess.run(
            cmd, cwd=ROOT_DIR, capture_output=True, text=True, timeout=90,
            env=_with_pebble_ca_env(),
        )
        output = result.stdout + result.stderr
        if result.returncode != 0:
            output += _diagnose(output)
        return output
    finally:
        if ini_path.exists():
            if shutil.which("shred"):
                subprocess.run(["shred", "-u", str(ini_path)], check=False)
            else:
                ini_path.unlink(missing_ok=True)


@tool
def deploy_certificate() -> str:
    """Install the currently-issued certificate into nginx's cert directory.

    Atomically replaces fullchain.pem/privkey.pem, runs `nginx -t`, and only
    reloads nginx if that passes. On any failure, rolls back to whatever was
    deployed before (nginx is never left pointed at a broken config). Call
    this after invoke_certificate reports success.
    """
    src_fullchain = LIVE_LINEAGE_DIR / "fullchain.pem"
    src_privkey = LIVE_LINEAGE_DIR / "privkey.pem"
    if not src_fullchain.exists() or not src_privkey.exists():
        return f"No issued certificate found at {LIVE_LINEAGE_DIR}. Call invoke_certificate first."

    dest_fullchain = CERT_DEST_DIR / "fullchain.pem"
    dest_privkey = CERT_DEST_DIR / "privkey.pem"
    bak_fullchain = dest_fullchain.with_name(dest_fullchain.name + ".bak")
    bak_privkey = dest_privkey.with_name(dest_privkey.name + ".bak")

    backed_up = []
    if dest_fullchain.exists():
        shutil.copy2(dest_fullchain, bak_fullchain)
        backed_up.append((dest_fullchain, bak_fullchain))
    if dest_privkey.exists():
        shutil.copy2(dest_privkey, bak_privkey)
        backed_up.append((dest_privkey, bak_privkey))

    def rollback():
        for dest, bak in backed_up:
            if bak.exists():
                bak.replace(dest)

    tmp_fullchain = dest_fullchain.with_name(dest_fullchain.name + ".tmp")
    tmp_privkey = dest_privkey.with_name(dest_privkey.name + ".tmp")
    shutil.copy2(src_fullchain, tmp_fullchain)
    os.chmod(tmp_fullchain, 0o644)
    shutil.copy2(src_privkey, tmp_privkey)
    os.chmod(tmp_privkey, 0o600)
    tmp_fullchain.replace(dest_fullchain)
    tmp_privkey.replace(dest_privkey)

    test = subprocess.run(NGINX_TEST_CMD, shell=True, cwd=ROOT_DIR, capture_output=True, text=True, timeout=20)
    if test.returncode != 0:
        rollback()
        return f"nginx -t FAILED, rolled back to previous cert:\n{test.stdout}{test.stderr}"

    reload = subprocess.run(NGINX_RELOAD_CMD, shell=True, cwd=ROOT_DIR, capture_output=True, text=True, timeout=20)
    if reload.returncode != 0:
        rollback()
        return f"nginx reload FAILED, rolled back to previous cert:\n{reload.stdout}{reload.stderr}"

    for _, bak in backed_up:
        bak.unlink(missing_ok=True)
    return f"Deployed successfully.\nnginx -t: {test.stdout.strip()}\nreload: ok"


@tool
def revoke_certificate(reason: str = "unspecified") -> str:
    """Revoke the currently issued certificate via ACME (certbot revoke).

    Does not touch nginx's currently-deployed cert file or issue a
    replacement -- call invoke_certificate + deploy_certificate afterwards
    if a valid certificate needs to be served again.

    Args:
        reason: one of unspecified, keycompromise, affiliationchanged,
            superseded, cessationofoperation.
    """
    if reason not in VALID_REVOKE_REASONS:
        return f"Invalid reason '{reason}'. Valid: {', '.join(sorted(VALID_REVOKE_REASONS))}"

    cert_path = LIVE_LINEAGE_DIR / "cert.pem"
    if not cert_path.exists():
        return f"No certificate found at {cert_path} to revoke."

    cmd = [
        *_certbot_base_args(), "revoke",
        "--server", ACME_SERVER,
        "--cert-path", str(cert_path),
        "--non-interactive", "--no-delete-after-revoke",
        "--reason", reason,
    ]
    result = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True, timeout=60, env=_with_pebble_ca_env())
    return result.stdout + result.stderr


@tool
def list_certificates() -> str:
    """List certbot-managed certificates: domains, expiry, status, paths."""
    cmd = [*_certbot_base_args(), "certificates"]
    result = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True, timeout=30)
    return result.stdout + result.stderr


@tool
def query_dns(name: str, record_type: str = "TXT") -> str:
    """Query the lab's authoritative BIND9 server for a DNS record.

    Examples: query_dns("_acme-challenge.lab.test", "TXT"),
    query_dns("lab.test", "SOA").
    """
    cmd = ["docker", "compose", "exec", "-T", "bind9", "dig", "@127.0.0.1",
           record_type, name, "+noall", "+answer"]
    result = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True, timeout=15)
    out = result.stdout.strip()
    if result.returncode != 0:
        return f"dig failed: {result.stderr.strip()}"
    return out if out else f"No answer for {record_type} {name} (NXDOMAIN or empty RRset)."


@tool
def search_logs(source: str, pattern: str, max_lines: int = 20) -> str:
    """Search a component's logs for a case-insensitive regex pattern.

    Args:
        source: one of certbot, bind9, pebble, nginx, openbao.
        pattern: regex to search for, e.g. 'accountDoesNotExist', 'REFUSED',
            'error', 'permission denied'.
        max_lines: cap on how many matching lines to return (most recent).
    """
    source = source.lower()
    if source not in VALID_LOG_SOURCES:
        return f"Unknown source '{source}'. Valid: {', '.join(sorted(VALID_LOG_SOURCES))}"
    try:
        regex = re.compile(pattern, re.IGNORECASE)
    except re.error as e:
        return f"Invalid regex: {e}"

    if source == "certbot":
        if not CERTBOT_LOG_FILE.exists():
            return "No certbot log file yet -- nothing has been issued/renewed."
        lines = CERTBOT_LOG_FILE.read_text(errors="replace").splitlines()
    else:
        result = subprocess.run(
            ["docker", "compose", "logs", "--no-color", source],
            cwd=ROOT_DIR, capture_output=True, text=True, timeout=15,
        )
        lines = (result.stdout + result.stderr).splitlines()

    matches = [l for l in lines if regex.search(l)]
    if not matches:
        return f"No matches for /{pattern}/ in {source} logs."
    tail = matches[-max_lines:]
    return f"{len(matches)} match(es) in {source} logs, showing last {len(tail)}:\n" + "\n".join(tail)


TOOLS = [invoke_certificate, deploy_certificate, revoke_certificate, list_certificates, query_dns, search_logs]
