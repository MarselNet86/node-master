# shellcheck shell=bash
# Post-install check from the bottom up (tech.md §5): xray on the loopback, origin nginx,
# the xhttp path through nginx, then the CDN edge the way clients reach it. Stops at the
# first broken layer with exit 8 and says what to fix there.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=node.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/node.sh"

validate::layers() {
  require::cmd curl jq openssl
  env::require CDN_DOMAIN XHTTP_PORT XHTTP_PATH NGINX_TLS_PORT ORIGIN_IP
  validate::_origin_ip
  validate::_xray
  validate::_origin
  validate::_xhttp
  validate::_cdn
  log::info "$(t 'all layers pass: xray, origin nginx, xhttp path, CDN edge')"
}

# --- layers -----------------------------------------------------------------------------

# Layer 1: the inbound that the panel pushed listens on the loopback. A node that runs here
# gets time to start xray, and a failure names its cause.
validate::_xray() {
  local addrs
  if ! validate::_listening "$XHTTP_PORT" && ! validate::_wait_node; then
    validate::_fail 1 "$(t xray)" "$(t 'nothing listens on 127.0.0.1:%s: %s' "$XHTTP_PORT" "$(validate::_node_cause)")"
  fi
  if command -v ss >/dev/null 2>&1; then
    addrs="$(ss -Hltn "sport = :$XHTTP_PORT" 2>/dev/null | awk '{print $4}' || true)"
    if [[ -n "$addrs" ]] && grep -qvE '^127\.0\.0\.1:' <<<"$addrs"; then
      log::warn "$(t 'port %s listens beyond the loopback (%s): set listen 127.0.0.1 in the inbound, TLS ends on nginx' "$XHTTP_PORT" "$(paste -sd' ' <<<"$addrs")")"
    fi
  fi
  log::info "$(t 'layer 1 (xray): 127.0.0.1:%s accepts connections' "$XHTTP_PORT")"
}

# Layer 2: origin nginx answers /cdn-check with 204 and its marker header.
validate::_origin() {
  local headers
  headers="$(validate::_origin_request /cdn-check)" ||
    validate::_fail 2 "$(t 'origin nginx')" "$(t 'no answer on 127.0.0.1:%s: see systemctl status nginx' "$NGINX_TLS_PORT")"
  if [[ "$(validate::_status "$headers")" != 204 ]] || ! validate::_has_header "$headers" X-CDN-Origin; then
    validate::_fail 2 "$(t 'origin nginx')" "$(t '/cdn-check gave %s without X-CDN-Origin, not 204: nginx does not serve the cdn-deploy site, rerun ./deploy.sh' "$(validate::_status "$headers")")"
  fi
  log::info "$(t 'layer 2 (origin nginx): /cdn-check on :%s gives 204' "$NGINX_TLS_PORT")"
}

# Layer 3: the xhttp path reaches xray. A request without a session gets 400 carrying the
# padding header of the inbound.
validate::_xhttp() {
  local inbound="$REPO_ROOT/out/remnawave/inbound-xhttp-cdn.json" header headers status
  header="$(jq -r '.streamSettings.xhttpSettings.extra.xPaddingHeader // empty' "$inbound" 2>/dev/null || true)"
  [[ -n "$header" ]] || validate::_fail 3 "$(t 'xhttp path')" "$(t 'no xPaddingHeader in %s: rerun ./deploy.sh' "$inbound")"
  headers="$(validate::_origin_request "${XHTTP_PATH}test")" ||
    validate::_fail 3 "$(t 'xhttp path')" "$(t 'no answer from nginx for %s' "${XHTTP_PATH}test")"
  status="$(validate::_status "$headers")"
  case "$status" in
    400)
      validate::_has_header "$headers" "$header" ||
        validate::_fail 3 "$(t 'xhttp path')" "$(t 'xray answered 400 without the %s padding header: the inbound in the panel differs from out/remnawave/inbound-xhttp-cdn.json' "$header")"
      ;;
    404) validate::_fail 3 "$(t 'xhttp path')" "$(t 'xray answered 404: XHTTP_PATH (%s) or the inbound host (%s) differs from the panel' "$XHTTP_PATH" "$CDN_DOMAIN")" ;;
    502 | 504) validate::_fail 3 "$(t 'xhttp path')" "$(t 'nginx cannot reach xray on 127.0.0.1:%s (%s)' "$XHTTP_PORT" "$status")" ;;
    *) validate::_fail 3 "$(t 'xhttp path')" "$(t '%s gave %s, not 400 with the %s padding header' "${XHTTP_PATH}test" "$status" "$header")" ;;
  esac
  # Timeweb forwards XHTTP_PATH without its trailing slash; it has to reach xray as well.
  headers="$(validate::_origin_request "${XHTTP_PATH%/}")" ||
    validate::_fail 3 "$(t 'xhttp path')" "$(t 'no answer from nginx for %s' "${XHTTP_PATH%/}")"
  status="$(validate::_status "$headers")"
  if [[ "$status" != 400 ]] || ! validate::_has_header "$headers" "$header"; then
    validate::_fail 3 "$(t 'xhttp path')" "$(t '%s gave %s, not 400 with %s: nginx does not pass the path without its trailing slash, which Timeweb sends, rerun ./deploy.sh' "${XHTTP_PATH%/}" "$status" "$header")"
  fi
  log::info "$(t 'layer 3 (xhttp path): xray answers %s and %s through nginx with 400 and %s' "$XHTTP_PATH" "${XHTTP_PATH%/}" "$header")"
}

