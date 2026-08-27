#!/usr/bin/env bash
# Porkbun API helpers (https://api.porkbun.com/api/json/v3).
# Requires: curl, jq, PORKBUN_API_KEY, PORKBUN_SECRET_API_KEY
#
# Errors: functions return non-zero and set PORKBUN_LAST_ERROR / PORKBUN_LAST_BODY.
# Do not call die() from inside $(...); callers should use:
#   json="$(porkbun_request ...)" || die "Porkbun: ${PORKBUN_LAST_ERROR}"

PORKBUN_API_BASE="${PORKBUN_API_BASE:-https://api.porkbun.com/api/json/v3}"
PORKBUN_CURL_INSECURE="${PORKBUN_CURL_INSECURE:-0}"
PORKBUN_CONNECT_TIMEOUT="${PORKBUN_CONNECT_TIMEOUT:-15}"
PORKBUN_MAX_TIME="${PORKBUN_MAX_TIME:-60}"
# Domain check default limit is 1 / 10s; wait between availability probes.
PORKBUN_CHECK_SLEEP_SECONDS="${PORKBUN_CHECK_SLEEP_SECONDS:-11}"

PORKBUN_LAST_ERROR=""
PORKBUN_LAST_BODY=""

porkbun_curl_args() {
  local args=(
    -sS
    --connect-timeout "${PORKBUN_CONNECT_TIMEOUT}"
    --max-time "${PORKBUN_MAX_TIME}"
    -H "Content-Type: application/json"
  )
  if [[ "${PORKBUN_CURL_INSECURE}" == "1" ]]; then
    args+=(-k)
  fi
  printf '%s\n' "${args[@]}"
}

porkbun_require_keys() {
  if [[ -z "${PORKBUN_API_KEY:-}" || -z "${PORKBUN_SECRET_API_KEY:-}" ]]; then
    PORKBUN_LAST_ERROR="PORKBUN_API_KEY and PORKBUN_SECRET_API_KEY must both be set (pk1_… and sk1_…)"
    return 1
  fi
  # Trim accidental whitespace/CR from credentials.env edits.
  PORKBUN_API_KEY="$(printf '%s' "${PORKBUN_API_KEY}" | tr -d '\r\n[:space:]')"
  PORKBUN_SECRET_API_KEY="$(printf '%s' "${PORKBUN_SECRET_API_KEY}" | tr -d '\r\n[:space:]')"
  export PORKBUN_API_KEY PORKBUN_SECRET_API_KEY
  if [[ "${PORKBUN_API_KEY}" == "${PORKBUN_SECRET_API_KEY}" ]]; then
    PORKBUN_LAST_ERROR="API key and secret are identical — use pk1_… for --api-key and sk1_… for --api-secret"
    return 1
  fi
}

