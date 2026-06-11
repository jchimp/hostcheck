#!/usr/bin/env bash
###############################################################################
# hostcheck-sec.sh
#
# Standalone host security check script for Proxmox / Linux nodes.
# Runs via cron on each host. Checks for security issues and sends alerts
# via Telegram and/or email when problems are found.
#
# Features:
#   - Failed SSH logins (delta-based), root SSH logins, failed sudo
#   - New user account detection, authorized_keys changes
#   - Security updates available, reboot required
#   - Certificate expiry monitoring
#   - SSH config hardening audit
#   - New listening port detection (baseline-based)
#   - World-writable files in /etc
#   - Alert cooldown to avoid spam
#   - Telegram + email + syslog notifications
#
# Usage:
#   /usr/local/bin/hostcheck-sec.sh
#   /usr/local/bin/hostcheck-sec.sh --config /path/to/config
#   /usr/local/bin/hostcheck-sec.sh --dry-run
#   /usr/local/bin/hostcheck-sec.sh --reset-baseline
###############################################################################

set -Euo pipefail

# ── Ensure sbin paths are available (cron uses minimal PATH) ────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ── Defaults (overridden by config file) ─────────────────────────────────────
CONF_FILE="/etc/hostcheck/hostcheck.conf"
DRY_RUN=0
RESET_BASELINE=0

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

EMAIL_ENABLED="false"
EMAIL_TO=""
EMAIL_FROM="hostcheck-sec@$(hostname -f 2>/dev/null || hostname)"

SYSLOG_ENABLED="true"
SYSLOG_TAG="hostcheck-sec"

ALERT_COOLDOWN_SEC=3600

CHECK_SSH_FAILED="true"
CHECK_SSH_ROOT="true"
CHECK_SUDO_FAILED="true"
CHECK_NEW_USERS="true"
CHECK_UPDATES="true"
CHECK_REBOOT="true"
CHECK_CERTS="true"
CHECK_SSH_CONFIG="true"
CHECK_AUTHORIZED_KEYS="true"
CHECK_LISTENING_PORTS="true"
CHECK_WORLD_WRITABLE="true"

SSH_FAIL_WARN=10
SSH_FAIL_CRIT=50
SUDO_FAIL_WARN=5

CERT_PATHS="/etc/pve/local /etc/ssl/certs"
CERT_WARN_DAYS=30
CERT_CRIT_DAYS=7

AUTH_LOG=""

STATE_DIR="/var/lib/hostcheck/sec"
LOG_FILE="/var/log/hostcheck/hostcheck-sec.log"

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

# ── Auto-detect auth log ────────────────────────────────────────────────────
if [[ -z "$AUTH_LOG" ]]; then
  if [[ -f /var/log/auth.log ]]; then
    AUTH_LOG="/var/log/auth.log"
  elif [[ -f /var/log/secure ]]; then
    AUTH_LOG="/var/log/secure"
  else
    AUTH_LOG=""
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
  header="$(printf '🔒 %s security alert(s) on %s' "$ALERT_COUNT" "$HOSTNAME_SHORT")"

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
    send_email "[SECURITY] ${HOSTNAME_SHORT}: ${ALERT_COUNT} issue(s)" "$full_message"
  fi

  log "Sent ${ALERT_COUNT} alert(s)"
}

# ── Auth log line tracking ───────────────────────────────────────────────────
# Returns new lines from auth log since last run
get_new_auth_lines() {
  if [[ -z "$AUTH_LOG" || ! -f "$AUTH_LOG" ]]; then
    return
  fi

  local offset_file="${STATE_DIR}/auth_log_offset"
  local current_lines
  current_lines="$(wc -l < "$AUTH_LOG")"

  local prev_lines=0
  if [[ -f "$offset_file" ]]; then
    prev_lines="$(cat "$offset_file" 2>/dev/null || echo 0)"
  fi

  # Handle log rotation (current file smaller than saved offset)
  if (( current_lines < prev_lines )); then
    prev_lines=0
  fi

  if (( current_lines > prev_lines )); then
    tail -n "+$(( prev_lines + 1 ))" "$AUTH_LOG"
  fi

  echo "$current_lines" > "$offset_file"
}

# ── Checks ───────────────────────────────────────────────────────────────────

