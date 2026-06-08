#!/usr/bin/env bash
###############################################################################
# hostcheck-oauth-token.sh
#
# Proactive OAuth2 token expiry monitor for sasl-xoauth2 Postfix relays.
# Checks token file existence, access token expiry, token file freshness,
# sasl-xoauth2 config validation, and token file permissions.
#
# Optionally performs a live token refresh test against Microsoft's endpoint.
#
# Designed for M365 OAuth relay setups using sasl-xoauth2:
#   https://github.com/tarickb/sasl-xoauth2
#   https://std.rocks/relay-ms365-oauth-debian-13.html
#
# Usage:
#   /usr/local/bin/hostcheck-oauth-token.sh
#   /usr/local/bin/hostcheck-oauth-token.sh --config /path/to/config
#   /usr/local/bin/hostcheck-oauth-token.sh --dry-run
#   /usr/local/bin/hostcheck-oauth-token.sh --check-refresh
###############################################################################

set -Euo pipefail

# ── Ensure sbin paths are available (cron uses minimal PATH) ────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ── Defaults (overridden by config file) ─────────────────────────────────────
CONF_FILE="/etc/hostcheck/hostcheck.conf"
DRY_RUN=0
FORCE_REFRESH_CHECK=0

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

EMAIL_ENABLED="false"
EMAIL_TO=""
EMAIL_FROM="hostcheck-oauth@$(hostname -f 2>/dev/null || hostname)"

SYSLOG_ENABLED="true"
SYSLOG_TAG="hostcheck-oauth-token"

ALERT_COOLDOWN_SEC=3600

CHECK_TOKEN_EXISTS="true"
CHECK_TOKEN_EXPIRY="true"
CHECK_TOKEN_STALENESS="true"
CHECK_TOKEN_REFRESH="false"
CHECK_SASL_CONFIG="true"
CHECK_TOKEN_PERMISSIONS="true"

TOKEN_FILES=""
TOKEN_WARN_HOURS=24
TOKEN_CRIT_HOURS=2
TOKEN_STALE_HOURS=6
TOKEN_STALE_CRIT_HOURS=24

SASL_XOAUTH2_CONF="/etc/sasl-xoauth2.conf"
TENANT_ID=""

STATE_DIR="/var/lib/hostcheck/oauth-token"
LOG_FILE="/var/log/hostcheck/hostcheck-oauth-token.log"

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)          CONF_FILE="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --check-refresh)   FORCE_REFRESH_CHECK=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--config <path>] [--dry-run] [--check-refresh]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Load config ──────────────────────────────────────────────────────────────
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

# Override refresh check if forced via CLI
if [[ "$FORCE_REFRESH_CHECK" -eq 1 ]]; then
  CHECK_TOKEN_REFRESH="true"
fi

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
ALERT_BUFFER=""
ALERT_COUNT=0

# ── Logging ──────────────────────────────────────────────────────────────────
log() {
  local msg="[${TIMESTAMP}] [${HOSTNAME_SHORT}] $*"
  echo "$msg" >> "$LOG_FILE"
  if [[ "$SYSLOG_ENABLED" == "true" ]] && command -v logger &>/dev/null; then
    logger -t "$SYSLOG_TAG" "$*"
  fi
}

log_alert() {
  local severity="$1"
  local check="$2"
  local message="$3"
  local alert_key="${check}::${message}"
  local cooldown_file="${STATE_DIR}/cooldown_$(echo "$alert_key" | md5sum | awk '{print $1}')"

  if [[ -f "$cooldown_file" ]]; then
    local last_sent
    last_sent="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
    local now
    now="$(date +%s)"
    local elapsed=$(( now - last_sent ))
    if (( elapsed < ALERT_COOLDOWN_SEC )); then
      log "COOLDOWN [${severity}] ${check}: ${message} (${elapsed}s / ${ALERT_COOLDOWN_SEC}s)"
      return 0
    fi
  fi

  log "ALERT [${severity}] ${check}: ${message}"
  ALERT_BUFFER+="$(printf '\n[%s] %s\n  %s\n' "$severity" "$check" "$message")"
  ALERT_COUNT=$(( ALERT_COUNT + 1 ))
  date +%s > "$cooldown_file"
}

# ── Notification ─────────────────────────────────────────────────────────────
send_telegram() {
  local text="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would send Telegram message"
    return 0
  fi
  curl -s --max-time 10 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="HTML" \
    -d text="${text}" \
    >/dev/null 2>&1 || log "WARN: Telegram send failed"
}

