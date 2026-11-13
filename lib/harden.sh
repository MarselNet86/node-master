# shellcheck shell=bash
# First hardening of the node, so a new server does not go into a subscription as the
# image left it: SSH with keys only, fail2ban for sshd, MPTCP off, and the node port open
# to the panel alone. Every part is safe to rerun and none of them stops the deploy: a part
# that cannot apply says why and what to do.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# Paths as the host sees them; files are created under $SYSROOT, which only tests set.
readonly HARDEN_KEYS=/root/.ssh/authorized_keys
# Sorts before 50-cloud-init.conf: sshd takes the first value it reads.
readonly HARDEN_SSHD=/etc/ssh/sshd_config.d/10-cdn-deploy.conf
readonly HARDEN_JAIL=/etc/fail2ban/jail.d/cdn-deploy-sshd.local
readonly HARDEN_SYSCTL=/etc/sysctl.d/98-cdn-mptcp.conf
# Loaded by its own unit and not from /etc/nftables.conf, whose flush ruleset would wipe
# the rules of docker.
readonly HARDEN_NFT=/etc/nftables-cdn-deploy.nft
readonly HARDEN_UNIT=/etc/systemd/system/cdn-deploy-guard.service
readonly HARDEN_TABLE=cdn_deploy_guard

harden::apply() {
  require::cmd sshd nft fail2ban-client sysctl systemctl
  harden::_sshd
  harden::_fail2ban
  harden::_mptcp
  harden::_guard
}

# Password logins go only when root has a key: without one the change would lock the
# operator out. sshd -t guards the reload, and a refused file is removed.
harden::_sshd() {
  local conf="$SYSROOT$HARDEN_SSHD"
  if ! harden::_has_key; then
    log::warn "$(t 'no SSH key in %s: password logins stay on. Add a key with ssh-copy-id and rerun ./deploy.sh' "$HARDEN_KEYS")"
    return 0
  fi
  mkdir -p "${conf%/*}"
  fs::write "$conf" 644 "$(harden::_sshd_conf)"
  if ((FS_CHANGED)); then
    if ! sshd -t >&2; then
      rm -f "$conf"
      log::warn "$(t 'sshd -t refused %s: removed it, password logins stay on' "$HARDEN_SSHD")"
      return 0
    fi
    systemctl reload ssh >&2 || log::warn "$(t 'sshd did not reload: see systemctl status ssh')"
    log::info "$(t 'SSH takes keys only: check a new connection before you close this one')"
  fi
  if [[ "$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2; exit }')" != no ]]; then
    log::warn "$(t 'sshd still accepts passwords: an earlier file in /etc/ssh/sshd_config.d or sshd_config without Include overrides %s' "$HARDEN_SSHD")"
  fi
}

# A plain key line. A key behind options (command=, from=) does not count: it may not
# give a shell.
harden::_has_key() {
  [[ -f "$SYSROOT$HARDEN_KEYS" ]] &&
    grep -Eq '^[[:space:]]*(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-)' "$SYSROOT$HARDEN_KEYS"
}

harden::_sshd_conf() {
  cat <<'EOF_CONF'
# cdn-deploy: root logs in with a key only. Written by ./deploy.sh once root has a key.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF_CONF
}

# Only the sshd jail: an HTTP jail would ban the CDN edges. The jail follows the port sshd
# listens on, and never bans the panel.
harden::_fail2ban() {
  local jail="$SYSROOT$HARDEN_JAIL" port
  port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
  mkdir -p "${jail%/*}"
  fs::write "$jail" 644 "$(harden::_jail "${port:-22}")"
  if ((FS_CHANGED)) || ! systemctl is-active --quiet fail2ban; then
    systemctl enable fail2ban >&2 || true
    systemctl restart fail2ban >&2 ||
      log::warn "$(t 'fail2ban did not start: see systemctl status fail2ban')"
  fi
}

harden::_jail() {
  cat <<EOF_JAIL
# cdn-deploy: the sshd jail and no other. Written by ./deploy.sh.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${PANEL_IP:+ $PANEL_IP}
[sshd]
enabled = true
port = $1
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF_JAIL
}

