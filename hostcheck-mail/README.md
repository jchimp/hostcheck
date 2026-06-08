# Host Mail Check Script for Postfix Relay Servers

A standalone Bash script that runs on each Postfix relay host via cron, monitors mail service health, and fires alerts via Telegram and/or email when problems are found.

Same format, same structure, same notification pipeline as hostcheck-health and hostcheck-sec — but focused on Postfix and mail relay operations.

No infrastructure dependencies. No agents. Just one script, one config file, and cron.

---

## What it checks

| # | Check | What it looks at | Severity |
|---|---|---|---|
| 1 | **Postfix service** | Is Postfix running (systemd / process check) | critical |
| 2 | **Queue size** | Total messages in all queues via `mailq` | warning / critical |
| 3 | **Deferred age** | Oldest message in deferred queue | warning / critical |
| 4 | **Queue growth** | Net queue growth between runs (delta-based) | warning |
| 5 | **Relay connectivity** | TCP connect test to each configured relay (Gmail, M365, etc.) | critical |
| 6 | **SASL auth failures** | Failed auth attempts in mail log (app passwords + OAuth) | warning / critical |
| 7 | **TLS errors** | TLS/SSL handshake failures in mail log | warning |
| 8 | **Bounce rate** | Bounced/rejected messages in mail log since last run | warning |
| 9 | **Mail log errors** | Postfix fatal/panic/error messages | warning / critical |
| 10 | **Spool disk usage** | Filesystem usage of `/var/spool/postfix` | warning / critical |

---

## File layout

```
hostcheck-mail/
├── hostcheck-mail.sh            # Main mail check script
└── README.md                    # This file
```

After installation:

```
/usr/local/bin/hostcheck-mail.sh                # Executable
/etc/hostcheck/hostcheck.conf                   # Central config (shared with all modules)
/etc/cron.d/hostcheck-mail                      # Cron job (every 5 min) — managed by: hostcheck enable/disable mail
/var/lib/hostcheck/mail/                        # State files (offsets, baselines, cooldowns)
/var/log/hostcheck/hostcheck-mail.log           # Module log
```

---

## Relay monitoring: Gmail vs M365

This script is designed to monitor both common homelab/SMB relay configurations.

### Gmail with app passwords

Postfix sends via `smtp.gmail.com:587` using SASL PLAIN with a Gmail app password.

When it fails, the mail log shows:
```
SASL authentication failed; server smtp.gmail.com said: 535 5.7.8 Username and Password not accepted
```

The script catches this via the `SASL authentication failed` and `535 5.7.` patterns.

**Common causes:**
- App password revoked or expired
- Account security policy change
- Rate limiting

### M365 / Outlook with SASL XOAUTH2

Postfix sends via `smtp.office365.com:587` using SASL XOAUTH2 with an OAuth2 token.

When it fails, the mail log shows patterns like:
```
SASL authentication failed; server smtp.office365.com said: 535 5.7.3 Authentication unsuccessful
```
or OAuth-specific errors.

**Common causes:**
- OAuth token expired (needs refresh)
- App registration permissions changed
- Conditional access policy blocking

The script catches both standard SASL failures and OAuth-specific errors in the same check.

---

## How to configure RELAY_HOSTS

`RELAY_HOSTS` is a **space-separated** list of `host:port` pairs:

```conf
# Single relay
RELAY_HOSTS="smtp.gmail.com:587"

# Multiple relays
RELAY_HOSTS="smtp.gmail.com:587 smtp.office365.com:587"

# Custom relay or internal smarthost
RELAY_HOSTS="smtp.gmail.com:587 mail.internal.lan:25"

# Disable relay check
RELAY_HOSTS=""
```

The script performs a **TCP connect test only** — it does not send SMTP commands or authenticate. This keeps it simple and avoids triggering rate limits.

---

## How delta tracking works (mail log)

Same approach as hostcheck-sec:

1. Store the current line count of the mail log in a state file
2. On the next run, only read lines added since the last offset
3. Handle log rotation: if the file shrinks, reset to line 0
4. First run saves the offset and doesn't alert on historical entries

All log-based checks (SASL, TLS, bounces, errors) share the same cached lines from a single read.

---

## How queue growth tracking works

