#!/usr/bin/env bats
# Contract tests for deploy.sh (tech.md §7): flags and the --dry-run plan.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  # A copy gives each test its own .env state and shows that a dry run writes nothing.
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$TMP/stubs"
  cp -R "$BATS_TEST_DIRNAME/../deploy.sh" "$BATS_TEST_DIRNAME/../lib" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  # Stubs record any call to a command that changes the system.
  local cmd
  for cmd in apt-get dpkg certbot nginx systemctl sysctl docker curl ln; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$cmd" "$TMP" >"$TMP/stubs/$cmd"
    chmod +x "$TMP/stubs/$cmd"
  done
}

teardown() {
  rm -rf "${TMP:?}"
}

# Runs the copy on empty stdin with the stubs first in PATH. $output holds stdout only;
# stderr goes to $TMP/stderr.
deploy() {
  run bash -c 'PATH="$1:$PATH" "$2" "${@:4}" </dev/null 2>"$3"' _ \
    "$TMP/stubs" "$REPO/deploy.sh" "$TMP/stderr" "$@"
}

has_line() {
  printf '%s\n' "$output" | grep -Eq "$1" || {
    echo "no line matches: $1"
    return 1
  }
}

step_line() {
  printf '%s\n' "$output" | grep -E "^ +[0-9]+\. $1 "
}

@test "--dry-run prints the plan on empty input and exits 0" {
  local steps
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "cdn-deploy dry run: nothing is changed."* ]]
  steps="$(printf '%s\n' "$output" | sed -nE 's/^ +[0-9]+\. ([a-z-]+) .*/\1/p' | tr '\n' ' ')"
  [ "$steps" = "preflight input config packages certs renew-hook sysctl nginx remnawave validate " ]
}

@test "--dry-run on empty input shows the contract defaults and unset required values" {
  deploy --dry-run
  [ "$status" -eq 0 ]
  has_line '^Settings \(no \.env yet'
  has_line '^ +VLESS_DOMAIN +<unset>$'
  has_line '^ +XHTTP_PORT +4443$'
  has_line '^ +XHTTP_PATH +/api/v2\.jpg/$'
  has_line '^ +NGINX_TLS_PORT +8444$'
  has_line 'nginx .*:8444 <CDN_DOMAIN> \(certificate of <VLESS_DOMAIN>\) -> 127\.0\.0\.1:4443'
  has_line '^ +NODE_PORT +2222$'
  has_line '^ +NODE_SECRET_KEY +<unset>$'
  has_line 'remnawave .*start the node from /opt/remnanode/docker-compose\.yml with its SECRET_KEY, installing Docker'
}

@test "--dry-run changes nothing" {
  local before after
  before="$(cd "$REPO" && find . -type f -exec cksum {} + | sort)"
  deploy --dry-run
  [ "$status" -eq 0 ]
  after="$(cd "$REPO" && find . -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$REPO/.env" ]
  [ ! -e "$TMP/calls" ]
}

@test "--dry-run shows .env values and hides secrets" {
  cat >"$REPO/.env" <<'EOF'
VLESS_DOMAIN=vless.example.com
HY2_DOMAIN=hy2.example.com
CDN_DOMAIN=cdn.example.com
ORIGIN_IP=203.0.113.10
XHTTP_PORT=4450
REALITY_PRIVATE_KEY=c3ludGhldGljLXJlYWxpdHkta2V5LWZvci10ZXN0cyE
NODE_SECRET_KEY=bm9kZS1zZWNyZXQtZm9yLXRlc3Rz
EOF
  chmod 600 "$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 0 ]
  has_line '^ +VLESS_DOMAIN +vless\.example\.com$'
  has_line '^ +REALITY_PRIVATE_KEY +<hidden>$'
  has_line '^ +NODE_SECRET_KEY +<hidden>$'
  has_line 'remnawave .*with its SECRET_KEY and /etc/letsencrypt mounted for Hysteria2'
  has_line 'certs .*via HTTP-01 on :80: vless\.example\.com hy2\.example\.com; skip'
  has_line 'nginx .*:8444 cdn\.example\.com \(certificate of vless\.example\.com\) -> 127\.0\.0\.1:4450'
  [[ "$output $(cat "$TMP/stderr")" != *c3ludGhldGljLXJl* ]]
  [[ "$output $(cat "$TMP/stderr")" != *bm9kZS1zZWNyZXQ* ]]
}

