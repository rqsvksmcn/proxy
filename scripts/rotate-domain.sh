#!/usr/bin/env bash
# Daily domain rotation: register new domain, DNS, wildcard cert, nginx vhosts.
# Existing domains remain reachable until older than DOMAIN_RETENTION_DAYS (default 14).
#
# If a previous run purchased a domain but failed later (e.g. SSL), the next run
# resumes that domain instead of buying a new one.
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"

# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/registrar.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/ssl.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/nginx.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/urls.sh"

usage() {
  cat <<'EOF'
Usage: rotate-domain.sh [options]

Registers a new random domain (suffix from DOMAIN_TLD), configures DNS + wildcard SSL + nginx.
If a prior purchase was incomplete, resumes that domain (no new spend).

Options:
  --api-key KEY           Registrar API key (optional if credentials.env exists)
  --password PASS         InternetBS password / Porkbun secret (optional)
  --api-secret SECRET     Alias for Porkbun secret API key
  --client-name NAME      Client name
  --resume-domain NAME    Resume setup for an already-purchased domain
  --force-new             Buy a new domain even if an incomplete one exists
  --skip-cleanup          Do not remove domains older than retention window
  --cleanup-only          Only remove expired local domain configs/certs
  -h, --help              Show this help
EOF
}

SKIP_CLEANUP=0
CLEANUP_ONLY=0
FORCE_NEW=0
RESUME_DOMAIN=""
CLI_API_KEY=""
CLI_PASSWORD=""
CLI_API_SECRET=""
CLI_CLIENT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)
      CLI_API_KEY="${2:-}"
      shift 2
      ;;
    --password)
      CLI_PASSWORD="${2:-}"
      shift 2
      ;;
    --api-secret)
      CLI_API_SECRET="${2:-}"
      shift 2
      ;;
    --client-name)
      CLI_CLIENT_NAME="${2:-}"
      shift 2
      ;;
    --resume-domain)
      RESUME_DOMAIN="${2:-}"
      shift 2
      ;;
    --force-new)
      FORCE_NEW=1
      shift
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=1
      shift
      ;;
    --cleanup-only)
      CLEANUP_ONLY=1
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

require_root
require_ubuntu_2604
ensure_runtime_dirs

if [[ -n "${CLI_API_KEY}" || -n "${CLI_PASSWORD}" || -n "${CLI_API_SECRET}" || -n "${CLI_CLIENT_NAME}" ]]; then
  mkdir -p "${PROXIES_ETC}"
  # Preserve existing origins/email when only overriding a subset via CLI.
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    source "${CREDENTIALS_FILE}"
    set +a
  fi
  REGISTRAR="$(printf '%s' "${REGISTRAR:-internetbs}" | tr '[:upper:]' '[:lower:]')"
  DOMAIN_TLD="$(normalize_domain_tld "${DOMAIN_TLD:-com}")"
  secret="${CLI_API_SECRET:-${CLI_PASSWORD:-}}"
  cat >"${CREDENTIALS_FILE}" <<EOF
REGISTRAR="${REGISTRAR}"
DOMAIN_TLD="${DOMAIN_TLD}"
CDN_ORIGIN="${CDN_ORIGIN:-}"
BACKEND_ORIGIN="${BACKEND_ORIGIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS:-1}"
DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS:-14}"
EOF
  if [[ "${REGISTRAR}" == "porkbun" ]]; then
    cat >>"${CREDENTIALS_FILE}" <<EOF
PORKBUN_API_KEY="${CLI_API_KEY:-${PORKBUN_API_KEY:-}}"
PORKBUN_SECRET_API_KEY="${secret:-${PORKBUN_SECRET_API_KEY:-}}"
EOF
  elif [[ "${REGISTRAR}" == "cloudflare" ]]; then
    cat >>"${CREDENTIALS_FILE}" <<EOF
CLOUDFLARE_API_TOKEN="${CLI_API_KEY:-${CLOUDFLARE_API_TOKEN:-}}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
EOF
  else
    cat >>"${CREDENTIALS_FILE}" <<EOF
INTERNETBS_API_KEY="${CLI_API_KEY:-${INTERNETBS_API_KEY:-}}"
INTERNETBS_PASSWORD="${CLI_PASSWORD:-${INTERNETBS_PASSWORD:-}}"
EOF
  fi
  chmod 600 "${CREDENTIALS_FILE}"
  if [[ -n "${CLI_CLIENT_NAME}" ]]; then
    mkdir -p "${CLIENTS_DIR}"
    if [[ ! -f "${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env" ]]; then
      printf '# Added via rotate-domain.sh --client-name\n' >"${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env"
      chmod 600 "${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env"
      log "Created ${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env"
    fi
  fi
fi

load_credentials
load_registrar
if registrar_needs_registrant; then
  load_registrant
fi
ensure_prefix_files