# Layer 4: the CDN edge, as clients see it. curl checks the edge certificate against
# CDN_DOMAIN, the query defeats caches, and the marker header proves the origin answered.
validate::_cdn() {
  local headers rc=0 status
  headers="$(validate::_request "https://$CDN_DOMAIN/cdn-check?nocache=$RANDOM$RANDOM")" || rc=$?
  case "$rc" in
    0) ;;
    6) validate::_fail 4 "$(t 'CDN edge')" "$(t '%s does not resolve: add the CNAME from the CDN resource to DNS' "$CDN_DOMAIN")" ;;
    7 | 28) validate::_fail 4 "$(t 'CDN edge')" "$(t 'no connection to %s:443: check the CNAME and that the CDN resource is active' "$CDN_DOMAIN")" ;;
    35) validate::_fail 4 "$(t 'CDN edge')" "$(t 'TLS handshake with %s failed: the CDN has no certificate for it yet' "$CDN_DOMAIN")" ;;
    60) validate::_fail 4 "$(t 'CDN edge')" "$(t 'the edge presents a certificate that does not cover %s (%s): attach a certificate for %s to the CDN resource, the change takes up to 30 minutes' "$CDN_DOMAIN" "$(validate::_edge_cert)" "$CDN_DOMAIN")" ;;
    *) validate::_fail 4 "$(t 'CDN edge')" "$(t 'curl failed with exit %s on https://%s/cdn-check' "$rc" "$CDN_DOMAIN")" ;;
  esac
  status="$(validate::_status "$headers")"
  case "$status" in
    204)
      validate::_has_header "$headers" X-CDN-Origin ||
        validate::_fail 4 "$(t 'CDN edge')" "$(t "204 without X-CDN-Origin: the answer did not come from this origin, check the resource's origin and caching")"
      ;;
    451) validate::_fail 4 "$(t 'CDN edge')" "$(t '451: the CDN blocks %s for legal reasons. A config change will not help, move to a new domain' "$CDN_DOMAIN")" ;;
    502 | 504) validate::_fail 4 "$(t 'CDN edge')" "$(t "%s: the CDN cannot reach the origin. The resource's origin must be %s:%s over HTTPS, with the port open" "$status" "$ORIGIN_IP" "$NGINX_TLS_PORT")" ;;
    503) validate::_fail 4 "$(t 'CDN edge')" "$(t '503: the CDN reports overload or a disabled resource')" ;;
    403) validate::_fail 4 "$(t 'CDN edge')" "$(t '403: the CDN refuses the request. Check that the resource is active and allows GET')" ;;
    *) validate::_fail 4 "$(t 'CDN edge')" "$(t '/cdn-check through the CDN gave %s, not 204' "$status")" ;;
  esac
  log::info "$(t 'layer 4 (CDN edge): https://%s/cdn-check gives 204 from this origin' "$CDN_DOMAIN")"
}

# ORIGIN_IP is where the CDN resource sends traffic, so it should point at this host.
validate::_origin_ip() {
  local public
  if hostname -I 2>/dev/null | tr ' ' '\n' | grep -qxF "$ORIGIN_IP"; then
    return 0
  fi
  public="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  if [[ "$public" != "$ORIGIN_IP" ]]; then
    log::warn "$(t 'ORIGIN_IP=%s is not an address of this host, whose public IPv4 is %s: the CDN resource may send traffic elsewhere' "$ORIGIN_IP" "${public:-unknown}")"
  fi
}

# --- helpers ----------------------------------------------------------------------------

validate::_fail() {
  log::die "$EXIT_VALIDATE" "$(t 'layer %s (%s) failed: %s' "$@")"
}