check_ssh_failed() {
  [[ "$CHECK_SSH_FAILED" == "true" ]] || return 0
  [[ -n "$AUTH_LOG" ]] || { log "Auth log not found — skipping SSH failed login check"; return 0; }
  log "Checking failed SSH logins"

  local new_lines
  new_lines="$(get_new_auth_lines)"

  # Cache new lines for other auth checks
  AUTH_LINES_CACHE="$new_lines"

  if [[ -z "$new_lines" ]]; then
    log "No new auth log entries"
    return 0
  fi

  local fail_count
  fail_count="$(echo "$new_lines" | grep -ci "Failed password\|Failed publickey\|authentication failure" || true)"

  if (( fail_count == 0 )); then
    return 0
  fi

  # Extract top source IPs
  local top_ips
  top_ips="$(echo "$new_lines" | grep -i "Failed password\|Failed publickey\|authentication failure" | \
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn | head -5 | \
    awk '{printf "  %s (%s attempts)\n", $2, $1}' || true)"

  if (( fail_count >= SSH_FAIL_CRIT )); then
    local msg
    msg="$(printf '%d failed SSH login attempts\nTop sources:\n%s' "$fail_count" "$top_ips")"
    log_alert "CRITICAL" "SSH_FAILED" "$msg"
  elif (( fail_count >= SSH_FAIL_WARN )); then
    local msg
    msg="$(printf '%d failed SSH login attempts\nTop sources:\n%s' "$fail_count" "$top_ips")"
    log_alert "WARNING" "SSH_FAILED" "$msg"
  fi
}

check_ssh_root() {
  [[ "$CHECK_SSH_ROOT" == "true" ]] || return 0
  log "Checking root SSH logins"

  local new_lines="${AUTH_LINES_CACHE:-}"
  if [[ -z "$new_lines" ]]; then
    return 0
  fi

  local root_logins
  root_logins="$(echo "$new_lines" | grep -i "Accepted.*for root" | head -10 || true)"

  if [[ -n "$root_logins" ]]; then
    local count
    count="$(echo "$root_logins" | wc -l)"
    local sources
    sources="$(echo "$root_logins" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ', ' | sed 's/,$//' || true)"
    log_alert "WARNING" "SSH_ROOT" "${count} successful root SSH login(s) from: ${sources}"
  fi
}

check_sudo_failed() {
  [[ "$CHECK_SUDO_FAILED" == "true" ]] || return 0
  log "Checking failed sudo attempts"

  local new_lines="${AUTH_LINES_CACHE:-}"
  if [[ -z "$new_lines" ]]; then
    return 0
  fi

  local fail_count
  fail_count="$(echo "$new_lines" | grep -ci "sudo.*authentication failure\|sudo.*3 incorrect password attempts\|sudo.*FAILED" || true)"

  if (( fail_count >= SUDO_FAIL_WARN )); then
    local users
    users="$(echo "$new_lines" | grep -i "sudo.*authentication failure\|sudo.*FAILED" | \
      grep -oP 'user=\K\S+|USER=\K\S+' | sort | uniq -c | sort -rn | head -5 | \
      awk '{printf "  %s (%s attempts)\n", $2, $1}' || true)"
    local msg
    msg="$(printf '%d failed sudo attempt(s)\n%s' "$fail_count" "$users")"
    log_alert "WARNING" "SUDO_FAILED" "$msg"
  fi
}

check_new_users() {
  [[ "$CHECK_NEW_USERS" == "true" ]] || return 0
  log "Checking for new user accounts"

  local hash_file="${STATE_DIR}/passwd_hash"
  local users_file="${STATE_DIR}/passwd_users"
  local current_hash
  current_hash="$(md5sum /etc/passwd | awk '{print $1}')"
  local current_users
  current_users="$(awk -F: '{print $1}' /etc/passwd | sort)"

  if [[ ! -f "$hash_file" ]]; then
    # First run — save baseline
    echo "$current_hash" > "$hash_file"
    echo "$current_users" > "$users_file"
    log "Baseline saved for /etc/passwd"
    return 0
  fi

  local prev_hash
  prev_hash="$(cat "$hash_file" 2>/dev/null || echo "")"

  if [[ "$current_hash" != "$prev_hash" ]]; then
    local new_users=""
    local removed_users=""
    if [[ -f "$users_file" ]]; then
      new_users="$(comm -13 "$users_file" <(echo "$current_users") || true)"
      removed_users="$(comm -23 "$users_file" <(echo "$current_users") || true)"
    fi

    local msg="/etc/passwd has changed"
    if [[ -n "$new_users" ]]; then
      msg="$(printf '%s\nNew users: %s' "$msg" "$(echo "$new_users" | tr '\n' ', ' | sed 's/,$//')")"
    fi
    if [[ -n "$removed_users" ]]; then
      msg="$(printf '%s\nRemoved users: %s' "$msg" "$(echo "$removed_users" | tr '\n' ', ' | sed 's/,$//')")"
    fi

    log_alert "CRITICAL" "NEW_USERS" "$msg"

    # Update baseline
    echo "$current_hash" > "$hash_file"
    echo "$current_users" > "$users_file"
  fi
}

