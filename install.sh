#!/usr/bin/env bash
# Bootstrap installer for the domain-rotation toolkit.
# Clients only need this file URL; it downloads the rest of the package.
#
# GitHub (recommended for a public repo):
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- \
#     --api-key KEY --password PASS --client CLIENT \
#     --cdn-origin cdn.example.com --backend-origin backend.example.com \
#     --email you@example.com --base-url https://github.com/OWNER/REPO
#
# Optional branch/tag (default: main):
#     --base-url https://github.com/OWNER/REPO --github-ref main
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
PROXIES_STATE="${PROXIES_STATE:-/var/lib/proxies}"

# Package source. Prefer a GitHub repo URL; raw.githubusercontent.com also works.
DEFAULT_BASE_URL="${PROXIES_BASE_URL:-}"
DEFAULT_GITHUB_REF="${PROXIES_GITHUB_REF:-main}"

API_KEY=""
PASSWORD=""
CLIENT_NAME=""
CASINO_ID=""
CLIENTS=()
BASE_URL="${DEFAULT_BASE_URL}"
GITHUB_REF="${DEFAULT_GITHUB_REF}"
LOCAL_DIR=""
PREFIX=""
RUN_NOW=0
SKIP_CRON=0
SKIP_PACKAGES=0
ALLOW_NON_ROOT=0
REGISTRANT_SRC=""
API_USER=""
API_PASSWORD=""
CDN_ORIGIN=""
BACKEND_ORIGIN=""
CERTBOT_EMAIL=""
ROTATION_INTERVAL_DAYS=1
DOMAIN_RETENTION_DAYS=14

PACKAGE_FILES=(
  "scripts/rotate-domain.sh"
  "scripts/force-rotate.sh"
  "scripts/manage-clients.sh"
  "scripts/cleanup.sh"
  "lib/common.sh"
  "lib/internetbs.sh"
  "lib/ssl.sh"
  "lib/nginx.sh"
  "lib/urls.sh"
  "hooks/certbot-auth.sh"
  "hooks/certbot-cleanup.sh"
  "templates/cdn.conf.tpl"
  "templates/origin.conf.tpl"
  "templates/websocket-map.conf"
  "templates/server-names-hash.conf"
  "templates/api-ip.conf.tpl"
  "config/registrant.env.example"
  "config/prefixes-client.env.example"
  "config/prefixes-shared.env.example"
  "config/client.env.example"
  "docs/CLIENT_GUIDE.md"
  "README.md"
)

usage() {
  cat <<'EOF'
Usage: install.sh --api-key KEY --password PASS --client NAME \
  --cdn-origin HOST --backend-origin HOST --base-url REPO_URL [options]

Options:
  --api-key KEY           InternetBS API key (required)
  --password PASS         InternetBS API password (required)
  --client NAME           Client id for hostname prefixes (repeatable; ≥1 required).
                          Creates /etc/proxies/clients/<NAME>.env
  --client-name NAME      Alias for a single --client (legacy)
  --cdn-origin HOST       Upstream host for CDN vhost (required), e.g. cdn.example.com
  --backend-origin HOST   Upstream host for backend/origin vhost (required), e.g. p4.example.com
  --email EMAIL           Real mailbox used for Let's Encrypt and InternetBS registrant
                          verification (required). Confirm InternetBS messages sent here.
  --rotate-every-days N   Buy a new domain every N days (default: 1). Cron still runs daily
                          to resume incomplete jobs and clean expired local configs.
  --retention-days N      Keep each domain's local nginx/certs for N days (default: 14).
  --casino-id ID          Optional CASINO_ID written into the client file when exactly
                          one --client is installed (for later URL API work)
  --api-user USER         Basic Auth username for /api/game/url-extended (required unless htpasswd exists)
  --api-password PASS     Basic Auth password for /api/game/url-extended
  --base-url URL          GitHub repo or raw package root (required unless --local-dir)
                          Examples:
                            https://github.com/OWNER/REPO
                            https://github.com/OWNER/REPO/tree/main
                            https://raw.githubusercontent.com/OWNER/REPO/main
  --github-ref REF        Branch/tag when --base-url is https://github.com/OWNER/REPO (default: main)
  --local-dir PATH        Copy package from a local directory instead of downloading
  --prefix DIR            Install under DIR (sets root/etc/state for testing)
  --registrant-file PATH  Existing registrant.env to install
  --run-now               Run first domain rotation after install
  --skip-cron             Do not install daily cron job
  --skip-packages         Do not apt-install nginx/certbot (for dry tests)
  --allow-non-root        Allow install without root when using --prefix
  -h, --help              Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)"
}

