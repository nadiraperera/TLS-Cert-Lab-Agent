# TLS Certificate Automation Lab

A fully local simulation of a production TLS automation pipeline:

```
OpenBao (secret) -> Certbot (DNS-01) -> DNS provider -> ACME CA -> Nginx (deploy-hook)
```

Everything runs on your machine, no cloud accounts, no real DNS, no real CA.

## Architecture / production mapping

| Lab component | Plays the role of | Production equivalent |
|---|---|---|
| OpenBao (dev mode, KV v2 + AppRole) | Secret manager | OpenBao / Vault |
| BIND9 + RFC2136 dynamic updates + TSIG key | DNS provider API | Cloudflare DNS + API token |
| Pebble (`letsencrypt/pebble`) | ACME certificate authority | Let's Encrypt |
| Certbot on the host, in a venv | Certificate agent | Certbot on the server |
| Nginx (containerized) | TLS-terminating web server | Nginx |
| `scripts/deploy-hook.sh` | Cert install + reload | Same script, prod just uses `systemctl reload nginx` |

The only things that differ from production are external services (DNS
provider, CA). OpenBao, Certbot, the deploy hook, and Nginx behave exactly as
they would in production. Swapping back to production means:
`DNS_PLUGIN=cloudflare`, `ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory`,
a real Cloudflare API token seeded at `SECRET_PATH` instead of a TSIG key, and
`NGINX_RELOAD_CMD="systemctl reload nginx"`.

### Why BIND9 + RFC2136 instead of a Cloudflare mock

Cloudflare's DNS-01 flow is "call an HTTP API with a bearer token." Faking
that convincingly buys nothing. RFC2136 dynamic DNS + TSIG is what Certbot's
`certbot-dns-rfc2136` plugin *actually* speaks against a real authoritative
DNS server, and the TSIG key plays exactly the role a scoped Cloudflare API
token would: a credential that OpenBao hands out, that only allows writing
one specific record.

### Least privilege, end to end

- The TSIG key's `update-policy` (in `bind/config/named.conf.local`) grants
  it permission to write **only** the `_acme-challenge.lab.test` TXT record —
  nothing else in the zone. Verified: an update to any other name/type gets
  `REFUSED` by BIND.
- The OpenBao AppRole policy (`lab-dns-read`) grants **read-only** access to
  exactly `secret/data/dns/lab` — nothing else in OpenBao. Certbot never sees
  the OpenBao root token, only ships with `role_id`/`secret_id`.

## Prerequisites

`setup.sh` checks for these and tells you what's missing instead of
installing anything itself: `docker`, `docker compose` (v2 plugin), `curl`,
`jq`, `python3` (with the `venv` module), `openssl`.

## Usage

```sh
make setup        # bring up containers, generate TSIG key + placeholder cert
make seed         # seed OpenBao: TSIG secret + least-privilege AppRole
make issue        # issue the first certificate via DNS-01 against Pebble
make verify       # fetch Pebble's issuing root and inspect the served cert
make renew        # renew if due (no-op right after issuance)
make force-renew  # force a renewal now, to test the full renew+deploy path
make logs         # tail all container logs
make down         # stop containers, keep generated state
make purge        # stop containers AND wipe all generated state
```

Full cycle from a clean checkout:

```sh
make setup && make seed && make issue && make verify
```

### What each script actually does

- **`scripts/setup.sh`** — checks prerequisites, creates `.env` from
  `.env.example` (stamping in your host UID/GID), creates the Python venv,
  downloads Pebble's test CA, generates the TSIG key via `tsig-keygen`, seeds
  the zone file from its template, generates a self-signed placeholder cert
  for Nginx, brings up the compose stack, and waits for everything to be
  healthy.
- **`scripts/seed-openbao.sh`** — idempotent. Writes the TSIG secret into KV
  v2, enables AppRole (if not already enabled), writes the `lab-dns-read`
  policy and `lab-dns-role` role, and writes fresh `role_id`/`secret_id` to
  `.secrets/` (mode 600).
- **`scripts/fetch-secret.sh`** — AppRole login, reads the secret, renders
  `.secrets/dns-credentials.ini` (shape depends on `DNS_PLUGIN`). Certbot
  stores this exact path in its renewal config, so it must stay fixed.
- **`scripts/issue.sh`** / **`scripts/renew.sh`** — call `fetch-secret.sh`,
  run `certbot certonly` / `certbot renew`, then delete (`shred -u`, falling
  back to `rm`) the credentials INI in a trap — even if certbot fails.
- **`scripts/deploy-hook.sh`** — certbot's `--deploy-hook`. Backs up the
  currently-deployed cert, atomically installs the new one (`fullchain.pem`
  0644, `privkey.pem` 0600, write-temp-then-`mv`), runs `$NGINX_TEST_CMD`,
  and only runs `$NGINX_RELOAD_CMD` if that passes. On any failure, restores
  the backed-up cert and exits non-zero — Nginx never reloads onto a broken
  config.
- **`scripts/verify.sh`** — fetches Pebble's current issuing root from
  `:15000/roots/0` and uses it (not the static `pebble.minica.pem`, which is
  a different CA — see below) to validate an HTTPS request to Nginx, then
  prints the cert's subject/SANs/issuer/serial/expiry.
- **`scripts/teardown.sh [--purge]`** — `docker compose down`, optionally
  wiping `.venv`, `.secrets`, `certbot/`, the TSIG key, the zone file, and
  deployed certs.

