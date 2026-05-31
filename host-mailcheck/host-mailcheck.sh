#!/usr/bin/env bash
###############################################################################
# host-mailcheck.sh
#
# Standalone Postfix / mail relay health check script.
# Runs via cron on each mail relay host. Checks service health, queue state,
# relay connectivity, SASL/OAuth auth failures, TLS errors, bounces, and
# spool disk usage. Sends alerts via Telegram and/or email.
#
# Features:
#   - Postfix service status, queue size, deferred age, queue growth
#   - Relay TCP connectivity testing
#   - SASL auth failure detection (Gmail app passwords + M365 OAuth)
#   - TLS error detection, bounce rate monitoring
#   - Fatal/panic log scanning
#   - Spool disk usage
#   - Alert cooldown to avoid spam
#   - Telegram + email + syslog notifications
#
# Usage:
#   /usr/local/bin/host-mailcheck.sh
#   /usr/local/bin/host-mailcheck.sh --config /path/to/config
#   /usr/local/bin/host-mailcheck.sh --dry-run
#   /usr/local/bin/host-mailcheck.sh --reset-baseline
###############################################################################

set -Euo pipefail

# ── Defaults (overridden by config file) ─────────────────────────────────────
CONF_FILE="/etc/host-mailcheck/host-mailcheck.conf"
DRY_RUN=0
RESET_BASELINE=0

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

EMAIL_ENABLED="false"
EMAIL_TO=""
EMAIL_FROM="mailcheck@$(hostname -f 2>/dev/null || hostname)"

SYSLOG_ENABLED="true"
SYSLOG_TAG="mailcheck"

ALERT_COOLDOWN_SEC=3600

CHECK_POSTFIX_SERVICE="true"
CHECK_QUEUE_SIZE="true"
CHECK_DEFERRED_AGE="true"
CHECK_QUEUE_GROWTH="true"
CHECK_RELAY_CONNECTIVITY="true"
CHECK_SASL_FAILURES="true"
CHECK_TLS_ERRORS="true"
CHECK_BOUNCES="true"
CHECK_MAIL_ERRORS="true"
CHECK_SPOOL_DISK="true"

QUEUE_WARN=50
QUEUE_CRIT=200

DEFERRED_WARN_AGE=3600
DEFERRED_CRIT_AGE=14400

QUEUE_GROWTH_WARN=20

RELAY_HOSTS="smtp.gmail.com:587 smtp.office365.com:587"
RELAY_TIMEOUT=10

SASL_FAIL_WARN=3
SASL_FAIL_CRIT=10

BOUNCE_WARN=20

SPOOL_WARN_PCT=80
SPOOL_CRIT_PCT=95

MAIL_LOG=""

STATE_DIR="/var/lib/host-mailcheck"
LOG_FILE="/var/log/host-mailcheck.log"

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)          CONF_FILE="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --reset-baseline)  RESET_BASELINE=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--config <path>] [--dry-run] [--reset-baseline]"
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

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
ALERT_BUFFER=""
ALERT_COUNT=0

# ── Auto-detect mail log ────────────────────────────────────────────────────
if [[ -z "$MAIL_LOG" ]]; then
  if [[ -f /var/log/mail.log ]]; then
    MAIL_LOG="/var/log/mail.log"
  elif [[ -f /var/log/maillog ]]; then
    MAIL_LOG="/var/log/maillog"
  else
    MAIL_LOG=""
  fi