require_ubuntu_2604() {
  local version_id=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    version_id="${VERSION_ID:-}"
  fi
  if [[ "${version_id}" != "26.04" ]]; then
    die "This toolkit requires Ubuntu 26.04 (detected: ${ID:-unknown} ${version_id:-unknown})"
  fi
}

# Convert GitHub repo / tree / raw URLs into a raw.githubusercontent.com package root.
# Other HTTPS roots are returned unchanged.
resolve_package_base_url() {
  local url="$1"
  local ref="${2:-main}"
  local owner repo tree_ref

  url="${url%%[?#]*}"
  url="${url%/}"
  url="${url%.git}"

  if [[ "${url}" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    tree_ref="${BASH_REMATCH[3]}"
    printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "${owner}" "${repo}" "${tree_ref}"
    return 0
  fi

  if [[ "${url}" =~ ^https://github\.com/([^/]+)/([^/]+)(/tree/([^/]+))? ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    tree_ref="${BASH_REMATCH[4]:-${ref}}"
    printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "${owner}" "${repo}" "${tree_ref}"
    return 0
  fi

  printf '%s\n' "${url}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    --client|--client-name)
      CLIENTS+=("${2:-}")
      shift 2
      ;;
    --casino-id)
      CASINO_ID="${2:-}"
      shift 2
      ;;
    --api-user)
      API_USER="${2:-}"
      shift 2
      ;;
    --api-password)
      API_PASSWORD="${2:-}"
      shift 2
      ;;
    --cdn-origin)
      CDN_ORIGIN="${2:-}"
      shift 2
      ;;
    --backend-origin)
      BACKEND_ORIGIN="${2:-}"
      shift 2
      ;;
    --email|--certbot-email)
      CERTBOT_EMAIL="${2:-}"
      shift 2
      ;;
    --rotate-every-days)
      ROTATION_INTERVAL_DAYS="${2:-}"
      shift 2
      ;;
    --retention-days)
      DOMAIN_RETENTION_DAYS="${2:-}"
      shift 2
      ;;
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --github-ref)
      GITHUB_REF="${2:-}"
      shift 2
      ;;
    --local-dir)
      LOCAL_DIR="${2:-}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:-}"
      shift 2
      ;;
    --registrant-file)
      REGISTRANT_SRC="${2:-}"
      shift 2
      ;;
    --run-now)
      RUN_NOW=1
      shift
      ;;
    --skip-cron)
      SKIP_CRON=1
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES=1
      shift
      ;;
    --allow-non-root)
      ALLOW_NON_ROOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -n "${PREFIX}" ]]; then
  PREFIX="${PREFIX%/}"
  PROXIES_ROOT="${PREFIX}/opt/proxies"
  PROXIES_ETC="${PREFIX}/etc/proxies"
  PROXIES_STATE="${PREFIX}/var/lib/proxies"
fi

if [[ "${ALLOW_NON_ROOT}" -eq 0 ]]; then
  require_root
fi

# Skip OS check for prefix-based dry installs (e.g. component tests on a laptop).
if [[ -z "${PREFIX}" ]]; then
  require_ubuntu_2604
fi

