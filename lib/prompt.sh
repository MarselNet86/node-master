# shellcheck shell=bash
# Collects the .env contract (tech.md §4) interactively: asks in table order, checks
# every answer, writes .env with mode 600. Values of an existing .env are the defaults.

set -euo pipefail

# Modules may source this file again; readonly constants must not be redefined.
if [[ -n "${_CDN_PROMPT_LOADED:-}" ]]; then
  return 0
fi
_CDN_PROMPT_LOADED=1

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

prompt::collect() {
  local key
  env::load "$ENV_EXAMPLE"
  if [[ -f "$ENV_FILE" ]]; then
    env::load "$ENV_FILE"
    log::info "$(t 'current values from %s are the defaults' "$ENV_FILE")"
  fi
  log::info "$(t 'Enter keeps the value in [brackets]')"
  for key in "${ENV_KEYS[@]}"; do
    # A key left without a question keeps its current value.
    if ! prompt::_asks "$key"; then
      continue
    fi
    prompt::_number "$key"
    case "$key" in
      ORIGIN_IP) prompt::_ask_origin_ip ;;
      REALITY_PRIVATE_KEY | REALITY_SHORT_ID) prompt::_ask_reality "$key" ;;
      NODE_NAME) prompt::_ask_node_name ;;
      *) prompt::_ask "$key" ;;
    esac
  done
  UI_NUMBER=""
  prompt::_write_env
}

# Whether KEY gets a question under the answers so far. A question that hangs on the
# answer for a key in PENDING, a list of keys still to ask, counts as asked.
prompt::_asks() {
  local key="$1" pending=" ${2-} " by
  case "$key" in
    # Panel step 2 asks for them: the panel creates the node from the rendered profile.
    NODE_PORT | NODE_SECRET_KEY) return 1 ;;
    NODE_RELOAD_CMD) by=HY2_DOMAIN ;;
    REALITY_PRIVATE_KEY | REALITY_SHORT_ID) by=REALITY_SNI ;;
    *) return 0 ;;
  esac
  if [[ "$pending" == *" $by "* ]]; then
    return 0
  fi
  case "$key" in
    # The restart makes the node load a renewed HY2_DOMAIN certificate.
    NODE_RELOAD_CMD) [[ -n "${HY2_DOMAIN:-}" ]] ;;
    # Without REALITY_SNI there is no Reality inbound.
    *) [[ -n "${REALITY_SNI:-}" ]] ;;
  esac
}

# Numbers the question for KEY in UI_NUMBER, as "3/14". KEY and the keys after it are
# pending, so the total counts every question they may bring and only goes down.
prompt::_number() {
  local key="$1" k n=0 total=0 pending=""
  for k in "${ENV_KEYS[@]}"; do
    if [[ "$k" == "$key" || -n "$pending" ]]; then
      pending+="$k "
    fi
    if prompt::_asks "$k" "$pending"; then
      total=$((total + 1))
      if [[ "$k" == "$key" ]]; then
        n="$total"
      fi
    fi
  done
  UI_NUMBER="$n/$total"
}

