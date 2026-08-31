# Security policy and failure handling

## Supported baseline

Support Ubuntu and Debian systems that provide `apt-get`, systemd, and OpenSSH. Abort before mutation on other distributions or when those facilities are absent. The workflow targets a fresh general-purpose VPS, not containers, immutable images, network appliances, or hosts managed by a conflicting configuration-management system.

## SSH policy

Keep the current SSH port. Configure these effective global values during lockdown:

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
```

OpenSSH normally uses the first obtained value for a keyword. Put the managed file at `/etc/ssh/sshd_config.d/00-secure-vps-bootstrap.conf`, then verify the result with `sshd -T` for both the administrator and root contexts. A syntactically valid but ineffective drop-in is a failure. Remove the unactivated drop-in and stop instead of rewriting an unfamiliar main configuration.

Do not disable TCP or agent forwarding by default; operators commonly need SSH tunnels and agent workflows. Do not replace the distribution's algorithm lists.

## Firewall policy

Set UFW defaults to deny incoming and allow outgoing. Preserve existing rules rather than resetting UFW. Before enabling it, dry-run every requested rule with `prepend`, which also works on an empty ruleset. Prepend explicitly requested ports in reverse order, then prepend SSH last; the effective SSH allow becomes rule one and every managed allow precedes older denies. Add no HTTP, HTTPS, database, control-panel, or application port unless the user explicitly requested it.

Treat existing extra allow rules as findings, not authorization to delete them. Report them for later review.

UFW verification covers only the host firewall. Provider firewalls, security groups, NAT, and upstream filtering require separate provider-side inspection.

Always print the actual UFW rules during inspection and final verification. Do not certify an exclusive public-port set from requested arguments alone.

## Fail2ban policy

Use `/etc/fail2ban/jail.d/00-secure-vps-bootstrap.local`, the packaged `sshd` filter, the systemd backend, the effective SSH port, five attempts in ten minutes, and a one-hour ban. Validate with `fail2ban-client -t` before enabling or restarting the service.

Fail2ban supplements key-only authentication and the firewall; it does not replace either control.

## Updates and reboot policy

Run `apt-get update`, then upgrade with new dependencies allowed (for example `apt-get --with-new-pkgs upgrade`) so kernel updates are not silently skipped; install the baseline tools from configured APT repositories. Afterward, run `apt list --upgradable` as a mandatory update gate. A non-empty result fails the prepare/verify readiness gate and must be reported before continuing. Configure periodic package-list refresh and unattended upgrades in a separate drop-in. Explicitly disable automatic reboot. Never alter third-party repository trust or add repositories.

Report `/var/run/reboot-required`; leave reboot scheduling to the user. When a reboot is required, rerun the update audit and verification after the user-approved reboot before declaring the host fully ready.

## Backups and rollback

Store run state under `/var/lib/secure-vps-bootstrap/RUN_ID` and pre-change file copies under `/var/backups/secure-vps-bootstrap/RUN_ID`, both root-only. Back up only managed files and UFW rule files. Never capture private keys or unrelated credential stores.

Rollback restores files and service state, but cannot undo installed packages or package upgrades. If the run created the administrator, rollback removes its managed sudo and key access and locks the account; it does not delete the account or home directory.

## Failure gates

- Invalid public key: stop before creating or changing the administrator.
- Existing administrator without `--reuse-admin`: stop before changes.
- Failed sudoers validation: restore its previous file and stop.
- Failed UFW dry-run or missing SSH allow rule: do not enable UFW.
- Failed Fail2ban validation: restore its previous file and stop.
- Failed `sshd -t` or ineffective `sshd -T`: remove the new SSH drop-in and do not reload.
- Wrong lockdown session (`SUDO_USER` differs from the prepared administrator): refuse lockdown.
- Failed post-lockdown reconnect: rollback through the original session immediately.
