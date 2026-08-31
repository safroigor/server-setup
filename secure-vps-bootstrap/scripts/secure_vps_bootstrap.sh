#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION="1.0.0"
DEFAULT_ADMIN="vpsadmin"
STATE_ROOT="${SVB_STATE_ROOT:-/var/lib/secure-vps-bootstrap}"
BACKUP_ROOT="${SVB_BACKUP_ROOT:-/var/backups/secure-vps-bootstrap}"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-secure-vps-bootstrap.conf"
SUDOERS_FILE_PREFIX="/etc/sudoers.d/90-secure-vps-bootstrap-"
FAIL2BAN_FILE="/etc/fail2ban/jail.d/00-secure-vps-bootstrap.local"
APT_AUTO_FILE="/etc/apt/apt.conf.d/20secure-vps-bootstrap-auto-upgrades"
CURRENT_LINK="$STATE_ROOT/current"

COMMAND=""
ADMIN_USER="$DEFAULT_ADMIN"
PUBLIC_KEY_FILE=""
SSH_PORT=""
REUSE_ADMIN=0
RUN_ID=""
DRY_RUN=0
ALLOW_PORTS=()

log() { printf '%s\n' "$*"; }
status() { printf '%s=%s\n' "$1" "$2"; }
die() { status STATUS FAILED; status ERROR "$*"; exit 1; }
on_error() {
  local code="$1" line="$2"
  trap - ERR
  status STATUS FAILED
  status ERROR "unexpected command failure at line $line"
  status NEXT_ACTION "Keep every working SSH session open; inspect the run state and use rollback if configuration was changed."
  exit "$code"
}
trap 'on_error $? $LINENO' ERR

