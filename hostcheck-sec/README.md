# Host Security Check Script for Proxmox / Linux Nodes

A standalone Bash script that runs on each host via cron, checks for security issues, and fires alerts via Telegram and/or email when problems are found.

Same format, same structure, same notification pipeline as the hostcheck-health script — but focused entirely on security.

No infrastructure dependencies. No agents. Just one script, one config file, and cron.

---

## What it checks

| # | Check | What it looks at | Severity |
|---|---|---|---|
| 1 | **Failed SSH logins** | Failed password/key attempts since last run (delta-based), top source IPs | warning / critical |
| 2 | **Root SSH logins** | Successful root SSH logins since last run | warning |
| 3 | **Failed sudo** | Failed sudo attempts since last run | warning |
| 4 | **New user accounts** | Detects changes to /etc/passwd (hash-based, shows added/removed users) | critical |
| 5 | **Security updates** | Pending security patches via apt | warning |
| 6 | **Reboot required** | /var/run/reboot-required exists | info |
| 7 | **Certificate expiry** | Scans PVE and SSL cert paths for expiring/expired certificates | warning / critical |
| 8 | **SSH config audit** | Flags PermitRootLogin=yes, PasswordAuthentication=yes, port 22 | info |
| 9 | **Authorized keys changes** | Detects modifications to any user's authorized_keys (hash-based) | warning |
| 10 | **New listening ports** | Compares current listening ports against a saved baseline | warning |
| 11 | **World-writable files** | Finds world-writable files in /etc | warning |

---

## File layout

```
hostcheck-sec/
├── hostcheck-sec.sh             # Main security check script
└── README.md                    # This file
```

After installation:

```
/usr/local/bin/hostcheck-sec.sh                 # Executable
/etc/hostcheck/hostcheck.conf                   # Central config (shared with all modules)
/etc/cron.d/hostcheck-sec                       # Cron job (every 15 min) — managed by: hostcheck enable/disable sec
/var/lib/hostcheck/sec/                         # State files (baselines, offsets, cooldowns)
/var/log/hostcheck/hostcheck-sec.log            # Module log
```

---

## How delta tracking works (auth logs)

The script tracks a **line offset** in the auth log (`/var/log/auth.log` or `/var/log/secure`).

On each run:
1. Read the saved line count from the state file
2. Process only new lines since that offset
3. Save the current line count

