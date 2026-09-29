"""Loads configuration for the agent from two .env files:
  - the lab's own <repo root>/.env   (domains, cert paths, nginx cmds, ...)
  - this agent's ./agent/.env        (LLM endpoint/model/key)
Keeping the lab config in one place (the same .env the bash scripts read)
means the agent and the scripts can never drift out of sync on e.g. DOMAINS
or CERT_DEST_DIR.
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import dotenv_values

AGENT_DIR = Path(__file__).resolve().parent
ROOT_DIR = AGENT_DIR.parent

_lab_env = dotenv_values(ROOT_DIR / ".env")
_agent_env = dotenv_values(AGENT_DIR / ".env")

# agent/.env overrides nothing in the lab .env; lab .env is the source of
# truth for lab config, agent/.env only adds LLM-specific settings.
_merged = {**_lab_env, **_agent_env}


def _get(key: str, default: str | None = None) -> str:
    val = os.environ.get(key) or _merged.get(key) or default
    if val is None:
        raise RuntimeError(f"Missing required config: {key} (set it in agent/.env or {ROOT_DIR}/.env)")
    return val


# --- LLM endpoint --------------------------------------------------------------
LLM_BASE_URL = _get("LLM_BASE_URL")
LLM_MODEL = _get("LLM_MODEL")
LLM_API_KEY = _get("LLM_API_KEY")

# --- Lab config (mirrors the bash scripts' .env) --------------------------------
ZONE = _get("ZONE", "lab.test")
DOMAINS = [d.strip() for d in _get("DOMAINS", "lab.test,*.lab.test").split(",")]
ACME_SERVER = _get("ACME_SERVER", "https://localhost:14000/dir")
ACME_EMAIL = _get("ACME_EMAIL", "lab-admin@lab.test")
DNS_PLUGIN = _get("DNS_PLUGIN", "rfc2136")
NGINX_TEST_CMD = _get("NGINX_TEST_CMD", "docker compose exec -T nginx nginx -t")
NGINX_RELOAD_CMD = _get("NGINX_RELOAD_CMD", "docker compose exec -T nginx nginx -s reload")
_cert_dest_raw = _get("CERT_DEST_DIR", "./nginx/certs").lstrip("./")

# --- Paths -----------------------------------------------------------------------
CERT_DEST_DIR = ROOT_DIR / _cert_dest_raw
CERTBOT_BIN = ROOT_DIR / ".venv" / "bin" / "certbot"
CERTBOT_CONFIG_DIR = ROOT_DIR / "certbot" / "config"
CERTBOT_WORK_DIR = ROOT_DIR / "certbot" / "work"
CERTBOT_LOGS_DIR = ROOT_DIR / "certbot" / "logs"
CERTBOT_LOG_FILE = CERTBOT_LOGS_DIR / "letsencrypt.log"
PEBBLE_CA_BUNDLE = ROOT_DIR / "pebble" / "pebble.minica.pem"
LIVE_LINEAGE_DIR = CERTBOT_CONFIG_DIR / "live" / ZONE
SCRIPTS_DIR = ROOT_DIR / "scripts"
