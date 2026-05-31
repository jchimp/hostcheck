# OAuth Token Expiry Monitor for sasl-xoauth2 Postfix Relays

A standalone Bash script that monitors OAuth2 token health for Postfix relays using the [sasl-xoauth2](https://github.com/tarickb/sasl-xoauth2) plugin. Catches expiring or stale tokens **before** your mail relay silently stops sending.

Designed for M365 OAuth relay setups following guides like:
- [Postfix + OAuth2: Relay Emails to Microsoft 365 (Debian 13)](https://std.rocks/relay-ms365-oauth-debian-13.html)

Same format, same notification pipeline as host-healthcheck, host-seccheck, and host-mailcheck.

---

## Why this matters

The sasl-xoauth2 plugin auto-refreshes OAuth tokens **only when Postfix sends mail**. If your relay goes quiet for a few hours (nights, weekends), no refresh happens. The access token expires (typically after 1 hour), and the refresh token can expire too (up to 90 days, but can be shorter depending on Entra policies).

When the token finally expires and Postfix tries to send:
- SASL auth fails
- Mail queues up
- You don't know until someone complains

This monitor catches the problem **before** it becomes an outage.

---

## What it checks

| # | Check | What it looks at | Severity |
|---|---|---|---|
| 1 | **Token file exists** | Is the token file present and readable? | critical |
| 2 | **Access token expiry** | Time remaining before access token expires | warning (24h) / critical (2h) |
| 3 | **Token file freshness** | When was the file last modified (proxy for refresh cycle health) | warning (6h) / critical (24h) |
| 4 | **Token refresh test** | Live refresh against Microsoft endpoint (disabled by default) | critical on failure |
| 5 | **sasl-xoauth2 config** | Is the config valid JSON with required fields? | warning |
| 6 | **Token file permissions** | World-readable? Readable by postfix? | warning |

---

## How sasl-xoauth2 manages tokens

```
Postfix sends mail
  → sasl-xoauth2 reads token file
  → If access_token is expired, uses refresh_token to get a new one
  → Updates token file with new access_token + expiry
  → Sends mail with fresh token
```

The token file is JSON and typically looks like:

```json
{
  "access_token": "eyJ0eX...",
  "refresh_token": "0.AAAA...",
  "expiry": 1717200000
}
```

**Key insight:** The token file's modification time tells you when the last successful refresh happened. If it hasn't been updated in hours, sasl-xoauth2 hasn't refreshed — either because no mail was sent, or because the refresh is failing.

---

## File layout

```
oauth-token-monitor/
├── oauth-token-monitor.sh       # Main script
├── oauth-token-monitor.conf     # Configuration
├── install-oauth-token-monitor.sh  # Installer
└── README.md                    # This file
```

After installation:

```
/usr/local/bin/oauth-token-monitor.sh               # Executable
/etc/oauth-token-monitor/oauth-token-monitor.conf    # Config (chmod 600)
/etc/cron.d/oauth-token-monitor                      # Cron job (every 30 min)
/var/lib/oauth-token-monitor/                        # State files (cooldowns)
/var/log/oauth-token-monitor.log                     # Local log
```

---

## Installation

```bash
tar xzf oauth-token-monitor.tar.gz
cd oauth-token-monitor/
chmod +x install-oauth-token-monitor.sh
sudo ./install-oauth-token-monitor.sh
```

### Configure

```bash
sudo vi /etc/oauth-token-monitor/oauth-token-monitor.conf
```

At minimum, set:

```conf
TOKEN_FILES="/var/spool/postfix/sasl2/tokens/postfix@yourdomain.com"
TELEGRAM_ENABLED="true"
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="987654321"
```

### How to find your token file path

```bash
# Check sasl_passwd for token file references
cat /etc/postfix/sasl_passwd

# Or look in the standard sasl-xoauth2 token directory
ls -la /var/spool/postfix/sasl2/tokens/

# Or check the Postfix config
postconf smtp_sasl_password_maps
```

### Test

```bash
# Dry run
sudo oauth-token-monitor.sh --dry-run

# Live run
sudo oauth-token-monitor.sh

# Force a token refresh test (hits Microsoft API)
sudo oauth-token-monitor.sh --check-refresh
```

---

## Auto-discovery

If `TOKEN_FILES` is left empty, the script searches common locations:

- `/var/spool/postfix/sasl2/tokens/`
- `/var/spool/postfix/sasl2/`
- `/etc/postfix/sasl2/`
- `/etc/tokens/`
- References in `/etc/postfix/sasl_passwd`

It validates each file by checking if it's valid JSON containing an `access_token` field.

---

## Token refresh test

Disabled by default (`CHECK_TOKEN_REFRESH="false"`) because it hits Microsoft's token endpoint.

### When to enable it

- If you want a **definitive** answer on whether the refresh cycle works
- As a manual check: `sudo oauth-token-monitor.sh --check-refresh`
- On a schedule: enable in config, but be aware it counts against API rate limits

### Requirements for refresh test

1. Set `TENANT_ID` in the config (your Microsoft Entra Directory ID)
2. `client_id` must be present in `/etc/sasl-xoauth2.conf`
3. `refresh_token` must be present in the token file
4. The host must have outbound HTTPS access to `login.microsoftonline.com`

```conf
TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
CHECK_TOKEN_REFRESH="true"
```

---

## Configuration reference

| Key | Default | Description |
|---|---|---|
| `TELEGRAM_ENABLED` | `false` | Enable Telegram notifications |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot API token |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID |
| `EMAIL_ENABLED` | `false` | Enable email notifications |
| `EMAIL_TO` | `admin@example.com` | Email recipient |
| `EMAIL_FROM` | `oauth-monitor@hostname` | Email sender |
| `SYSLOG_ENABLED` | `true` | Log to syslog via `logger` |
| `SYSLOG_TAG` | `oauth-token-monitor` | Syslog tag |
| `ALERT_COOLDOWN_SEC` | `3600` | Seconds before repeating same alert |
| `CHECK_TOKEN_EXISTS` | `true` | Check token file existence |
| `CHECK_TOKEN_EXPIRY` | `true` | Check access token expiry time |
| `CHECK_TOKEN_STALENESS` | `true` | Check token file modification time |
| `CHECK_TOKEN_REFRESH` | `false` | Live refresh test (hits Microsoft API) |
| `CHECK_SASL_CONFIG` | `true` | Validate sasl-xoauth2 config |
| `CHECK_TOKEN_PERMISSIONS` | `true` | Check file permissions |
| `TOKEN_FILES` | *(empty)* | Token file paths (empty = auto-discover) |
| `TOKEN_WARN_HOURS` | `24` | Expiry warning threshold (hours) |
| `TOKEN_CRIT_HOURS` | `2` | Expiry critical threshold (hours) |
| `TOKEN_STALE_HOURS` | `6` | Staleness warning threshold (hours) |
| `TOKEN_STALE_CRIT_HOURS` | `24` | Staleness critical threshold (hours) |
| `SASL_XOAUTH2_CONF` | `/etc/sasl-xoauth2.conf` | Path to sasl-xoauth2 config |
| `TENANT_ID` | *(empty)* | Microsoft Entra tenant ID (for refresh test) |
| `STATE_DIR` | `/var/lib/oauth-token-monitor` | State file directory |
| `LOG_FILE` | `/var/log/oauth-token-monitor.log` | Local log file path |

---

## Pairing with host-mailcheck

This script complements host-mailcheck:

| Script | What it catches | When |
|---|---|---|
| `host-mailcheck.sh` | SASL auth failure **after** it happens | reactive (5 min) |
| `oauth-token-monitor.sh` | Token expiry **before** it fails | proactive (30 min) |

Together they give you both early warning and failure detection.

| Script | Focus | Cron | State |
|---|---|---|---|
| `host-healthcheck.sh` | Hardware / services | 5 min | `/var/lib/host-healthcheck/` |
| `host-seccheck.sh` | Security / auth / drift | 15 min | `/var/lib/host-seccheck/` |
| `host-mailcheck.sh` | Postfix / relay health | 5 min | `/var/lib/host-mailcheck/` |
| `oauth-token-monitor.sh` | OAuth token expiry | 30 min | `/var/lib/oauth-token-monitor/` |

---

## Example alert output (Telegram)

```
🔑 2 OAuth token alert(s) on relay01

[CRITICAL] TOKEN_EXPIRY
  Token EXPIRED 3h ago (2026-05-31 06:00:00): /var/spool/postfix/sasl2/tokens/postfix@domain.com

[CRITICAL] TOKEN_STALE
  Token file not updated in 28h (last: 2026-05-30 02:15:00): /var/spool/postfix/sasl2/tokens/postfix@domain.com

Time: 2026-05-31 09:30:02
```

---

## Troubleshooting

### Token expired — what do I do?

1. Force a manual refresh:
   ```bash
   sudo sasl-xoauth2-tool get-token outlook \
     /etc/sasl-xoauth2.conf \
     /var/spool/postfix/sasl2/tokens/postfix@domain.com
   ```
2. If that fails, generate a new token:
   ```bash
   sudo sasl-xoauth2-tool get-token outlook \
     /etc/sasl-xoauth2.conf \
     /var/spool/postfix/sasl2/tokens/postfix@domain.com \
     --client-id YOUR_CLIENT_ID
   ```
3. Check your Entra app registration — token lifetime or conditional access policies may have changed

### Token file not found

- Check `TOKEN_FILES` in the config
- Check your `sasl_passwd`:
  ```bash
  cat /etc/postfix/sasl_passwd
  ```
- Verify the path matches what Postfix is using

### Refresh test fails

- Verify `TENANT_ID` is correct
- Verify `client_id` in `/etc/sasl-xoauth2.conf`
- Check if the app registration still has `SMTP.Send` permission in Entra
- Check if "Allow public client flows" is still enabled
- Check for conditional access policies blocking the refresh

### Token file is world-readable

```bash
chmod 640 /var/spool/postfix/sasl2/tokens/postfix@domain.com
chown root:postfix /var/spool/postfix/sasl2/tokens/postfix@domain.com
```

### Staleness alert but token isn't expired

This usually means no mail has been sent recently (weekends, quiet periods). sasl-xoauth2 only refreshes when Postfix sends. Options:
- Enable `CHECK_TOKEN_REFRESH` to proactively test the refresh
- Set up a cron job to send a test email periodically
- Increase `TOKEN_STALE_HOURS` if your mail volume is naturally low

---

## Limitations

- **Access token expiry field** varies by sasl-xoauth2 version — the script checks both `expiry` and `expires_at` keys
- **Token file location** varies by setup — auto-discovery covers common paths but may miss custom locations
- **Refresh test** hits Microsoft's API — don't run it too frequently (every 30 min is fine)
- **Cannot auto-refresh** — the script monitors only, it doesn't fix expired tokens
- **Postfix user readability check** uses `sudo -u postfix test -r` which may not work in all environments

---

## Uninstall

```bash
rm -f /usr/local/bin/oauth-token-monitor.sh
rm -f /etc/cron.d/oauth-token-monitor
rm -rf /etc/oauth-token-monitor
rm -rf /var/lib/oauth-token-monitor
rm -f /var/log/oauth-token-monitor.log
```

---

## Quick reference

| Action | Command |
|---|---|
| Run manually | `sudo oauth-token-monitor.sh` |
| Dry run | `sudo oauth-token-monitor.sh --dry-run` |
| Force refresh test | `sudo oauth-token-monitor.sh --check-refresh` |
| Custom config | `sudo oauth-token-monitor.sh --config /path/to/conf` |
| Edit config | `vi /etc/oauth-token-monitor/oauth-token-monitor.conf` |
| View log | `tail -f /var/log/oauth-token-monitor.log` |
| Check cron | `cat /etc/cron.d/oauth-token-monitor` |
| Clear cooldowns | `rm /var/lib/oauth-token-monitor/cooldown_*` |
