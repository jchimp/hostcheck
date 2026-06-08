# hostcheck — Host Monitoring Scripts

A cohesive collection of lightweight, cron-based monitoring scripts for Linux or Proxmox hosts. Catches system health issues, security problems, mail relay faults, and OAuth token expirations **before** they become outages.

Also great for Postfix email relays for M365 or Google Apps.

Install once, configure once, get alerts via Telegram and/or email.

---

## Quick Start

### Install

```bash
sudo ./install.sh
```

The installer copies all module scripts to `/usr/local/bin`, installs the dispatcher, and prompts which modules to activate (creates cron jobs for the selected ones).

### Enable or disable modules at any time

```bash
sudo hostcheck enable health
sudo hostcheck enable all
sudo hostcheck disable mail
```

### Configure

```bash
sudo vi /etc/hostcheck/hostcheck.conf
```

One config file, shared by all four modules. At minimum, set your Telegram or email credentials.

### Check status

```bash
hostcheck status
```

---

## What's included

| Tool | Purpose | Checks | Cron |
|---|---|---|---|
| **hostcheck-health** | System & cluster health | NIC errors, disk space, SMART, Ceph, Corosync, CPU, memory, load, systemd, filesystems | 5 min |
| **hostcheck-sec** | Security & drift detection | SSH failures, root SSH, sudo failures, new users, security updates, cert expiry, SSH hardening, authorized_keys, listening ports, world-writable files | 15 min |
| **hostcheck-mail** | Postfix relay health | Service status, queue size, deferred age, queue growth, relay TCP, SASL/OAuth failures, TLS errors, bounces, fatal errors, spool disk | 5 min |
| **hostcheck-oauth-token** | OAuth2 token expiry (M365) | Token file exists, access token expiry, file staleness, refresh test, config validation, permissions | 30 min |

---

## Installation locations

After running the installer:

```
/usr/local/bin/hostcheck                                        # Dispatcher
/usr/local/bin/hostcheck-{health,sec,mail,oauth-token}.sh       # Module scripts
/etc/hostcheck/hostcheck.conf                                   # Single config file (all modules)
/etc/cron.d/hostcheck-{health,sec,mail,oauth-token}             # Cron jobs (created by: hostcheck enable)
/var/lib/hostcheck/{health,sec,mail,oauth-token}/               # State files (baselines, cooldowns)
/var/log/hostcheck/hostcheck-{health,sec,mail,oauth-token}.log  # Logs
```

---

## Configuration

All four modules share a single config file at `/etc/hostcheck/hostcheck.conf`. It covers notification settings (Telegram, email, syslog, cooldown) and all module-specific thresholds and check toggles.

```bash
# Telegram (set once, used by all modules)
TELEGRAM_ENABLED="true"
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="987654321"

# Email (set once, used by all modules)
EMAIL_ENABLED="false"
EMAIL_TO="admin@example.com"
EMAIL_FROM="hostcheck@example.com"
```

For the full list of module-specific settings, see:

- [hostcheck-health/README.md](hostcheck-health/README.md) — Hardware thresholds, peer hosts, NIC exclusions
- [hostcheck-sec/README.md](hostcheck-sec/README.md) — SSH/sudo thresholds, cert paths, update checks
- [hostcheck-mail/README.md](hostcheck-mail/README.md) — Relay hosts, queue thresholds, SASL failures
- [hostcheck-oauth-token/README.md](hostcheck-oauth-token/README.md) — Token paths, tenant ID, refresh test

---

## How it works

### Alert system

All modules use the same pipeline:

```
Check runs → Issues detected → Alert queued
  → Cooldown check (same alert within 1h? skip)
  → Alert sent (Telegram + email + syslog)
  → Logged locally
```

**Cooldown** (default 1 hour) prevents alert spam — same issue won't re-alert more than once per hour.

### Cron schedule

Cron jobs are created and removed by `hostcheck enable/disable`. The schedules are:

```
*/5  * * * *  root /usr/local/bin/hostcheck-health.sh      # Every 5 min
*/15 * * * *  root /usr/local/bin/hostcheck-sec.sh         # Every 15 min
*/5  * * * *  root /usr/local/bin/hostcheck-mail.sh        # Every 5 min
*/30 * * * *  root /usr/local/bin/hostcheck-oauth-token.sh # Every 30 min
```

(Cron files live in `/etc/cron.d/hostcheck-*`)

### Baselines & state

Each module maintains state in `/var/lib/hostcheck/{module}/`:

- **Baselines**: First run saves current state (NIC error counts, authorized_keys hashes, listening ports)
- **Deltas**: Subsequent runs compare against baseline — only alert on changes
- **Cooldowns**: Per-alert cooldown file prevents spam