send_email() {
  local subject="$1"
  local body="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would send email"
    return 0
  fi

  if command -v msmtp &>/dev/null; then
    printf 'From: %s\nTo: %s\nSubject: %s\n\n%s\n' \
      "$EMAIL_FROM" "$EMAIL_TO" "$subject" "$body" | msmtp "$EMAIL_TO" \
      2>/dev/null || log "WARN: msmtp send failed"
  elif command -v sendmail &>/dev/null; then
    printf 'From: %s\nTo: %s\nSubject: %s\n\n%s\n' \
      "$EMAIL_FROM" "$EMAIL_TO" "$subject" "$body" | sendmail -t \
      2>/dev/null || log "WARN: sendmail send failed"
  elif command -v mail &>/dev/null; then
    echo "$body" | mail -s "$subject" "$EMAIL_TO" \
      2>/dev/null || log "WARN: mail send failed"
  else
    log "WARN: no mail command found (msmtp, sendmail, mail)"
  fi
}

fire_notifications() {
  if [[ "$ALERT_COUNT" -eq 0 ]]; then
    log "All checks passed — no alerts"
    return 0
  fi

  local header
  header="$(printf '🔑 %s OAuth token alert(s) on %s' "$ALERT_COUNT" "$HOSTNAME_SHORT")"

  local full_message
  full_message="$(printf '%s\n%s\n\nTime: %s' "$header" "$ALERT_BUFFER" "$TIMESTAMP")"

  if [[ "$TELEGRAM_ENABLED" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    local tg_msg
    tg_msg="$(printf '<b>%s</b>\n<pre>%s</pre>\n<i>%s</i>' "$header" "$ALERT_BUFFER" "$TIMESTAMP")"
    send_telegram "$tg_msg"
  fi

  if [[ "$EMAIL_ENABLED" == "true" && -n "$EMAIL_TO" ]]; then
    send_email "[OAUTH] ${HOSTNAME_SHORT}: ${ALERT_COUNT} token issue(s)" "$full_message"
  fi

  log "Sent ${ALERT_COUNT} alert(s)"
}

# ── JSON helpers (python3) ───────────────────────────────────────────────────
json_get() {
  local file="$1"
  local key="$2"
  python3 -c "
import json, sys
try:
    with open('${file}') as f:
        data = json.load(f)
    val = data.get('${key}', '')
    if val is None:
        val = ''
    print(val)
except Exception as e:
    print('')
" 2>/dev/null || echo ""
}

json_valid() {
  local file="$1"
  python3 -c "
import json, sys
try:
    with open('${file}') as f:
        json.load(f)
    print('1')
except Exception:
    print('0')
" 2>/dev/null || echo "0"
}

# ── Auto-discover token files if not configured ─────────────────────────────
discover_token_files() {
  if [[ -n "$TOKEN_FILES" ]]; then
    return
  fi

  log "TOKEN_FILES not configured — attempting auto-discovery"

  # Common sasl-xoauth2 token locations
  local search_dirs=(
    "/var/spool/postfix/sasl2/tokens"
    "/var/spool/postfix/sasl2"
    "/etc/postfix/sasl2"
    "/etc/tokens"
  )

  local found=""
  for dir in "${search_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      local files
      files="$(find "$dir" -maxdepth 2 -type f \( -name "*.json" -o -name "*token*" \) 2>/dev/null || true)"
      for f in $files; do
        if [[ "$(json_valid "$f")" == "1" ]]; then
          local has_token
          has_token="$(json_get "$f" "access_token")"
          if [[ -n "$has_token" ]]; then
            found+="$f "
          fi
        fi
      done
    fi
  done

  # Also check sasl_passwd for token file references
  if [[ -f /etc/postfix/sasl_passwd ]]; then
    local passwd_paths
    passwd_paths="$(grep -oE '/[^ ]+\.json' /etc/postfix/sasl_passwd 2>/dev/null || true)"
    for p in $passwd_paths; do
      if [[ -f "$p" && ! "$found" =~ "$p" ]]; then
        found+="$p "
      fi
    done
  fi

  TOKEN_FILES="$(echo "$found" | xargs)"
  if [[ -n "$TOKEN_FILES" ]]; then
    log "Auto-discovered token files: $TOKEN_FILES"
  else
    log "WARN: No token files found via auto-discovery. Set TOKEN_FILES in config."
  fi
}

# ── Checks ───────────────────────────────────────────────────────────────────

check_token_exists() {
  [[ "$CHECK_TOKEN_EXISTS" == "true" ]] || return 0
  log "Checking token file existence"

  local file
  for file in $TOKEN_FILES; do
    if [[ ! -f "$file" ]]; then
      log_alert "CRITICAL" "TOKEN_MISSING" "Token file not found: ${file}"
    elif [[ ! -r "$file" ]]; then
      log_alert "CRITICAL" "TOKEN_MISSING" "Token file not readable: ${file}"
    else
      log "Token file exists: ${file}"
    fi
  done
}

check_token_expiry() {
  [[ "$CHECK_TOKEN_EXPIRY" == "true" ]] || return 0
  log "Checking access token expiry"

  local file
  for file in $TOKEN_FILES; do
    [[ -f "$file" && -r "$file" ]] || continue

    local expiry_raw
    expiry_raw="$(json_get "$file" "expiry")"

    if [[ -z "$expiry_raw" ]]; then
      # Try alternate key names
      expiry_raw="$(json_get "$file" "expires_at")"
    fi

    if [[ -z "$expiry_raw" ]]; then
      log "No expiry field found in ${file} — skipping expiry check"
      continue
    fi

    # Convert to epoch if needed
    local expiry_epoch
    expiry_epoch="$(python3 -c "
import sys, time
raw = '${expiry_raw}'.strip()
try:
    # Try as Unix timestamp (int or float)
    ts = float(raw)
    print(int(ts))
except ValueError:
    try:
        # Try as ISO format
        from datetime import datetime
        dt = datetime.fromisoformat(raw.replace('Z', '+00:00'))
        print(int(dt.timestamp()))
    except Exception:
        print('')
" 2>/dev/null || echo "")"

    if [[ -z "$expiry_epoch" ]]; then
      log "Could not parse expiry value '${expiry_raw}' in ${file}"
      continue
    fi

    local now_epoch
    now_epoch="$(date +%s)"
    local diff_sec=$(( expiry_epoch - now_epoch ))
    local diff_hours=$(( diff_sec / 3600 ))

    local expiry_human
    expiry_human="$(date -d "@${expiry_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
    local label
    label="$(basename "$file")"

    if (( diff_sec < 0 )); then
      local expired_ago=$(( (now_epoch - expiry_epoch) / 3600 ))
      log_alert "CRITICAL" "TOKEN_EXPIRY" "Token EXPIRED ${expired_ago}h ago (${expiry_human}): ${file}"
    elif (( diff_hours < TOKEN_CRIT_HOURS )); then
      log_alert "CRITICAL" "TOKEN_EXPIRY" "Token expires in ${diff_hours}h (${expiry_human}): ${file}"
    elif (( diff_hours < TOKEN_WARN_HOURS )); then
      log_alert "WARNING" "TOKEN_EXPIRY" "Token expires in ${diff_hours}h (${expiry_human}): ${file}"
    else
      log "Token OK: ${label} expires in ${diff_hours}h (${expiry_human})"
    fi
  done
}

check_token_staleness() {
  [[ "$CHECK_TOKEN_STALENESS" == "true" ]] || return 0
  log "Checking token file freshness"

  local file
  for file in $TOKEN_FILES; do
    [[ -f "$file" ]] || continue

    local mod_epoch
    mod_epoch="$(stat -c '%Y' "$file" 2>/dev/null || echo 0)"
    local now_epoch
    now_epoch="$(date +%s)"
    local age_sec=$(( now_epoch - mod_epoch ))
    local age_hours=$(( age_sec / 3600 ))

    local stale_crit_sec=$(( TOKEN_STALE_CRIT_HOURS * 3600 ))
    local stale_warn_sec=$(( TOKEN_STALE_HOURS * 3600 ))

    local last_mod
    last_mod="$(date -d "@${mod_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"

    if (( age_sec >= stale_crit_sec )); then
      log_alert "CRITICAL" "TOKEN_STALE" "Token file not updated in ${age_hours}h (last: ${last_mod}): ${file}"
    elif (( age_sec >= stale_warn_sec )); then
      log_alert "WARNING" "TOKEN_STALE" "Token file not updated in ${age_hours}h (last: ${last_mod}): ${file}"
    else
      log "Token file fresh: $(basename "$file") (modified ${age_hours}h ago)"
    fi
  done
}

check_token_refresh() {
  [[ "$CHECK_TOKEN_REFRESH" == "true" ]] || return 0
  log "Performing token refresh test"

  if [[ -z "$TENANT_ID" ]]; then
    log "WARN: TENANT_ID not set — cannot perform refresh test"
    return 0
  fi

  # Read client_id from sasl-xoauth2 config
  local client_id=""
  local client_secret=""
  if [[ -f "$SASL_XOAUTH2_CONF" ]]; then
    client_id="$(json_get "$SASL_XOAUTH2_CONF" "client_id")"
    client_secret="$(json_get "$SASL_XOAUTH2_CONF" "client_secret")"
  fi

  if [[ -z "$client_id" ]]; then
    log "WARN: client_id not found in ${SASL_XOAUTH2_CONF}"
    return 0
  fi

  local endpoint="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"

  local file
  for file in $TOKEN_FILES; do
    [[ -f "$file" && -r "$file" ]] || continue

    local refresh_token
    refresh_token="$(json_get "$file" "refresh_token")"

    if [[ -z "$refresh_token" ]]; then
      log_alert "WARNING" "TOKEN_REFRESH" "No refresh_token in ${file} — cannot test refresh"
      continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN: would attempt token refresh for ${file}"
      continue
    fi

    local response
    local http_code
    response="$(curl -s --max-time 30 -w "\n%{http_code}" \
      -X POST "$endpoint" \
      -d "client_id=${client_id}" \
      -d "client_secret=${client_secret}" \
      -d "refresh_token=${refresh_token}" \
      -d "grant_type=refresh_token" \
      -d "scope=https://outlook.office365.com/.default" \
      2>/dev/null || echo -e "\n000")"

    http_code="$(echo "$response" | tail -1)"
    local body
    body="$(echo "$response" | head -n -1)"

    if [[ "$http_code" == "200" ]]; then
      log "Token refresh successful for $(basename "$file") (HTTP ${http_code})"
    else
      local error_desc
      error_desc="$(echo "$body" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('error_description', data.get('error', 'unknown')))
except Exception:
    print('parse error')
" 2>/dev/null || echo "unknown")"

      log_alert "CRITICAL" "TOKEN_REFRESH" "Refresh FAILED for ${file} (HTTP ${http_code}): ${error_desc}"
    fi
  done
}

check_sasl_config() {
  [[ "$CHECK_SASL_CONFIG" == "true" ]] || return 0
  log "Checking sasl-xoauth2 configuration"

  if [[ ! -f "$SASL_XOAUTH2_CONF" ]]; then
    log_alert "WARNING" "SASL_CONFIG" "sasl-xoauth2 config not found: ${SASL_XOAUTH2_CONF}"
    return 0
  fi

  if [[ "$(json_valid "$SASL_XOAUTH2_CONF")" != "1" ]]; then
    log_alert "WARNING" "SASL_CONFIG" "sasl-xoauth2 config is not valid JSON: ${SASL_XOAUTH2_CONF}"
    return 0
  fi

  local client_id
  client_id="$(json_get "$SASL_XOAUTH2_CONF" "client_id")"
  if [[ -z "$client_id" ]]; then
    log_alert "WARNING" "SASL_CONFIG" "client_id is missing from ${SASL_XOAUTH2_CONF}"
  fi

  local token_endpoint
  token_endpoint="$(json_get "$SASL_XOAUTH2_CONF" "token_endpoint")"
  if [[ -z "$token_endpoint" ]]; then
    log "INFO: token_endpoint not set in config (will use sasl-xoauth2 default)"
  fi

  log "sasl-xoauth2 config OK"
}

check_token_permissions() {
  [[ "$CHECK_TOKEN_PERMISSIONS" == "true" ]] || return 0
  log "Checking token file permissions"

  local file
  for file in $TOKEN_FILES; do
    [[ -f "$file" ]] || continue

    local perms
    perms="$(stat -c '%a' "$file" 2>/dev/null || echo "000")"
    local owner
    owner="$(stat -c '%U:%G' "$file" 2>/dev/null || echo "unknown:unknown")"

    # Check world-readable
    local other_read=$(( 8#$perms & 8#004 ))
    if (( other_read > 0 )); then
      log_alert "WARNING" "TOKEN_PERMS" "Token file is world-readable (${perms}): ${file}"
    fi

    # Check if postfix user can read it
    if id postfix &>/dev/null; then
      local postfix_readable=0
      if sudo -u postfix test -r "$file" 2>/dev/null; then
        postfix_readable=1
      fi

      if [[ "$postfix_readable" -eq 0 ]]; then
        log_alert "WARNING" "TOKEN_PERMS" "Token file not readable by postfix user (${owner}, ${perms}): ${file}"
      fi
    fi

    log "Token permissions: ${file} owner=${owner} mode=${perms}"
  done
}

# ── Cleanup old cooldown files (older than 7 days) ───────────────────────────
cleanup_state() {
  find "$STATE_DIR" -maxdepth 1 -name "cooldown_*" -type f -mtime +7 -delete 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  log "========== OAuth token check starting =========="

  discover_token_files

  if [[ -z "$TOKEN_FILES" ]]; then
    log "WARN: No token files configured or discovered — nothing to check"
    log "Set TOKEN_FILES in ${CONF_FILE}"
    log "========== OAuth token check complete (0 alert(s)) =========="
    return 0
  fi

  check_token_exists
  check_token_expiry
  check_token_staleness
  check_token_refresh
  check_sasl_config
  check_token_permissions

  cleanup_state
  fire_notifications

  log "========== OAuth token check complete (${ALERT_COUNT} alert(s)) =========="
}

main
