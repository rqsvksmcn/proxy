#!/usr/bin/env bash
# Certbot wildcard issuance via registrar DNS-01 hooks.

DNS_PROPAGATION_SECONDS="${DNS_PROPAGATION_SECONDS:-180}"
# Fresh registrations (esp. .xyz) often NXDOMAIN until registry NS delegates.
DNS_DELEGATION_WAIT_SECONDS="${DNS_DELEGATION_WAIT_SECONDS:-5400}"
DNS_DELEGATION_POLL_SECONDS="${DNS_DELEGATION_POLL_SECONDS:-60}"
DNS_PUBLIC_RESOLVERS="${DNS_PUBLIC_RESOLVERS:-1.1.1.1 8.8.8.8 9.9.9.9}"

# Resolve via several public resolvers (first non-empty wins). Avoids sitting
# behind one resolver's NXDOMAIN negative cache after a fresh registration.
public_dns_query() {
  local type="$1"
  local name="$2"
  local resolver ans

  if command -v dig >/dev/null 2>&1; then
    for resolver in ${DNS_PUBLIC_RESOLVERS}; do
      ans="$(dig +short +time=2 +tries=1 "${type}" "${name}" @"${resolver}" 2>/dev/null || true)"
      if [[ -n "${ans}" ]]; then
        printf '%s\n' "${ans}"
        return 0
      fi
    done
    return 0
  fi

  # DoH fallback when dig is missing
  local qtype
  case "$(printf '%s' "${type}" | tr '[:lower:]' '[:upper:]')" in
    A) qtype=1 ;;
    NS) qtype=2 ;;
    TXT) qtype=16 ;;
    *) qtype=1 ;;
  esac
  curl -fsS --connect-timeout 5 --max-time 15 \
    -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=${name}&type=${qtype}" 2>/dev/null \
    | jq -r '.Answer[]?.data // empty' 2>/dev/null || true
}

# Block until the domain exists in public DNS (NS delegated), optionally matching A.
wait_for_public_dns() {
  local domain="$1"
  local expect_ip="${2:-}"
  local max_wait="${DNS_DELEGATION_WAIT_SECONDS}"
  local interval="${DNS_DELEGATION_POLL_SECONDS}"
  local elapsed=0
  local ns_ans a_ans

  log "Waiting up to $((max_wait / 60))m (poll every ${interval}s) for public DNS of ${domain}"
  while (( elapsed <= max_wait )); do
    ns_ans="$(public_dns_query NS "${domain}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ -n "${ns_ans}" ]]; then
      a_ans="$(public_dns_query A "${domain}" | head -n1 | tr -d '[:space:]')"
      if [[ -n "${expect_ip}" ]]; then
        if [[ "${a_ans}" == "${expect_ip}" ]]; then
          log "Public DNS ready: ${domain} NS=[${ns_ans}] A=${a_ans}"
          return 0
        fi
        log "NS live ([${ns_ans}]) but A='${a_ans:-empty}' (want ${expect_ip}); next check in ${interval}s..."
      else
        log "Public DNS ready: ${domain} NS=[${ns_ans}] A=${a_ans:-none}"
        return 0
      fi
    else
      log "Public DNS still NXDOMAIN for ${domain}; next check in ${interval}s (${elapsed}s/$((max_wait))s)"
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  die "Public DNS for ${domain} not delegated after $((max_wait / 60))m. Re-run: force-rotate.sh --resume-domain ${domain}"
}

issue_wildcard_certificate() {
  local domain="$1"
  local auth_hook="${PROXIES_ROOT}/hooks/certbot-auth.sh"
  local cleanup_hook="${PROXIES_ROOT}/hooks/certbot-cleanup.sh"

  [[ -x "${auth_hook}" ]] || die "Missing auth hook: ${auth_hook}"
  [[ -x "${cleanup_hook}" ]] || die "Missing cleanup hook: ${cleanup_hook}"
  [[ -n "${CERTBOT_EMAIL:-}" ]] || die "CERTBOT_EMAIL is required for Let's Encrypt registration"

  # Already issued (e.g. resume after later-stage failure).
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    log "Certificate already present for ${domain}; skipping certbot issuance"
    return 0
  fi

  log "Requesting wildcard certificate for ${domain} and *.${domain} (email=${CERTBOT_EMAIL})"
  # Export so auth hook inherits the same wait budget.
  export DNS_PROPAGATION_SECONDS
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "${CERTBOT_EMAIL}" \
    --manual \
    --preferred-challenges dns \
    --manual-auth-hook "${auth_hook}" \
    --manual-cleanup-hook "${cleanup_hook}" \
    --cert-name "${domain}" \
    -d "${domain}" \
    -d "*.${domain}"

  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] \
    || die "Certificate files missing after certbot for ${domain}"
  log "Certificate issued for ${domain}"
}

ensure_certbot_renewal_hooks() {
  # Certbot renew reuses the auth/cleanup hooks stored in renewal config
  # when the certificate was issued with --manual-auth-hook.
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx 2>/dev/null || true
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
}
