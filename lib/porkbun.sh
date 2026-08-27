#!/usr/bin/env bash
# Porkbun API helpers (https://api.porkbun.com/api/json/v3).
# Requires: curl, jq, PORKBUN_API_KEY, PORKBUN_SECRET_API_KEY

PORKBUN_API_BASE="${PORKBUN_API_BASE:-https://api.porkbun.com/api/json/v3}"
PORKBUN_CURL_INSECURE="${PORKBUN_CURL_INSECURE:-0}"
PORKBUN_CONNECT_TIMEOUT="${PORKBUN_CONNECT_TIMEOUT:-15}"
PORKBUN_MAX_TIME="${PORKBUN_MAX_TIME:-60}"
# Domain check default limit is 1 / 10s; wait between availability probes.
PORKBUN_CHECK_SLEEP_SECONDS="${PORKBUN_CHECK_SLEEP_SECONDS:-11}"

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

porkbun_auth_json() {
  jq -nc \
    --arg key "${PORKBUN_API_KEY}" \
    --arg secret "${PORKBUN_SECRET_API_KEY}" \
    '{apikey: $key, secretapikey: $secret}'
}

# POST JSON to path; merge extra object fields into the auth body.
# Optional Idempotency-Key via PORKBUN_IDEMPOTENCY_KEY.
porkbun_request() {
  local path="$1"
  local extra_json="${2:-{}}"
  shift 2 || true
  local body response http_code
  local curl_opts=()
  mapfile -t curl_opts < <(porkbun_curl_args)

  body="$(
    jq -nc --argjson auth "$(porkbun_auth_json)" --argjson extra "${extra_json}" \
      '$auth + $extra'
  )"

  log "Porkbun request: ${PORKBUN_API_BASE}${path}"
  local headers=(-H "Content-Type: application/json")
  if [[ -n "${PORKBUN_IDEMPOTENCY_KEY:-}" ]]; then
    headers+=(-H "Idempotency-Key: ${PORKBUN_IDEMPOTENCY_KEY}")
  fi

  response="$(
    curl -f "${curl_opts[@]}" -w '\n%{http_code}' \
      -X POST "${PORKBUN_API_BASE}${path}" \
      "${headers[@]}" \
      --data "${body}"
  )" || die "Porkbun request failed: ${path}. Check API keys, account credit, outbound HTTPS to api.porkbun.com, and that API access is enabled for the domain."

  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"

  if [[ "${http_code}" != "200" ]]; then
    die "Porkbun HTTP ${http_code} for ${path}: ${body}"
  fi

  local status
  status="$(jq -r '.status // empty' <<<"${body}")"
  if [[ "$(printf '%s' "${status}" | tr '[:lower:]' '[:upper:]')" != "SUCCESS" ]]; then
    die "Porkbun error for ${path}: ${body}"
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
  json="$(porkbun_request "/domain/checkDomain/${domain}" '{}')"
  avail="$(jq -r '.response.avail // .avail // empty' <<<"${json}")"
  case "$(printf '%s' "${avail}" | tr '[:upper:]' '[:lower:]')" in
    yes|available|true|1)
      # Stash last quoted registration price (USD) for create.
      PORKBUN_LAST_PRICE_USD="$(jq -r '
        .response.price.registration // .response.price // .price.registration // .price // empty
      ' <<<"${json}")"
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
  # awk avoids locale issues better than bc for simple decimal.
  awk -v p="${usd}" 'BEGIN {
    if (p ~ /^[0-9]+$/) { printf "%d\n", p * 100; exit }
    printf "%d\n", int(p * 100 + 0.5)
  }'
}

porkbun_register_domain() {
  local domain="$1"
  local json cost_cents idem

  log "Verifying ${domain} is still available before Porkbun purchase"
  if ! porkbun_domain_available "${domain}"; then
    die "Refusing to purchase ${domain}: Porkbun checkDomain did not report available"
  fi

  cost_cents="$(porkbun_usd_to_cents "${PORKBUN_LAST_PRICE_USD}")"
  log "Availability confirmed for ${domain}; price=${PORKBUN_LAST_PRICE_USD} USD (${cost_cents} cents)"

  idem="proxies-register-${domain}-$(date -u +%Y%m%d)"
  PORKBUN_IDEMPOTENCY_KEY="${idem}"
  export PORKBUN_IDEMPOTENCY_KEY

  json="$(
    porkbun_request "/domain/create/${domain}" "$(
      jq -nc --argjson cost "${cost_cents}" \
        '{cost: $cost, agreeToTerms: "yes", whoisPrivacy: true}'
    )"
  )"
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

  # Apex/wildcard A: replace existing. TXT (ACME): add alongside siblings.
  if [[ "${type}" == "A" || "${type}" == "AAAA" ]]; then
    porkbun_dns_remove "${full_name}" "${type}" || true
  fi

  json="$(porkbun_request "/dns/create/${zone}" "${extra}")"
  log "DNS ${type} ${full_name} -> ${value} (porkbun id=$(jq -r '.id // empty' <<<"${json}"))"
}

porkbun_dns_remove() {
  local full_name="$1"
  local type="$2"
  local value="${3:-}"
  local zone sub json ids id

  zone="$(porkbun_dns_zone)"
  sub="$(porkbun_subdomain_from_full "${full_name}" "${zone}")"

  # Soft-fail path for cleanup hooks.
  if [[ -n "${value}" ]]; then
    json="$(porkbun_request "/dns/retrieveByNameType/${zone}/${type}/${sub}" '{}' 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      while IFS= read -r id; do
        [[ -n "${id}" && "${id}" != "null" ]] || continue
        porkbun_request "/dns/delete/${zone}/${id}" '{}' >/dev/null 2>&1 || true
        log "DNS remove ${type} ${full_name} id=${id}"
      done < <(jq -r --arg v "${value}" '
        (.records // [])[]
        | select((.content // .CONTENT // "") == $v)
        | (.id // .ID // empty)
      ' <<<"${json}")
    fi
    return 0
  fi

  # Delete all records of this name+type (used before replacing A records).
  if [[ -n "${sub}" ]]; then
    porkbun_request "/dns/deleteByNameType/${zone}/${type}/${sub}" '{}' >/dev/null 2>&1 || true
  else
    # Apex: path with empty subdomain — Porkbun accepts trailing slash form.
    porkbun_request "/dns/deleteByNameType/${zone}/${type}/" '{}' >/dev/null 2>&1 \
      || porkbun_request "/dns/deleteByNameType/${zone}/${type}" '{}' >/dev/null 2>&1 \
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
