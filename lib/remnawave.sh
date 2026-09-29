# shellcheck shell=bash
# Files for the Remnawave panel (tech.md §5, §6): renders remnawave/ into out/remnawave/
# for this node's domains and inbounds, then walks the operator through the panel and,
# with a CDN, the CDN resource.
# The panel manages xray on the node: the operator pastes the files by hand. At panel step
# 2 the node that the panel created starts on this server (lib/node.sh).

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=prompt.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/prompt.sh"
# shellcheck source=node.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/node.sh"

# Fields that must match one for one between the inbound and the host extra, or the tunnel
# breaks exactly through the CDN (remnawave/README.md).
readonly -a REMNAWAVE_SYNCED=(
  seqKey seqPlacement xPaddingKey xPaddingHeader xPaddingMethod xPaddingBytes xPaddingPlacement
  xPaddingObfsMode sessionIDTable sessionIDLength sessionIDPlacement uplinkDataKey
  uplinkChunkSize uplinkHTTPMethod uplinkDataPlacement serverMaxHeaderBytes
)

# Writes the files the panel takes: the config profile and the Xray JSON subscription
# template, and with the CDN the host extra and the xhttp inbound alone, for a node that
# keeps its own profile. Then prints the steps; in a terminal it waits for each one while
# a file changed.
remnawave::emit() {
  local out="$REPO_ROOT/out/remnawave" inbound="" host="" reality="" hy2="" profile template
  local file changed=0
  local -a files=(config-profile subscription-xray-json)
  require::cmd envsubst jq
  env::require NODE_NAME
  if env::has_cdn; then
    env::require XHTTP_PATH XHTTP_PORT
    inbound="$(remnawave::_render inbound-xhttp-cdn.json.tmpl)"
    host="$(<"$REPO_ROOT/remnawave/host-xhttp-extra.json")"
    jq -e . >/dev/null <<<"$host" ||
      log::die "$EXIT_FAILURE" "$(t '%s is not valid JSON' remnawave/host-xhttp-extra.json)"
    remnawave::_check_sync "$inbound" "$host"
    files+=(host-xhttp-extra inbound-xhttp-cdn)
  fi
  if [[ -n "${REALITY_SNI:-}" ]]; then
    env::require REALITY_PRIVATE_KEY REALITY_SHORT_ID
    reality="$(remnawave::_render inbound-reality.json.tmpl)"
  fi
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    # The masquerade answers probes with the Reality site; without one, xray's default.
    hy2="$(remnawave::_render inbound-hysteria2.json.tmpl |
      jq --arg sni "${REALITY_SNI:-}" 'if $sni == "" then del(.streamSettings.hysteriaSettings.masquerade) else . end')"
  fi
  profile="$(jq --arg reality "$reality" --arg xhttp "$inbound" --arg hy2 "$hy2" \
    '.inbounds = [($reality, $xhttp, $hy2) | select(. != "") | fromjson]' \
    "$REPO_ROOT/remnawave/config-profile.json")" ||
    log::die "$EXIT_FAILURE" "$(t '%s does not make a valid profile' remnawave/config-profile.json)"
  template="$(jq --argjson own "$(remnawave::_own_domains)" \
    'walk(if . == "__OWN_DOMAINS__" then $own else . end)' "$REPO_ROOT/remnawave/subscription-xray-json.json")" ||
    log::die "$EXIT_FAILURE" "$(t '%s is not valid JSON' remnawave/subscription-xray-json.json)"

  mkdir -p "$out"
  # The files carry the Reality private key, the xhttp path and the obfuscation profile.
  chmod 700 "$REPO_ROOT/out" "$out"
  for file in "${files[@]}"; do
    case "$file" in
      config-profile) fs::write "$out/$file.json" 600 "$profile" ;;
      host-xhttp-extra) fs::write "$out/$file.json" 600 "$host" ;;
      subscription-xray-json) fs::write "$out/$file.json" 600 "$template" ;;
      inbound-xhttp-cdn) fs::write "$out/$file.json" 600 "$inbound" ;;
    esac
    changed=$((changed + FS_CHANGED))
  done
  # The CDN files of an earlier run would lead to an inbound the profile no longer has.
  if ! env::has_cdn; then
    for file in host-xhttp-extra inbound-xhttp-cdn; do
      if [[ -e "${out:?}/$file.json" ]]; then
        rm -f -- "${out:?}/$file.json"
        log::info "$(t 'removed %s: no CDN_DOMAIN' "$out/$file.json")"
        changed=$((changed + 1))
      fi
    done
  fi
  jq -e . "$out"/*.json >/dev/null || log::die "$EXIT_FAILURE" "$(t 'the files in %s are not valid JSON' "$out")"
  remnawave::_guide "$out" "$changed"
}

# Renders remnawave/NAME with the .env values it names and checks that it is JSON.
# NODE_TAG, the node name in capitals, ends the inbound tags: the panel wants every tag
# unique across its profiles.
remnawave::_render() {
  local name="$1" out
  # shellcheck disable=SC2016  # envsubst takes the placeholder list literally
  out="$(CDN_DOMAIN="${CDN_DOMAIN:-}" XHTTP_PATH="${XHTTP_PATH:-}" XHTTP_PORT="${XHTTP_PORT:-}" \
    HY2_DOMAIN="${HY2_DOMAIN:-}" REALITY_SNI="${REALITY_SNI:-}" \
    REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}" REALITY_SHORT_ID="${REALITY_SHORT_ID:-}" \
    NODE_TAG="${NODE_NAME^^}" \
    envsubst '${CDN_DOMAIN} ${XHTTP_PATH} ${XHTTP_PORT} ${HY2_DOMAIN} ${REALITY_SNI} ${REALITY_PRIVATE_KEY} ${REALITY_SHORT_ID} ${NODE_TAG}' \
    <"$REPO_ROOT/remnawave/$name")"
  jq -e . >/dev/null <<<"$out" || log::die "$EXIT_FAILURE" "$(t 'remnawave/%s does not render to valid JSON' "$name")"
  printf '%s' "$out"
}

# The operator's own domains, as the subscription template routes them direct: the zone
# of CDN_DOMAIN, which Timeweb wants as a subdomain, or of VLESS_DOMAIN without a CDN, and
# any other domain outside it.
remnawave::_own_domains() {
  local base="${CDN_DOMAIN:-${VLESS_DOMAIN:-}}" zone domain
  local -a own
  zone="$base"
  if [[ "$base" == *.*.* ]]; then
    zone="${base#*.}"
  fi
  own=("domain:$zone")
  for domain in "${VLESS_DOMAIN:-}" "${HY2_DOMAIN:-}"; do
    if [[ -n "$domain" && "$domain" != "$zone" && "$domain" != *".$zone" &&
      " ${own[*]} " != *" domain:$domain "* ]]; then
      own+=("domain:$domain")
    fi
  done
  jq -cn '$ARGS.positional' --args "${own[@]}"
}

# Dies naming each synced field that differs, and when the client may post more than the
# server accepts (scMaxEachPostBytes).
remnawave::_check_sync() {
  local inbound="$1" host="$2" problems
  problems="$(jq -rn --argjson inbound "$inbound" --argjson host "$host" \
    --args '$inbound.streamSettings.xhttpSettings as $x
      | ([$ARGS.positional[] | select($x.extra[.] != $host[.])
          | "\(.): inbound \($x.extra[.] | tojson), host \($host[.] | tojson)"]
        + (if ($host.scMaxEachPostBytes // 0) > ($x.scMaxEachPostBytes // 1000000)
           then ["scMaxEachPostBytes: host \($host.scMaxEachPostBytes) is above the inbound limit \($x.scMaxEachPostBytes // 1000000)"]
           else [] end))[]' "${REMNAWAVE_SYNCED[@]}")"
  if [[ -n "$problems" ]]; then
    log::die "$EXIT_FAILURE" "$(t 'the inbound and the host extra in remnawave/ disagree, the tunnel would break through the CDN: %s' "$(paste -sd';' <<<"$problems")")"
  fi
}

# The steps, as data for the operator, so they go to stdout. PAUSE (the count of changed
# files) makes a terminal session wait after each step: a rerun with the same files only
# lists them.
remnawave::_guide() {
  local out="${1#"$REPO_ROOT"/}" pause="$2" step=0 inbounds="" address bold="" reset=""
  local tag="${NODE_NAME^^}" ip title own_profile="" hosts_file=""
  local -a hosts=()
  # The colours follow stderr; a guide sent to a file stays plain.
  if [[ -t 1 ]]; then
    bold="$UI_BOLD" reset="$UI_RESET"
  fi
  if [[ -n "${REALITY_SNI:-}" ]]; then
    inbounds="$(t 'VLESS-REALITY-%s on :443/tcp' "$tag")"
  fi
  if env::has_cdn; then
    inbounds+="${inbounds:+, }$(t 'VLESS-XHTTP-CDN-%s on 127.0.0.1:%s' "$tag" "$XHTTP_PORT")"
  fi
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    inbounds+="${inbounds:+, }$(t 'HYSTERIA2-%s on :443/udp' "$tag")"
  fi
  ip="${ORIGIN_IP:-$(t '<IP of this server>')}"
  address="${VLESS_DOMAIN:-$ip}"
  title="$(t 'Remnawave panel, step by step.')"
  if env::has_cdn; then
    title="$(t 'Remnawave panel and the CDN resource, step by step.')"
    own_profile="$(t 'The node keeps a profile of its own? Put only %s/inbound-xhttp-cdn.json into its "inbounds".' "$out")"
    hosts_file="$REPO_ROOT/$out/host-xhttp-extra.json"
    hosts+=("$(t 'CDN: inbound VLESS-XHTTP-CDN-%s, address %s, port 443. Advanced: SNI and host %s, path %s, security TLS, extra <- %s/host-xhttp-extra.json' \
      "$tag" "$CDN_DOMAIN" "$CDN_DOMAIN" "$XHTTP_PATH" "$out")")
  fi
  if [[ -n "${REALITY_SNI:-}" ]]; then
    hosts+=("$(t 'Reality: inbound VLESS-REALITY-%s, address %s, port 443' "$tag" "$address")")
  fi
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    hosts+=("$(t 'Hysteria2: inbound HYSTERIA2-%s, address %s, port 443. Advanced: SNI %s' "$tag" "$HY2_DOMAIN" "$HY2_DOMAIN")")
  fi

  printf '\n%s%s%s %s\n' "$bold" "$title" "$reset" "$(t 'The files are in %s/.' "$out")"
  # Profile names are unique in the panel too, so the node name serves as one.
  remnawave::_step "$REPO_ROOT/$out/config-profile.json" "$(t 'Config profile')" \
    "$(t 'Config Profiles -> Create Config Profile -> the name %s -> paste %s/config-profile.json -> Save.' "$tag" "$out")" \
    "$(t 'Inbounds: %s.' "$inbounds")" "$own_profile"
  # The panel asks for the profile when it creates a node, so the node comes second. Its
  # questions take the place of the wait.
  remnawave::_print "$(t 'Node')" \
    "$(t 'New node: Nodes -> Management -> Create node, address %s; on the last step choose the profile from step 1 with all its inbounds -> Create node.' "$ip")" \
    "$(t 'The panel then shows docker-compose.yml: ./deploy.sh takes its SECRET_KEY and NODE_PORT once, keeps them in .env and runs the node from %s, installing Docker when it is missing.' "$NODE_COMPOSE")" \
    "$(t 'A node already in the panel: the node card -> Change Profile -> the profile from step 1 with all its inbounds.')"
  remnawave::_node
  remnawave::_step "" "$(t 'Internal squad')" \
    "$(t 'Internal Squads -> the squad of your users (Default-Squad) -> turn the new inbounds on -> Save.')"
  remnawave::_step "$REPO_ROOT/$out/subscription-xray-json.json" "$(t 'Subscription template')" \
    "$(t 'Templates -> Xray JSON -> a new template -> paste %s/subscription-xray-json.json -> Save.' "$out")"
  remnawave::_step "$hosts_file" \
    "$(t 'Hosts: Hosts -> Create new host, one per inbound; Advanced -> Xray JSON template: the one from step 4')" \
    "${hosts[@]}"
  if env::has_cdn; then
    # The check through the CDN follows this step: the pause waits for Timeweb.
    remnawave::_step_until "$(t 'Press Enter once the CDN resource is set up: the certificate issued and attached, the changes applied (up to 30 minutes). The check through the CDN comes next.')" \
      "$(t 'CDN resource (Timeweb)')" \
      "$(t 'Source: %s:%s, HTTPS for the source on.' "$ip" "${NGINX_TLS_PORT:-8444}")" \
      "$(t "Distribution domain %s: a CNAME to the technical domain of the resource (*.cdn.twcstorage.ru), then Let's Encrypt in the Timeweb panel." "$CDN_DOMAIN")" \
      "$(t 'Caching stays on; ignoring cache headers, always online and large file acceleration stay off.')"
    printf '\n%s\n' "$(t 'Obfuscation fields stay identical in the inbound and the host extra (remnawave/README.md).')"
  fi
}

# Prints a step, then waits per remnawave::_guide. FILE, when the step pastes one into the
# panel, shows on s: no second session to read it.
remnawave::_step() {
  local file="$1"
  shift
  remnawave::_print "$@"
  if ((pause > 0)) && remnawave::_interactive; then
    remnawave::_wait "$file"
  fi
}

# A step without a file whose pause says what to wait for: PROMPT, then TITLE and LINEs as
# remnawave::_step takes them.
remnawave::_step_until() {
  local prompt="$1"
  shift
  remnawave::_print "$@"
  if ((pause > 0)) && remnawave::_interactive; then
    remnawave::_wait "" "$prompt"
  fi
}

# Waits for Enter; s (ы on a Russian layout) prints FILE to copy it from the terminal.
# PROMPT, when given, replaces the plain one of a step without a file.
remnawave::_wait() {
  local file="$1" key LC_ALL=C.UTF-8
  remnawave::_ask_done "$file" "${2-}"
  while IFS= read -rsn1 key; do
    case "$key" in
      "") break ;;
      s | S | ы | Ы)
        if [[ -n "$file" ]]; then
          printf '\n' >&2
          remnawave::_show "$file"
          remnawave::_ask_done "$file"
        fi
        ;;
    esac
  done
  printf '\n' >&2
}

remnawave::_ask_done() {
  if [[ -n "$1" ]]; then
    printf '     %s%s%s ' "$UI_DIM" "$(t 'Enter when done, s shows %s:' "${1##*/}")" "$UI_RESET" >&2
  else
    printf '     %s%s%s ' "$UI_DIM" "${2:-$(t 'Press Enter when done.')}" "$UI_RESET" >&2
  fi
}