1. Each run records the current queue size from `mailq`
2. Compare with the previous run's count
3. Alert if the queue grew by more than `QUEUE_GROWTH_WARN` messages
4. This catches relay failures before the queue hits critical size

Example: if the queue was 5 and is now 30, that's a growth of 25 → alert fires.

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
| `EMAIL_FROM` | `mailcheck@hostname` | Email sender |
| `SYSLOG_ENABLED` | `true` | Log to syslog via `logger` |
| `SYSLOG_TAG` | `mailcheck` | Syslog tag |
| `ALERT_COOLDOWN_SEC` | `3600` | Seconds before repeating same alert |
| `CHECK_POSTFIX_SERVICE` | `true` | Enable Postfix service check |
| `CHECK_QUEUE_SIZE` | `true` | Enable queue size check |
| `CHECK_DEFERRED_AGE` | `true` | Enable deferred queue age check |
| `CHECK_QUEUE_GROWTH` | `true` | Enable queue growth check |
| `CHECK_RELAY_CONNECTIVITY` | `true` | Enable relay TCP connect check |
| `CHECK_SASL_FAILURES` | `true` | Enable SASL auth failure check |
| `CHECK_TLS_ERRORS` | `true` | Enable TLS error check |
| `CHECK_BOUNCES` | `true` | Enable bounce rate check |
| `CHECK_MAIL_ERRORS` | `true` | Enable mail log error check |
| `CHECK_SPOOL_DISK` | `true` | Enable spool disk usage check |
| `QUEUE_WARN` | `50` | Queue size warning threshold |
| `QUEUE_CRIT` | `200` | Queue size critical threshold |
| `DEFERRED_WARN_AGE` | `3600` | Deferred message age warning (seconds) |
| `DEFERRED_CRIT_AGE` | `14400` | Deferred message age critical (seconds) |
| `QUEUE_GROWTH_WARN` | `20` | Queue growth warning (messages per interval) |
| `RELAY_HOSTS` | `smtp.gmail.com:587 smtp.office365.com:587` | Relay servers to check (host:port) |
| `RELAY_TIMEOUT` | `10` | TCP connect timeout (seconds) |
| `SASL_FAIL_WARN` | `3` | SASL failure warning threshold |
| `SASL_FAIL_CRIT` | `10` | SASL failure critical threshold |
| `BOUNCE_WARN` | `20` | Bounce warning threshold |
| `SPOOL_WARN_PCT` | `80` | Spool disk warning threshold (%) |
| `SPOOL_CRIT_PCT` | `95` | Spool disk critical threshold (%) |
| `MAIL_LOG` | *(empty)* | Mail log path (empty = auto-detect) |
| `STATE_DIR` | `/var/lib/hostcheck-mail` | State file directory |
| `LOG_FILE` | `/var/log/hostcheck-mail.log` | Local log file path |

---

## Pairing with hostcheck-health and hostcheck-sec

All three scripts are designed to work side-by-side:

| Script | Focus | Cron | Log | State |
|---|---|---|---|---|
| `hostcheck-health.sh` | Hardware / services | every 5 min | `/var/log/hostcheck/hostcheck-health.log` | `/var/lib/hostcheck/health/` |
| `hostcheck-sec.sh` | Security / auth / drift | every 15 min | `/var/log/hostcheck/hostcheck-sec.log` | `/var/lib/hostcheck/sec/` |
| `hostcheck-mail.sh` | Postfix / relay health | every 5 min | `/var/log/hostcheck/hostcheck-mail.log` | `/var/lib/hostcheck/mail/` |

They share the same notification config format, so you can copy your Telegram credentials between them.

---

## Example alert output (Telegram)

```
📬 3 mail alert(s) on relay01

[CRITICAL] SASL
  8 SASL auth failure(s)
  relay=smtp.office365.com (8 failures)

[WARNING] QUEUE_SIZE
  Mail queue has 73 messages (warning threshold: 50)

[WARNING] DEFERRED
  12 deferred message(s), oldest is 2h 15m old

Time: 2026-05-31 09:20:02
```

---

## Example log output