if [[ "${CLEANUP_ONLY}" -eq 1 ]]; then
  cleanup_expired_domains
  exit 0
fi

ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS:-1}"
DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS:-14}"
log "Starting domain rotation for clients=${CLIENT_NAMES[*]} (registrar=${REGISTRAR}; tld=.${DOMAIN_TLD}; interval=${ROTATION_INTERVAL_DAYS}d; retention=${DOMAIN_RETENTION_DAYS}d)"

PUBLIC_IP="$(detect_public_ip)"
log "Detected public IP: ${PUBLIC_IP}"

DOMAIN=""
RESUME=0
STATUS=""

if [[ -n "${RESUME_DOMAIN}" ]]; then
  DOMAIN="${RESUME_DOMAIN}"
  RESUME=1
  STATUS="$(get_domain_status "${DOMAIN}")"
  [[ -n "${STATUS}" ]] || STATUS="${DOMAIN_STATUS_PURCHASED}"
  set_domain_status "${DOMAIN}" "${STATUS}"
  set_pending_domain "${DOMAIN}"
  log "Resuming explicit domain ${DOMAIN} (status=${STATUS})"
elif [[ "${FORCE_NEW}" -eq 0 ]] && DOMAIN="$(find_incomplete_domain)"; then
  RESUME=1
  STATUS="$(get_domain_status "${DOMAIN}")"
  [[ -n "${STATUS}" ]] || STATUS="${DOMAIN_STATUS_PURCHASED}"
  log "Found incomplete domain ${DOMAIN} (status=${STATUS}); resuming instead of purchasing a new one"
else
  # New purchase path: honor ROTATION_INTERVAL_DAYS unless force-rotate / --force-new.
  if [[ "${FORCE_ROTATION:-0}" -eq 0 && "${FORCE_NEW}" -eq 0 ]] && rotation_interval_not_elapsed; then
    log "Skipping scheduled purchase: current domain is within ROTATION_INTERVAL_DAYS=${ROTATION_INTERVAL_DAYS}"
    if [[ "${SKIP_CLEANUP}" -eq 0 ]]; then
      cleanup_expired_domains
    fi
    exit 0
  fi
  log "Searching for an available random .${DOMAIN_TLD} via ${REGISTRAR}"
  DOMAIN="$(find_available_domain 30)"
  log "Selected available domain: ${DOMAIN}"
  registrar_register_domain "${DOMAIN}"
  mark_domain_purchased "${DOMAIN}"
  STATUS="${DOMAIN_STATUS_PURCHASED}"
fi

export REGISTRAR_ZONE="${DOMAIN}"

# --- DNS ---
if [[ "${STATUS}" == "${DOMAIN_STATUS_PURCHASED}" ]]; then
  registrar_point_domain_to_ip "${DOMAIN}" "${PUBLIC_IP}"
  mark_domain_dns_configured "${DOMAIN}"
  STATUS="${DOMAIN_STATUS_DNS}"
  log "Waiting briefly for DNS zone to settle before ACME challenge"
  sleep 30
elif [[ "${STATUS}" == "${DOMAIN_STATUS_DNS}" || "${STATUS}" == "${DOMAIN_STATUS_SSL}" ]]; then
  log "Re-asserting DNS A records for ${DOMAIN} -> ${PUBLIC_IP}"
  registrar_point_domain_to_ip "${DOMAIN}" "${PUBLIC_IP}" || true
fi

# --- SSL ---
if [[ "${STATUS}" == "${DOMAIN_STATUS_DNS}" ]]; then
  ensure_certbot_renewal_hooks
  issue_wildcard_certificate "${DOMAIN}"
  mark_domain_ssl_issued "${DOMAIN}"
  STATUS="${DOMAIN_STATUS_SSL}"
elif [[ "${STATUS}" == "${DOMAIN_STATUS_SSL}" ]]; then
  ensure_certbot_renewal_hooks
  issue_wildcard_certificate "${DOMAIN}"
fi

# --- nginx + API JSON ---
install_websocket_map
install_server_names_hash
enable_domain_sites "${DOMAIN}"
ensure_url_prefixes_file
write_current_urls_json "${DOMAIN}"
render_api_ip_vhost
nginx_test_and_reload

mark_domain_active "${DOMAIN}"
log "Domain ${DOMAIN} is active and will remain reachable for ${DOMAIN_RETENTION_DAYS} days"
log "Query current URLs: curl -u USER:PASS http://${PUBLIC_IP}/api/game/url-extended/<client>"

if [[ "${SKIP_CLEANUP}" -eq 0 ]]; then
  cleanup_expired_domains
fi

if [[ "${RESUME}" -eq 1 ]]; then
  log "Resume complete: ${DOMAIN}"
else
  log "Rotation complete: ${DOMAIN}"
fi
printf '%s\n' "${DOMAIN}"