fi

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

  # Check cooldown
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

  # Record alert
  log "ALERT [${severity}] ${check}: ${message}"
  ALERT_BUFFER+="$(printf '\n[%s] %s\n  %s\n' "$severity" "$check" "$message")"
  ALERT_COUNT=$(( ALERT_COUNT + 1 ))

  # Update cooldown
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
  header="$(printf '📬 %s mail alert(s) on %s' "$ALERT_COUNT" "$HOSTNAME_SHORT")"

  local full_message
  full_message="$(printf '%s\n%s\n\nTime: %s' "$header" "$ALERT_BUFFER" "$TIMESTAMP")"

  # Telegram
  if [[ "$TELEGRAM_ENABLED" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    local tg_msg
    tg_msg="$(printf '<b>%s</b>\n<pre>%s</pre>\n<i>%s</i>' "$header" "$ALERT_BUFFER" "$TIMESTAMP")"
    send_telegram "$tg_msg"
  fi

  # Email
  if [[ "$EMAIL_ENABLED" == "true" && -n "$EMAIL_TO" ]]; then
    send_email "[MAIL] ${HOSTNAME_SHORT}: ${ALERT_COUNT} issue(s)" "$full_message"
  fi

  log "Sent ${ALERT_COUNT} alert(s)"
}

# ── Mail log line tracking ───────────────────────────────────────────────────
get_new_mail_lines() {
  if [[ -z "$MAIL_LOG" || ! -f "$MAIL_LOG" ]]; then
    return
  fi

  local offset_file="${STATE_DIR}/mail_log_offset"
  local current_lines
  current_lines="$(wc -l < "$MAIL_LOG")"

  local prev_lines=0
  if [[ -f "$offset_file" ]]; then
    prev_lines="$(cat "$offset_file" 2>/dev/null || echo 0)"
  fi

  # Handle log rotation
  if (( current_lines < prev_lines )); then
    prev_lines=0
  fi

  if (( current_lines > prev_lines )); then
    tail -n "+$(( prev_lines + 1 ))" "$MAIL_LOG"
  fi

  echo "$current_lines" > "$offset_file"
}

# ── Checks ───────────────────────────────────────────────────────────────────

check_postfix_service() {
  [[ "$CHECK_POSTFIX_SERVICE" == "true" ]] || return 0
  log "Checking Postfix service"

  if ! command -v systemctl &>/dev/null; then
    # Fallback: check if master process is running
    if ! pgrep -x master >/dev/null 2>&1; then
      log_alert "CRITICAL" "POSTFIX" "Postfix master process is not running"
    fi
    return 0
  fi

  if ! systemctl is-active --quiet postfix 2>/dev/null; then
    log_alert "CRITICAL" "POSTFIX" "Postfix service is not running"
  fi
}

check_queue_size() {
  [[ "$CHECK_QUEUE_SIZE" == "true" ]] || return 0
  command -v mailq &>/dev/null || { log "mailq not found — skipping queue size check"; return 0; }
  log "Checking mail queue size"

  local mailq_output
  mailq_output="$(mailq 2>/dev/null || true)"

  local queue_count=0
  if echo "$mailq_output" | grep -q "Mail queue is empty"; then
    queue_count=0
  else
    # Parse "-- N Kbytes in M Requests."
    queue_count="$(echo "$mailq_output" | grep -oP '\d+\s+Requests' | awk '{print $1}' || true)"
    if [[ -z "$queue_count" ]]; then
      # Fallback: count queue IDs (lines starting with hex ID)
      queue_count="$(echo "$mailq_output" | grep -cE '^[0-9A-F]{10,}' || true)"
    fi
  fi

  if (( queue_count >= QUEUE_CRIT )); then
    log_alert "CRITICAL" "QUEUE_SIZE" "Mail queue has ${queue_count} messages (critical threshold: ${QUEUE_CRIT})"
  elif (( queue_count >= QUEUE_WARN )); then
    log_alert "WARNING" "QUEUE_SIZE" "Mail queue has ${queue_count} messages (warning threshold: ${QUEUE_WARN})"
  fi

  # Save for queue growth check
  echo "$queue_count" > "${STATE_DIR}/queue_count_current"
}

check_deferred_age() {
  [[ "$CHECK_DEFERRED_AGE" == "true" ]] || return 0
  local deferred_dir="/var/spool/postfix/deferred"
  [[ -d "$deferred_dir" ]] || { log "Deferred dir not found — skipping"; return 0; }
  log "Checking deferred queue age"

  local deferred_count
  deferred_count="$(find "$deferred_dir" -type f 2>/dev/null | wc -l || echo 0)"

  if (( deferred_count == 0 )); then
    return 0
  fi

  # Find oldest deferred message
  local oldest_file
  oldest_file="$(find "$deferred_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 || true)"

  if [[ -z "$oldest_file" ]]; then
    return 0
  fi

  local oldest_epoch
  oldest_epoch="$(echo "$oldest_file" | awk '{printf "%.0f", $1}')"
  local now_epoch
  now_epoch="$(date +%s)"
  local age_sec=$(( now_epoch - oldest_epoch ))

  local age_human
  if (( age_sec >= 86400 )); then
    age_human="$(( age_sec / 86400 ))d $(( (age_sec % 86400) / 3600 ))h"
  elif (( age_sec >= 3600 )); then
    age_human="$(( age_sec / 3600 ))h $(( (age_sec % 3600) / 60 ))m"
  else
    age_human="$(( age_sec / 60 ))m"
  fi

  if (( age_sec >= DEFERRED_CRIT_AGE )); then
    log_alert "CRITICAL" "DEFERRED" "${deferred_count} deferred message(s), oldest is ${age_human} old"
  elif (( age_sec >= DEFERRED_WARN_AGE )); then
    log_alert "WARNING" "DEFERRED" "${deferred_count} deferred message(s), oldest is ${age_human} old"
  fi
}

