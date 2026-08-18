# Domain rotation proxy toolkit

Ubuntu **26.04** toolkit that registers a random 20-letter `.com` domain via InternetBS, points DNS (apex + wildcard) at the VM, issues a Let’s Encrypt wildcard certificate, and configures nginx reverse proxies for CDN and origin traffic.

**Clients:** start with the step-by-step guide → [`docs/CLIENT_GUIDE.md`](docs/CLIENT_GUIDE.md)

One VM can host **multiple clients** (hostname prefixes) on the same rotated domain. Purchase frequency is set with `--rotate-every-days` (default daily). Configured domains stay reachable for `--retention-days` (default **14**), then local nginx configs and certificates are removed from the VM.

## Client quick start

Host this repository as a **public GitHub repo**, then on the Ubuntu 26.04 VM:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- \
  --api-key 'YOUR_INTERNETBS_API_KEY' \
  --password 'YOUR_INTERNETBS_PASSWORD' \
  --client 'clientname42' \
  --client 'otherclient' \
  --cdn-origin 'cdn.your-upstream.example' \
  --backend-origin 'backend.your-upstream.example' \
  --email 'you@your-real-domain.com' \
  --rotate-every-days 2 \
  --api-user 'domainapi' \
  --api-password 'STRONG_PASSWORD' \
  --base-url 'https://github.com/OWNER/REPO'

sudo nano /etc/proxies/registrant.env   # required fields; private WHOIS hides them publicly
sudo /opt/proxies/scripts/force-rotate.sh
```

`--base-url` accepts `https://github.com/OWNER/REPO`, `.../tree/<ref>`, or a `raw.githubusercontent.com` root. Use `--github-ref` for a non-default branch/tag.

**Force a new domain on demand** (any time, billable):

```bash
sudo /opt/proxies/scripts/force-rotate.sh
```

**Read current domain URLs by VM IP** (Basic Auth; same user/password for all clients):

```bash
curl -u 'domainapi:STRONG_PASSWORD' "http://VM_PUBLIC_IP/api/game/url-extended/clientname42"
```

**Clean up a previous install:**

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/cleanup.sh | sudo bash -s -- --yes
# or: sudo /opt/proxies/scripts/cleanup.sh --yes [--purge-packages]
```

Full instructions, day-to-day commands, troubleshooting, and file locations: **[Client guide](docs/CLIENT_GUIDE.md)**.

## What gets installed

| Path | Purpose |
|------|---------|
| `/opt/proxies/scripts/manage-clients.sh` | Add/remove/list/sync clients without buying a domain |
| `/etc/proxies/credentials.env` | API key, password, CDN/backend origins, email, intervals |
| `/etc/proxies/clients/<name>.env` | Per-client id (filename) + optional `CASINO_ID` |
| `/etc/proxies/prefixes-client.env` | Per-client hostname templates |
| `/etc/proxies/prefixes-shared.env` | Shared hostname prefixes |
| `/etc/proxies/registrant.env` | WHOIS contact for Domain/Create |
| `/var/lib/proxies/current-domain` | Most recent domain |
| `/var/lib/proxies/urls/<name>.json` | Per-client URL JSON |
| `/var/lib/proxies/domains/<domain>/` | Retention stamps (`created`) |
| `/etc/cron.d/proxies-domain-rotation` | Daily check at 03:00; purchases every `ROTATION_INTERVAL_DAYS` |

### Nginx vhosts (per domain)

- **CDN:** `cdn.<domain>`, `lobby-prod-cdn.<domain>` → `CDN_ORIGIN` (install input)
- **Backend shared:** `proxies-origin-shared-<domain>.conf` → shared prefixes → `BACKEND_ORIGIN`
- **Backend per client:** `proxies-origin-<client>-<domain>.conf` → that client’s prefixes → `BACKEND_ORIGIN`

## Notes

- **Billable:** live `Domain/Create` spends InternetBS balance.
- Availability is checked with `Domain/Check` before every purchase.
- Wildcard certs use Certbot DNS-01 hooks against the InternetBS DNS API.
- Local cleanup after `DOMAIN_RETENTION_DAYS` deletes nginx sites and runs `certbot delete` for that domain (not the registrar registration). Let's Encrypt may still email about expiry until the cert ages out; it is not auto-revoked.
- `--email` is used for Let's Encrypt and InternetBS registrant verification (stored as `CERTBOT_EMAIL` in credentials.env).
- Target OS is **Ubuntu 26.04** only (install and rotation scripts enforce this).
- Package hosting: publish this repo publicly on GitHub and pass `--base-url https://github.com/OWNER/REPO` (optional `--github-ref`).
- URL API: `GET http://<vm-ip>/api/game/url-extended/<client>` with shared Basic Auth (`--api-user` / `--api-password`).