# CVE-2026-98432 is a use-after-free in the kernel TCP code that MPTCP sockets reach, and
# xray before 26.10.31 opens them. Nothing here needs MPTCP. A kernel without it has no
# such key, and a file for it would make sysctl --system fail on every run.
harden::_mptcp() {
  local conf="$SYSROOT$HARDEN_SYSCTL"
  if ! sysctl -n net.mptcp.enabled >/dev/null 2>&1; then
    log::info "$(t 'the kernel has no MPTCP: nothing to switch off')"
    return 0
  fi
  mkdir -p "${conf%/*}"
  fs::write "$conf" 644 "$(harden::_mptcp_conf)"
  if [[ "$(sysctl -n net.mptcp.enabled 2>/dev/null)" != 0 ]]; then
    sysctl -q -p "$conf" >&2 ||
      log::warn "$(t 'cannot switch MPTCP off: a container kernel forbids it, update the kernel of the host')"
  fi
}

harden::_mptcp_conf() {
  cat <<'EOF_CONF'
# cdn-deploy: no MPTCP sockets (CVE-2026-98432). Written by ./deploy.sh.
net.mptcp.enabled = 0
EOF_CONF
}

# The node port carries the API that the panel drives the node through, and a scanner
# tells a Remnawave node by it. With PANEL_IP only the panel reaches it. The node runs
# with network_mode host, so an input hook sees the port.
harden::_guard() {
  local rules="$SYSROOT$HARDEN_NFT" unit="$SYSROOT$HARDEN_UNIT" changed=0
  if [[ -z "${PANEL_IP:-}" ]]; then
    log::warn "$(t 'PANEL_IP is empty: port %s of the node answers anyone. Put the address the panel connects from into %s and rerun ./deploy.sh' "${NODE_PORT:-2222}" "$ENV_FILE")"
  fi
  mkdir -p "${rules%/*}" "${unit%/*}"
  fs::write "$rules" 644 "$(harden::_rules)"
  changed=$((changed | FS_CHANGED))
  fs::write "$unit" 644 "$(harden::_unit)"
  changed=$((changed | FS_CHANGED))
  if ! nft -c -f "$rules" >&2; then
    log::warn "$(t 'nft refused %s: the rules are not loaded, see the error above' "$HARDEN_NFT")"
    return 0
  fi
  if ((changed)) || ! systemctl is-active --quiet "${HARDEN_UNIT##*/}"; then
    systemctl daemon-reload >&2
    systemctl enable "${HARDEN_UNIT##*/}" >&2 || true
    systemctl restart "${HARDEN_UNIT##*/}" >&2 ||
      log::warn "$(t 'the nft rules did not load: see systemctl status %s' "${HARDEN_UNIT##*/}")"
  fi
}

# The first two lines make the file loadable twice: nft has no "replace table".
harden::_rules() {
  cat <<EOF_RULES
# cdn-deploy: input guard. Written by ./deploy.sh from .env, loaded by ${HARDEN_UNIT##*/}.
table inet $HARDEN_TABLE
delete table inet $HARDEN_TABLE
table inet $HARDEN_TABLE {
	chain input {
		type filter hook input priority -10; policy accept;
		ip protocol tcp ip hdrlength > 5 counter drop comment "IPv4 TCP with IP options (CVE-2026-98432)"
EOF_RULES
  if [[ -n "${PANEL_IP:-}" && -n "${NODE_PORT:-}" ]]; then
    cat <<EOF_RULES
		tcp dport $NODE_PORT ip saddr $PANEL_IP counter accept comment "Remnawave panel"
		tcp dport $NODE_PORT counter drop comment "node port: the panel only"
EOF_RULES
  fi
  printf '\t}\n}\n'
}

harden::_unit() {
  cat <<EOF_UNIT
# cdn-deploy: loads $HARDEN_NFT at boot. Written by ./deploy.sh.
[Unit]
Description=cdn-deploy input guard: node port for the panel, no TCP with IP options
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f $HARDEN_NFT
ExecStop=/usr/sbin/nft delete table inet $HARDEN_TABLE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
}
