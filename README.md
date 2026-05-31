# hostcheck — Unified Host Monitoring Suite

A cohesive collection of lightweight, cron-based monitoring scripts for Linux hosts. Catches system health issues, security problems, mail relay faults, and OAuth token expirations **before** they become outages.

Install once, configure once, get alerts via Telegram and/or email.

---

## Quick Start

### Install all four tools:
```bash
sudo ./install-all.sh
```

### Or install just what you need:
```bash
sudo ./install-health.sh      # System health (5 min)
sudo ./install-sec.sh         # Security auditing (15 min)
sudo ./install-mail.sh        # Postfix relay (5 min)
sudo ./install-oauth-token.sh # OAuth token expiry (30 min)
```

### Configure once for all tools:
```bash
sudo vi /etc/hostcheck/hostcheck.conf
```
Set your Telegram and email settings — all four scripts will use them.

### Configure each tool (optional):
```bash
sudo vi /etc/hostcheck/hostcheck-health.conf
sudo vi /etc/hostcheck/hostcheck-sec.conf
sudo vi /etc/hostcheck/hostcheck-mail.conf
sudo vi /etc/hostcheck/hostcheck-oauth-token.conf
```

---

## What's included

| Tool | Purpose | Checks | Cron | Alert Types |
|---|---|---|---|---|
| **hostcheck-health** | System & cluster health | NIC errors, disk space, SMART, Ceph, Corosync, CPU, memory, load, systemd, filesystems | 5 min | Hardware, service issues |
| **hostcheck-sec** | Security & drift detection | SSH failures, root SSH, sudo failures, new users, security updates, cert expiry, SSH hardening, authorized_keys, listening ports, world-writable files | 15 min | Break-ins, config drift, updates needed |
| **hostcheck-mail** | Postfix relay health | Service status, queue size, deferred age, queue growth, relay TCP, SASL/OAuth failures, TLS errors, bounces, fatal errors, spool disk | 5 min | Mail relay failures |
| **hostcheck-oauth-token** | OAuth2 token expiry (M365) | Token file exists, access token expiry, file staleness, refresh test, config validation, permissions | 30 min | Token about to expire |

---

## Installation locations

After running the installer:

```
/usr/local/bin/hostcheck-{health,sec,mail,oauth-token}.sh
/etc/hostcheck/hostcheck.conf                                 # General config (shared)
/etc/hostcheck/hostcheck-{health,sec,mail,oauth-token}.conf   # Module configs
/etc/cron.d/hostcheck-{health,sec,mail,oauth-token}           # Cron jobs
/var/lib/hostcheck-{health,sec,mail,oauth-token}/             # State files (baselines, cooldowns)
/var/log/hostcheck-{health,sec,mail,oauth-token}.log          # Local logs
```

---

## Configuration hierarchy

Scripts load config in this order (later overrides earlier):

1. **Built-in defaults** in the script
2. **Module config** `/etc/hostcheck/hostcheck-{TYPE}.conf`
3. **General config** `/etc/hostcheck/hostcheck.conf`

This means:
- Set `TELEGRAM_BOT_TOKEN` once in `hostcheck.conf` → used by all 4 tools
- Override it in `hostcheck-mail.conf` → just mail tool uses different token
- All other tools still use the general setting

---

## Configuration reference

### General config (`/etc/hostcheck/hostcheck.conf`)

```bash
# Telegram (set once, use everywhere)
TELEGRAM_ENABLED="true"
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="987654321"

# Email (set once, use everywhere)
EMAIL_ENABLED="false"
EMAIL_TO="admin@example.com"
EMAIL_FROM="hostcheck@example.com"
```

### Module-specific configs

Each tool has its own config in `/etc/hostcheck/`. For details, see:

- [hostcheck-health/README.md](hostcheck-health/README.md) — Hardware thresholds, peer hosts, NIC exclusions
- [hostcheck-sec/README.md](hostcheck-sec/README.md) — SSH/sudo thresholds, cert paths, update checks
- [hostcheck-mail/README.md](hostcheck-mail/README.md) — Relay hosts, queue thresholds, SASL failures
- [hostcheck-oauth-token/README.md](hostcheck-oauth-token/README.md) — Token paths, tenant ID, refresh test

