#!/usr/bin/env bats
# Contract tests for lib/harden.sh: SSH with keys only once root has a key, the sshd jail,
# MPTCP off, the node port for the panel alone, and reruns that change nothing. sshd, nft,
# sysctl, systemctl and fail2ban-client are stubs; files go under CDN_DEPLOY_SYSROOT.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  ROOT="$TMP/root"
  mkdir -p "$REPO" "$TMP/bin" "$ROOT/etc" "$ROOT/root/.ssh"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  export CDN_DEPLOY_SYSROOT="$ROOT" STUB_DIR="$TMP"
  stubs
  PATH="$TMP/bin:$PATH"
  # shellcheck source=../lib/harden.sh
  source "$REPO/lib/harden.sh"
  echo 1 >"$TMP/mptcp"
  NODE_PORT=2222
  PANEL_IP=""
  SSHD="$ROOT/etc/ssh/sshd_config.d/10-cdn-deploy.conf"
  JAIL="$ROOT/etc/fail2ban/jail.d/cdn-deploy-sshd.local"
  MPTCP="$ROOT/etc/sysctl.d/98-cdn-mptcp.conf"
  RULES="$ROOT/etc/nftables-cdn-deploy.nft"
  UNIT="$ROOT/etc/systemd/system/cdn-deploy-guard.service"
}

teardown() {
  rm -rf "${TMP:?}"
}

# stub NAME: installs stdin as the script $TMP/bin/NAME.
stub() {
  {
    echo '#!/bin/sh'
    cat
  } >"$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

# Every stub appends its call to $STUB_DIR/calls. sshd -T reports what the drop-in gives,
# sshd -t and nft -c fail when $STUB_DIR/<name>-fails exists, a started unit stays active.
stubs() {
  stub sshd <<'EOF_STUB'
echo "sshd $*" >>"$STUB_DIR/calls"
case "$1" in
  -t) [ ! -e "$STUB_DIR/sshd-fails" ] ;;
  -T)
    echo "port $(cat "$STUB_DIR/sshd-port" 2>/dev/null || echo 22)"
    if [ -e "$CDN_DEPLOY_SYSROOT/etc/ssh/sshd_config.d/10-cdn-deploy.conf" ]; then
      echo "passwordauthentication no"
    else
      echo "passwordauthentication yes"
    fi
    ;;
esac
EOF_STUB
  stub nft <<'EOF_STUB'
echo "nft $*" >>"$STUB_DIR/calls"
[ ! -e "$STUB_DIR/nft-fails" ]
EOF_STUB
  stub sysctl <<'EOF_STUB'
echo "sysctl $*" >>"$STUB_DIR/calls"
case "$1" in
  -n)
    [ -f "$STUB_DIR/mptcp" ] || exit 255
    cat "$STUB_DIR/mptcp"
    ;;
  -q) echo 0 >"$STUB_DIR/mptcp" ;;
esac
EOF_STUB
  stub systemctl <<'EOF_STUB'
echo "systemctl $*" >>"$STUB_DIR/calls"
case "$1" in
  is-active) grep -qx "$3" "$STUB_DIR/active" 2>/dev/null ;;
  restart) echo "$2" >>"$STUB_DIR/active" ;;
esac
EOF_STUB
  stub fail2ban-client <<'EOF_STUB'
echo "fail2ban-client $*" >>"$STUB_DIR/calls"
EOF_STUB
}

root_key() {
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexamplekeyexamplekeyexamplekeyexamplekeyexa op@example' \
    >"$ROOT/root/.ssh/authorized_keys"
}

calls() {
  grep -c -- "$1" "$TMP/calls" || true
}

@test "without a key of root the passwords stay, and the warning says what to do" {
  run harden::apply
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD" ]
  [[ "$output" == *"no SSH key in /root/.ssh/authorized_keys: password logins stay on. Add a key with ssh-copy-id"* ]]
  [ "$(calls 'systemctl reload ssh')" -eq 0 ]
}

@test "a key behind options does not count as a way in" {
  echo 'command="/bin/false" ssh-ed25519 AAAAexample op@example' >"$ROOT/root/.ssh/authorized_keys"
  run harden::apply
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD" ]
}