validate::_listening() {
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# The panel starts xray once it reaches a node, so a node container that runs here gets
# CDN_DEPLOY_NODE_WAIT seconds (60; tests cut it) to open the port. A failure in its log
# ends the wait.
validate::_wait_node() {
  local wait="${CDN_DEPLOY_NODE_WAIT:-60}" waited=0
  if [[ "$(validate::_node_state)" != running ]]; then
    return 1
  fi
  log::info "$(t 'waiting up to %ss for xray on the node to open 127.0.0.1:%s' "$wait" "$XHTTP_PORT")"
  while ((waited < wait)); do
    sleep 2
    waited=$((waited + 2))
    if validate::_listening "$XHTTP_PORT"; then
      return 0
    fi
    if [[ -n "$(validate::_node_error)" ]]; then
      return 1
    fi
  done
  return 1
}

# Why no xray listens: no node here yet, a node that does not see the Hysteria2
# certificate, an error in the node log, a stopped container, or a panel that has not
# started the inbound.
validate::_node_cause() {
  local state error absent tag="VLESS-XHTTP-CDN${NODE_NAME:+-${NODE_NAME^^}}"
  state="$(validate::_node_state)"
  error="$(validate::_node_error)"
  absent="$(t 'no Docker')"
  if command -v docker >/dev/null 2>&1; then
    absent="$(t 'no %s container' "$NODE_CONTAINER")"
  fi
  if [[ -z "$state" ]]; then
    t 'no node runs here yet (%s): create it in the panel (steps 1 and 2 above), give ./deploy.sh its SECRET_KEY there or as NODE_SECRET_KEY in .env, rerun ./deploy.sh' \
      "$absent"
  elif [[ -n "${HY2_DOMAIN:-}" ]] &&
    ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$NODE_CONTAINER" 2>/dev/null | grep -qw /etc/letsencrypt; then
    t 'the %s container does not see /etc/letsencrypt, so xray stops on the Hysteria2 certificate: rerun ./deploy.sh, it rewrites %s with the volume /etc/letsencrypt:/etc/letsencrypt:ro' \
      "$NODE_CONTAINER" "$NODE_COMPOSE"
  elif [[ "$error" == *SECRET_KEY* ]]; then
    t 'the node rejects its SECRET_KEY (docker logs %s): copy it again from the panel into NODE_SECRET_KEY in .env, rerun ./deploy.sh' "$NODE_CONTAINER"
  elif [[ -n "$error" ]]; then
    t 'xray on the node fails: %s (docker logs %s)' "$error" "$NODE_CONTAINER"
  elif [[ "$state" != running ]]; then
    t 'the %s container is %s: docker logs %s says why' "$NODE_CONTAINER" "$state" "$NODE_CONTAINER"
  else
    t 'the node runs, but xray has no %s: check in the panel that the node is online (the panel reaches NODE_PORT %s) with this inbound on, rerun ./deploy.sh' \
      "$tag" "${NODE_PORT:-2222}"
  fi
}

# The state of the node container (running, restarting, exited...), empty without one.
validate::_node_state() {
  if command -v docker >/dev/null 2>&1; then
    docker inspect -f '{{.State.Status}}' "$NODE_CONTAINER" 2>/dev/null || true
  fi
}

# The latest failure in the node log: a rejected SECRET_KEY, or the last link of the error
# chain of a failed xray start ("... > open /etc/...: no such file or directory").
validate::_node_error() {
  local line
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  line="$(docker logs --tail 200 "$NODE_CONTAINER" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' |
    grep -E 'Failed to start Xray|SECRET_KEY (INVALID|payload|missing|contains)|Invalid SECRET_KEY' |
    tail -n 1 || true)"
  if [[ "$line" == *SECRET_KEY* ]]; then
    printf 'SECRET_KEY rejected'
  elif [[ -n "$line" ]]; then
    line="${line#*Failed to start Xray: }"
    printf '%s' "${line##* > }"
  fi
}

# Headers of a GET, CR stripped; returns curl's exit code.
validate::_request() {
  local out rc=0
  out="$(curl -s -o /dev/null -D - --max-time 10 "$@")" || rc=$?
  printf '%s' "${out//$'\r'/}"
  return "$rc"
}

# Origin requests skip DNS and certificate checks: the origin certificate may name
# VLESS_DOMAIN, and layer 4 covers what clients see.
validate::_origin_request() {
  validate::_request -k --resolve "$CDN_DOMAIN:$NGINX_TLS_PORT:127.0.0.1" \
    "https://$CDN_DOMAIN:$NGINX_TLS_PORT$1"
}

validate::_status() {
  local line
  line="$(head -n 1 <<<"$1")"
  line="${line#* }"
  printf '%s' "${line%% *}"
}

validate::_has_header() {
  grep -qi "^$2:" <<<"$1"
}

validate::_edge_cert() {
  openssl s_client -connect "$CDN_DOMAIN:443" -servername "$CDN_DOMAIN" </dev/null 2>/dev/null |
    openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | tr -s '\n ' ' ' | sed 's/ $//' ||
    t 'certificate unreadable'
}
