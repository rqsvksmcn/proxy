#!/usr/bin/env bash
# Cloudflare Registrar + DNS helpers (https://api.cloudflare.com/client/v4).
# Requires: curl, jq, CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID
#
# Notes:
# - Registrar API is in beta; only a subset of TLDs are API-registerable.
# - A/AAAA records are created DNS-only (proxied=false) so this VM terminates TLS.

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
CF_CONNECT_TIMEOUT="${CF_CONNECT_TIMEOUT:-15}"
CF_MAX_TIME="${CF_MAX_TIME:-90}"
CF_REGISTER_POLL_SECONDS="${CF_REGISTER_POLL_SECONDS:-5}"
CF_REGISTER_POLL_MAX="${CF_REGISTER_POLL_MAX:-36}"
CF_ZONE_WAIT_SECONDS="${CF_ZONE_WAIT_SECONDS:-5}"
CF_ZONE_WAIT_MAX="${CF_ZONE_WAIT_MAX:-24}"

cloudflare_curl_args() {
  local args=(
    -sS
    --connect-timeout "${CF_CONNECT_TIMEOUT}"
    --max-time "${CF_MAX_TIME}"
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    -H "Content-Type: application/json"
  )
  printf '%s\n' "${args[@]}"
}

# cloudflare_request METHOD PATH [JSON_BODY]
# Prints response body on success (success=true). Dies otherwise.
# Sets CF_LAST_HTTP_CODE.
cloudflare_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response http_code body
  local curl_opts=()
  mapfile -t curl_opts < <(cloudflare_curl_args)

  log "Cloudflare ${method} ${path}"
  if [[ -n "${data}" ]]; then
    response="$(
      curl -f "${curl_opts[@]}" -w '\n%{http_code}' \
        -X "${method}" "${CF_API_BASE}${path}" \
        --data "${data}"
    )" || die "Cloudflare request failed: ${method} ${path}. Check CLOUDFLARE_API_TOKEN permissions (Registrar + Zone DNS), account billing, and default registrant contact."
  else
    response="$(
      curl -f "${curl_opts[@]}" -w '\n%{http_code}' \
        -X "${method}" "${CF_API_BASE}${path}"
    )" || die "Cloudflare request failed: ${method} ${path}. Check CLOUDFLARE_API_TOKEN permissions (Registrar + Zone DNS), account billing, and default registrant contact."
  fi

  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"
  CF_LAST_HTTP_CODE="${http_code}"
  export CF_LAST_HTTP_CODE

  # 201/202 are success for registration; most others use 200.
  if [[ ! "${http_code}" =~ ^(200|201|202)$ ]]; then
    die "Cloudflare HTTP ${http_code} for ${method} ${path}: ${body}"
  fi

  local ok
  ok="$(jq -r '.success // false' <<<"${body}")"
  if [[ "${ok}" != "true" ]]; then
    die "Cloudflare API error for ${method} ${path}: ${body}"
  fi

  printf '%s\n' "${body}"
}

# Soft request that does not die (for cleanup). Prints body or empty.
cloudflare_request_soft() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response http_code body
  local curl_opts=()
  mapfile -t curl_opts < <(cloudflare_curl_args)

  if [[ -n "${data}" ]]; then
    response="$(
      curl "${curl_opts[@]}" -w '\n%{http_code}' \
        -X "${method}" "${CF_API_BASE}${path}" \
        --data "${data}" 2>/dev/null || true
    )"
  else
    response="$(
      curl "${curl_opts[@]}" -w '\n%{http_code}' \
        -X "${method}" "${CF_API_BASE}${path}" 2>/dev/null || true
    )"
  fi
  [[ -n "${response}" ]] || return 1
  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"
  [[ "${http_code}" =~ ^(200|201|202)$ ]] || return 1
  [[ "$(jq -r '.success // false' <<<"${body}")" == "true" ]] || return 1
  printf '%s\n' "${body}"
}

cloudflare_dns_zone() {
  local zone="${REGISTRAR_ZONE:-${CERTBOT_DOMAIN:-${DOMAIN:-}}}"
  [[ -n "${zone}" ]] || die "Cloudflare DNS zone unknown (set REGISTRAR_ZONE or CERTBOT_DOMAIN)"
  printf '%s\n' "${zone}"
}

# Resolve Cloudflare zone id for a domain name; empty if not found.
cloudflare_zone_id_lookup() {
  local domain="$1"
  local json
  json="$(cloudflare_request GET "/zones?name=${domain}&status=active")"
  jq -r '.result[0].id // empty' <<<"${json}"
}