This means:
- No duplicate alerts from the same log entry
- Fast execution (doesn't re-parse the entire log)
- Handles log rotation gracefully (if the file shrinks, it resets to line 0)

The first run after installation saves the current offset and does **not** alert on historical entries.

---

## How port baseline works

On first run (or after `--reset-baseline`), the script saves all currently listening ports as the **known-good baseline**.

On subsequent runs, it compares current ports to the baseline and alerts on any **new** ports that were not present before.

### Accepting new ports into the baseline

After installing a new service or making expected changes:

```bash
sudo hostcheck-sec.sh --reset-baseline
```

This re-snapshots all baselines:
- Listening ports
- Authorized keys hashes
- /etc/passwd hash
- Auth log offset

### What `--reset-baseline` resets

| Baseline | What it stores |
|---|---|
| Ports | Current listening ports (port + process) |
| Authorized keys | MD5 hashes of all authorized_keys files |
| User accounts | MD5 hash of /etc/passwd + username list |
| Auth log offset | Current line count (skip historical entries) |

---

## SSH config audit

The SSH hardening check flags common misconfigurations:

| Finding | Why it matters |
|---|---|
| `PermitRootLogin is YES` | Direct root SSH access is a security risk |
| `PasswordAuthentication is YES` | Susceptible to brute force (prefer key-based) |
| `SSH on default port 22` | Increases exposure to automated scanning |

These are **informational** alerts. They use the standard cooldown, so they won't repeat every 15 minutes. They'll re-fire after the cooldown expires only if the config hasn't changed.

If you intentionally allow password auth or root login, set `CHECK_SSH_CONFIG="false"` in the config.

---

## Configuration reference

Configuration lives in `/etc/hostcheck/hostcheck.conf`, shared across all modules.
Edit it with: `sudo vi /etc/hostcheck/hostcheck.conf`

| Key | Default | Description |
|---|---|---|
| `TELEGRAM_ENABLED` | `false` | Enable Telegram notifications |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot API token |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID (numeric) |
| `EMAIL_ENABLED` | `false` | Enable email notifications |
| `EMAIL_TO` | `admin@example.com` | Email recipient |
| `EMAIL_FROM` | `seccheck@hostname` | Email sender |
| `SYSLOG_ENABLED` | `true` | Log to syslog via `logger` |
| `SYSLOG_TAG` | `seccheck` | Syslog tag |
| `ALERT_COOLDOWN_SEC` | `3600` | Seconds before repeating same alert |
| `CHECK_SSH_FAILED` | `true` | Enable failed SSH login check |
| `CHECK_SSH_ROOT` | `true` | Enable root SSH login check |
| `CHECK_SUDO_FAILED` | `true` | Enable failed sudo check |
| `CHECK_NEW_USERS` | `true` | Enable new user account detection |
| `CHECK_UPDATES` | `true` | Enable security updates check |
| `CHECK_REBOOT` | `true` | Enable reboot-required check |
| `CHECK_CERTS` | `true` | Enable certificate expiry check |
| `CHECK_SSH_CONFIG` | `true` | Enable SSH config audit |
| `CHECK_AUTHORIZED_KEYS` | `true` | Enable authorized_keys change detection |
| `CHECK_LISTENING_PORTS` | `true` | Enable new listening port detection |
| `CHECK_WORLD_WRITABLE` | `true` | Enable world-writable file check |
| `AUTH_LOG` | *(empty)* | Auth log path (empty = auto-detect) |
| `SSH_FAIL_WARN` | `10` | Failed SSH login warning threshold |
| `SSH_FAIL_CRIT` | `50` | Failed SSH login critical threshold |
| `SUDO_FAIL_WARN` | `5` | Failed sudo warning threshold |
| `CERT_PATHS` | `/etc/pve/local /etc/ssl/certs` | Certificate paths to scan |
| `CERT_WARN_DAYS` | `30` | Certificate expiry warning (days) |
| `CERT_CRIT_DAYS` | `7` | Certificate expiry critical (days) |
| `STATE_DIR` | `/var/lib/hostcheck-sec` | State file directory |
| `LOG_FILE` | `/var/log/hostcheck-sec.log` | Local log file path |

---

## Example alert output (Telegram)

```
🔒 3 security alert(s) on pve01

[CRITICAL] SSH_FAILED
  52 failed SSH login attempts
  Top sources:
    203.0.113.45 (38 attempts)
    198.51.100.12 (14 attempts)

[WARNING] AUTH_KEYS
  authorized_keys changed: MODIFIED: /root/.ssh/authorized_keys

[INFO] SSH_CONFIG
  SSH hardening findings: PasswordAuthentication is YES, SSH on default port 22

Time: 2026-05-30 18:15:02
```

---

## Example log output

```
[2026-05-30 18:15:02] [pve01] ========== Security check starting ==========
[2026-05-30 18:15:02] [pve01] Checking failed SSH logins
[2026-05-30 18:15:02] [pve01] ALERT [CRITICAL] SSH_FAILED: 52 failed SSH login attempts...
[2026-05-30 18:15:02] [pve01] Checking root SSH logins
[2026-05-30 18:15:02] [pve01] Checking failed sudo attempts
[2026-05-30 18:15:02] [pve01] Checking for new user accounts
[2026-05-30 18:15:02] [pve01] Checking for security updates
[2026-05-30 18:15:02] [pve01] Checking if reboot is required
[2026-05-30 18:15:02] [pve01] Checking certificate expiry
[2026-05-30 18:15:02] [pve01] Checking SSH hardening
[2026-05-30 18:15:02] [pve01] ALERT [INFO] SSH_CONFIG: SSH hardening findings: PasswordAuthentication is YES
[2026-05-30 18:15:02] [pve01] Checking authorized_keys changes
[2026-05-30 18:15:02] [pve01] ALERT [WARNING] AUTH_KEYS: authorized_keys changed: MODIFIED: /root/.ssh/authorized_keys
[2026-05-30 18:15:02] [pve01] Checking for new listening ports
[2026-05-30 18:15:02] [pve01] Checking for world-writable files in /etc
[2026-05-30 18:15:02] [pve01] Sent 3 alert(s)
[2026-05-30 18:15:02] [pve01] ========== Security check complete (3 alert(s)) ==========
```

---

## Non-Proxmox usage

This script works on any Debian/Ubuntu/RHEL-based Linux host.

For non-Proxmox systems:
- Certificate checks auto-skip `/etc/pve/` if it doesn't exist
- Auth log auto-detects between `/var/log/auth.log` and `/var/log/secure`
- All Proxmox-specific paths are simply skipped if not present

No config changes needed — it just works.

---

## Troubleshooting

### No alerts are being sent

- Run manually: `sudo hostcheck-sec.sh`
- Check the log: `tail -50 /var/log/hostcheck-sec.log`
- Look for `COOLDOWN` entries — the alert may be within cooldown
- Verify Telegram credentials: `curl "https://api.telegram.org/bot<TOKEN>/getMe"`

### False positives on listening ports

After installing a new service:

```bash
sudo hostcheck-sec.sh --reset-baseline
```

### False positives on authorized_keys

After intentionally adding SSH keys:

```bash
sudo hostcheck-sec.sh --reset-baseline
```

### Auth log checks show nothing

- Verify which log exists: `ls -la /var/log/auth.log /var/log/secure`
- Or set `AUTH_LOG="/var/log/auth.log"` explicitly in the config
- First run saves the offset — it will only alert on **new** entries after install

### SSH config audit keeps alerting

If you intentionally allow password auth or root login:

```conf
CHECK_SSH_CONFIG="false"
```

---

## Pairing with hostcheck-health

These two scripts are designed to work side-by-side:

| Script | Focus | Cron | State dir |
|---|---|---|---|
| `hostcheck-health.sh` | Hardware/service health | every 5 min | `/var/lib/hostcheck/health/` |
| `hostcheck-sec.sh` | Security/auth/drift | every 15 min | `/var/lib/hostcheck/sec/` |

They share the same notification config format, so you can copy your Telegram credentials between them.

---

## Limitations

- **Point-in-time check** — runs every 15 minutes. Events between runs may be missed if the auth log rotates.
- **Auth log parsing** is pattern-based and covers standard sshd/sudo messages. Non-standard PAM modules may not be detected.
- **Certificate scanning** checks X.509 certificates only. It skips key files and non-certificate PEM files.
- **Port baseline** is simple port-number comparison. It does not track which specific address a port binds to.
- **SSH config parsing** reads the main `sshd_config` only. It does not parse `Include` directives or `Match` blocks.
- **No intrusion detection** — this is a compliance/hygiene script, not an IDS. For deep analysis, consider OSSEC or Wazuh.

---

## Uninstall

```bash
sudo hostcheck disable sec
sudo rm -f /usr/local/bin/hostcheck-sec.sh
sudo rm -rf /var/lib/hostcheck/sec
sudo rm -f /var/log/hostcheck/hostcheck-sec.log
```

---

## Quick reference

| Action | Command |
|---|---|
| Run manually | `sudo hostcheck-sec.sh` |
| Dry run | `sudo hostcheck-sec.sh --dry-run` |
| Custom config | `sudo hostcheck-sec.sh --config /path/to/conf` |
| Reset baselines | `sudo hostcheck-sec.sh --reset-baseline` |
| Edit config | `sudo vi /etc/hostcheck/hostcheck.conf` |
| View log | `tail -f /var/log/hostcheck-sec.log` |
| Check cron | `cat /etc/cron.d/hostcheck-sec` |
| Clear cooldowns | `rm /var/lib/hostcheck/sec/cooldown_*` |