_uu_is_active() {
  # 1. Security origin is uncommented in unattended-upgrades config
  local uu_conf="/etc/apt/apt.conf.d/50unattended-upgrades"
  grep -qE '^\s*"\$\{distro_id\}:\$\{distro_codename\}-security"' "$uu_conf" 2>/dev/null || return 1

  # 2. Daily unattended upgrades are enabled
  local uu_period="/etc/apt/apt.conf.d/20auto-upgrades"
  grep -qE 'APT::Periodic::Unattended-Upgrade\s+"1"' "$uu_period" 2>/dev/null || return 1

  # 3. Has run today or yesterday
  local uu_log="/var/log/unattended-upgrades/unattended-upgrades.log"
  [[ -f "$uu_log" ]] || return 1
  local today yesterday
  today="$(date +%Y-%m-%d)"
  yesterday="$(date -d yesterday +%Y-%m-%d)"
  grep -qE "^($today|$yesterday)" "$uu_log" 2>/dev/null || return 1
}

check_updates() {
  [[ "$CHECK_UPDATES" == "true" ]] || return 0
  command -v apt &>/dev/null || { log "apt not found — skipping updates check"; return 0; }
  log "Checking for security updates"

  local upgradable
  upgradable="$(apt list --upgradable 2>/dev/null | grep -i security || true)"

  [[ -n "$upgradable" ]] || return 0

  local count packages
  count="$(echo "$upgradable" | wc -l)"
  packages="$(echo "$upgradable" | head -10 | awk -F/ '{print $1}' | tr '\n' ', ' | sed 's/,$//')"

  if _uu_is_active; then
    log "${count} security update(s) pending, unattended-upgrades is active: ${packages}"
  else
    log_alert "WARNING" "UPDATES" "${count} security update(s) available: ${packages}"
  fi
}

check_reboot() {
  [[ "$CHECK_REBOOT" == "true" ]] || return 0
  log "Checking if reboot is required"

  if [[ -f /var/run/reboot-required ]]; then
    local reason=""
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      reason="$(head -5 /var/run/reboot-required.pkgs | tr '\n' ', ' | sed 's/,$//')"
    fi
    log_alert "INFO" "REBOOT" "System reboot required${reason:+ (packages: ${reason})}"
  fi
}

check_certs() {
  [[ "$CHECK_CERTS" == "true" ]] || return 0
  command -v openssl &>/dev/null || { log "openssl not found — skipping cert check"; return 0; }
  log "Checking certificate expiry"

  local now_epoch
  now_epoch="$(date +%s)"

  local path
  for path in $CERT_PATHS; do
    [[ -d "$path" || -f "$path" ]] || continue

    local cert_files
    if [[ -d "$path" ]]; then
      mapfile -t cert_files < <(find "$path" -maxdepth 2 -type f \( -name "*.pem" -o -name "*.crt" \) 2>/dev/null)
    else
      cert_files=("$path")
    fi

    local cert
    for cert in "${cert_files[@]}"; do
      [[ -f "$cert" ]] || continue

      # Skip non-certificate files (some .pem files are keys)
      if ! openssl x509 -in "$cert" -noout 2>/dev/null; then
        continue
      fi

      local expiry_date
      expiry_date="$(openssl x509 -in "$cert" -enddate -noout 2>/dev/null | cut -d= -f2 || true)"
      if [[ -z "$expiry_date" ]]; then
        continue
      fi

      local expiry_epoch
      expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null || true)"
      if [[ -z "$expiry_epoch" ]]; then
        continue
      fi

      local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

      if (( days_left < 0 )); then
        log_alert "CRITICAL" "CERT" "Certificate EXPIRED ${days_left#-} day(s) ago: ${cert}"
      elif (( days_left <= CERT_CRIT_DAYS )); then
        log_alert "CRITICAL" "CERT" "Certificate expires in ${days_left} day(s): ${cert}"
      elif (( days_left <= CERT_WARN_DAYS )); then
        log_alert "WARNING" "CERT" "Certificate expires in ${days_left} day(s): ${cert}"
      fi
    done
  done
}

