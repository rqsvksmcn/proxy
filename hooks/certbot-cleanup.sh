#!/usr/bin/env bash
# Certbot DNS-01 cleanup hook: remove _acme-challenge TXT via the configured registrar.
# Keep stdout/stderr clean for Certbot (see certbot-auth.sh).
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/registrar.sh"

load_credentials
load_registrar

: "${CERTBOT_DOMAIN:?CERTBOT_DOMAIN not set}"
: "${CERTBOT_VALIDATION:?CERTBOT_VALIDATION not set}"

export REGISTRAR_ZONE="${CERTBOT_DOMAIN}"
RECORD_NAME="_acme-challenge.${CERTBOT_DOMAIN}"

log "Cleanup hook: removing TXT ${RECORD_NAME}"
registrar_dns_remove "${RECORD_NAME}" "TXT" "${CERTBOT_VALIDATION}" || true
exit 0