---

## How it works

### Alert system

All tools use the same pipeline:

```
Check runs → Issues detected → Alert queued
  → Cooldown check (same alert within 1h? skip)
  → Alert sent (Telegram + email + syslog)
  → Logged locally
```

**Cooldown** (default 1 hour) prevents alert spam — same issue won't re-alert more than once per hour.

### Cron schedule

```
* * * * *  root /usr/local/bin/hostcheck-health.sh     # Every 5 min
* * * * *  root /usr/local/bin/hostcheck-sec.sh        # Every 15 min
* * * * *  root /usr/local/bin/hostcheck-mail.sh       # Every 5 min
* * * * *  root /usr/local/bin/hostcheck-oauth-token.sh # Every 30 min
```

(Cron files are in `/etc/cron.d/hostcheck-*`)

### Baselines & state

Each tool maintains state in `/var/lib/hostcheck-{TYPE}/`:

- **Baselines**: First run saves current state (NIC error counts, authorized_keys hashes, listening ports)
- **Deltas**: Subsequent runs compare against baseline → only alert on changes
- **Cooldowns**: Per-alert cooldown file prevents spam

To reset baselines after expected changes:

```bash
sudo hostcheck-health.sh --reset-baseline
sudo hostcheck-sec.sh --reset-baseline
sudo hostcheck-mail.sh --reset-baseline
```

---

## Monitoring & logs

### View logs (real-time)

```bash
tail -f /var/log/hostcheck-health.log
tail -f /var/log/hostcheck-sec.log
tail -f /var/log/hostcheck-mail.log
tail -f /var/log/hostcheck-oauth-token.log
```

### Test a tool

```bash
# Dry run (no notifications sent, no state updated)
sudo hostcheck-health.sh --dry-run

# Live run
sudo hostcheck-health.sh

# Custom config
sudo hostcheck-health.sh --config /etc/hostcheck/hostcheck-health.conf
```

### Clear cooldown (force re-alert)

```bash
rm /var/lib/hostcheck-{TYPE}/cooldown_*
```

### Check cron jobs

```bash
grep hostcheck /etc/cron.d/* 
```

---

## Module details

### hostcheck-health

**System and cluster health for Proxmox/Ceph/Corosync nodes.**

Checks: NIC errors & drops, disk space, SMART disk temps, Ceph cluster status, Corosync quorum, peer reachability (ping), CPU usage, memory usage, load average, systemd failed units, read-only filesystems.

**Great for:** Proxmox clusters, hypervisor hosts, any Linux system with storage/clustering.

👉 See [hostcheck-health/README.md](hostcheck-health/README.md) for full details.

---

### hostcheck-sec

**Security and configuration drift detection.**

Checks: Failed SSH logins, root SSH logins, failed sudo attempts, new user accounts, security updates available, reboot required, certificate expiry, SSH hardening (PermitRootLogin, PasswordAuthentication, port), authorized_keys changes, new listening ports, world-writable files in /etc.

**Great for:** Finding intrusions, tracking config changes, staying on top of patches.

👉 See [hostcheck-sec/README.md](hostcheck-sec/README.md) for full details.

---

### hostcheck-mail

**Postfix mail relay health and SASL/OAuth failures.**

Checks: Postfix service status, mail queue size & growth, deferred message age, relay TCP connectivity, SASL auth failures (Gmail, M365), TLS errors, bounce rate, fatal/panic errors, spool disk usage.

**Great for:** Mail relay operators, Gmail/Office365 relays, alerting before queue backlog.

👉 See [hostcheck-mail/README.md](hostcheck-mail/README.md) for full details.

---

### hostcheck-oauth-token

**Proactive OAuth2 token expiry monitoring for M365 Postfix relays.**

Checks: Token file exists, access token expiry time, token file staleness (auto-refresh health), live token refresh test, sasl-xoauth2 config validation, file permissions.

