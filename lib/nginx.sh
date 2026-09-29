# shellcheck shell=bash
# Origin nginx for the CDN edge (tech.md §5, §6): renders templates/ into /etc/nginx/,
# enables the site, drops the stock default site, applies the result only after nginx -t.
# A node without CDN_DOMAIN gets the main config and no site.

set -euo pipefail

# certs.sh sources this module too; readonly constants must not be redefined.
if [[ -n "${_CDN_NGINX_LOADED:-}" ]]; then
  return 0
fi
_CDN_NGINX_LOADED=1

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# Paths as the host sees them; files are created under $SYSROOT, which only tests set.
readonly NGINX_CONF=/etc/nginx/nginx.conf
readonly NGINX_STOCK_CONF=/etc/nginx/nginx.conf.cdn-deploy-orig
readonly NGINX_SITE=/etc/nginx/sites-available/cdn-deploy.conf
readonly NGINX_SITE_LINK=/etc/nginx/sites-enabled/cdn-deploy.conf
readonly NGINX_DEFAULT_LINK=/etc/nginx/sites-enabled/default

# Renders the templates and applies them. With the CDN it returns only once nginx serves
# the origin site; a config that nginx -t rejects, or that nginx does not put into service
# after the reload, is rolled back, so the previous one keeps serving (exit 7). Without the
# CDN nginx gets the main config and no site: it only opens :80 for the certificates.
nginx::render() {
  local cert_dir="" main site="" id="" saved changed=0
  require::cmd nginx envsubst curl
  if env::has_cdn; then
    env::require XHTTP_PORT XHTTP_PATH NGINX_TLS_PORT VLESS_DOMAIN
    cert_dir="$(nginx::_cert_dir)"
    if [[ ! -r "$SYSROOT$cert_dir/fullchain.pem" || ! -r "$SYSROOT$cert_dir/privkey.pem" ]]; then
      log::die "$EXIT_NGINX" "$(t 'no certificate in %s: the certs step issues it, rerun ./deploy.sh' "$cert_dir")"
    fi
  fi
  main="$(nginx::_template nginx.conf.tmpl "$cert_dir" "")" || log::die "$EXIT_NGINX" "$(t 'cannot render %s' templates/nginx.conf.tmpl)"
  if env::has_cdn; then
    site="$(nginx::_template site-8444.conf.tmpl "$cert_dir" "")" || log::die "$EXIT_NGINX" "$(t 'cannot render %s' templates/site-8444.conf.tmpl)"
    # The id names this exact render; nginx serves it on the loopback, which shows whether
    # the running config is this one.
    id="$(printf '%s\n%s\n' "$main" "$site" | sha256sum | cut -c1-16)"
    site="$(nginx::_template site-8444.conf.tmpl "$cert_dir" "$id")" || log::die "$EXIT_NGINX" "$(t 'cannot render %s' templates/site-8444.conf.tmpl)"
  fi

  mkdir -p "$SYSROOT${NGINX_SITE%/*}" "$SYSROOT${NGINX_SITE_LINK%/*}"
  saved="$(mktemp -d)"
  nginx::_save "$saved"
  nginx::_keep_stock_conf
  fs::write "$SYSROOT$NGINX_CONF" 644 "$main"
  changed=$((changed | FS_CHANGED))
  if env::has_cdn; then
    fs::write "$SYSROOT$NGINX_SITE" 644 "$site"
    changed=$((changed | FS_CHANGED))
    if [[ "$(readlink "$SYSROOT$NGINX_SITE_LINK" || true)" != "$NGINX_SITE" ]]; then
      ln -sfn "$NGINX_SITE" "$SYSROOT$NGINX_SITE_LINK"
      changed=1
    fi
  elif [[ -e "$SYSROOT$NGINX_SITE" || -e "$SYSROOT$NGINX_SITE_LINK" || -L "$SYSROOT$NGINX_SITE_LINK" ]]; then
    # A node that dropped the CDN: the origin site would keep :8444 open for nobody.
    rm -f "$SYSROOT$NGINX_SITE_LINK" "$SYSROOT$NGINX_SITE"
    log::info "$(t 'removed %s: no CDN_DOMAIN' "$NGINX_SITE")"
    changed=1
  fi
  if [[ -e "$SYSROOT$NGINX_DEFAULT_LINK" || -L "$SYSROOT$NGINX_DEFAULT_LINK" ]]; then
    rm -f "$SYSROOT$NGINX_DEFAULT_LINK"
    log::info "$(t 'removed %s: the stock site answers any host; sites-available/default stays' "$NGINX_DEFAULT_LINK")"
    changed=1
  fi

  if ! env::has_cdn; then
    nginx::_apply_bare "$saved" "$changed"
    return 0
  fi
  if ((changed == 0)) && nginx::_serves "$id" 1 1; then
    rm -rf "$saved"
    log::info "$(t 'nginx config is up to date and serving')"
    return 0
  fi
  if ! nginx -t >&2; then
    nginx::_restore "$saved"
    rm -rf "$saved"
    log::die "$EXIT_NGINX" "$(t 'nginx -t rejects the rendered config, the previous one stays: see the errors above')"
  fi
  # nginx -t does not bind ports, and nginx -s reload succeeds even when the master then
  # keeps the old config, so only the served id proves the reload.
  if ! nginx::reload || ! nginx::_serves "$id" 10 100; then
    nginx::_restore "$saved"
    rm -rf "$saved"
    nginx::reload || true
    log::die "$EXIT_NGINX" "$(t 'nginx did not put the new config into service, the previous one stays: see /var/log/nginx/error.log (port %s taken by another program, for one)' "$NGINX_TLS_PORT")"
  fi
  rm -rf "$saved"
  log::info "$(t 'nginx serves the new config')"
}