```
[2026-05-31 09:20:02] [relay01] ========== Mail check starting ==========
[2026-05-31 09:20:02] [relay01] Checking Postfix service
[2026-05-31 09:20:02] [relay01] Checking mail queue size
[2026-05-31 09:20:02] [relay01] Checking deferred queue age
[2026-05-31 09:20:02] [relay01] ALERT [WARNING] DEFERRED: 12 deferred message(s), oldest is 2h 15m old
[2026-05-31 09:20:02] [relay01] Checking queue growth
[2026-05-31 09:20:02] [relay01] Checking relay connectivity
[2026-05-31 09:20:02] [relay01] Relay reachable: smtp.gmail.com:587
[2026-05-31 09:20:02] [relay01] Relay reachable: smtp.office365.com:587
[2026-05-31 09:20:02] [relay01] Checking SASL authentication failures
[2026-05-31 09:20:02] [relay01] ALERT [CRITICAL] SASL: 8 SASL auth failure(s)...
[2026-05-31 09:20:02] [relay01] Checking TLS errors
[2026-05-31 09:20:02] [relay01] Checking bounce rate
[2026-05-31 09:20:02] [relay01] Checking mail log errors
[2026-05-31 09:20:02] [relay01] Checking spool disk usage
[2026-05-31 09:20:02] [relay01] Sent 3 alert(s)
[2026-05-31 09:20:02] [relay01] ========== Mail check complete (3 alert(s)) ==========
```

---

## Troubleshooting

### No alerts are being sent

- Run manually: `sudo hostcheck-mail.sh`
- Check the log: `tail -50 /var/log/hostcheck-mail.log`
- Look for `COOLDOWN` entries — the alert may be within cooldown
- Verify Telegram credentials: `curl "https://api.telegram.org/bot<TOKEN>/getMe"`

### Queue check shows no data

- Verify `mailq` works: `mailq`
- Verify postfix is running: `systemctl status postfix`

### SASL failures not detected

- Check which log exists: `ls -la /var/log/mail.log /var/log/maillog`
- Or set `MAIL_LOG="/var/log/mail.log"` explicitly
- First run saves the offset — it will only alert on **new** entries after install
- Check manually: `grep -i "SASL authentication failed" /var/log/mail.log | tail -5`

### Relay connectivity check fails but mail is working

- The check uses TCP connect only — it doesn't authenticate
- Possible causes: DNS resolution failure, firewall rules, ISP blocking port 587
- Check manually: `nc -zv smtp.gmail.com 587`

### M365 OAuth token expired

The script detects the failure via SASL error patterns, but it **cannot refresh the token** for you. You'll need to:
1. Refresh the OAuth token via your token refresh script
2. Restart Postfix if needed
3. Run `hostcheck-mail.sh --reset-baseline` to clear the mail log offset

### Queue keeps growing

This usually means relay delivery is failing. Check:
1. Relay connectivity (can you reach the SMTP server?)
2. SASL auth (are credentials valid?)
3. TLS (any certificate issues?)
4. The deferred queue for error reasons: `postqueue -p`

---

## Limitations

- **TCP connect only** for relay checks — does not perform SMTP handshake or authentication test
- **OAuth token expiry prediction** is not supported — the script detects failures after they happen, not before
- **Mail log parsing** is pattern-based — unusual Postfix configurations or non-standard log formats may not match
- **Queue size parsing** depends on standard `mailq` output format
- **Point-in-time check** — runs every 5 minutes. Very brief relay outages between runs may not be caught
- **No per-recipient tracking** — the script monitors overall health, not individual message delivery

---

## Uninstall

```bash
sudo hostcheck disable mail
sudo rm -f /usr/local/bin/hostcheck-mail.sh
sudo rm -rf /var/lib/hostcheck/mail
sudo rm -f /var/log/hostcheck/hostcheck-mail.log
```

---

## Quick reference

| Action | Command |
|---|---|
| Run manually | `sudo hostcheck-mail.sh` |
| Dry run | `sudo hostcheck-mail.sh --dry-run` |
| Custom config | `sudo hostcheck-mail.sh --config /path/to/conf` |
| Reset baselines | `sudo hostcheck-mail.sh --reset-baseline` |
| Edit config | `sudo vi /etc/hostcheck/hostcheck.conf` |
| View log | `tail -f /var/log/hostcheck-mail.log` |
| Check cron | `cat /etc/cron.d/hostcheck-mail` |
| Clear cooldowns | `rm /var/lib/hostcheck/mail/cooldown_*` |