[[ -n "${API_KEY}" ]] || die "--api-key is required"
[[ -n "${PASSWORD}" ]] || die "--password is required"
[[ ${#CLIENTS[@]} -gt 0 ]] || die "At least one --client NAME is required (or legacy --client-name)"
[[ -n "${CDN_ORIGIN}" ]] || die "--cdn-origin is required"
[[ -n "${BACKEND_ORIGIN}" ]] || die "--backend-origin is required"
[[ -n "${CERTBOT_EMAIL}" ]] || die "--email is required (used for Let's Encrypt and InternetBS registrant verification)"
if [[ ! "${ROTATION_INTERVAL_DAYS}" =~ ^[1-9][0-9]*$ ]] || [[ "${ROTATION_INTERVAL_DAYS}" -gt 365 ]]; then
  die "--rotate-every-days must be an integer from 1 to 365 (got: ${ROTATION_INTERVAL_DAYS})"
fi
if [[ ! "${DOMAIN_RETENTION_DAYS}" =~ ^[1-9][0-9]*$ ]] || [[ "${DOMAIN_RETENTION_DAYS}" -gt 365 ]]; then
  die "--retention-days must be an integer from 1 to 365 (got: ${DOMAIN_RETENTION_DAYS})"
fi

# Validate + dedupe client ids.
_VALID_CLIENTS=()
for CLIENT_NAME in "${CLIENTS[@]}"; do
  [[ -n "${CLIENT_NAME}" ]] || die "Empty --client value"
  if [[ ! "${CLIENT_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    die "Invalid --client '${CLIENT_NAME}' (use letters, digits, _ or -)"
  fi
  _dup=0
  for _c in "${_VALID_CLIENTS[@]+"${_VALID_CLIENTS[@]}"}"; do
    if [[ "${_c}" == "${CLIENT_NAME}" ]]; then
      _dup=1
      break
    fi
  done
  if [[ "${_dup}" -eq 0 ]]; then
    _VALID_CLIENTS+=("${CLIENT_NAME}")
  fi
done
CLIENTS=("${_VALID_CLIENTS[@]}")
CLIENT_NAME="${CLIENTS[0]}"

# Normalize to host[:port] without scheme/path.
CDN_ORIGIN="${CDN_ORIGIN#http://}"
CDN_ORIGIN="${CDN_ORIGIN#https://}"
CDN_ORIGIN="${CDN_ORIGIN%%/*}"
BACKEND_ORIGIN="${BACKEND_ORIGIN#http://}"
BACKEND_ORIGIN="${BACKEND_ORIGIN#https://}"
BACKEND_ORIGIN="${BACKEND_ORIGIN%%/*}"

if [[ -z "${LOCAL_DIR}" && -z "${BASE_URL}" ]]; then
  die "Provide --base-url (GitHub repo URL) or --local-dir"
fi

if [[ -z "${LOCAL_DIR}" ]]; then
  BASE_URL="$(resolve_package_base_url "${BASE_URL}" "${GITHUB_REF}")"
  BASE_URL="${BASE_URL%/}"
  log "Package download root: ${BASE_URL}"
fi

download_file() {
  local rel="$1"
  local dest="${PROXIES_ROOT}/${rel}"
  mkdir -p "$(dirname "${dest}")"
  log "Downloading ${rel}"
  curl -fsSL "${BASE_URL}/${rel}" -o "${dest}" \
    || die "Failed to download ${BASE_URL}/${rel}"
}

copy_local_file() {
  local rel="$1"
  local src="${LOCAL_DIR}/${rel}"
  local dest="${PROXIES_ROOT}/${rel}"
  mkdir -p "$(dirname "${dest}")"
  [[ -f "${src}" ]] || die "Missing local package file: ${src}"
  log "Copying ${rel}"
  cp "${src}" "${dest}"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx certbot curl jq ca-certificates openssl apache2-utils
  systemctl enable --now nginx
}

write_credentials() {
  mkdir -p "${PROXIES_ETC}" "${PROXIES_STATE}/domains" "${PROXIES_STATE}/urls" "${PROXIES_ETC}/clients"
  # Traversable by nginx; secret files below stay 600.
  chmod 755 "${PROXIES_ETC}" "${PROXIES_STATE}" "${PROXIES_STATE}/domains" "${PROXIES_STATE}/urls" "${PROXIES_ETC}/clients" 2>/dev/null || true
  cat >"${PROXIES_ETC}/credentials.env" <<EOF
INTERNETBS_API_KEY="${API_KEY}"
INTERNETBS_PASSWORD="${PASSWORD}"
CDN_ORIGIN="${CDN_ORIGIN}"
BACKEND_ORIGIN="${BACKEND_ORIGIN}"
CERTBOT_EMAIL="${CERTBOT_EMAIL}"
ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS}"
DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS}"
EOF
  chmod 600 "${PROXIES_ETC}/credentials.env"
  log "Wrote ${PROXIES_ETC}/credentials.env (rotate every ${ROTATION_INTERVAL_DAYS}d; retain ${DOMAIN_RETENTION_DAYS}d)"
}

install_clients() {
  local clients_dir="${PROXIES_ETC}/clients"
  local name dest
  mkdir -p "${clients_dir}"
  chmod 755 "${clients_dir}"
  for name in "${CLIENTS[@]}"; do
    dest="${clients_dir}/${name}.env"
    if [[ -f "${dest}" ]]; then
      log "Keeping existing ${dest}"
      continue
    fi
    if [[ ${#CLIENTS[@]} -eq 1 && -n "${CASINO_ID}" ]]; then
      printf 'CASINO_ID="%s"\n' "${CASINO_ID}" >"${dest}"
    elif [[ -f "${PROXIES_ROOT}/config/client.env.example" ]]; then
      cp "${PROXIES_ROOT}/config/client.env.example" "${dest}"
    else
      printf '# client %s\n' "${name}" >"${dest}"
    fi
    chmod 600 "${dest}"
    log "Wrote ${dest}"
  done
}

install_url_prefixes() {
  local client_dest="${PROXIES_ETC}/prefixes-client.env"
  local shared_dest="${PROXIES_ETC}/prefixes-shared.env"

  if [[ -f "${client_dest}" ]] && grep -q -- '-bgsp' "${client_dest}"; then
    sed -i 's/-bgsp//g' "${client_dest}"
    log "Removed -bgsp suffix from ${client_dest}"
  elif [[ -f "${client_dest}" ]] && grep -qE '__CLIENT__-(gc|gs)-prod' "${client_dest}"; then
    log "Keeping existing ${client_dest}"
  else
    cp "${PROXIES_ROOT}/config/prefixes-client.env.example" "${client_dest}"
    chmod 644 "${client_dest}"
    log "Wrote ${client_dest}"
  fi

  if [[ -f "${shared_dest}" ]] && grep -q 'lottery-api-instant\|tournaments-prod' "${shared_dest}"; then
    if ! grep -qx 'player-history-prod-bgsp' "${shared_dest}"; then
      printf '%s\n' "player-history-prod-bgsp" >>"${shared_dest}"
      log "Added player-history-prod-bgsp to ${shared_dest}"
    fi
    if ! grep -qx 'tournaments-prod-bgsp' "${shared_dest}"; then
      printf '%s\n' "tournaments-prod-bgsp" >>"${shared_dest}"
      log "Added tournaments-prod-bgsp to ${shared_dest}"
    fi
    log "Keeping existing ${shared_dest}"
  else
    cp "${PROXIES_ROOT}/config/prefixes-shared.env.example" "${shared_dest}"
    chmod 644 "${shared_dest}"
    log "Wrote ${shared_dest}"
  fi

  # Remove obsolete single-file mock map if present.
  if [[ -f "${PROXIES_ETC}/url-prefixes.env" ]]; then
    rm -f "${PROXIES_ETC}/url-prefixes.env"
    log "Removed obsolete ${PROXIES_ETC}/url-prefixes.env"
  fi
}

write_api_htpasswd() {
  local htpasswd_file="${PROXIES_ETC}/api.htpasswd"
  local nginx_user="www-data"
  if [[ -z "${API_USER}" || -z "${API_PASSWORD}" ]]; then
    if [[ -f "${htpasswd_file}" ]]; then
      log "Keeping existing ${htpasswd_file}"
      chmod 755 "${PROXIES_ETC}" 2>/dev/null || true
      if id "${nginx_user}" >/dev/null 2>&1; then
        chown "root:${nginx_user}" "${htpasswd_file}" 2>/dev/null || true
        chmod 640 "${htpasswd_file}"
      else
        chmod 644 "${htpasswd_file}"
      fi
      return
    fi
    die "--api-user and --api-password are required on first install (Basic Auth for /api/game/url-extended)"
  fi
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bBc "${htpasswd_file}" "${API_USER}" "${API_PASSWORD}"
  else
    # Fallback when apache2-utils is not installed (e.g. --skip-packages tests)
    local hash
    hash="$(openssl passwd -apr1 "${API_PASSWORD}")"
    printf '%s:%s\n' "${API_USER}" "${hash}" >"${htpasswd_file}"
  fi
  chmod 755 "${PROXIES_ETC}" 2>/dev/null || true
  if id "${nginx_user}" >/dev/null 2>&1; then
    chown "root:${nginx_user}" "${htpasswd_file}" 2>/dev/null || true
    chmod 640 "${htpasswd_file}"
  else
    chmod 644 "${htpasswd_file}"
  fi
  log "Wrote ${htpasswd_file} for user ${API_USER} (readable by nginx)"
}

install_registrant() {
  local dest="${PROXIES_ETC}/registrant.env"
  if [[ -n "${REGISTRANT_SRC}" ]]; then
    [[ -f "${REGISTRANT_SRC}" ]] || die "Registrant file not found: ${REGISTRANT_SRC}"
    cp "${REGISTRANT_SRC}" "${dest}"
    chmod 600 "${dest}"
    log "Installed registrant.env from ${REGISTRANT_SRC}"
  elif [[ -f "${dest}" ]]; then
    log "Keeping existing ${dest}"
  else
    cp "${PROXIES_ROOT}/config/registrant.env.example" "${dest}"
    chmod 600 "${dest}"
    log "Wrote placeholder ${dest} — edit WHOIS contact details before --run-now / first rotation"
  fi

  # Always align registrant email with Certbot email (InternetBS verification mailbox).
  if [[ -n "${CERTBOT_EMAIL}" && -f "${dest}" ]]; then
    local tmp
    tmp="$(mktemp)"
    if grep -q '^REGISTRANT_EMAIL=' "${dest}"; then
      # Portable replace (GNU/BSD sed -i differ).
      awk -v email="${CERTBOT_EMAIL}" '
        BEGIN { done=0 }
        /^REGISTRANT_EMAIL=/ {
          printf "REGISTRANT_EMAIL=\"%s\"\n", email
          done=1
          next
        }
        { print }
        END {
          if (!done) printf "\nREGISTRANT_EMAIL=\"%s\"\n", email
        }
      ' "${dest}" >"${tmp}"
      mv "${tmp}" "${dest}"
    else
      printf '\nREGISTRANT_EMAIL="%s"\n' "${CERTBOT_EMAIL}" >>"${dest}"
      rm -f "${tmp}"
    fi
    chmod 600 "${dest}"
    log "Set REGISTRANT_EMAIL=${CERTBOT_EMAIL} in ${dest} (same as Certbot)"
  fi
}

chmod_package() {
  chmod 755 \
    "${PROXIES_ROOT}/scripts/rotate-domain.sh" \
    "${PROXIES_ROOT}/scripts/force-rotate.sh" \
    "${PROXIES_ROOT}/scripts/manage-clients.sh" \
    "${PROXIES_ROOT}/scripts/cleanup.sh" \
    "${PROXIES_ROOT}/hooks/certbot-auth.sh" \
    "${PROXIES_ROOT}/hooks/certbot-cleanup.sh"
  find "${PROXIES_ROOT}/lib" -type f -name '*.sh' -exec chmod 644 {} \;
}

install_cron() {
  local cron_file="/etc/cron.d/proxies-domain-rotation"
  if [[ -n "${PREFIX}" ]]; then
    cron_file="${PREFIX}/etc/cron.d/proxies-domain-rotation"
    mkdir -p "$(dirname "${cron_file}")"
  fi
  cat >"${cron_file}" <<EOF
# Proxies domain rotation: runs daily at 03:00. Actual Domain/Create only when
# ROTATION_INTERVAL_DAYS has elapsed (see /etc/proxies/credentials.env).
# Incomplete purchases are always resumed; expired local domains are cleaned up.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root PROXIES_ROOT=${PROXIES_ROOT} /usr/bin/stdbuf -oL -eL ${PROXIES_ROOT}/scripts/rotate-domain.sh >>/var/log/proxies-rotate.log 2>&1
EOF
  chmod 644 "${cron_file}"
  log "Installed cron job ${cron_file} (daily 03:00 check; purchase every ${ROTATION_INTERVAL_DAYS} day(s))"
}

main() {
  if [[ -n "${LOCAL_DIR}" ]]; then
    LOCAL_DIR="$(cd "${LOCAL_DIR}" && pwd)"
    log "Installing proxies toolkit from local dir ${LOCAL_DIR}"
  else
    log "Installing proxies toolkit from ${BASE_URL}"
  fi
  mkdir -p "${PROXIES_ROOT}"

  local rel
  for rel in "${PACKAGE_FILES[@]}"; do
    if [[ -n "${LOCAL_DIR}" ]]; then
      copy_local_file "${rel}"
    else
      download_file "${rel}"
    fi
  done

  if [[ -n "${LOCAL_DIR}" && -f "${LOCAL_DIR}/install.sh" ]]; then
    cp "${LOCAL_DIR}/install.sh" "${PROXIES_ROOT}/install.sh"
    chmod 755 "${PROXIES_ROOT}/install.sh"
  elif [[ -z "${LOCAL_DIR}" ]]; then
    if curl -fsSL "${BASE_URL}/install.sh" -o "${PROXIES_ROOT}/install.sh" 2>/dev/null; then
      chmod 755 "${PROXIES_ROOT}/install.sh"
    fi
  fi

  if [[ -n "${LOCAL_DIR}" && -f "${LOCAL_DIR}/cleanup.sh" ]]; then
    cp "${LOCAL_DIR}/cleanup.sh" "${PROXIES_ROOT}/cleanup.sh"
    chmod 755 "${PROXIES_ROOT}/cleanup.sh"
  elif [[ -z "${LOCAL_DIR}" ]]; then
    if curl -fsSL "${BASE_URL}/cleanup.sh" -o "${PROXIES_ROOT}/cleanup.sh" 2>/dev/null; then
      chmod 755 "${PROXIES_ROOT}/cleanup.sh"
    fi
  fi

  chmod_package

  if [[ "${SKIP_PACKAGES}" -eq 0 ]]; then
    install_packages
  else
    log "Skipping apt package installation (--skip-packages)"
  fi

  write_credentials
  write_api_htpasswd
  install_clients
  install_registrant
  install_url_prefixes

  if [[ "${SKIP_CRON}" -eq 0 ]]; then
    install_cron
  fi

  log "Install complete. Package root: ${PROXIES_ROOT} (clients: ${CLIENTS[*]})"

  if [[ "${RUN_NOW}" -eq 1 ]]; then
    if [[ -z "${CERTBOT_EMAIL}" ]]; then
      die "CERTBOT_EMAIL missing from credentials; re-run install with --email"
    fi
    log "Running first domain rotation"
    PROXIES_ROOT="${PROXIES_ROOT}" \
      PROXIES_ETC="${PROXIES_ETC}" \
      PROXIES_STATE="${PROXIES_STATE}" \
      "${PROXIES_ROOT}/scripts/rotate-domain.sh"
  else
    cat <<EOF

Next steps:
  1. Edit ${PROXIES_ETC}/registrant.env contact details (email comes from --email / CERTBOT_EMAIL)
  2. Add/remove clients: ${PROXIES_ROOT}/scripts/manage-clients.sh add|remove|list|sync
  3. Force first domain now: ${PROXIES_ROOT}/scripts/force-rotate.sh
  4. Or re-run install with --run-now after registrant.env is filled
  5. Confirm InternetBS verification emails sent to the --email address
  6. Read: ${PROXIES_ROOT}/docs/CLIENT_GUIDE.md

Clients installed: ${CLIENTS[*]}
Domains stay configured for ${DOMAIN_RETENTION_DAYS} days (DOMAIN_RETENTION_DAYS under ${PROXIES_ETC}/credentials.env).
EOF
  fi
}

main
