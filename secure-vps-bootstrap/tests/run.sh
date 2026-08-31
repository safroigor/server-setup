#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/bin:/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/secure_vps_bootstrap.sh"
export SVB_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
cleanup() {
  case "$TMP_ROOT" in
    /tmp/tmp.*) rm -rf -- "$TMP_ROOT" ;;
    *) printf 'Refusing to remove unexpected test directory: %s\n' "$TMP_ROOT" >&2; return 1 ;;
  esac
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
expect_true() { local name="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
expect_false() { local name="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi; }
expect_eq() { local name="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then pass "$name"; else printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual"; fail "$name"; fi; }

# Ubuntu/Debian scope and rejection of unrelated distributions.
expect_true "Ubuntu is supported" is_supported_os_id ubuntu
expect_true "Debian is supported" is_supported_os_id debian
expect_false "AlmaLinux is rejected" is_supported_os_id almalinux

# User, SSH port, and explicit firewall-input validation.
expect_true "default administrator is valid" valid_admin_user vpsadmin
expect_false "root cannot be the managed administrator" valid_admin_user root
expect_false "invalid administrator characters are rejected" valid_admin_user 'Bad User'
expect_true "custom SSH port is valid" valid_port 2222
expect_false "out-of-range SSH port is rejected" valid_port 70000
expect_true "explicit TCP allow rule is valid" valid_allow_port 443/tcp
expect_true "explicit UDP allow rule is valid" valid_allow_port 53/udp
expect_false "unknown firewall protocol is rejected" valid_allow_port 443/sctp
ufw() { printf '%s\n' 'Status: active' '2222/tcp DENY Anywhere'; }
expect_false "a deny rule is not mistaken for SSH allow" ufw_has_allow 2222/tcp
ufw() { printf '%s\n' 'Status: active' '2222/tcp ALLOW Anywhere'; }
expect_true "an explicit SSH allow rule is recognized" ufw_has_allow 2222/tcp
unset -f ufw

# UFW prepend works with an empty ruleset and yields managed rules before old rules.
MOCK_UFW_LOG="$TMP_ROOT/ufw.log"
ufw() { printf '%s\n' "$*" >> "$MOCK_UFW_LOG"; }
: > "$MOCK_UFW_LOG"
expect_true "empty-ruleset UFW preflight uses prepend" ufw_preflight_allows 2222
expect_eq "empty-ruleset preflight command" '--dry-run prepend allow 2222/tcp' "$(cat "$MOCK_UFW_LOG")"
: > "$MOCK_UFW_LOG"
expect_true "requested allows can be prepended" ufw_apply_allows 2222 443/tcp 80/tcp
expect_eq "managed UFW ordering" $'prepend allow 80/tcp\nprepend allow 443/tcp\nprepend allow 2222/tcp' "$(cat "$MOCK_UFW_LOG")"
unset -f ufw

# Automatic SSH-port detection accepts one effective port and rejects ambiguity.
sshd() { printf '%s\n' 'port 2222'; }
SSH_PORT=""
expect_eq "single effective SSH port is detected" 2222 "$(detect_ssh_port)"
sshd() { printf '%s\n' 'port 22' 'port 2222'; }
expect_false "multiple SSH ports require an explicit choice" detect_ssh_port
unset -f sshd

# Existing accounts require explicit reuse and must not be system accounts.
expect_false "existing administrator needs reuse approval" admin_account_policy 1 0 1000
expect_true "approved normal administrator can be reused" admin_account_policy 1 1 1000
expect_false "system account cannot be reused" admin_account_policy 1 1 999

# Lockdown requires both a prepared phase and the second sudo session.
expect_true "prepared second-session checkpoint passes" assert_lockdown_context PREPARED vpsadmin vpsadmin
expect_false "unprepared run cannot lock down" assert_lockdown_context STARTED vpsadmin vpsadmin
expect_false "root session cannot lock down" assert_lockdown_context PREPARED vpsadmin root
expect_false "missing SUDO_USER cannot lock down" assert_lockdown_context PREPARED vpsadmin ''
expect_true "administrator sudo session is accepted" assert_admin_session vpsadmin vpsadmin
expect_false "root cannot perform final verification" assert_admin_session vpsadmin root
expect_true "a different post-lockdown connection is accepted" assert_new_connection '198.51.100.1 50000 203.0.113.1 22' '198.51.100.1 50001 203.0.113.1 22'
expect_false "the lockdown connection cannot verify itself" assert_new_connection '198.51.100.1 50000 203.0.113.1 22' '198.51.100.1 50000 203.0.113.1 22'

# Public-key validation accepts a generated public key and rejects non-key text.
KEY_BASE="$TMP_ROOT/test-key"
ssh-keygen -q -t ed25519 -N '' -f "$KEY_BASE"
PUBLIC_KEY_FILE="$KEY_BASE.pub"
expect_true "valid OpenSSH public key is accepted" validate_public_key
printf 'not a public key\n' > "$TMP_ROOT/bad.pub"
PUBLIC_KEY_FILE="$TMP_ROOT/bad.pub"
expect_false "invalid public key is rejected" validate_public_key

# sshd effective-value validation catches an ineffective drop-in.
effective_sshd() {
  if [[ "${MOCK_EFFECTIVE:-good}" == good ]]; then
    printf '%s\n' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'permitemptypasswords no' 'x11forwarding no' 'maxauthtries 4' 'logingracetime 30' 'permitrootlogin no'
  else
    printf '%s\n' 'passwordauthentication yes' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'permitemptypasswords no' 'x11forwarding no' 'maxauthtries 4' 'logingracetime 30' 'permitrootlogin no'
  fi
}
MOCK_EFFECTIVE=good
expect_true "effective SSH hardening is accepted" assert_effective_sshd vpsadmin
MOCK_EFFECTIVE=bad
expect_false "ineffective SSH drop-in is rejected" assert_effective_sshd vpsadmin

# A failed sshd syntax check is a hard gate before reload.
sshd() { return "${MOCK_SSHD_RESULT:-0}"; }
MOCK_SSHD_RESULT=0
expect_true "valid sshd syntax passes" sshd_config_syntax_valid
MOCK_SSHD_RESULT=1
expect_false "sshd syntax failure blocks lockdown" sshd_config_syntax_valid
unset -f sshd

# Repeated backup calls create one manifest entry and retain the first copy.
STATE_ROOT="$TMP_ROOT/state"
BACKUP_ROOT="$TMP_ROOT/backups"
RUN_ID="test-run"
RUN_DIR="$STATE_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR" "$BACKUP_ROOT/$RUN_ID" "$TMP_ROOT/etc"
: > "$RUN_DIR/manifest.tsv"
printf 'original\n' > "$TMP_ROOT/etc/example"
install() { mkdir -p "${@: -1}"; }
backup_path "$TMP_ROOT/etc/example" "$RUN_DIR"
backup_path "$TMP_ROOT/etc/example" "$RUN_DIR"
unset -f install
expect_eq "backup operation is idempotent" 1 "$(wc -l < "$RUN_DIR/manifest.tsv" | tr -d ' ')"
expect_eq "backup retains original content" original "$(cat "$BACKUP_ROOT/$RUN_ID$TMP_ROOT/etc/example")"

# Rollback is constrained to paths the skill owns.
expect_true "managed SSH drop-in is restorable" is_allowed_restore_path /etc/ssh/sshd_config.d/00-secure-vps-bootstrap.conf
expect_true "managed administrator key is restorable" is_allowed_restore_path /home/vpsadmin/.ssh/authorized_keys
expect_false "arbitrary system path is never restorable" is_allowed_restore_path /etc/passwd

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
