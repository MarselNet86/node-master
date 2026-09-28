#!/usr/bin/env bats
# Contract tests for the Russian messages of lib/i18n-ru.sh: every English format that the
# code passes to t has a translation with the same conversions in the same order, and the
# catalogue holds nothing else.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  # A copy points ENV_FILE at $TMP/repo/.env, away from the real checkout.
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$TMP/bin"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  # No network: the curl stub fails, so ORIGIN_IP is typed.
  printf '#!/bin/sh\nexit 7\n' >"$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
  PATH="$TMP/bin:$PATH"
  # shellcheck source=../lib/prompt.sh
  source "$REPO/lib/prompt.sh"
}

teardown() {
  rm -rf "${TMP:?}"
}

# Prints the formats of the t calls in the code, one per line: single-quoted, double-quoted
# without a variable, or a bare word.
formats() {
  perl -ne '
    while (/(?:^|[\s(;|&])t \x27([^\x27]*)\x27/g) { print "$1\n" }
    while (/(?:^|[\s(;|&])t "((?:[^"\\]|\\.)*)"/g) {
      my $f = $1;
      next if $f =~ /\$/;
      $f =~ s/\\(["\\`])/$1/g;
      print "$f\n";
    }
    while (/(?:^|[\s(;|&])t ([A-Za-z][A-Za-z0-9]*)\)/g) { print "$1\n" }
  ' "$BATS_TEST_DIRNAME"/../deploy.sh "$BATS_TEST_DIRNAME"/../lib/*.sh | sort -u
}

conversions() {
  grep -o '%[sd]' <<<"$1" | tr -d '\n' || true
}

@test "every message of the code has a Russian translation with the same conversions" {
  local format bad=0
  while IFS= read -r format; do
    if [[ -z "${I18N_RU[$format]+set}" ]]; then
      echo "no translation: $format"
      bad=1
    elif [[ "$(conversions "$format")" != "$(conversions "${I18N_RU[$format]}")" ]]; then
      echo "other conversions: $format"
      bad=1
    fi
  done < <(formats)
  ((bad == 0))
}

@test "the catalogue holds no message the code does not use" {
  local key used bad=0
  used="$(formats)"
  for key in "${!I18N_RU[@]}"; do
    # The hint of a menu comes from a variable: UI_KEYS.
    if [[ "$key" == "up, down, Enter" ]]; then
      continue
    fi
    grep -qxF -- "$key" <<<"$used" || {
      echo "unused: $key"
      bad=1
    }
  done
  ((bad == 0))
}

@test "t prints English by default and Russian under I18N_LANG=ru, English where none" {
  [ "$(t 'wrote %s (mode %s)' /etc/x 600)" = "wrote /etc/x (mode 600)" ]
  [ "$(I18N_LANG=ru t 'wrote %s (mode %s)' /etc/x 600)" = "записан /etc/x (права 600)" ]
  [ "$(I18N_LANG=ru t 'no such message %s' x)" = "no such message x" ]
  run log::die 4 "$(I18N_LANG=ru t 'root privileges required: rerun with sudo')"
  [ "$status" -eq 4 ]
  [ "$output" = "[ERROR] нужны права root: запустите через sudo" ]
}

@test "the language comes from UI_LANG in .env, else from the locale, and off a terminal nobody is asked" {
  LC_ALL="" LC_MESSAGES="" LANG=C.UTF-8 prompt::language ask </dev/null
  [ "$I18N_LANG" = en ]
  LC_ALL="" LC_MESSAGES="" LANG=ru_RU.UTF-8 prompt::language
  [ "$I18N_LANG" = ru ]
  [ "$UI_LANG" = ru ]
  printf 'UI_LANG="en" # set by hand\n' >"$ENV_FILE"
  LC_ALL="" LC_MESSAGES="" LANG=ru_RU.UTF-8 prompt::language ask </dev/null
  [ "$I18N_LANG" = en ]
}

@test "a .env that gives no language leaves it to the locale" {
  local env
  # A value other than en or ru, then files that step 2 rejects.
  for env in 'UI_LANG=russian' $'VLESS_DOMAIN\nUI_LANG=ru' $'UI_LANG=ru\nCDN_DOMAIN="cdn'; do
    printf '%s\n' "$env" >"$ENV_FILE"
    LC_ALL="" LC_MESSAGES="" LANG=C.UTF-8 prompt::language
    [ "$I18N_LANG" = en ] || {
      echo "a .env with $env gave $I18N_LANG"
      return 1
    }
  done
  # Root reads any file.
  if ((EUID != 0)); then
    printf 'UI_LANG=ru\n' >"$ENV_FILE"
    chmod 000 "$ENV_FILE"
    LC_ALL="" LC_MESSAGES="" LANG=C.UTF-8 prompt::language
    [ "$I18N_LANG" = en ]
  fi
}

@test "a Russian run asks in Russian and keeps the language in .env" {
  printf '%s\n' vless.example.com hy2.example.com cdn.example.com 203.0.113.10 "" "" "" "" "" >"$TMP/answers"
  I18N_LANG=ru run prompt::collect <"$TMP/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Домен этого сервера для origin nginx и прямого VLESS (A-запись на этот сервер, порт 80 открыт: Let's Encrypt проверяет его по HTTP)"* ]]
  [[ "$output" == *"[INFO] Enter оставляет значение в [скобках]"* ]]
  grep -qx 'UI_LANG=ru' "$ENV_FILE"
}

@test "on a terminal the language is picked first from a menu" {
  script --version >/dev/null 2>&1 || skip "needs script from util-linux for a terminal"
  printf 'source %q\n' "$REPO/lib/prompt.sh" >"$TMP/lang.sh"
  cat >>"$TMP/lang.sh" <<'EOF'
prompt::language ask
echo "picked=$I18N_LANG"
t 'deploy finished'
echo
EOF
  {
    sleep 1
    printf '\e[B\n'
    sleep 1
  } | TERM=xterm LANG=C.UTF-8 timeout 20 script -qec "bash $TMP/lang.sh" /dev/null >"$TMP/out" 2>&1 || true
  grep -q 'Language / Язык' "$TMP/out"
  grep -q 'picked=ru' "$TMP/out"
  grep -q 'развёртывание закончено' "$TMP/out"
}

@test "without colour a terminal types the language" {
  script --version >/dev/null 2>&1 || skip "needs script from util-linux for a terminal"
  printf 'source %q\n' "$REPO/lib/prompt.sh" >"$TMP/lang.sh"
  cat >>"$TMP/lang.sh" <<'EOF'
prompt::language ask
echo "picked=$I18N_LANG"
EOF
  {
    sleep 1
    printf 'de\n'
    sleep 1
    printf ' RU \n'
    sleep 1
  } | NO_COLOR=1 TERM=xterm LANG=C.UTF-8 timeout 20 script -qec "bash $TMP/lang.sh" /dev/null >"$TMP/out" 2>&1 || true
  grep -q 'Language / Язык (en, ru)' "$TMP/out"
  grep -q 'UI_LANG \[en\]: ' "$TMP/out"
  grep -q '\[WARN\] UI_LANG: type en or ru / введите en или ru' "$TMP/out"
  grep -q 'picked=ru' "$TMP/out"
}