check_queue_growth() {
  [[ "$CHECK_QUEUE_GROWTH" == "true" ]] || return 0
  log "Checking queue growth"

  local current_file="${STATE_DIR}/queue_count_current"
  local prev_file="${STATE_DIR}/queue_count_previous"

  if [[ ! -f "$current_file" ]]; then
    log "No current queue count available — skipping growth check"
    return 0
  fi

  local current
  current="$(cat "$current_file" 2>/dev/null || echo 0)"

  if [[ ! -f "$prev_file" ]]; then
    cp "$current_file" "$prev_file"
    log "Queue growth baseline saved (${current} messages)"
    return 0
  fi

  local previous
  previous="$(cat "$prev_file" 2>/dev/null || echo 0)"
  local growth=$(( current - previous ))

  if (( growth >= QUEUE_GROWTH_WARN )); then
    log_alert "WARNING" "QUEUE_GROWTH" "Queue grew by ${growth} messages (${previous} → ${current})"
  fi

  # Update previous
  cp "$current_file" "$prev_file"
}

check_relay_connectivity() {
  [[ "$CHECK_RELAY_CONNECTIVITY" == "true" ]] || return 0
  [[ -n "$RELAY_HOSTS" ]] || { log "No relay hosts configured — skipping"; return 0; }
  log "Checking relay connectivity"

  local entry
  for entry in $RELAY_HOSTS; do
    local host port
    host="${entry%%:*}"
    port="${entry##*:}"

    if [[ -z "$host" || -z "$port" ]]; then
      log "WARN: Invalid relay entry: ${entry}"
      continue
    fi

    local reachable=0

    # Try bash /dev/tcp first
    if (timeout "$RELAY_TIMEOUT" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null); then
      reachable=1
    # Fallback to nc
    elif command -v nc &>/dev/null; then
      if nc -z -w "$RELAY_TIMEOUT" "$host" "$port" 2>/dev/null; then
        reachable=1
      fi
    fi

    if [[ "$reachable" -eq 1 ]]; then
      log "Relay reachable: ${host}:${port}"
    else
      log_alert "CRITICAL" "RELAY" "Relay ${host}:${port} is UNREACHABLE"
    fi
  done
}