# Applies a config without the origin site, with the backup in SAVED. No site serves an
# id, so a reload that nginx takes is as far as the check goes.
nginx::_apply_bare() {
  local saved="$1" changed="$2"
  if ((changed == 0)); then
    rm -rf "$saved"
    log::info "$(t 'nginx config is up to date, without an origin site: no CDN_DOMAIN')"
    return 0
  fi
  if ! nginx -t >&2; then
    nginx::_restore "$saved"
    rm -rf "$saved"
    log::die "$EXIT_NGINX" "$(t 'nginx -t rejects the rendered config, the previous one stays: see the errors above')"
  fi
  if ! nginx::reload; then
    nginx::_restore "$saved"
    rm -rf "$saved"
    nginx::reload || true
    log::die "$EXIT_NGINX" "$(t 'nginx did not take the new config, the previous one stays: see /var/log/nginx/error.log')"
  fi
  rm -rf "$saved"
  log::info "$(t 'nginx took the new config, without an origin site: no CDN_DOMAIN')"
}

# Reloads nginx, or starts it when it is down. nginx -s reload prints a notice even on
# success, so its output shows only on failure, and the function returns 1.
nginx::reload() {
  local out
  if ! systemctl is-active --quiet nginx; then
    log::info "$(t 'nginx is not running: starting it')"
    if systemctl start nginx >&2; then
      return 0
    fi
    log::error "$(t 'cannot start nginx: see systemctl status nginx')"
    return 1
  fi
  if ! out="$(nginx -s reload 2>&1)"; then
    log::error "$(t 'nginx -s reload failed: %s' "$out")"
    return 1
  fi
}

# --- rendering --------------------------------------------------------------------------

# The certificate of VLESS_DOMAIN, a name of this server. Timeweb takes it: the CDN edge
# does not check the name of the origin certificate against CDN_DOMAIN.
nginx::_cert_dir() {
  echo "/etc/letsencrypt/live/$VLESS_DOMAIN"
}

# Renders templates/NAME with the cert directory CERT_DIR and the config id CONFIG_ID.
# Only the listed placeholders change, so nginx variables such as $request_method stay.
nginx::_template() {
  local name="$1" path="${XHTTP_PATH:-}" names="${CDN_DOMAIN:-} ${VLESS_DOMAIN:-}" out
  # shellcheck disable=SC2016  # envsubst takes the placeholder list literally
  out="$(XHTTP_PORT="${XHTTP_PORT:-}" XHTTP_PATH="$path" XHTTP_PATH_BARE="${path%/}" \
    NGINX_TLS_PORT="${NGINX_TLS_PORT:-}" CDN_DOMAIN="${CDN_DOMAIN:-}" SERVER_NAMES="$names" \
    ORIGIN_CERT_DIR="$2" CONFIG_ID="$3" \
    envsubst '${XHTTP_PORT} ${XHTTP_PATH} ${XHTTP_PATH_BARE} ${NGINX_TLS_PORT} ${CDN_DOMAIN} ${SERVER_NAMES} ${ORIGIN_CERT_DIR} ${CONFIG_ID}' \
    <"$REPO_ROOT/templates/$name")"
  if [[ "$out" == *"\${"* ]]; then
    log::error "$(t 'templates/%s has a placeholder that nginx::render does not fill' "$name")"
    return 1
  fi
  printf '%s' "$out"
}

# 0 once the origin answers with config id ID in STREAK probes in a row, each on a new
# connection, within TRIES probes. Old workers keep the old config for a moment after a
# reload, so a single answer proves little.
nginx::_serves() {
  local id="$1" streak="$2" tries="$3" run=0 i
  for ((i = 0; i < tries && run < streak; i++)); do
    if [[ "$(curl -sk --max-time 2 --resolve "$CDN_DOMAIN:$NGINX_TLS_PORT:127.0.0.1" \
      "https://$CDN_DOMAIN:$NGINX_TLS_PORT/cdn-deploy-config" || true)" == "$id" ]]; then
      run=$((run + 1))
    else
      run=0
    fi
    if ((run < streak && i + 1 < tries)); then
      sleep 0.1
    fi
  done
  ((run >= streak))
}

# --- rollback ---------------------------------------------------------------------------

# Files and links that nginx::render may change, as the host sees them.
nginx::_managed() {
  printf '%s\n' "$NGINX_CONF" "$NGINX_SITE" "$NGINX_SITE_LINK" "$NGINX_DEFAULT_LINK"
}

nginx::_save() {
  local dir="$1" path i=0
  while IFS= read -r path; do
    if [[ -e "$SYSROOT$path" || -L "$SYSROOT$path" ]]; then
      cp -a "$SYSROOT$path" "$dir/$i"
    fi
    i=$((i + 1))
  done < <(nginx::_managed)
}

nginx::_restore() {
  local dir="$1" path i=0
  while IFS= read -r path; do
    rm -f "$SYSROOT$path"
    if [[ -e "$dir/$i" || -L "$dir/$i" ]]; then
      cp -a "$dir/$i" "$SYSROOT$path"
    fi
    i=$((i + 1))
  done < <(nginx::_managed)
  log::warn "$(t 'restored the previous nginx config')"
}

# Keeps the distro's nginx.conf once, before the first overwrite, for a manual revert.
nginx::_keep_stock_conf() {
  if [[ -f "$SYSROOT$NGINX_CONF" && ! -e "$SYSROOT$NGINX_STOCK_CONF" ]]; then
    cp -p "$SYSROOT$NGINX_CONF" "$SYSROOT$NGINX_STOCK_CONF"
    log::info "$(t 'kept the stock nginx.conf as %s' "$NGINX_STOCK_CONF")"
  fi
}