## Configuration (`.env`)

All provider-specific and environment-specific values live in `.env`
(generated from `.env.example`; see that file for every variable). The
notable ones for portability: `DNS_PLUGIN` (`rfc2136` or `cloudflare`),
`ACME_SERVER`, `SECRET_PATH`, `DOMAINS`, `CERT_DEST_DIR`, `NGINX_TEST_CMD`,
`NGINX_RELOAD_CMD`. `fetch-secret.sh` branches on `DNS_PLUGIN` to render the
right credential shape.

## Design notes worth knowing before you dig into the scripts

- **BIND runs as your host user, not root.** The image's default entrypoint
  runs `named` as root then drops to a `bind` (uid 53) user that doesn't
  exist on your host, which would make the bind-mounted `bind/zones` and
  `bind/keys` directories unwritable without `chown`/`sudo`. Instead,
  `docker-compose.yml` overrides the entrypoint, sets `user: "${HOST_UID}:${HOST_GID}"`,
  and adds `cap_add: NET_BIND_SERVICE` so the non-root process can still bind
  port 53. No chown, no sudo, no world-writable mounts.
- **Two different Pebble CAs, don't confuse them.** `pebble/pebble.minica.pem`
  (downloaded once by `setup.sh`) is the CA for Pebble's *own* HTTPS API
  (used as `REQUESTS_CA_BUNDLE` so Certbot can reach `:14000`). The
  certificates Pebble *issues* (like `lab.test`'s) are signed by a completely
  different root/intermediate that Pebble **generates fresh on every
  restart** and only exists in memory — fetch it live from `:15000/roots/0`
  (that's what `verify.sh` does). Using `pebble.minica.pem` to validate an
  issued cert will fail; that's expected, not a bug.
- **Nginx's cert directory is a directory mount, not file mounts**, so the
  deploy hook's atomic `mv` (which replaces the inode) is actually visible
  inside the container. The filenames (`fullchain.pem`/`privkey.pem`) never
  change, so `nginx.conf` never needs to change either.

## Troubleshooting

**"could not open file '//run/named/session.key': Permission denied" (or
`named.pid`) in BIND logs**
Already handled in `bind/config/named.conf.options` (`session-keyfile` /
`pid-file` point at the writable `/var/cache/bind` mount instead of the
root-owned default `/run/named`). If you see this again after editing that
file, check you didn't remove those two directives.

**`nsupdate`/Certbot gets "update failed: REFUSED"**
The TSIG key is scoped by `update-policy` in `bind/config/named.conf.local`
to only the exact name `_acme-challenge.lab.test`, TXT records only. Any
other name or record type is correctly refused — this is the point, not a
bug. If Certbot itself gets refused, check `DOMAINS` in `.env` matches
`lab.test`/`*.lab.test` (both use the same challenge name) and that
`bind/keys/certbot-key.key` matches what's stored in OpenBao
(`make seed` re-syncs them from the same file, so they can't drift on their
own — but if you manually regenerated the key, re-run `make seed`).

**Certbot/curl can't verify Pebble's ACME endpoint (`SSLError`, "unable to
get local issuer certificate")**
`REQUESTS_CA_BUNDLE` must point at `pebble/pebble.minica.pem`. `issue.sh` and
`renew.sh` export this automatically; if you're running certbot manually,
export it yourself. If the file is missing/stale, delete it and re-run
`make setup` to re-download it.

**Nginx container won't start / crashes immediately**
Nginx refuses to start without a valid cert at `nginx/certs/fullchain.pem`
and `privkey.pem`. `setup.sh` generates a self-signed placeholder for
exactly this reason — if it's missing (e.g. after a `make purge`), re-run
`make setup` before `docker compose up`.

**`fetch-secret.sh` fails with "OpenBao was restarted, run make seed"**
OpenBao runs in `-dev` mode here, which is entirely in-memory — restarting
the container (or `docker compose down` without `--purge` followed by `up`,
if the container itself was recreated) wipes the secret, the AppRole, and
your `role_id`/`secret_id`. This is expected in dev mode; production OpenBao
is not run this way. Fix: `make seed`.

**`issue.sh`/`renew.sh` fails with an `accountDoesNotExist` / "Account does
not exist" error from Pebble**
Pebble resets *all* of its state, including registered ACME accounts, on
every restart — it has no persistent storage by design (it's a test server).
Certbot, however, still has the old account key cached locally and tries to
reuse it. Fix:
```sh
rm -rf certbot/config/{accounts,live,renewal,archive}/*
make issue   # re-registers a fresh account and re-issues from scratch
```
Clearing `accounts/` alone is *not* enough: the per-domain renewal config
(`certbot/config/renewal/lab.test.conf`) pins a specific account ID, and that
only gets refreshed by an actual issuance — if the existing cert isn't due
yet, `certbot certonly` registers a new account but skips re-issuing, leaving
the renewal config pointing at the now-deleted account. The full wipe above
forces a real fresh issuance every time. Both `issue.sh` and `renew.sh`
detect the resulting error in Certbot's output and print this same fix.

**Testing retry logic**
Set `PEBBLE_WFE_NONCEREJECT` in `.env` to a positive number (e.g. `5`) to
make Pebble reject that many nonces before succeeding, then
`docker compose up -d pebble` to apply it and re-run `make issue` /
`make force-renew` to watch Certbot retry.