To reset baselines after expected changes:

```bash
sudo hostcheck health --reset-baseline
sudo hostcheck sec --reset-baseline
sudo hostcheck mail --reset-baseline
```

---

## Running & monitoring

### Run a module manually

```bash
hostcheck health
hostcheck sec --dry-run
hostcheck mail --reset-baseline
hostcheck oauth-token --check-refresh
```

### View logs (real-time)

```bash
hostcheck log           # tail all module logs
hostcheck log health    # tail one module's log
```

### Check status

```bash
hostcheck status
```

Shows which modules are enabled (have an active cron job), whether their scripts are installed, and the current notification config.

### Check cron jobs

```bash
hostcheck cron
```

### Clear cooldown (force re-alert)

```bash
rm /var/lib/hostcheck/{health,sec,mail,oauth-token}/cooldown_*
```

---

## Module details

### hostcheck-health

**System and cluster health for Proxmox/Ceph/Corosync nodes.**

Checks: NIC errors & drops, disk space, SMART disk temps, Ceph cluster status, Corosync quorum, peer reachability (ping), CPU usage, memory usage, load average, systemd failed units, read-only filesystems.

**Great for:** Proxmox clusters, hypervisor hosts, any Linux system with storage/clustering.

See [hostcheck-health/README.md](hostcheck-health/README.md) for full details.

---

### hostcheck-sec

**Security and configuration drift detection.**

Checks: Failed SSH logins, root SSH logins, failed sudo attempts, new user accounts, security updates available, reboot required, certificate expiry, SSH hardening (PermitRootLogin, PasswordAuthentication, port), authorized_keys changes, new listening ports, world-writable files in /etc.

**Great for:** Finding intrusions, tracking config changes, staying on top of patches.

See [hostcheck-sec/README.md](hostcheck-sec/README.md) for full details.

---

### hostcheck-mail

**Postfix mail relay health and SASL/OAuth failures.**

Checks: Postfix service status, mail queue size & growth, deferred message age, relay TCP connectivity, SASL auth failures (Gmail, M365), TLS errors, bounce rate, fatal/panic errors, spool disk usage.

**Great for:** Mail relay operators, Gmail/Office365 relays, alerting before queue backlog.

See [hostcheck-mail/README.md](hostcheck-mail/README.md) for full details.

---

### hostcheck-oauth-token

**Proactive OAuth2 token expiry monitoring for M365 Postfix relays.**

Checks: Token file exists, access token expiry time, token file staleness (auto-refresh health), live token refresh test, sasl-xoauth2 config validation, file permissions.

**Why**: sasl-xoauth2 only refreshes tokens when Postfix sends mail. If your relay is quiet, tokens can expire silently. This catches it **before** mail fails.

**Great for:** M365 OAuth relay setups using sasl-xoauth2.

See [hostcheck-oauth-token/README.md](hostcheck-oauth-token/README.md) for full details.

---

## Uninstall

Remove everything:
```bash
sudo hostcheck disable all
sudo rm -f /usr/local/bin/hostcheck /usr/local/bin/hostcheck-*.sh
sudo rm -rf /var/lib/hostcheck
sudo rm -rf /var/log/hostcheck
sudo rm -rf /etc/hostcheck
```

Or remove just one module:
```bash
sudo hostcheck disable mail
sudo rm -f /usr/local/bin/hostcheck-mail.sh
sudo rm -rf /var/lib/hostcheck/mail
sudo rm -f /var/log/hostcheck/hostcheck-mail.log
```

---

## Quick reference

| Task | Command |
|---|---|
| Install | `sudo ./install.sh` |
| Enable a module | `sudo hostcheck enable <module\|all>` |
| Disable a module | `sudo hostcheck disable <module\|all>` |
| Run a module | `hostcheck <module> [--dry-run]` |
| View all logs | `hostcheck log` |
| View one module's log | `hostcheck log <module>` |
| Check status | `hostcheck status` |
| Check cron jobs | `hostcheck cron` |
| Reset baselines | `sudo hostcheck <module> --reset-baseline` |
| Test OAuth refresh | `sudo hostcheck oauth-token --check-refresh` |
| Edit config | `sudo vi /etc/hostcheck/hostcheck.conf` |

---

## For more details

- **System health**: [hostcheck-health/README.md](hostcheck-health/README.md)
- **Security**: [hostcheck-sec/README.md](hostcheck-sec/README.md)
- **Mail relay**: [hostcheck-mail/README.md](hostcheck-mail/README.md)
- **OAuth tokens**: [hostcheck-oauth-token/README.md](hostcheck-oauth-token/README.md)

---

**MIT License**: See [LICENSE](LICENSE)