cloudflare_ensure_zone_id() {
  local domain="$1"
  local zid attempt

  zid="$(cloudflare_zone_id_lookup "${domain}")"
  if [[ -n "${zid}" ]]; then
    printf '%s\n' "${zid}"
    return 0
  fi

  log "Zone for ${domain} not found yet; creating Cloudflare zone"
  cloudflare_request POST "/zones" "$(
    jq -nc --arg name "${domain}" --arg aid "${CLOUDFLARE_ACCOUNT_ID}" \
      '{name: $name, account: {id: $aid}, type: "full", jump_start: false}'
  )" >/dev/null || true

  for ((attempt = 1; attempt <= CF_ZONE_WAIT_MAX; attempt++)); do
    zid="$(cloudflare_zone_id_lookup "${domain}")"
    if [[ -n "${zid}" ]]; then
      log "Cloudflare zone ready: ${domain} id=${zid}"
      printf '%s\n' "${zid}"
      return 0
    fi
    log "Waiting for Cloudflare zone ${domain} (${attempt}/${CF_ZONE_WAIT_MAX})"
    sleep "${CF_ZONE_WAIT_SECONDS}"
  done
  die "Cloudflare zone for ${domain} did not appear. Ensure the domain registered under this account and the API token can manage Zone DNS."
}

cloudflare_domain_available() {
  local domain="$1"
  local json entry registrable reason tier

  json="$(cloudflare_request POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/registrar/domain-check" \
    "$(jq -nc --arg d "${domain}" '{domains: [$d]}')")"

  entry="$(jq -c --arg d "${domain}" '
    (.result.domains // [])[] | select(.name == $d) // empty
  ' <<<"${json}" | head -n1)"

  [[ -n "${entry}" ]] || {
    log "Cloudflare domain-check returned no entry for ${domain}: ${json}"
    return 1
  }

  registrable="$(jq -r '.registrable // false' <<<"${entry}")"
  reason="$(jq -r '.reason // empty' <<<"${entry}")"
  tier="$(jq -r '.tier // empty' <<<"${entry}")"

  if [[ "${registrable}" == "true" ]]; then
    if [[ "${tier}" == "premium" ]]; then
      log "Domain ${domain} is premium; Cloudflare Registrar API does not support premium purchase yet"
      return 1
    fi
    CF_LAST_CHECK_JSON="${entry}"
    export CF_LAST_CHECK_JSON
    return 0
  fi

  case "${reason}" in
    extension_not_supported_via_api|extension_not_supported|extension_disallows_registration)
      die "Cloudflare cannot register '.${DOMAIN_TLD:-?}' via API (${reason}). Pick another --tld or use --registrar internetbs|porkbun."
      ;;
  esac
  log "Domain not registrable via Cloudflare: ${domain} reason=${reason:-unknown}"
  return 1
}

cloudflare_wait_registration() {
  local domain="$1"
  local attempt json state

  for ((attempt = 1; attempt <= CF_REGISTER_POLL_MAX; attempt++)); do
    json="$(cloudflare_request GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/registrar/registrations/${domain}/registration-status")"
    state="$(jq -r '.result.state // empty' <<<"${json}")"
    case "${state}" in
      succeeded)
        log "Cloudflare registration succeeded for ${domain}"
        return 0
        ;;
      failed|blocked|action_required)
        die "Cloudflare registration ${state} for ${domain}: ${json}"
        ;;
      in_progress|"")
        log "Cloudflare registration in progress for ${domain} (${attempt}/${CF_REGISTER_POLL_MAX})"
        sleep "${CF_REGISTER_POLL_SECONDS}"
        ;;
      *)
        log "Cloudflare registration state=${state} for ${domain}; continuing to poll"
        sleep "${CF_REGISTER_POLL_SECONDS}"
        ;;
    esac
  done
  die "Timed out waiting for Cloudflare registration of ${domain}"
}