check_ssh_config() {
  [[ "$CHECK_SSH_CONFIG" == "true" ]] || return 0
  local sshd_config="/etc/ssh/sshd_config"
  [[ -f "$sshd_config" ]] || { log "sshd_config not found — skipping"; return 0; }
  log "Checking SSH hardening"

  local findings=""

  # PermitRootLogin
  local root_login
  root_login="$(grep -Ei '^\s*PermitRootLogin' "$sshd_config" | tail -1 | awk '{print tolower($2)}' || true)"
  if [[ -z "$root_login" ]]; then
    root_login="prohibit-password"  # sshd default
  fi
  if [[ "$root_login" == "yes" ]]; then
    findings+="PermitRootLogin is YES, "
  fi

  # PasswordAuthentication
  local pass_auth
  pass_auth="$(grep -Ei '^\s*PasswordAuthentication' "$sshd_config" | tail -1 | awk '{print tolower($2)}' || true)"
  if [[ -z "$pass_auth" ]]; then
    pass_auth="yes"  # sshd default
  fi
  if [[ "$pass_auth" == "yes" ]]; then
    findings+="PasswordAuthentication is YES, "
  fi

  # Port
  local ssh_port
  ssh_port="$(grep -Ei '^\s*Port\s' "$sshd_config" | tail -1 | awk '{print $2}' || true)"
  if [[ -z "$ssh_port" ]]; then
    ssh_port="22"  # default
  fi
  if [[ "$ssh_port" == "22" ]]; then
    findings+="SSH on default port 22, "
  fi

  # Clean trailing comma
  findings="${findings%, }"

  if [[ -n "$findings" ]]; then
    log_alert "INFO" "SSH_CONFIG" "SSH hardening findings: ${findings}"
  fi
}

check_authorized_keys() {
  [[ "$CHECK_AUTHORIZED_KEYS" == "true" ]] || return 0
  log "Checking authorized_keys changes"

  local hash_file="${STATE_DIR}/authorized_keys_hash"
  local detail_file="${STATE_DIR}/authorized_keys_detail"

  # Collect all authorized_keys files and their hashes
  local current_detail=""
  local key_file
  while IFS= read -r -d '' key_file; do
    local file_hash
    file_hash="$(md5sum "$key_file" 2>/dev/null | awk '{print $1}' || true)"
    current_detail+="${key_file}:${file_hash}"$'\n'
  done < <(find /root/.ssh /home -maxdepth 3 -name "authorized_keys" -type f -print0 2>/dev/null || true)

  local current_hash
  current_hash="$(echo "$current_detail" | md5sum | awk '{print $1}')"

  if [[ ! -f "$hash_file" ]]; then
    echo "$current_hash" > "$hash_file"
    echo "$current_detail" > "$detail_file"
    log "Baseline saved for authorized_keys"
    return 0
  fi

  local prev_hash
  prev_hash="$(cat "$hash_file" 2>/dev/null || echo "")"

  if [[ "$current_hash" != "$prev_hash" ]]; then
    # Find which files changed
    local changed_users=""
    if [[ -f "$detail_file" ]]; then
      local prev_detail
      prev_detail="$(cat "$detail_file")"

      # Compare line by line
      while IFS=: read -r file hash; do
        [[ -n "$file" ]] || continue
        local prev_entry
        prev_entry="$(echo "$prev_detail" | grep "^${file}:" || true)"
        if [[ -z "$prev_entry" ]]; then
          changed_users+="NEW: ${file}, "
        elif [[ "$prev_entry" != "${file}:${hash}" ]]; then
          changed_users+="MODIFIED: ${file}, "
        fi
      done <<< "$current_detail"

      # Check for removed files
      while IFS=: read -r file hash; do
        [[ -n "$file" ]] || continue
        if ! echo "$current_detail" | grep -q "^${file}:"; then
          changed_users+="REMOVED: ${file}, "
        fi
      done <<< "$prev_detail"
    else
      changed_users="details unavailable"
    fi

    changed_users="${changed_users%, }"
    log_alert "WARNING" "AUTH_KEYS" "authorized_keys changed: ${changed_users}"

    echo "$current_hash" > "$hash_file"
    echo "$current_detail" > "$detail_file"
  fi
}

