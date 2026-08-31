---
name: secure-vps-bootstrap
description: Safely inspect, bootstrap, harden, verify, or roll back a fresh Ubuntu or Debian VPS over SSH, including applying and verifying current APT security and kernel updates before declaring the host ready. Use when an AI agent needs to create a key-only non-root administrator, disable remote root and password login without locking out the operator, configure UFW and Fail2ban, install baseline administration tools, enable unattended security updates, or assess whether a new VPS is ready for use.
---

# Secure VPS Bootstrap

Harden a fresh Ubuntu or Debian VPS through a guarded two-session workflow. Use the bundled script for all server changes; do not reproduce its commands ad hoc.

## Safety invariants

- Keep the original SSH session open until final verification succeeds.
- Never run `lockdown` from the original root session. Run it with `sudo` from a new SSH session authenticated as the configured administrator.
- Never disable root or password SSH until the new public-key login and passwordless sudo both work.
- Never pass a password in a command, environment variable, file, or chat message. Let the SSH client prompt interactively when initial access uses a password.
- Never create or retain a private key on the VPS. Accept an existing public key or offer to generate a key on the controlling machine after telling the user where it will be stored.
- Preserve existing firewall rules. Open only the detected SSH port and ports explicitly requested by the user.
- Stop on unsupported distributions, failed validation, ambiguous SSH configuration, or an unexpected existing administrator account.
- Do not reboot automatically. Report `/var/run/reboot-required` at completion.
- Do not declare the server ready while APT reports pending upgrades; treat the update audit as a mandatory gate.

Read [security-policy.md](references/security-policy.md) before applying changes or troubleshooting a failed gate.

## Required inputs

Collect or discover:

- VPS hostname or IP, initial SSH user, SSH port, optional client identity file, and the provider's SSH host-key fingerprint when available.
- Public key file on the controlling machine. Prefer Ed25519. Validate its fingerprint with `ssh-keygen -lf` and show the fingerprint, never private key material.
- Administrator name; default to `vpsadmin`.
- Additional inbound ports, if any, as `PORT/tcp` or `PORT/udp`. Default to none.

If an administrator with that name already exists, stop and ask whether to use `--reuse-admin` or choose another name. Do not infer ownership of an existing account.

## Phase 1: inspect

Before the first connection, compare the SSH host-key fingerprint with the VPS provider's console or metadata when available. On first use without an authoritative fingerprint, show the fingerprint and ask the user to confirm it. Never suppress host-key checking or blindly delete an existing `known_hosts` entry.

Upload the public key to a unique root-only temporary directory. Upload the script separately, then install it with `install -o root -g root -m 0755 STAGED_SCRIPT /usr/local/sbin/secure-vps-bootstrap`; abort if that destination contains an unrelated file. The script contains no secrets and must be readable by the new administrator for later phases.

When the initial user is root, invoke the script directly because a minimal Debian image may not have `sudo` yet. When the initial user is non-root, use `sudo` and stop if privilege escalation is unavailable. Run:

```bash
/usr/local/sbin/secure-vps-bootstrap inspect
```

Confirm Ubuntu or Debian, `apt`, systemd, OpenSSH, current SSH port, sudo capability, the complete UFW rule list, listening sockets, and pending updates. Explain any existing public services before continuing. If the user requires an exclusive port set and extra allow rules exist, stop for explicit review; this skill preserves rather than deletes them.

## Phase 2: prepare

Run from the original session:

```bash
/usr/local/sbin/secure-vps-bootstrap prepare \
  --admin-user vpsadmin \
  --public-key-file /root/.secure-vps-bootstrap-upload/admin.pub
```

Add one `--allow-port PORT/PROTO` for each user-approved public service. Add `--ssh-port PORT` only if automatic detection is wrong. Add `--reuse-admin` only after explicit user approval.

`prepare` must run `apt-get update`, upgrade packages with new dependencies allowed so kernel updates are not skipped, install the baseline tools, and audit `apt list --upgradable`. If any packages remain upgradable, print the list and fail before the SSH checkpoint. It then creates or updates the administrator, configures sudo, enables unattended security updates without automatic reboot, configures UFW and Fail2ban, and prints `STATUS=CHECKPOINT_READY` plus the run ID and backup path.

If it fails, do not proceed. Diagnose from the reported failed gate. Use `rollback` when configuration changes were already made.

## Phase 3: checkpoint

From the controlling machine, open a genuinely new SSH connection using the administrator and intended private key. Do not reuse the root connection or merely run `su`:

```bash
ssh -p PORT -i PRIVATE_KEY \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  -o ControlMaster=no \
  -o ControlPath=none \
  vpsadmin@HOST
```

In that new session verify noninteractive sudo:

```bash
sudo -n true
```

Keep both sessions open. If either check fails, fix the key, account, SSH port, or firewall while the original session remains available. Do not run `lockdown`.

## Phase 4: lockdown

From the new administrator session only, run:

```bash
sudo --preserve-env=SSH_CONNECTION /usr/local/sbin/secure-vps-bootstrap lockdown --run-id RUN_ID
```

The script verifies that `SUDO_USER` matches the prepared administrator, writes the SSH hardening drop-in, checks syntax and effective settings, and only then reloads OpenSSH. Expected output includes `STATUS=LOCKDOWN_COMPLETE`.

If effective values do not match, the script removes its unactivated drop-in and stops. Follow [security-policy.md](references/security-policy.md); do not rewrite an unfamiliar main `sshd_config` automatically.

## Phase 5: reconnect and verify

Open another new administrator SSH connection with the same key-only options and `ControlMaster=no` plus `ControlPath=none`. If it fails, immediately run `rollback` from the still-open original session. The script records the lockdown connection tuple and refuses to verify through that same connection.

After reconnecting, run:

```bash
sudo --preserve-env=SSH_CONNECTION /usr/local/sbin/secure-vps-bootstrap verify --run-id RUN_ID
```

Require `STATUS=SECURE` and confirm:

- Effective SSH values disable root, password, and keyboard-interactive login while allowing public keys.
- UFW is active and allows the actual SSH port.
- Fail2ban and its `sshd` jail are active.
- The administrator exists, has an authorized key, and has a valid sudoers drop-in.
- Automatic security updates are enabled and automatic reboot is disabled.
- No packages remain in `apt list --upgradable`; if a reboot is required, report it and rerun verification after the user-approved reboot before declaring the host fully ready.

Remove only the root-only staging directory after verification. Preserve the installed script, `/var/lib/secure-vps-bootstrap`, and `/var/backups/secure-vps-bootstrap` for future verification and rollback. Report that provider-level firewalls or security groups remain outside this host-level check.

## Rollback

From a still-working privileged session, run:

```bash
sudo /usr/local/sbin/secure-vps-bootstrap rollback --run-id RUN_ID
```

Use `--run-id ID` only to select a non-current run. Rollback restores configuration files saved by that run, validates SSH before reload, reloads affected services, and disables access through a newly created administrator without deleting its home or user-owned data. Package upgrades are not reversible.

After rollback, test the intended original login before closing any session.

## Completion report

Report the OS, administrator, SSH port, actual UFW rules, requested inbound rules, service status, pending package updates, backup/run ID, whether reboot is required, and exact commands for future `verify` or `rollback`. Never claim that only the requested ports are publicly reachable unless the actual UFW rules, listeners, and any provider firewall were all checked. Never include passwords, private keys, full authorized key contents, or other secrets.
