#!/usr/bin/env bats
# Contract tests for the Russian messages of lib/i18n-ru.sh: every English format that the
# code passes to t has a translation with the same conversions in the same order, and the
# catalogue holds nothing else.

setup() {
  # shellcheck source=../lib/common.sh
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
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