cloudflare_register_domain() {
  local domain="$1"
  local json state http

  log "Verifying ${domain} is still available before Cloudflare purchase"
  if ! cloudflare_domain_available "${domain}"; then
    die "Refusing to purchase ${domain}: Cloudflare domain-check did not report registrable"
  fi
  log "Availability confirmed for ${domain}; proceeding with Cloudflare registration"

  # Allow 201 sync or 202 async without curl -f aborting on 202 — use soft path then validate.
  local curl_opts=() response body
  mapfile -t curl_opts < <(cloudflare_curl_args)
  response="$(
    curl "${curl_opts[@]}" -w '\n%{http_code}' \
      -X POST "${CF_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/registrar/registrations" \
      --data "$(jq -nc --arg d "${domain}" '{domain_name: $d, auto_renew: false, privacy_mode: "redaction"}')"
  )" || die "Cloudflare registration request failed for ${domain}"

  http="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"
  CF_LAST_HTTP_CODE="${http}"

  if [[ ! "${http}" =~ ^(200|201|202)$ ]]; then
    die "Cloudflare registration HTTP ${http} for ${domain}: ${body}"
  fi
  if [[ "$(jq -r '.success // false' <<<"${body}")" != "true" ]]; then
    die "Cloudflare registration error for ${domain}: ${body}"
  fi

  state="$(jq -r '.result.state // empty' <<<"${body}")"
  if [[ "${state}" == "succeeded" || "$(jq -r '.result.completed // false' <<<"${body}")" == "true" ]]; then
    log "Registered domain ${domain} via Cloudflare (state=${state})"
  else
    log "Cloudflare registration accepted for ${domain} (HTTP ${http}, state=${state}); polling"
    cloudflare_wait_registration "${domain}"
  fi

  # Ensure DNS zone exists for subsequent A/TXT records.
  cloudflare_ensure_zone_id "${domain}" >/dev/null
}

# List DNS record ids matching name+type, optionally content.
cloudflare_dns_list_ids() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local content="${4:-}"
  local json enc_name

  enc_name="$(jq -nr --arg n "${name}" '$n|@uri')"
  json="$(cloudflare_request_soft GET "/zones/${zone_id}/dns_records?type=${type}&name=${enc_name}&per_page=100" || true)"
  [[ -n "${json}" ]] || return 0

  if [[ -n "${content}" ]]; then
    jq -r --arg c "${content}" '
      (.result // [])[]
      | select((.content // "") == $c)
      | .id
    ' <<<"${json}"
  else
    jq -r '(.result // [])[].id // empty' <<<"${json}"
  fi
}

cloudflare_dns_add() {
  local full_name="$1"
  local type="$2"
  local value="$3"
  local zone zone_id payload

  zone="$(cloudflare_dns_zone)"
  zone_id="$(cloudflare_ensure_zone_id "${zone}")"

  # Replace existing A/AAAA at this name; keep sibling TXT values for ACME.
  if [[ "${type}" == "A" || "${type}" == "AAAA" ]]; then
    cloudflare_dns_remove "${full_name}" "${type}" || true
  fi

  if [[ "${type}" == "A" || "${type}" == "AAAA" ]]; then
    payload="$(
      jq -nc \
        --arg type "${type}" \
        --arg name "${full_name}" \
        --arg content "${value}" \
        '{type: $type, name: $name, content: $content, ttl: 120, proxied: false}'
    )"
  else
    payload="$(
      jq -nc \
        --arg type "${type}" \
        --arg name "${full_name}" \
        --arg content "${value}" \
        '{type: $type, name: $name, content: $content, ttl: 120}'
    )"
  fi

  cloudflare_request POST "/zones/${zone_id}/dns_records" "${payload}" >/dev/null
  log "DNS ${type} ${full_name} -> ${value} (cloudflare, dns-only)"
}

cloudflare_dns_remove() {
  local full_name="$1"
  local type="$2"
  local value="${3:-}"
  local zone zone_id id

  zone="$(cloudflare_dns_zone)"
  zone_id="$(cloudflare_zone_id_lookup "${zone}")"
  [[ -n "${zone_id}" ]] || {
    log "DNS remove skipped; no zone for ${zone}"
    return 0
  }

  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    cloudflare_request_soft DELETE "/zones/${zone_id}/dns_records/${id}" >/dev/null || true
    log "DNS remove ${type} ${full_name} id=${id}"
  done < <(cloudflare_dns_list_ids "${zone_id}" "${full_name}" "${type}" "${value}")
}

cloudflare_point_domain_to_ip() {
  local domain="$1"
  local ip="$2"
  export REGISTRAR_ZONE="${domain}"
  cloudflare_ensure_zone_id "${domain}" >/dev/null
  cloudflare_dns_add "${domain}" "A" "${ip}"
  cloudflare_dns_add "*.${domain}" "A" "${ip}"
}
