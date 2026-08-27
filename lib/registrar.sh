#!/usr/bin/env bash
# Registrar dispatch: InternetBS, Porkbun, or Cloudflare.
# Source after lib/common.sh. Loads the active provider and exposes generic helpers.

# Call after load_credentials (or once REGISTRAR / keys are in the environment).
load_registrar() {
  REGISTRAR="$(printf '%s' "${REGISTRAR:-internetbs}" | tr '[:upper:]' '[:lower:]')"
  DOMAIN_TLD="$(normalize_domain_tld "${DOMAIN_TLD:-com}")"
  export REGISTRAR DOMAIN_TLD

  case "${REGISTRAR}" in
    internetbs)
      [[ -n "${INTERNETBS_API_KEY:-}" ]] || die "INTERNETBS_API_KEY is not set"
      [[ -n "${INTERNETBS_PASSWORD:-}" ]] || die "INTERNETBS_PASSWORD is not set"
      # shellcheck disable=SC1091
      source "${PROXIES_ROOT}/lib/internetbs.sh"
      ;;
    porkbun)
      [[ -n "${PORKBUN_API_KEY:-}" ]] || die "PORKBUN_API_KEY is not set"
      [[ -n "${PORKBUN_SECRET_API_KEY:-}" ]] || die "PORKBUN_SECRET_API_KEY is not set"
      # shellcheck disable=SC1091
      source "${PROXIES_ROOT}/lib/porkbun.sh"
      ;;
    cloudflare)
      [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN is not set"
      [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || die "CLOUDFLARE_ACCOUNT_ID is not set"
      # shellcheck disable=SC1091
      source "${PROXIES_ROOT}/lib/cloudflare.sh"
      ;;
    *)
      die "Unsupported REGISTRAR='${REGISTRAR}' (use internetbs, porkbun, or cloudflare)"
      ;;
  esac
  log "Registrar=${REGISTRAR}; domain suffix=.${DOMAIN_TLD}"
}

registrar_needs_registrant() {
  [[ "${REGISTRAR}" == "internetbs" ]]
}

registrar_domain_available() {
  case "${REGISTRAR}" in
    internetbs) internetbs_domain_available "$@" ;;
    porkbun) porkbun_domain_available "$@" ;;
    cloudflare) cloudflare_domain_available "$@" ;;
  esac
}

registrar_register_domain() {
  case "${REGISTRAR}" in
    internetbs) internetbs_register_domain "$@" ;;
    porkbun) porkbun_register_domain "$@" ;;
    cloudflare) cloudflare_register_domain "$@" ;;
  esac
}

registrar_dns_add() {
  case "${REGISTRAR}" in
    internetbs) internetbs_dns_add "$@" ;;
    porkbun) porkbun_dns_add "$@" ;;
    cloudflare) cloudflare_dns_add "$@" ;;
  esac
}

registrar_dns_remove() {
  case "${REGISTRAR}" in
    internetbs) internetbs_dns_remove "$@" ;;
    porkbun) porkbun_dns_remove "$@" ;;
    cloudflare) cloudflare_dns_remove "$@" ;;
  esac
}

registrar_point_domain_to_ip() {
  local domain="$1"
  local ip="$2"
  export REGISTRAR_ZONE="${domain}"
  case "${REGISTRAR}" in
    internetbs) internetbs_point_domain_to_ip "${domain}" "${ip}" ;;
    porkbun) porkbun_point_domain_to_ip "${domain}" "${ip}" ;;
    cloudflare) cloudflare_point_domain_to_ip "${domain}" "${ip}" ;;
  esac
}

find_available_domain() {
  local max_attempts="${1:-30}"
  local attempt label domain
  local tld="${DOMAIN_TLD:-com}"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    label="$(random_label 20)"
    domain="${label}.${tld}"
    log "Checking availability for ${domain} (attempt ${attempt}/${max_attempts}, registrar=${REGISTRAR})"
    if registrar_domain_available "${domain}"; then
      log "Domain available: ${domain}"
      printf '%s\n' "${domain}"
      return 0
    fi
    log "Domain not available: ${domain}"
    # Porkbun checkDomain is rate-limited (~1 / 10s).
    if [[ "${REGISTRAR}" == "porkbun" && "${attempt}" -lt "${max_attempts}" ]]; then
      sleep "${PORKBUN_CHECK_SLEEP_SECONDS:-11}"
    fi
  done
  die "Unable to find an available .${tld} domain after ${max_attempts} attempts"
}