# Prints FILE between two plain lines: no colour and no indent in what is copied.
remnawave::_show() {
  printf -- '----- %s -----\n' "$(t '%s: copy from the next line' "${1#"$REPO_ROOT"/}")" >&2
  cat "$1" >&2
  printf -- '----- %s -----\n' "$(t 'end of %s' "${1##*/}")" >&2
}

# Prints step TITLE with its LINEs, skipping the empty ones.
remnawave::_print() {
  local title="$1" line
  shift
  step=$((step + 1))
  printf '\n  %s%d. %s%s\n' "$bold" "$step" "$title" "$reset"
  for line in "$@"; do
    if [[ -n "$line" ]]; then
      printf '     %s\n' "$line"
    fi
  done
}

# Starts the node of step 2 on this server. Without a SECRET_KEY from .env, from the
# compose file of a node set up by hand or from the terminal, the node waits for one.
remnawave::_node() {
  if prompt::node "$(node::compose_value SECRET_KEY)" "$(node::compose_value NODE_PORT)"; then
    node::install
  else
    log::warn "$(t 'no SECRET_KEY for the node: put SECRET_KEY and NODE_PORT from the docker-compose.yml that the panel shows into %s as NODE_SECRET_KEY and NODE_PORT, rerun ./deploy.sh' "$ENV_FILE")"
  fi
}

remnawave::_interactive() {
  [[ -t 0 ]]
}