check_listening_ports() {
  [[ "$CHECK_LISTENING_PORTS" == "true" ]] || return 0
  log "Checking for new listening ports"

  local baseline_file="${STATE_DIR}/ports_baseline"

  # Get current listening ports (protocol:address:port:process)
  local current_ports
  current_ports="$(ss -tlnpH 2>/dev/null | awk '{
    split($4, a, ":")
    port = a[length(a)]
    proc = $6
    gsub(/.*"/, "", proc)
    gsub(/".*/, "", proc)
    if (proc == "") proc = "unknown"
    print port "|" proc
  }' | sort -t'|' -k1 -n -u || true)"

  if [[ ! -f "$baseline_file" ]]; then
    echo "$current_ports" > "$baseline_file"
    log "Port baseline saved ($(echo "$current_ports" | wc -l) ports)"
    return 0
  fi

  local baseline
  baseline="$(cat "$baseline_file")"

  # Find new ports not in baseline
  local new_ports
  new_ports="$(comm -23 <(echo "$current_ports" | awk -F'|' '{print $1}' | sort -n -u) \
                        <(echo "$baseline" | awk -F'|' '{print $1}' | sort -n -u) || true)"

  if [[ -n "$new_ports" ]]; then
    local details=""
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      local proc
      proc="$(echo "$current_ports" | grep "^${port}|" | head -1 | cut -d'|' -f2)"
      details+="  port ${port} (${proc:-unknown})"$'\n'
    done <<< "$new_ports"

    local count
    count="$(echo "$new_ports" | grep -c . || true)"
    local msg
    msg="$(printf '%d new listening port(s) detected:\n%s' "$count" "$details")"
    log_alert "WARNING" "PORTS" "$msg"
  fi
}

check_world_writable() {
  [[ "$CHECK_WORLD_WRITABLE" == "true" ]] || return 0
  log "Checking for world-writable files in /etc"

  local ww_files
  ww_files="$(find /etc -maxdepth 3 -type f -perm -o+w 2>/dev/null | head -15 || true)"

  if [[ -n "$ww_files" ]]; then
    local count
    count="$(echo "$ww_files" | wc -l)"
    local file_list
    file_list="$(echo "$ww_files" | head -10 | sed 's/^/  /')"
    local msg
    msg="$(printf '%d world-writable file(s) in /etc:\n%s' "$count" "$file_list")"
    if (( count > 10 )); then
      msg+=$'\n  ... and more'
    fi
    log_alert "WARNING" "WORLD_WRITABLE" "$msg"
  fi
}

# ── Reset baseline ──────────────────────────────────────────────────────────
do_reset_baseline() {
  mkdir -p "$STATE_DIR"
  log "Resetting baselines"

  # Port baseline
  local current_ports
  current_ports="$(ss -tlnpH 2>/dev/null | awk '{
    split($4, a, ":")
    port = a[length(a)]
    proc = $6
    gsub(/.*"/, "", proc)
    gsub(/".*/, "", proc)
    if (proc == "") proc = "unknown"
    print port "|" proc
  }' | sort -t'|' -k1 -n -u || true)"
  echo "$current_ports" > "${STATE_DIR}/ports_baseline"
  log "Port baseline updated ($(echo "$current_ports" | wc -l) ports)"

  # Authorized keys baseline
  local current_detail=""
  local key_file
  while IFS= read -r -d '' key_file; do
    local file_hash
    file_hash="$(md5sum "$key_file" 2>/dev/null | awk '{print $1}' || true)"
    current_detail+="${key_file}:${file_hash}"$'\n'
  done < <(find /root/.ssh /home -maxdepth 3 -name "authorized_keys" -type f -print0 2>/dev/null || true)
  local current_hash
  current_hash="$(echo "$current_detail" | md5sum | awk '{print $1}')"
  echo "$current_hash" > "${STATE_DIR}/authorized_keys_hash"
  echo "$current_detail" > "${STATE_DIR}/authorized_keys_detail"
  log "Authorized keys baseline updated"

  # Passwd baseline
  md5sum /etc/passwd | awk '{print $1}' > "${STATE_DIR}/passwd_hash"
  awk -F: '{print $1}' /etc/passwd | sort > "${STATE_DIR}/passwd_users"
  log "User account baseline updated"

  # Auth log offset
  if [[ -n "$AUTH_LOG" && -f "$AUTH_LOG" ]]; then
    wc -l < "$AUTH_LOG" > "${STATE_DIR}/auth_log_offset"
    log "Auth log offset updated"
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

  log "========== Security check starting =========="

  # Auth log checks (share cached lines)
  AUTH_LINES_CACHE=""
  check_ssh_failed
  check_ssh_root
  check_sudo_failed

  # System checks
  check_new_users
  check_updates
  check_reboot
  check_certs

  # Hardening / drift checks
  check_ssh_config
  check_authorized_keys
  check_listening_ports
  check_world_writable

  cleanup_state
  fire_notifications

  log "========== Security check complete (${ALERT_COUNT} alert(s)) =========="
}

main