@test "with a key sshd takes keys only: drop-in, sshd -t, reload" {
  root_key
  run harden::apply
  [ "$status" -eq 0 ]
  grep -qx 'PasswordAuthentication no' "$SSHD"
  grep -qx 'KbdInteractiveAuthentication no' "$SSHD"
  grep -qx 'PermitRootLogin prohibit-password' "$SSHD"
  [ "$(calls 'sshd -t')" -eq 1 ]
  [ "$(calls 'systemctl reload ssh')" -eq 1 ]
  [[ "$output" == *"check a new connection before you close this one"* ]]
  [[ "$output" != *"still accepts passwords"* ]]
}

@test "a drop-in that sshd -t refuses is removed and sshd is not reloaded" {
  root_key
  touch "$TMP/sshd-fails"
  run harden::apply
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD" ]
  [ "$(calls 'systemctl reload ssh')" -eq 0 ]
  [[ "$output" == *"sshd -t refused /etc/ssh/sshd_config.d/10-cdn-deploy.conf: removed it"* ]]
}

@test "the jail is the sshd one, follows the port of sshd and never bans the panel" {
  echo 56777 >"$TMP/sshd-port"
  PANEL_IP=203.0.113.7 run harden::apply
  [ "$status" -eq 0 ]
  grep -qx 'port = 56777' "$JAIL"
  grep -qx 'ignoreip = 127.0.0.1/8 ::1 203.0.113.7' "$JAIL"
  [ "$(grep -c '^\[' "$JAIL")" -eq 2 ]
  [ "$(calls 'systemctl restart fail2ban')" -eq 1 ]
}

@test "MPTCP goes off through a sysctl file of its own" {
  run harden::apply
  [ "$status" -eq 0 ]
  grep -qx 'net.mptcp.enabled = 0' "$MPTCP"
  [ "$(cat "$TMP/mptcp")" = 0 ]
}

@test "a kernel without MPTCP gets no sysctl file" {
  rm "$TMP/mptcp"
  run harden::apply
  [ "$status" -eq 0 ]
  [ ! -e "$MPTCP" ]
  [[ "$output" == *"the kernel has no MPTCP"* ]]
}

@test "without PANEL_IP the node port stays open, and the warning names the setting" {
  run harden::apply
  [ "$status" -eq 0 ]
  grep -q 'ip hdrlength > 5 counter drop' "$RULES"
  [ "$(grep -c 'dport' "$RULES" || true)" -eq 0 ]
  [[ "$output" == *"PANEL_IP is empty: port 2222 of the node answers anyone"* ]]
  [ "$(calls 'systemctl restart cdn-deploy-guard.service')" -eq 1 ]
}

@test "with PANEL_IP only the panel reaches NODE_PORT, in a table that loads twice" {
  NODE_PORT=2223 PANEL_IP=203.0.113.7 run harden::apply
  [ "$status" -eq 0 ]
  grep -q 'tcp dport 2223 ip saddr 203.0.113.7 counter accept' "$RULES"
  grep -q 'tcp dport 2223 counter drop' "$RULES"
  [ "$(sed -n 2,3p "$RULES")" = $'table inet cdn_deploy_guard\ndelete table inet cdn_deploy_guard' ]
  grep -qx 'ExecStart=/usr/sbin/nft -f /etc/nftables-cdn-deploy.nft' "$UNIT"
  [[ "$output" != *"PANEL_IP is empty"* ]]
}

@test "rules that nft refuses are not loaded" {
  touch "$TMP/nft-fails"
  PANEL_IP=203.0.113.7 run harden::apply
  [ "$status" -eq 0 ]
  [ "$(calls 'systemctl restart cdn-deploy-guard.service')" -eq 0 ]
  [[ "$output" == *"nft refused /etc/nftables-cdn-deploy.nft"* ]]
}

@test "a rerun writes nothing and restarts nothing" {
  root_key
  PANEL_IP=203.0.113.7 harden::apply 2>/dev/null
  cp "$TMP/calls" "$TMP/calls.first"
  : >"$TMP/calls"
  find "$ROOT" -type f -exec touch -d '2000-01-01' {} +
  PANEL_IP=203.0.113.7 run harden::apply
  [ "$status" -eq 0 ]
  [ -z "$(find "$ROOT" -type f -newermt '2000-01-02')" ]
  [ "$(calls 'restart')" -eq 0 ]
  [ "$(calls 'reload')" -eq 0 ]
  [ "$(calls 'sysctl -q')" -eq 0 ]
}
