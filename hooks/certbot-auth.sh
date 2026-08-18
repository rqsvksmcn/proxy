#!/usr/bin/env bash
# Certbot DNS-01 auth hook: create _acme-challenge TXT via InternetBS.
#
# IMPORTANT: Keep stdout/stderr clean. Certbot treats stderr from this hook
# as failure ("ran with error output"). Logging goes to
# /var/log/proxies-certbot-hooks.log via lib/common.sh when CERTBOT_DOMAIN is set.
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/internetbs.sh"

load_credentials

: "${CERTBOT_DOMAIN:?CERTBOT_DOMAIN not set}"
: "${CERTBOT_VALIDATION:?CERTBOT_VALIDATION not set}"

# For wildcards CERTBOT_DOMAIN is the apex (example.com).
RECORD_NAME="_acme-challenge.${CERTBOT_DOMAIN}"

# Apex + wildcard each need their own TXT value present at the same time.
# Always ADD; do not wipe sibling challenge records.
log "Auth hook: adding TXT ${RECORD_NAME} (remaining=${CERTBOT_REMAINING_CHALLENGES:-?})"
internetbs_dns_add "${RECORD_NAME}" "TXT" "${CERTBOT_VALIDATION}"

# Wait for propagation only after the last challenge record is in place.
if [[ "${CERTBOT_REMAINING_CHALLENGES:-0}" == "0" ]]; then
  local_wait="${DNS_PROPAGATION_SECONDS:-120}"
  log "Auth hook: waiting ${local_wait}s for DNS TXT propagation"
  sleep "${local_wait}"

  # Best-effort visibility check (does not fail the hook if dig is missing).
  if command -v dig >/dev/null 2>&1; then
    if dig +short TXT "${RECORD_NAME}" @8.8.8.8 | grep -Fq "${CERTBOT_VALIDATION}"; then
      log "Auth hook: TXT visible via 8.8.8.8"
    else
      log "Auth hook: TXT not yet visible via 8.8.8.8; Certbot will retry validation"
    fi
  fi
fi

exit 0
