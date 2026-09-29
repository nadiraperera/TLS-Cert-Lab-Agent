# Cert lab agent

A LangChain/LangGraph ReAct agent that operates the TLS cert lab (see the
repo root README for what the lab itself does). It talks to an
OpenAI-compatible LLM endpoint (currently a local Ollama server serving
`qwen2.5:14b`, configured in `.env`) and exposes six
tools:

| Tool | Does |
|---|---|
| `invoke_certificate(force=False)` | Issues/renews the cert via ACME DNS-01 against Pebble. **Does not deploy it.** |
| `deploy_certificate()` | Atomically installs the currently-issued cert into nginx, `nginx -t`, reload-or-rollback. |
| `revoke_certificate(reason=...)` | Revokes the current cert via ACME. |
| `list_certificates()` | `certbot certificates` -- domains, expiry, paths. |
| `query_dns(name, record_type)` | `dig`s the lab's BIND9 for a record. |
| `search_logs(source, pattern, max_lines=20)` | Greps certbot/bind9/pebble/nginx/openbao logs. |

`invoke_certificate` and `deploy_certificate` are deliberately separate tools
(not wired through certbot's `--deploy-hook`) so the agent decides when to
actually touch nginx, rather than certbot doing it silently.

Secret handling is not an agent tool: `invoke_certificate` shells out to the
lab's own `scripts/fetch-secret.sh` (AppRole login, fixed-path INI, shredded
in a `finally` block) -- the agent can request a certificate but never
handles the DNS credential itself.

## Setup

```sh
cd agent
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
cp .env.example .env
```

The lab itself (`make setup && make seed`, from the repo root) must already
be up -- the agent drives it, it doesn't stand it up.

## Run

```sh
./.venv/bin/python cli.py
```

Then, e.g.:
- "list the certificates"
- "force-renew the cert and deploy it"
- "why did the last renewal fail? check the certbot logs"
- "revoke the current cert, reason superseded"

## Config (`.env`)

```
LLM_BASE_URL=http://<ollama-host>:11434/v1
LLM_MODEL=qwen2.5:14b
LLM_API_KEY=ollama   # ignored by Ollama, but must be non-empty
```

Lab-specific config (`DOMAINS`, `ACME_SERVER`, `CERT_DEST_DIR`,
`NGINX_TEST_CMD`/`NGINX_RELOAD_CMD`, `DNS_PLUGIN`) is read from the repo
root's own `.env` -- `config.py` merges both so the agent and the bash
scripts can never drift out of sync.