# POST JSON to path; merge extra object fields into the auth body.
# Optional Idempotency-Key via PORKBUN_IDEMPOTENCY_KEY.
# On success: prints body, sets PORKBUN_LAST_BODY, returns 0.
# On failure: sets PORKBUN_LAST_ERROR, returns 1 (safe inside $(...)).
porkbun_request() {
  local path="$1"
  local extra_json="${2:-{}}"
  local body response http_code
  local curl_opts=()

  PORKBUN_LAST_ERROR=""
  PORKBUN_LAST_BODY=""

  porkbun_require_keys || return 1

  # Validate extra JSON early (empty → {}).
  [[ -n "${extra_json}" ]] || extra_json='{}'
  if ! jq -ne --argjson x "${extra_json}" '$x | type == "object"' >/dev/null 2>&1; then
    PORKBUN_LAST_ERROR="Invalid JSON body for ${path}: ${extra_json}"
    return 1
  fi

  # Single jq build — avoid nested --argjson "$(...)" which broke on some hosts.
  if ! body="$(
    jq -nc \
      --arg key "${PORKBUN_API_KEY}" \
      --arg secret "${PORKBUN_SECRET_API_KEY}" \
      --argjson extra "${extra_json}" \
      '{apikey: $key, secretapikey: $secret} + $extra'
  )"; then
    PORKBUN_LAST_ERROR="Failed to build Porkbun JSON body for ${path}"
    return 1
  fi

  mapfile -t curl_opts < <(porkbun_curl_args)
  log "Porkbun request: ${PORKBUN_API_BASE}${path}"

  local headers=()
  if [[ -n "${PORKBUN_IDEMPOTENCY_KEY:-}" ]]; then
    headers+=(-H "Idempotency-Key: ${PORKBUN_IDEMPOTENCY_KEY}")
  fi

  # Do not use curl -f — we need the error body for 400 diagnostics.
  response="$(
    curl "${curl_opts[@]}" -w '\n%{http_code}' \
      -X POST "${PORKBUN_API_BASE}${path}" \
      "${headers[@]}" \
      --data "${body}"
  )" || {
    PORKBUN_LAST_ERROR="curl failed talking to ${PORKBUN_API_BASE}${path}"
    return 1
  }

  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"
  PORKBUN_LAST_BODY="${body}"

  if [[ "${http_code}" != "200" ]]; then
    PORKBUN_LAST_ERROR="HTTP ${http_code} for ${path}: ${body}"
    return 1
  fi

  local status
  status="$(jq -r '.status // empty' <<<"${body}" 2>/dev/null || true)"
  if [[ "$(printf '%s' "${status}" | tr '[:lower:]' '[:upper:]')" != "SUCCESS" ]]; then
    PORKBUN_LAST_ERROR="API status='${status}' for ${path}: ${body}"
    return 1
  fi

  printf '%s\n' "${body}"
}

# Zone apex for relative DNS names (set by rotate / certbot).
porkbun_dns_zone() {
  local zone="${REGISTRAR_ZONE:-${CERTBOT_DOMAIN:-${DOMAIN:-}}}"
  [[ -n "${zone}" ]] || die "Porkbun DNS zone unknown (set REGISTRAR_ZONE or CERTBOT_DOMAIN)"
  printf '%s\n' "${zone}"
}

# full_name under zone -> Porkbun "name" (subdomain only; blank = apex).
porkbun_subdomain_from_full() {
  local full="$1"
  local zone="$2"
  if [[ "${full}" == "${zone}" ]]; then
    printf ''
  elif [[ "${full}" == "*.${zone}" ]]; then
    printf '*'
  elif [[ "${full}" == *".${zone}" ]]; then
    printf '%s' "${full%.${zone}}"
  else
    die "DNS name '${full}' is not under zone '${zone}'"
  fi
}

porkbun_domain_available() {
  local domain="$1"
  local json avail

  if ! json="$(porkbun_request "/domain/checkDomain/${domain}" '{}')"; then
    die "Porkbun checkDomain failed for ${domain}: ${PORKBUN_LAST_ERROR}"
  fi

  avail="$(jq -r '.response.avail // .avail // empty' <<<"${json}")"
  case "$(printf '%s' "${avail}" | tr '[:upper:]' '[:lower:]')" in
    yes|available|true|1)
      PORKBUN_LAST_PRICE_USD="$(jq -r '
        .response.price.registration
        // .response.price
        // .price.registration
        // .price
        // empty
      ' <<<"${json}")"
      # price may be a nested object in newer API shapes
      if [[ -z "${PORKBUN_LAST_PRICE_USD}" || "${PORKBUN_LAST_PRICE_USD}" == "null" ]]; then
        PORKBUN_LAST_PRICE_USD="$(jq -r '
          .response.price.registration // empty
        ' <<<"${json}")"
      fi
      # If jq returned a JSON object, try .registration inside it as string via tostring paths
      if [[ "${PORKBUN_LAST_PRICE_USD}" == \{* ]]; then
        PORKBUN_LAST_PRICE_USD="$(jq -r '.registration // .renew // empty' <<<"${PORKBUN_LAST_PRICE_USD}")"
      fi
      export PORKBUN_LAST_PRICE_USD
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Convert USD price string/number to integer cents.
porkbun_usd_to_cents() {
  local usd="$1"
  [[ -n "${usd}" && "${usd}" != "null" ]] || die "Porkbun registration price missing"
  awk -v p="${usd}" 'BEGIN {
    if (p ~ /^[0-9]+$/) { printf "%d\n", p * 100; exit }
    printf "%d\n", int(p * 100 + 0.5)
  }'
}