@test "--dry-run plans no CDN certificate and :80 hooks for every renewal" {
  printf 'VLESS_DOMAIN=vless.example.com\nCDN_DOMAIN=cdn.example.com\nCERT_MODE=dns-cloudflare\n' >"$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$(step_line certs)" != *cdn.example.com* ]]
  [[ "$(step_line renew-hook)" == *"pre/post hooks open :80 for HTTP-01"* ]]
  [[ "$(step_line nginx)" == *"(certificate of vless.example.com)"* ]]
  # A CERT_MODE left from an older .env passes without a word.
  [[ "$(cat "$TMP/stderr")" != *CERT_MODE* ]]
}

@test "--dry-run plans no node restart without HY2_DOMAIN" {
  printf 'VLESS_DOMAIN=vless.example.com\nCDN_DOMAIN=cdn.example.com\nORIGIN_IP=203.0.113.10\n' >"$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$(step_line certs)" == *"via HTTP-01 on :80: vless.example.com; skip"* ]]
  [[ "$(step_line renew-hook)" == *"no node restart: HY2_DOMAIN is not set"* ]]
}

@test "--dry-run warns that a real run stops without VLESS_DOMAIN" {
  printf 'CDN_DOMAIN=cdn.example.com\n' >"$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMP/stderr")" == *"a real run stops here: required settings are empty: VLESS_DOMAIN"* ]]
  [[ "$(step_line nginx)" == *"(certificate of <VLESS_DOMAIN>)"* ]]
}

@test "--dry-run exits 2 on a malformed .env" {
  printf 'VLESS_DOMAIN\n' >"$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 2 ]
  [[ "$(cat "$TMP/stderr")" == *".env:1: expected KEY=VALUE"* ]]
}

@test "--dry-run warns about failing guards instead of stopping" {
  deploy --dry-run
  [ "$status" -eq 0 ]
  if ((EUID != 0)); then
    [[ "$(cat "$TMP/stderr")" == *"a real run stops here: root privileges required"* ]]
  fi
}

@test "--help prints usage and exits 0" {
  deploy --help
  [ "$status" -eq 0 ]
  [[ "$output" == Usage:* ]]
}

@test "an unknown option exits 2" {
  deploy --force
  [ "$status" -eq 2 ]
  [[ "$(cat "$TMP/stderr")" == *"unknown option: --force"* ]]
}

@test "a real run without root exits 4 and touches nothing" {
  ((EUID != 0)) || skip "running as root: a real run would change this system"
  deploy
  [ "$status" -eq 4 ]
  [ ! -e "$REPO/.env" ]
  [ ! -e "$TMP/calls" ]
}

@test "the packages step installs every command a module requires, beyond the base system" {
  local cmd pkg plan missing=""
  local -A from=([sysctl]=procps [systemctl]=base [certbot]=certbot [openssl]=openssl
    [nginx]=nginx [envsubst]=gettext-base [curl]=curl [jq]=jq)
  deploy --dry-run
  plan="$(printf '%s\n' "$output" | sed -nE 's/.* packages +install missing: //p')"
  [ -n "$plan" ]
  for cmd in $(grep -ho 'require::cmd [a-z0-9 -]*' "$REPO"/lib/*.sh | cut -d' ' -f2- | tr ' ' '\n' | sort -u); do
    pkg="${from[$cmd]:-}"
    [ -n "$pkg" ] || {
      echo "no package known for $cmd: add it to the table"
      return 1
    }
    [[ "$pkg" == base || " $plan " == *" $pkg "* ]] || missing+=" $cmd ($pkg)"
  done
  [ -z "$missing" ] || {
    echo "not installed:$missing"
    return 1
  }
}

@test "every step is wired to its module" {
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"not implemented"* ]]
}