**Why**: sasl-xoauth2 only refreshes tokens when Postfix sends mail. If your relay is quiet, tokens can expire silently. This catches it **before** mail fails.

**Great for:** M365 OAuth relay setups using sasl-xoauth2.

👉 See [hostcheck-oauth-token/README.md](hostcheck-oauth-token/README.md) for full details.

---

## Example: Multiple hosts

**Host 1 (Proxmox cluster node):**
```bash
sudo ./install-all.sh
# Runs: health, sec, mail, oauth-token
```

**Host 2 (Mail relay only):**
```bash
sudo ./install-mail.sh
sudo ./install-oauth-token.sh
# Runs: mail, oauth-token (skips health, sec)
```

**Host 3 (Workstation):**
```bash
sudo ./install-health.sh
sudo ./install-sec.sh
# Runs: health, sec (skips mail, oauth-token)
```

All send to the same Telegram chat and email — one unified alerts channel.

---

## Troubleshooting

### Check installation

```bash
ls -la /usr/local/bin/hostcheck-*.sh
ls -la /etc/hostcheck/
ls -la /etc/cron.d/hostcheck-*
```

### Verify config

```bash
sudo hostcheck-health.sh --dry-run
sudo hostcheck-sec.sh --dry-run
sudo hostcheck-mail.sh --dry-run
sudo hostcheck-oauth-token.sh --dry-run
```

### Review logs

```bash
tail -20 /var/log/hostcheck-*.log
```

### Test Telegram/email

Edit the config, set `TELEGRAM_ENABLED="true"`, then run:
```bash
sudo hostcheck-health.sh --dry-run
```
(DRY-RUN won't send, but will log if it *would* send)

### Module not running?

Check cron:
```bash
sudo grep hostcheck /etc/cron.d/*
```

Verify the script is executable:
```bash
ls -l /usr/local/bin/hostcheck-*.sh
```

Check logs:
```bash
grep hostcheck /var/log/syslog | tail -20
```

---

## Uninstall

Remove everything:
```bash
sudo rm -f /usr/local/bin/hostcheck-*.sh
sudo rm -f /etc/cron.d/hostcheck-*
sudo rm -rf /var/lib/hostcheck-*
sudo rm -f /var/log/hostcheck-*.log
sudo rm -rf /etc/hostcheck
```

Or uninstall just one tool:
```bash
sudo rm -f /usr/local/bin/hostcheck-mail.sh
sudo rm -f /etc/cron.d/hostcheck-mail
sudo rm -rf /var/lib/hostcheck-mail
sudo rm -f /var/log/hostcheck-mail.log
sudo rm -f /etc/hostcheck/hostcheck-mail.conf
```

---

## Quick reference

| Task | Command |
|---|---|
| Install all | `sudo ./install-all.sh` |
| Install health only | `sudo ./install-health.sh` |
| Install mail + oauth | `sudo ./install-mail.sh && sudo ./install-oauth-token.sh` |
| View all logs | `tail -f /var/log/hostcheck-*.log` |
| Test health check | `sudo hostcheck-health.sh --dry-run` |
| Reset health baselines | `sudo hostcheck-health.sh --reset-baseline` |
| Manual mail check | `sudo hostcheck-mail.sh` |
| Test OAuth token refresh | `sudo hostcheck-oauth-token.sh --check-refresh` |
| Edit general config | `sudo vi /etc/hostcheck/hostcheck.conf` |
| Edit health config | `sudo vi /etc/hostcheck/hostcheck-health.conf` |
| View cron schedule | `cat /etc/cron.d/hostcheck-*` |
| Check status | `sudo hostcheck-health.sh --dry-run` (repeat for each tool) |

---

## For more details

- **System health**: [hostcheck-health/README.md](hostcheck-health/README.md)
- **Security**: [hostcheck-sec/README.md](hostcheck-sec/README.md)
- **Mail relay**: [hostcheck-mail/README.md](hostcheck-mail/README.md)
- **OAuth tokens**: [hostcheck-oauth-token/README.md](hostcheck-oauth-token/README.md)

---

**License**: See [LICENSE](LICENSE)