porkbun_register_domain() {
  local domain="$1"
  local json cost_cents idem extra

  log "Verifying ${domain} is still available before Porkbun purchase"
  if ! porkbun_domain_available "${domain}"; then
    die "Refusing to purchase ${domain}: Porkbun checkDomain did not report available"
  fi

  cost_cents="$(porkbun_usd_to_cents "${PORKBUN_LAST_PRICE_USD}")"
  log "Availability confirmed for ${domain}; price=${PORKBUN_LAST_PRICE_USD} USD (${cost_cents} cents)"

  idem="proxies-register-${domain}-$(date -u +%Y%m%d)"
  PORKBUN_IDEMPOTENCY_KEY="${idem}"
  export PORKBUN_IDEMPOTENCY_KEY

  extra="$(jq -nc --argjson cost "${cost_cents}" '{cost: $cost, agreeToTerms: "yes", whoisPrivacy: true}')"
  if ! json="$(porkbun_request "/domain/create/${domain}" "${extra}")"; then
    unset PORKBUN_IDEMPOTENCY_KEY || true
    die "Porkbun domain/create failed for ${domain}: ${PORKBUN_LAST_ERROR}"
  fi
  unset PORKBUN_IDEMPOTENCY_KEY || true

  log "Registered domain ${domain} via Porkbun: $(jq -c '{status,domain,message}' <<<"${json}" 2>/dev/null || printf '%s' "${json}")"
}

porkbun_dns_add() {
  local full_name="$1"
  local type="$2"
  local value="$3"
  local zone sub json extra

  zone="$(porkbun_dns_zone)"
  sub="$(porkbun_subdomain_from_full "${full_name}" "${zone}")"

  extra="$(
    jq -nc \
      --arg name "${sub}" \
      --arg type "${type}" \
      --arg content "${value}" \
      '{type: $type, content: $content, ttl: 600} + (if $name == "" then {} else {name: $name} end)'
  )"

  if [[ "${type}" == "A" || "${type}" == "AAAA" ]]; then
    porkbun_dns_remove "${full_name}" "${type}" || true
  fi

  if ! json="$(porkbun_request "/dns/create/${zone}" "${extra}")"; then
    die "Porkbun DNS add failed for ${full_name}: ${PORKBUN_LAST_ERROR}"
  fi
  log "DNS ${type} ${full_name} -> ${value} (porkbun id=$(jq -r '.id // empty' <<<"${json}"))"
}

porkbun_dns_remove() {
  local full_name="$1"
  local type="$2"
  local value="${3:-}"
  local zone sub json id

  zone="$(porkbun_dns_zone)"
  sub="$(porkbun_subdomain_from_full "${full_name}" "${zone}")"

  if [[ -n "${value}" ]]; then
    json="$(porkbun_request "/dns/retrieveByNameType/${zone}/${type}/${sub}" '{}' || true)"
    if [[ -n "${json}" ]]; then
      while IFS= read -r id; do
        [[ -n "${id}" && "${id}" != "null" ]] || continue
        porkbun_request "/dns/delete/${zone}/${id}" '{}' >/dev/null || true
        log "DNS remove ${type} ${full_name} id=${id}"
      done < <(jq -r --arg v "${value}" '
        (.records // [])[]
        | select((.content // .CONTENT // "") == $v)
        | (.id // .ID // empty)
      ' <<<"${json}")
    fi
    return 0
  fi

  if [[ -n "${sub}" ]]; then
    porkbun_request "/dns/deleteByNameType/${zone}/${type}/${sub}" '{}' >/dev/null || true
  else
    porkbun_request "/dns/deleteByNameType/${zone}/${type}/" '{}' >/dev/null \
      || porkbun_request "/dns/deleteByNameType/${zone}/${type}" '{}' >/dev/null \
      || true
  fi
  log "DNS remove ${type} ${full_name}: ok"
}

porkbun_point_domain_to_ip() {
  local domain="$1"
  local ip="$2"
  export REGISTRAR_ZONE="${domain}"
  porkbun_dns_add "${domain}" "A" "${ip}"
  porkbun_dns_add "*.${domain}" "A" "${ip}"
}
