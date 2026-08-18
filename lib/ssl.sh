#!/usr/bin/env bash
# Certbot wildcard issuance via InternetBS DNS-01 hooks.

DNS_PROPAGATION_SECONDS="${DNS_PROPAGATION_SECONDS:-120}"

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