check_sasl_failures() {
  [[ "$CHECK_SASL_FAILURES" == "true" ]] || return 0
  [[ -n "$MAIL_LOG" ]] || { log "Mail log not found — skipping SASL check"; return 0; }
  log "Checking SASL authentication failures"

  local new_lines="${MAIL_LINES_CACHE:-}"
  if [[ -z "$new_lines" ]]; then
    return 0
  fi

  local fail_lines
  fail_lines="$(echo "$new_lines" | grep -iE 'SASL authentication failed|535 5\.7\.|authentication fail|XOAUTH2.*fail|OAuth.*error|auth.*fail.*relay' || true)"

  if [[ -z "$fail_lines" ]]; then
    return 0
  fi

  local fail_count
  fail_count="$(echo "$fail_lines" | wc -l)"

  # Extract relay hosts from failure lines
  local relay_summary
  relay_summary="$(echo "$fail_lines" | grep -oE 'relay=[^ ,]+|to=[^ ,]+' | sort | uniq -c | sort -rn | head -5 | \
    awk '{printf "  %s (%s failures)\n", $2, $1}' || true)"

  if (( fail_count >= SASL_FAIL_CRIT )); then
    local msg
    msg="$(printf '%d SASL auth failure(s)\n%s' "$fail_count" "$relay_summary")"
    log_alert "CRITICAL" "SASL" "$msg"
  elif (( fail_count >= SASL_FAIL_WARN )); then
    local msg
    msg="$(printf '%d SASL auth failure(s)\n%s' "$fail_count" "$relay_summary")"
    log_alert "WARNING" "SASL" "$msg"
  fi
}

check_tls_errors() {
  [[ "$CHECK_TLS_ERRORS" == "true" ]] || return 0
  [[ -n "$MAIL_LOG" ]] || { log "Mail log not found — skipping TLS check"; return 0; }
  log "Checking TLS errors"

  local new_lines="${MAIL_LINES_CACHE:-}"
  if [[ -z "$new_lines" ]]; then
    return 0
  fi

  local tls_errors
  tls_errors="$(echo "$new_lines" | grep -iE 'TLS connection error|SSL_connect error|certificate verification failed|untrusted issuer|cannot verify' || true)"

  if [[ -n "$tls_errors" ]]; then
    local count
    count="$(echo "$tls_errors" | wc -l)"
    local samples
    samples="$(echo "$tls_errors" | head -3 | sed 's/^/  /')"
    local msg
    msg="$(printf '%d TLS error(s)\n%s' "$count" "$samples")"
    log_alert "WARNING" "TLS" "$msg"
  fi
}

check_bounces() {
  [[ "$CHECK_BOUNCES" == "true" ]] || return 0
  [[ -n "$MAIL_LOG" ]] || { log "Mail log not found — skipping bounce check"; return 0; }
  log "Checking bounce rate"

  local new_lines="${MAIL_LINES_CACHE:-}"
  if [[ -z "$new_lines" ]]; then
    return 0
  fi

  local bounce_lines
  bounce_lines="$(echo "$new_lines" | grep -iE 'status=bounced|dsn=5\.|reject:|550 ' || true)"

  if [[ -z "$bounce_lines" ]]; then
    return 0
  fi

  local bounce_count
  bounce_count="$(echo "$bounce_lines" | wc -l)"

  if (( bounce_count >= BOUNCE_WARN )); then
    # Top bounce reasons
    local reasons
    reasons="$(echo "$bounce_lines" | grep -oE 'dsn=[^ ,]+|said:.*' | head -5 | sed 's/^/  /' || true)"
    local msg
    msg="$(printf '%d bounced/rejected message(s)\n%s' "$bounce_count" "$reasons")"
    log_alert "WARNING" "BOUNCES" "$msg"
  fi
}