# Checks VALUE for KEY against the contract (tech.md §4) and the answers given before
# it in table order. Prints the reason and returns 1 when the value is rejected.
prompt::validate() {
  local key="$1" value="$2" reason="" sample
  case "$key" in
    VLESS_DOMAIN | HY2_DOMAIN | CDN_DOMAIN)
      sample="${key%%_*}"
      # Hysteria2 is optional: a server that already runs it adds only the CDN. VLESS_DOMAIN
      # is not: HTTP-01 issues the certificate of origin nginx for it.
      if [[ -z "$value" && "$key" == HY2_DOMAIN ]]; then
        :
      elif [[ -z "$value" && "$key" == VLESS_DOMAIN ]]; then
        reason="$(t 'required: a domain of this server with an A record, origin nginx serves its certificate')"
      elif ! is::fqdn "$value"; then
        reason="$(t 'expected a domain name like %s.example.com%s' "${sample,,}" "$(prompt::_foreign_chars "$value")")"
      elif [[ "$key" == CDN_DOMAIN &&
        ("$value" == "${VLESS_DOMAIN:-}" || "$value" == "${HY2_DOMAIN:-}") ]]; then
        reason="$(t 'must differ from VLESS_DOMAIN and HY2_DOMAIN: it resolves to the CDN, they resolve to this server')"
      elif [[ "$key" != CDN_DOMAIN && "$value" == "${CDN_DOMAIN:-}" ]]; then
        reason="$(t 'must differ from CDN_DOMAIN: it resolves to this server, CDN_DOMAIN to the CDN')"
      fi
      ;;
    ORIGIN_IP)
      is::ipv4 "$value" || reason="$(t 'expected an IPv4 address like 203.0.113.10')"
      ;;
    XHTTP_PORT | NGINX_TLS_PORT)
      if ! is::port "$value"; then
        reason="$(t 'expected a port from 1 to 65535')"
      elif ((value == 443)); then
        reason="$(t '443 belongs to xray: Reality over TCP, Hysteria2 over UDP')"
      elif [[ "$key" == NGINX_TLS_PORT && "$value" == "${XHTTP_PORT:-}" ]]; then
        reason="$(t 'must differ from XHTTP_PORT: nginx would take the port of the xray inbound')"
      fi
      ;;
    XHTTP_PATH)
      # Unreserved URL characters only: the path lands in nginx locations and in JSON.
      if [[ ! "$value" =~ ^/([A-Za-z0-9._~-]+/)+$ || "$value" == */./* || "$value" == */../* ]]; then
        reason="$(t 'expected a path like /api/v2.jpg/: starts and ends with /, letters, digits and . _ ~ -')"
      fi
      ;;
    LE_EMAIL)
      if [[ -n "$value" ]] && ! prompt::_is_email "$value"; then
        reason="$(t 'expected an email like ops@example.com, or - for none')"
      fi
      ;;
    NODE_RELOAD_CMD)
      if [[ -z "$value" ]]; then
        reason="$(t 'expected a command like: docker restart remnanode')"
      elif [[ "$value" == *\'* && "$value" == *\"* ]]; then
        reason="$(t 'use either single or double quotes: .env keeps the command as one quoted value')"
      fi
      ;;
    REALITY_SNI)
      if [[ -n "$value" ]] && ! is::fqdn "$value"; then
        reason="$(t 'expected a domain name like www.swiss.com, or - for no Reality%s' "$(prompt::_foreign_chars "$value")")"
      fi
      ;;
    REALITY_PRIVATE_KEY)
      # 32 bytes in unpadded base64url, the form xray x25519 prints.
      [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]] ||
        reason="$(t 'expected an x25519 private key: 43 characters of base64url')"
      ;;
    REALITY_SHORT_ID)
      [[ "$value" =~ ^([0-9a-f]{2}){1,8}$ ]] || reason="$(t 'expected 2 to 16 hex digits, an even count')"
      ;;
    NODE_NAME)
      [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$ ]] ||
        reason="$(t 'expected a short name like de1: up to 16 letters, digits and inner -%s' "$(prompt::_foreign_chars "$value" a-z0-9-)")"
      ;;
    NODE_PORT)
      if ! is::port "$value"; then
        reason="$(t 'expected a port from 1 to 65535, NODE_PORT in the docker-compose.yml of the panel')"
      elif [[ "$value" == 443 || "$value" == "${XHTTP_PORT:-}" || "$value" == "${NGINX_TLS_PORT:-}" ]]; then
        reason="$(t 'must differ from 443, XHTTP_PORT and NGINX_TLS_PORT: xray and nginx listen there')"
      fi
      ;;
    NODE_SECRET_KEY)
      reason="$(prompt::_node_key_problem "$value")"
      ;;
    *) reason="$(t '%s is not in the .env contract' "$key")" ;;
  esac
  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason"
    return 1
  fi
}

# What is wrong with a SECRET_KEY, if anything. The node takes base64 of a JSON object with
# four PEM strings (remnawave/node 3.4 checks the same), so a mangled paste shows up here
# and not in the node log.
prompt::_node_key_problem() {
  local value="$1"
  if [[ -z "$value" ]]; then
    t 'nothing entered: copy SECRET_KEY from the docker-compose.yml that the panel shows for the node'
  elif [[ ! "$value" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
    t 'expected SECRET_KEY from the panel: base64, letters, digits, + and /%s' "$(prompt::_foreign_chars "$value" 'A-Za-z0-9+/=')"
  elif ! base64 -d <<<"$value" 2>/dev/null |
    jq -e 'type == "object" and ([.caCertPem, .jwtPublicKey, .nodeCertPem, .nodeKeyPem] | all(type == "string"))' \
      >/dev/null 2>&1; then
    t 'it does not decode to the node certificates (caCertPem, jwtPublicKey, nodeCertPem, nodeKeyPem): copy the whole value from the panel'
  fi
}

# Lowercases the case-insensitive values; "-" clears the optional ones. A SECRET_KEY
# pasted with its line from docker-compose.yml keeps only the value.
prompt::_normalize() {
  local key="$1" value="$2"
  case "$key" in
    VLESS_DOMAIN | HY2_DOMAIN | LE_EMAIL | REALITY_SNI)
      if [[ "$value" == - ]]; then
        value=""
      fi
      ;;
    NODE_SECRET_KEY)
      value="$(prompt::_trim "${value#-}")"
      if [[ "$value" == SECRET_KEY* ]]; then
        value="$(prompt::_trim "${value#SECRET_KEY}")"
        value="$(prompt::_trim "${value#[=:]}")"
      fi
      case "$value" in
        \"*\" | \'*\') value="${value:1:${#value}-2}" ;;
      esac
      ;;
  esac
  case "$key" in
    *_DOMAIN | REALITY_SNI | REALITY_SHORT_ID | NODE_NAME) value="${value,,}" ;;
  esac
  printf '%s' "$value"
}

prompt::_is_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@([^@]+)$ ]] && is::fqdn "${BASH_REMATCH[1]}"
}

# --- questions --------------------------------------------------------------------------

# Asks for KEY until prompt::validate accepts the answer, then sets and exports KEY.
# Enter takes DEFAULT (the current value unless given); LABEL is shown in its place.
# Once stdin runs out, an acceptable default is taken and anything else is an error,
# so deploy.sh runs without a terminal when .env is complete.
prompt::_ask() {
  local key="$1" default label="${3-}" answer value reason eof cut hidden=0 text
  if (($# >= 2)); then
    default="$2"
  else
    default="${!key:-}"
  fi
  if [[ -z "$label" && -n "$default" ]]; then
    label="$default"
    if env::is_secret "$key"; then
      label="$(t 'keep current')"
    fi
  fi
  if [[ -t 0 ]] && env::is_secret "$key"; then
    hidden=1
  fi
  text="$(prompt::_question "$key")"
  ui::question "${text%%|*}" "${text#*|}"
  while true; do
    ui::field "$key" "$label"
    eof=0
    if ((hidden)); then
      IFS= read -rs answer || eof=1
    else
      IFS= read -r answer || eof=1
      # Without a terminal the answer is not echoed; end the line for the next message.
      [[ -t 0 ]] || printf '\n' >&2
    fi
    cut=0
    if [[ -t 0 ]] && (($(prompt::_bytes "$answer") >= 4095)); then
      cut=1
    fi
    answer="$(prompt::_trim "$answer")"
    if ((hidden)); then
      ui::hidden "${#answer}"
    fi
    # A terminal line holds 4095 bytes and drops the rest of a longer paste, so a line that
    # fills it lost its end.
    if ((cut)); then
      ui::rejected "$key" "$(t 'the terminal cut the paste at 4095 characters: put %s into %s by hand' "$key" "$ENV_FILE")"
      continue
    fi
    value="$(prompt::_normalize "$key" "${answer:-$default}")"
    if reason="$(prompt::validate "$key" "$value")"; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
      return 0
    fi
    if ((eof)); then
      log::die "$EXIT_INPUT" "$(t '%s: %s. Input ended: run ./deploy.sh in a terminal or complete %s' "$key" "$reason" "$ENV_FILE")"
    fi
    ui::rejected "$key" "$reason"
  done
}

# The length of S in bytes.
prompt::_bytes() {
  local LC_ALL=C
  printf '%d' "${#1}"
}

# Prints the question for KEY and, after a |, its hint.
prompt::_question() {
  case "$1" in
    VLESS_DOMAIN) t "Domain of this server for origin nginx and direct VLESS|an A record to this server, port 80 open: Let's Encrypt checks it over HTTP" ;;
    HY2_DOMAIN) t 'Domain for Hysteria2 whose certificate this script issues|an A record to this server; - for none' ;;
    CDN_DOMAIN) t 'Domain of the CDN resource|a CNAME to the CDN' ;;
    ORIGIN_IP) t 'Public IPv4 of this server|the origin of the CDN resource' ;;
    XHTTP_PORT) t 'Local port of the xray xhttp inbound|' ;;
    XHTTP_PATH) t 'xhttp path|the same in the panel inbound and host' ;;
    NGINX_TLS_PORT) t 'Port where nginx accepts connections from the CDN edge|' ;;
    LE_EMAIL) t "Let's Encrypt contact email|- for none" ;;
    NODE_RELOAD_CMD) t 'Command that restarts the node after the Hysteria2 certificate renews|certbot runs it after each renewal; remnanode is the container from the panel' ;;
    REALITY_SNI) t 'Site that VLESS Reality impersonates|TLS 1.3, close to this server, open from Russia; - for no Reality' ;;
    REALITY_PRIVATE_KEY) t 'Reality x25519 private key|input hidden' ;;
    REALITY_SHORT_ID) t 'Reality short id|hex' ;;
    NODE_NAME) t 'Short name of this node for the panel|the inbound tags end with it, de1 gives VLESS-REALITY-DE1: the panel wants every tag unique' ;;
    NODE_PORT) t 'NODE_PORT of the node|from the same docker-compose.yml; the panel connects to the node on it' ;;
    NODE_SECRET_KEY) t 'SECRET_KEY of the node|from the docker-compose.yml that the panel shows; input hidden: paste the value or its whole line' ;;
  esac
}

# A paste from a web page or a messenger can carry characters that a terminal does not
# show: zero-width space, non-joiner and joiner, the direction marks, the word joiner, the
# byte order mark and the soft hyphen. No setting holds them, so they go. No-break spaces
# (plain, figure, narrow), which [:space:] leaves out, count as spaces.
readonly -a PROMPT_INVISIBLE=($'\xe2\x80\x8b' $'\xe2\x80\x8c' $'\xe2\x80\x8d' $'\xe2\x80\x8e'
  $'\xe2\x80\x8f' $'\xe2\x81\xa0' $'\xef\xbb\xbf' $'\xc2\xad')
readonly -a PROMPT_NBSP=($'\xc2\xa0' $'\xe2\x80\x87' $'\xe2\x80\xaf')

prompt::_trim() {
  local s="$1" c
  for c in "${PROMPT_INVISIBLE[@]}"; do
    s="${s//"$c"/}"
  done
  for c in "${PROMPT_NBSP[@]}"; do
    s="${s//"$c"/ }"
  done
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Names the first characters of VALUE outside ALLOWED, a bracket expression that defaults
# to the characters of a domain, with their positions: a Cyrillic letter that looks Latin,
# a typographic dash, a key typed as a control code.
prompt::_foreign_chars() {
  local LC_ALL=C.UTF-8 s="$1" re="^[${2:-A-Za-z0-9.-}]$" ch n i code list="" found=0
  for ((i = 0; i < ${#s} && found < 3; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" =~ $re ]]; then
      continue
    fi
    printf -v n '%d' "'$ch"
    if ((n < 32 || n == 127)); then
      ch="$(t 'a control character (an arrow or another special key)')"
    elif ((n == 32)); then
      ch="$(t 'a space')"
    elif ((n < 128)); then
      ch="'$ch'"
    elif ((n >= 0x400 && n <= 0x4ff)); then
      ch="$(t 'Cyrillic %s' "$ch")"
    elif ((n >= 0x2010 && n <= 0x2015 || n == 0x2212)); then
      printf -v code 'U+%04X' "$n"
      ch="$(t 'a typographic dash %s (%s)' "$ch" "$code")"
    else
      printf -v ch '%s (U+%04X)' "$ch" "$n"
    fi
    list+="${list:+, }$(t '%s at %s' "$ch" "$((i + 1))")"
    # A special key types a whole escape sequence: its start says enough.
    if ((n < 32 || n == 127)); then
      break
    fi
    found=$((found + 1))
  done
  if [[ -n "$list" ]]; then
    t '; it holds %s' "$list"
  fi
}

# Without a value in .env, offers the IPv4 that ifconfig.me sees (tech.md §4).
prompt::_ask_origin_ip() {
  local detected
  if [[ -z "${ORIGIN_IP:-}" ]] && detected="$(prompt::_detect_ip)" &&
    confirm "$(t 'Detected public IPv4 %s. Use it as ORIGIN_IP?' "$detected")" y; then
    export ORIGIN_IP="$detected"
    return 0
  fi
  prompt::_ask ORIGIN_IP
}

prompt::_detect_ip() {
  local ip
  if ! command -v curl >/dev/null 2>&1; then
    log::warn "$(t 'curl not found: enter ORIGIN_IP by hand')"
    return 1
  fi
  # HTTPS, so nobody on the path can swap the address that gets confirmed.
  if ! ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null)" || ! is::ipv4 "$ip"; then
    log::warn "$(t 'cannot detect the public IPv4 via ifconfig.me: enter ORIGIN_IP by hand')"
    return 1
  fi
  printf '%s' "$ip"
}

# The Reality keys of the generated config profile. Enter keeps the keys of an existing
# .env, so a rerun does not break the clients; without them it takes new ones.
prompt::_ask_reality() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    prompt::_ask "$key"
  elif [[ "$key" == REALITY_PRIVATE_KEY ]]; then
    prompt::_ask "$key" "$(prompt::_new_reality_key)" "$(t 'new random')"
  else
    prompt::_ask "$key" "$(prompt::_new_short_id)"
  fi
}

# Any 32 random bytes make an x25519 private key: the curve clamps it on use.
prompt::_new_reality_key() {
  head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_'
}

prompt::_new_short_id() {
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Panel step 2: SECRET_KEY and NODE_PORT of the node that the panel has just created, from
# the docker-compose.yml it shows. Asked once and kept in .env. SECRET and PORT, the values
# of a compose file set up by hand, are the defaults, and input that has ended takes them.
# Returns 1 when no key comes from anywhere.
prompt::node() {
  local secret="$1" port="${2:-}"
  if [[ -n "${NODE_SECRET_KEY:-}" ]]; then
    return 0
  fi
  if [[ -z "$secret" && ! -t 0 ]]; then
    return 1
  fi
  UI_NUMBER=""
  prompt::_ask NODE_SECRET_KEY "$secret" "${secret:+$(t 'from docker-compose.yml')}"
  prompt::_ask NODE_PORT "${port:-${NODE_PORT:-}}"
  prompt::_write_env
}

# Without a name in .env, the first label of VLESS_DOMAIN names the node.
prompt::_ask_node_name() {
  local name="${NODE_NAME:-${VLESS_DOMAIN%%.*}}"
  prompt::_ask NODE_NAME "${name,,}"
}

# --- .env -----------------------------------------------------------------------------

# Writes .env with mode 600: it holds the Reality private key and the SECRET_KEY of the node.
prompt::_write_env() {
  local key
  for key in "${ENV_KEYS[@]}"; do
    if [[ "${!key:-}" == *\'* && "${!key:-}" == *\"* ]]; then
      log::die "$EXIT_INPUT" "$(t "%s holds both ' and \": .env cannot keep it, fix it in %s" "$key" "$ENV_FILE")"
    fi
  done
  fs::write "$ENV_FILE" 600 "$(prompt::_render_env)"
}

prompt::_render_env() {
  local key
  printf '# cdn-deploy settings, described in .env.example. Written by ./deploy.sh: rerun it to change them.\n'
  for key in "${ENV_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "$(prompt::_quote "${!key:-}")"
  done
}

# Quotes a value so that env::load reads it back unchanged.
prompt::_quote() {
  if [[ "$1" =~ ^[A-Za-z0-9._~@%+=:,/-]*$ ]]; then
    printf '%s' "$1"
  elif [[ "$1" != *\'* ]]; then
    printf "'%s'" "$1"
  else
    printf '"%s"' "$1"
  fi
}