usage() {
  cat <<'EOF'
Usage:
  secure_vps_bootstrap.sh inspect
  secure_vps_bootstrap.sh prepare --public-key-file PATH [options]
  secure_vps_bootstrap.sh lockdown [--run-id ID]
  secure_vps_bootstrap.sh verify [--run-id ID]
  secure_vps_bootstrap.sh rollback [--run-id ID]

Options:
  --admin-user USER       Administrator name (default: vpsadmin)
  --public-key-file PATH  Public key file on the VPS; required by prepare
  --ssh-port PORT         Preserve and allow this SSH port (default: detect)
  --allow-port PORT/PROTO Additional inbound UFW rule; repeatable
  --reuse-admin           Allow prepare to update an existing administrator
  --run-id ID             Select an existing run
  --dry-run               Inspect and print planned prepare/lockdown actions
  --version               Print version
EOF
}

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 2; }
  COMMAND="$1"
  shift
  case "$COMMAND" in inspect|prepare|lockdown|verify|rollback) ;; --version) log "$VERSION"; exit 0 ;; -h|--help) usage; exit 0 ;; *) usage; die "unknown command: $COMMAND" ;; esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --admin-user) [[ $# -ge 2 ]] || die "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
      --public-key-file) [[ $# -ge 2 ]] || die "--public-key-file requires a value"; PUBLIC_KEY_FILE="$2"; shift 2 ;;
      --ssh-port) [[ $# -ge 2 ]] || die "--ssh-port requires a value"; SSH_PORT="$2"; shift 2 ;;
      --allow-port) [[ $# -ge 2 ]] || die "--allow-port requires a value"; ALLOW_PORTS+=("$2"); shift 2 ;;
      --reuse-admin) REUSE_ADMIN=1; shift ;;
      --run-id) [[ $# -ge 2 ]] || die "--run-id requires a value"; RUN_ID="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "$COMMAND must run as root (normally through sudo)"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_admin_user() { valid_user "$1" && [[ "$1" != root ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_allow_port() {
  [[ "$1" =~ ^([0-9]+)/((tcp)|(udp))$ ]] || return 1
  valid_port "${BASH_REMATCH[1]}"
}
ufw_has_allow() { ufw status | grep -Eq "^[[:space:]]*$1[[:space:]]+ALLOW([[:space:]]|$)"; }
ufw_preflight_allows() {
  local ssh_port="$1" entry
  shift
  ufw --dry-run prepend allow "$ssh_port/tcp" >/dev/null || return 1
  for entry in "$@"; do ufw --dry-run prepend allow "$entry" >/dev/null || return 1; done
}
ufw_apply_allows() {
  local ssh_port="$1" index
  shift
  local entries=("$@")
  for ((index=${#entries[@]} - 1; index >= 0; index--)); do ufw prepend allow "${entries[index]}"; done
  ufw prepend allow "$ssh_port/tcp"
}

is_supported_os_id() { [[ "$1" == ubuntu || "$1" == debian ]]; }
admin_account_policy() {
  local exists="$1" reuse="$2" uid="$3"
  [[ "$exists" == 0 ]] && return 0
  [[ "$reuse" == 1 ]] || return 2
  (( uid >= 1000 )) || return 3
}
assert_lockdown_context() {
  local phase="$1" expected="$2" invoking="$3"
  [[ "$phase" == PREPARED || "$phase" == LOCKED_DOWN ]] || return 2
  assert_admin_session "$expected" "$invoking" || return 3
}
assert_admin_session() { [[ -n "$2" && "$2" == "$1" ]]; }
assert_new_connection() { [[ -n "$1" && -n "$2" && "$1" != "$2" ]]; }
is_allowed_restore_path() {
  case "$1" in
    /etc/ssh/sshd_config.d/00-secure-vps-bootstrap.conf|/etc/sudoers.d/90-secure-vps-bootstrap-*|/etc/apt/apt.conf.d/20secure-vps-bootstrap-auto-upgrades|/etc/default/ufw|/etc/ufw/user.rules|/etc/ufw/user6.rules|/etc/fail2ban/jail.d/00-secure-vps-bootstrap.local|/home/*/.ssh/authorized_keys) return 0 ;;
    *) return 1 ;;
  esac
}

assert_supported_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  is_supported_os_id "${ID:-}" || die "unsupported distribution: ${ID:-unknown}; expected ubuntu or debian"
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == "systemd" ]] || die "systemd is required"
  require_command apt-get
  require_command systemctl
  require_command sshd
}

detect_ssh_port() {
  if [[ -n "$SSH_PORT" ]]; then valid_port "$SSH_PORT" || return 1; printf '%s' "$SSH_PORT"; return; fi
  local detected ports
  ports="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u)"
  [[ "$(grep -c . <<<"$ports")" -le 1 ]] || return 2
  detected="$(head -n1 <<<"$ports")"
  [[ -n "$detected" ]] || detected=22
  valid_port "$detected" || return 1
  printf '%s' "$detected"
}

ssh_service() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf '%s' ssh; else printf '%s' sshd; fi
}

current_run_id() {
  [[ -r "$CURRENT_LINK" ]] || die "no current run found under $STATE_ROOT"
  tr -d '\r\n' < "$CURRENT_LINK"
}

state_dir() { printf '%s/%s' "$STATE_ROOT" "$1"; }
state_get() {
  local key="$1" dir="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$dir/state" 2>/dev/null || true
}
state_set() {
  local key="$1" value="$2" dir="$3" tmp
  tmp="$dir/state.tmp"
  awk -F= -v key="$key" '$1 != key' "$dir/state" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$dir/state"
}

new_run() {
  local now dir
  now="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  RUN_ID="$now"
  dir="$(state_dir "$RUN_ID")"
  install -d -m 700 "$STATE_ROOT" "$BACKUP_ROOT" "$dir" "$BACKUP_ROOT/$RUN_ID"
  printf '%s\n' "$RUN_ID" > "$CURRENT_LINK"
  chmod 600 "$CURRENT_LINK"
  : > "$dir/state"
  : > "$dir/manifest.tsv"
  chmod 600 "$dir/state" "$dir/manifest.tsv"
}

select_run() {
  [[ -n "$RUN_ID" ]] || RUN_ID="$(current_run_id)"
  [[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid run ID"
  local dir
  dir="$(state_dir "$RUN_ID")"
  [[ -r "$dir/state" ]] || die "run state not found: $RUN_ID"
}

backup_path() {
  local source="$1" run_dir="$2" backup_dir="$BACKUP_ROOT/$RUN_ID" destination
  grep -Fqx "$source"$'\t'present "$run_dir/manifest.tsv" 2>/dev/null && return 0
  grep -Fqx "$source"$'\t'absent "$run_dir/manifest.tsv" 2>/dev/null && return 0
  if [[ -e "$source" || -L "$source" ]]; then
    destination="$backup_dir$source"
    install -d -m 700 "$(dirname "$destination")"
    cp -a "$source" "$destination"
    printf '%s\tpresent\n' "$source" >> "$run_dir/manifest.tsv"
  else
    printf '%s\tabsent\n' "$source" >> "$run_dir/manifest.tsv"
  fi
}

restore_path() {
  local source="$1" run_dir="$2" backup_dir="$BACKUP_ROOT/$RUN_ID" presence saved
  is_allowed_restore_path "$source" || die "refusing to restore unexpected path: $source"
  presence="$(awk -F '\t' -v source="$source" '$1 == source { print $2; exit }' "$run_dir/manifest.tsv")"
  [[ -n "$presence" ]] || die "path is absent from the backup manifest: $source"
  saved="$backup_dir$source"
  if [[ "$presence" == present ]]; then
    [[ -e "$saved" || -L "$saved" ]] || die "backup is missing for $source"
    install -d -m 755 "$(dirname "$source")"
    cp -a "$saved" "$source"
  elif [[ "$presence" == absent ]]; then
    rm -f "$source"
  else
    die "invalid manifest entry for $source"
  fi
}

write_file() {
  local target="$1" mode="$2" content="$3" tmp
  install -d -m 755 "$(dirname "$target")"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  chmod "$mode" "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$target"
}

validate_public_key() {
  [[ -n "$PUBLIC_KEY_FILE" ]] || die "prepare requires --public-key-file"
  [[ -f "$PUBLIC_KEY_FILE" && -r "$PUBLIC_KEY_FILE" ]] || die "public key file is not readable: $PUBLIC_KEY_FILE"
  ! grep -q 'PRIVATE KEY' "$PUBLIC_KEY_FILE" || die "the supplied file appears to contain a private key"
  [[ "$(grep -cve '^[[:space:]]*$' "$PUBLIC_KEY_FILE")" -eq 1 ]] || die "public key file must contain exactly one non-empty line"
  require_command ssh-keygen
  ssh-keygen -lf "$PUBLIC_KEY_FILE" >/dev/null 2>&1 || die "invalid OpenSSH public key"
}

inspect() {
  assert_supported_os
  local detected_port
  if ! detected_port="$(detect_ssh_port)"; then die "could not uniquely determine the effective SSH port; use prepare --ssh-port PORT after confirming the listener"; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  status STATUS INSPECTED
  status OS_ID "$ID"
  status OS_VERSION "${VERSION_ID:-unknown}"
  status SSH_PORT "$detected_port"
  status CURRENT_USER "$(id -un)"
  status SUDO_AVAILABLE "$(command -v sudo >/dev/null 2>&1 && printf yes || printf no)"
  status UFW_STATUS "$(command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n1 | tr ' ' '_' || printf not_installed)"
  status FAIL2BAN_ACTIVE "$(systemctl is-active fail2ban 2>/dev/null || true)"
  status REBOOT_REQUIRED "$([[ -e /var/run/reboot-required ]] && printf yes || printf no)"
  log "UFW_RULES_BEGIN"
  if command -v ufw >/dev/null 2>&1; then ufw status numbered 2>/dev/null || true; else log "ufw not installed"; fi
  log "UFW_RULES_END"
  log "LISTENING_SOCKETS_BEGIN"
  if command -v ss >/dev/null 2>&1; then ss -lntup 2>/dev/null || ss -lnt 2>/dev/null || true; else log "ss command not installed"; fi
  log "LISTENING_SOCKETS_END"
  log "PENDING_UPDATES_BEGIN"
  apt list --upgradable 2>/dev/null || true
  log "PENDING_UPDATES_END"
}

prepare() {
  require_root
  assert_supported_os
  valid_admin_user "$ADMIN_USER" || die "invalid administrator name: $ADMIN_USER"
  [[ -n "$SSH_PORT" ]] && valid_port "$SSH_PORT" || [[ -z "$SSH_PORT" ]] || die "invalid SSH port: $SSH_PORT"
  local entry
  for entry in "${ALLOW_PORTS[@]}"; do valid_allow_port "$entry" || die "invalid --allow-port value: $entry"; done
  validate_public_key
  local port existing_user=0 created_user=0 run_dir key_line sudoers_file home added_sudo_group=0
  if ! port="$(detect_ssh_port)"; then die "could not uniquely determine the effective SSH port; pass --ssh-port after confirming the active listener"; fi
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    existing_user=1
    local existing_uid
    existing_uid="$(id -u "$ADMIN_USER")"
    admin_account_policy "$existing_user" "$REUSE_ADMIN" "$existing_uid" || {
      [[ $REUSE_ADMIN -eq 1 ]] || die "administrator already exists; rerun only with explicit --reuse-admin approval"
      die "refusing to reuse a system account with UID $existing_uid"
    }
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    status STATUS DRY_RUN
    status ADMIN_USER "$ADMIN_USER"
    status SSH_PORT "$port"
    status ALLOW_PORTS "${ALLOW_PORTS[*]:-none}"
    status EXISTING_ADMIN "$existing_user"
    return
  fi

  new_run
  run_dir="$(state_dir "$RUN_ID")"
  state_set PHASE STARTED "$run_dir"
  state_set ADMIN_USER "$ADMIN_USER" "$run_dir"
  state_set SSH_PORT "$port" "$run_dir"
  state_set CREATED_USER 0 "$run_dir"
  state_set ADDED_SUDO_GROUP 0 "$run_dir"
  state_set ALLOW_PORTS "${ALLOW_PORTS[*]}" "$run_dir"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then state_set UFW_WAS_ACTIVE 1 "$run_dir"; else state_set UFW_WAS_ACTIVE 0 "$run_dir"; fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then state_set FAIL2BAN_WAS_ACTIVE 1 "$run_dir"; else state_set FAIL2BAN_WAS_ACTIVE 0 "$run_dir"; fi
  if systemctl is-enabled --quiet fail2ban 2>/dev/null; then state_set FAIL2BAN_WAS_ENABLED 1 "$run_dir"; else state_set FAIL2BAN_WAS_ENABLED 0 "$run_dir"; fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confold upgrade
  apt-get -y install sudo curl git jq tmux htop ufw fail2ban unattended-upgrades openssh-server

  if [[ $existing_user -eq 0 ]]; then
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
    passwd -l "$ADMIN_USER" >/dev/null
    created_user=1
    state_set CREATED_USER 1 "$run_dir"
  fi
  if ! id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo; then
    usermod -aG sudo "$ADMIN_USER"
    added_sudo_group=1
    state_set ADDED_SUDO_GROUP 1 "$run_dir"
  fi
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  [[ "$home" == "/home/$ADMIN_USER" ]] || die "administrator home must be /home/$ADMIN_USER; found ${home:-unknown}"
  backup_path "$home/.ssh/authorized_keys" "$run_dir"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"
  key_line="$(grep -v '^[[:space:]]*$' "$PUBLIC_KEY_FILE")"
  grep -qxF "$key_line" "$home/.ssh/authorized_keys" || printf '%s\n' "$key_line" >> "$home/.ssh/authorized_keys"

  sudoers_file="${SUDOERS_FILE_PREFIX}${ADMIN_USER}"
  backup_path "$sudoers_file" "$run_dir"
  write_file "$sudoers_file" 440 "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"
  if ! visudo -cf "$sudoers_file" >/dev/null; then restore_path "$sudoers_file" "$run_dir"; die "sudoers validation failed; previous file restored"; fi

  backup_path "$APT_AUTO_FILE" "$run_dir"
  write_file "$APT_AUTO_FILE" 644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";'

  backup_path /etc/default/ufw "$run_dir"
  backup_path /etc/ufw/user.rules "$run_dir"
  backup_path /etc/ufw/user6.rules "$run_dir"
  ufw_preflight_allows "$port" "${ALLOW_PORTS[@]}" || die "UFW dry-run failed for the managed allow rules"
  ufw_apply_allows "$port" "${ALLOW_PORTS[@]}"
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ufw_has_allow "$port/tcp" || die "UFW does not show an allow rule for SSH port $port"

  backup_path "$FAIL2BAN_FILE" "$run_dir"
  write_file "$FAIL2BAN_FILE" 644 "[sshd]
enabled = true
backend = systemd
port = $port
maxretry = 5
findtime = 10m
bantime = 1h"
  if ! fail2ban-client -t >/dev/null; then restore_path "$FAIL2BAN_FILE" "$run_dir"; die "Fail2ban configuration validation failed; previous file restored"; fi
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  for _ in {1..15}; do
    fail2ban-client status sshd >/dev/null 2>&1 && break
    sleep 1
  done
  fail2ban-client status sshd >/dev/null || die "Fail2ban sshd jail is not active"

  state_set PHASE PREPARED "$run_dir"
  status STATUS CHECKPOINT_READY
  status RUN_ID "$RUN_ID"
  status ADMIN_USER "$ADMIN_USER"
  status SSH_PORT "$port"
  status BACKUP_DIR "$BACKUP_ROOT/$RUN_ID"
  status CREATED_USER "$created_user"
  status NEXT_ACTION "Open a new external SSH session as $ADMIN_USER, verify sudo -n true, then run lockdown from that session."
}

effective_sshd() {
  local user="$1" host addr
  host="$(hostname -f 2>/dev/null || hostname)"
  addr="${SSH_CONNECTION%% *}"
  [[ -n "$addr" ]] || return 2
  sshd -T -C "user=$user,host=$host,addr=$addr"
}

assert_effective_sshd() {
  local admin="$1" admin_cfg root_cfg
  admin_cfg="$(effective_sshd "$admin")"
  root_cfg="$(effective_sshd root)"
  grep -qx 'passwordauthentication no' <<<"$admin_cfg" || return 1
  grep -qx 'kbdinteractiveauthentication no' <<<"$admin_cfg" || return 1
  grep -qx 'pubkeyauthentication yes' <<<"$admin_cfg" || return 1
  grep -qx 'permitemptypasswords no' <<<"$admin_cfg" || return 1
  grep -qx 'x11forwarding no' <<<"$admin_cfg" || return 1
  grep -qx 'maxauthtries 4' <<<"$admin_cfg" || return 1
  grep -qx 'logingracetime 30' <<<"$admin_cfg" || return 1
  grep -qx 'permitrootlogin no' <<<"$root_cfg" || return 1
}

sshd_config_syntax_valid() { sshd -t; }

lockdown() {
  require_root
  assert_supported_os
  select_run
  local run_dir phase expected_admin invoking_user service home
  run_dir="$(state_dir "$RUN_ID")"
  phase="$(state_get PHASE "$run_dir")"
  expected_admin="$(state_get ADMIN_USER "$run_dir")"
  invoking_user="${SUDO_USER:-}"
  assert_lockdown_context "$phase" "$expected_admin" "$invoking_user" || {
    [[ "$phase" == PREPARED || "$phase" == LOCKED_DOWN ]] || die "lockdown requires a PREPARED run; current phase is ${phase:-unknown}"
    die "lockdown must be invoked with sudo from the new $expected_admin SSH session; SUDO_USER is ${invoking_user:-unset}"
  }
  [[ -n "${SSH_CONNECTION:-}" ]] || die "SSH_CONNECTION was not preserved through sudo; rerun with sudo --preserve-env=SSH_CONNECTION from the new SSH session"
  sudo -u "$expected_admin" sudo -n true >/dev/null 2>&1 || die "passwordless sudo checkpoint failed for $expected_admin"
  home="$(getent passwd "$expected_admin" | cut -d: -f6)"
  [[ -s "$home/.ssh/authorized_keys" ]] || die "administrator has no authorized key"
  if [[ $DRY_RUN -eq 1 ]]; then status STATUS DRY_RUN; status NEXT_ACTION "Write and validate $SSH_DROPIN, then reload OpenSSH"; return; fi

  backup_path "$SSH_DROPIN" "$run_dir"
  write_file "$SSH_DROPIN" 644 'PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30'
  if ! sshd_config_syntax_valid; then restore_path "$SSH_DROPIN" "$run_dir"; die "OpenSSH syntax validation failed; previous drop-in restored and SSH was not reloaded"; fi
  if ! assert_effective_sshd "$expected_admin"; then restore_path "$SSH_DROPIN" "$run_dir"; die "managed SSH values are not effective, likely because of Include ordering; previous drop-in restored and SSH was not reloaded"; fi
  service="$(ssh_service)"
  systemctl reload "$service"
  systemctl is-active --quiet "$service" || die "OpenSSH service is not active after reload"
  state_set LOCKDOWN_CONNECTION "$SSH_CONNECTION" "$run_dir"
  state_set PHASE LOCKED_DOWN "$run_dir"
  status STATUS LOCKDOWN_COMPLETE
  status RUN_ID "$RUN_ID"
  status NEXT_ACTION "Open another new SSH session as $expected_admin before closing either existing session, then run verify."
}

verify() {
  require_root
  assert_supported_os
  select_run
  local run_dir phase admin port sudoers_file service home entry allowed_ports lockdown_connection invoking_user
  run_dir="$(state_dir "$RUN_ID")"
  phase="$(state_get PHASE "$run_dir")"
  [[ "$phase" == LOCKED_DOWN || "$phase" == VERIFIED ]] || die "verify requires a LOCKED_DOWN run; current phase is ${phase:-unknown}"
  admin="$(state_get ADMIN_USER "$run_dir")"
  port="$(state_get SSH_PORT "$run_dir")"
  invoking_user="${SUDO_USER:-}"
  assert_admin_session "$admin" "$invoking_user" || die "verify must be invoked with sudo from a new $admin SSH session; SUDO_USER is ${invoking_user:-unset}"
  lockdown_connection="$(state_get LOCKDOWN_CONNECTION "$run_dir")"
  assert_new_connection "$lockdown_connection" "${SSH_CONNECTION:-}" || die "verify requires a new SSH connection created after lockdown; do not reuse the lockdown connection"
  sudoers_file="${SUDOERS_FILE_PREFIX}${admin}"
  id "$admin" >/dev/null 2>&1 || die "administrator is missing"
  home="$(getent passwd "$admin" | cut -d: -f6)"
  [[ -s "$home/.ssh/authorized_keys" ]] || die "administrator authorized_keys is empty"
  visudo -cf "$sudoers_file" >/dev/null || die "administrator sudoers file is invalid"
  sshd_config_syntax_valid || die "OpenSSH syntax validation failed"
  assert_effective_sshd "$admin" || die "effective OpenSSH hardening values do not match policy"
  service="$(ssh_service)"
  systemctl is-active --quiet "$service" || die "OpenSSH service is not active"
  ufw status | grep -q '^Status: active' || die "UFW is not active"
  ufw_has_allow "$port/tcp" || die "UFW does not allow SSH port $port"
  allowed_ports="$(state_get ALLOW_PORTS "$run_dir")"
  for entry in $allowed_ports; do
    ufw_has_allow "$entry" || die "UFW does not allow requested port $entry"
  done
  systemctl is-active --quiet fail2ban || die "Fail2ban is not active"
  fail2ban-client status sshd >/dev/null || die "Fail2ban sshd jail is not active"
  grep -q 'Unattended-Upgrade "1"' "$APT_AUTO_FILE" || die "automatic security upgrades are not enabled"
  grep -q 'Automatic-Reboot "false"' "$APT_AUTO_FILE" || die "automatic reboot is not disabled"
  state_set PHASE VERIFIED "$run_dir"
  status STATUS SECURE
  status RUN_ID "$RUN_ID"
  status ADMIN_USER "$admin"
  status SSH_PORT "$port"
  status ALLOW_PORTS "$allowed_ports"
  status REBOOT_REQUIRED "$([[ -e /var/run/reboot-required ]] && printf yes || printf no)"
  status BACKUP_DIR "$BACKUP_ROOT/$RUN_ID"
  status FIREWALL_SCOPE "host UFW only; existing rules were preserved and must be reviewed below"
  log "UFW_RULES_BEGIN"
  ufw status numbered
  log "UFW_RULES_END"
}

restore_manifest() {
  local run_dir="$1" source presence
  while IFS=$'\t' read -r source presence; do
    [[ -n "$source" ]] || continue
    restore_path "$source" "$run_dir"
  done < "$run_dir/manifest.tsv"
}

rollback() {
  require_root
  select_run
  local run_dir admin created service added_sudo_group ufw_was_active fail2ban_was_active fail2ban_was_enabled
  run_dir="$(state_dir "$RUN_ID")"
  admin="$(state_get ADMIN_USER "$run_dir")"
  created="$(state_get CREATED_USER "$run_dir")"
  added_sudo_group="$(state_get ADDED_SUDO_GROUP "$run_dir")"
  ufw_was_active="$(state_get UFW_WAS_ACTIVE "$run_dir")"
  fail2ban_was_active="$(state_get FAIL2BAN_WAS_ACTIVE "$run_dir")"
  fail2ban_was_enabled="$(state_get FAIL2BAN_WAS_ENABLED "$run_dir")"
  restore_manifest "$run_dir"
  if command -v sshd >/dev/null 2>&1; then sshd_config_syntax_valid || die "restored OpenSSH configuration is invalid; service was not reloaded"; service="$(ssh_service)"; systemctl reload "$service"; fi
  if command -v ufw >/dev/null 2>&1; then if [[ "$ufw_was_active" == 1 ]]; then ufw reload >/dev/null; else ufw --force disable >/dev/null; fi; fi
  if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client -t >/dev/null 2>&1; then
    if [[ "$fail2ban_was_active" == 1 ]]; then systemctl restart fail2ban; else systemctl stop fail2ban >/dev/null 2>&1 || true; fi
    if [[ "$fail2ban_was_enabled" == 1 ]]; then systemctl enable fail2ban >/dev/null; else systemctl disable fail2ban >/dev/null 2>&1 || true; fi
  fi
  if [[ "$added_sudo_group" == 1 ]] && id "$admin" >/dev/null 2>&1; then gpasswd -d "$admin" sudo >/dev/null 2>&1 || true; fi
  if [[ "$created" == 1 ]] && id "$admin" >/dev/null 2>&1; then passwd -l "$admin" >/dev/null 2>&1 || true; fi
  state_set PHASE ROLLED_BACK "$run_dir"
  status STATUS ROLLED_BACK
  status RUN_ID "$RUN_ID"
  status NOTE "Package installations and upgrades were not reverted; a created administrator was locked but not deleted."
}

main() {
  parse_args "$@"
  case "$COMMAND" in
    inspect) inspect ;;
    prepare) prepare ;;
    lockdown) lockdown ;;
    verify) verify ;;
    rollback) rollback ;;
  esac
}

if [[ "${SVB_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