check_mail_errors() {
  [[ "$CHECK_MAIL_ERRORS" == "true" ]] || return 0
  [[ -n "$MAIL_LOG" ]] || { log "Mail log not found — skipping error check"; return 0; }
  log "Checking mail log errors"

  local new_lines="${MAIL_LINES_CACHE:-}"
  if [[ -z "$new_lines" ]]; then
    return 0
  fi

  # Fatal / panic — critical
  local fatal_lines
  fatal_lines="$(echo "$new_lines" | grep -iE 'postfix.*fatal:|postfix.*panic:' || true)"

  if [[ -n "$fatal_lines" ]]; then
    local count
    count="$(echo "$fatal_lines" | wc -l)"
    local samples
    samples="$(echo "$fatal_lines" | head -3 | sed 's/^/  /')"
    local msg
    msg="$(printf '%d fatal/panic error(s)\n%s' "$count" "$samples")"
    log_alert "CRITICAL" "MAIL_ERROR" "$msg"
  fi

  # General errors — warning
  local error_lines
  error_lines="$(echo "$new_lines" | grep -iE 'postfix.*error:' | grep -viE 'fatal:|panic:' || true)"

  if [[ -n "$error_lines" ]]; then
    local count
    count="$(echo "$error_lines" | wc -l)"
    if (( count >= 5 )); then
      local samples
      samples="$(echo "$error_lines" | head -3 | sed 's/^/  /')"
      local msg
      msg="$(printf '%d postfix error(s)\n%s' "$count" "$samples")"
      log_alert "WARNING" "MAIL_ERROR" "$msg"
    fi
  fi
}

check_spool_disk() {
  [[ "$CHECK_SPOOL_DISK" == "true" ]] || return 0
  log "Checking spool disk usage"

  local spool_dir="/var/spool/postfix"
  [[ -d "$spool_dir" ]] || { log "Spool directory not found — skipping"; return 0; }

  local pct
  pct="$(df -P "$spool_dir" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || true)"

  if [[ -z "$pct" ]]; then
    return 0
  fi

  if (( pct >= SPOOL_CRIT_PCT )); then
    log_alert "CRITICAL" "SPOOL_DISK" "Spool filesystem is ${pct}% full"
  elif (( pct >= SPOOL_WARN_PCT )); then
    log_alert "WARNING" "SPOOL_DISK" "Spool filesystem is ${pct}% full"
  fi
}

# ── Reset baseline ──────────────────────────────────────────────────────────
do_reset_baseline() {
  mkdir -p "$STATE_DIR"
  log "Resetting baselines"

  # Mail log offset
  if [[ -n "$MAIL_LOG" && -f "$MAIL_LOG" ]]; then
    wc -l < "$MAIL_LOG" > "${STATE_DIR}/mail_log_offset"
    log "Mail log offset updated"
  fi

  # Queue count
  if command -v mailq &>/dev/null; then
    local mailq_output
    mailq_output="$(mailq 2>/dev/null || true)"
    local queue_count=0
    if echo "$mailq_output" | grep -q "Mail queue is empty"; then
      queue_count=0
    else
      queue_count="$(echo "$mailq_output" | grep -oP '\d+\s+Requests' | awk '{print $1}' || echo 0)"
    fi
    echo "$queue_count" > "${STATE_DIR}/queue_count_current"
    echo "$queue_count" > "${STATE_DIR}/queue_count_previous"
    log "Queue count baseline updated (${queue_count})"
  fi

  log "All baselines reset"
  echo "All baselines reset. See log: $LOG_FILE"
}

# ── Cleanup old cooldown files (older than 7 days) ───────────────────────────
cleanup_state() {
  find "$STATE_DIR" -maxdepth 1 -name "cooldown_*" -type f -mtime +7 -delete 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  if [[ "$RESET_BASELINE" -eq 1 ]]; then
    do_reset_baseline
    exit 0
  fi

  log "========== Mail check starting =========="

  # Service and queue checks
  check_postfix_service
  check_queue_size
  check_deferred_age
  check_queue_growth

  # Relay checks
  check_relay_connectivity

  # Log-based checks (share cached lines)
  MAIL_LINES_CACHE=""
  if [[ -n "$MAIL_LOG" && -f "$MAIL_LOG" ]]; then
    MAIL_LINES_CACHE="$(get_new_mail_lines)"
  fi

  check_sasl_failures
  check_tls_errors
  check_bounces
  check_mail_errors

  # Disk check
  check_spool_disk

  cleanup_state
  fire_notifications

  log "========== Mail check complete (${ALERT_COUNT} alert(s)) =========="
}

main
