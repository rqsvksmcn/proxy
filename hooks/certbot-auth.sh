#!/usr/bin/env bash
# Certbot DNS-01 auth hook: create _acme-challenge TXT via the configured registrar.
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
source "${PROXIES_ROOT}/lib/registrar.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/ssl.sh"

load_credentials
load_registrar

: "${CERTBOT_DOMAIN:?CERTBOT_DOMAIN not set}"
: "${CERTBOT_VALIDATION:?CERTBOT_VALIDATION not set}"

export REGISTRAR_ZONE="${CERTBOT_DOMAIN}"

# For wildcards CERTBOT_DOMAIN is the apex (example.com).
RECORD_NAME="_acme-challenge.${CERTBOT_DOMAIN}"

# Apex + wildcard each need their own TXT value present at the same time.
# Always ADD; do not wipe sibling challenge records.
log "Auth hook: adding TXT ${RECORD_NAME} (remaining=${CERTBOT_REMAINING_CHALLENGES:-?})"
registrar_dns_add "${RECORD_NAME}" "TXT" "${CERTBOT_VALIDATION}"

# Wait for propagation only after the last challenge record is in place.
if [[ "${CERTBOT_REMAINING_CHALLENGES:-0}" == "0" ]]; then
  local_wait="${DNS_PROPAGATION_SECONDS:-180}"
  local_poll=15
  local_elapsed=0
  log "Auth hook: waiting up to ${local_wait}s for DNS TXT propagation of ${RECORD_NAME}"

  while (( local_elapsed < local_wait )); do
    if public_dns_query TXT "${RECORD_NAME}" | tr -d '"' | grep -Fq "${CERTBOT_VALIDATION}"; then
      log "Auth hook: TXT visible via public DNS after ${local_elapsed}s"
      exit 0
    fi
    # Still NXDOMAIN for the whole zone? Keep waiting — LE will fail hard otherwise.
    if [[ -z "$(public_dns_query NS "${CERTBOT_DOMAIN}")" ]]; then
      log "Auth hook: apex still NXDOMAIN; waiting ${local_poll}s... (${local_elapsed}s/${local_wait}s)"
    else
      log "Auth hook: TXT not yet visible; waiting ${local_poll}s... (${local_elapsed}s/${local_wait}s)"
    fi
    sleep "${local_poll}"
    local_elapsed=$((local_elapsed + local_poll))
  done

  die "Auth hook: TXT ${RECORD_NAME} not visible in public DNS after ${local_wait}s (refusing LE validation)"
fi

exit 0
