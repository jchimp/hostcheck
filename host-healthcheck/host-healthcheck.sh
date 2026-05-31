#!/usr/bin/env bash
###############################################################################
# host-healthcheck.sh
#
# Standalone host health-check script for Proxmox / Ceph nodes.
# Runs via cron on each host. Checks system health and sends alerts via
# Telegram and/or email when problems are found.
#
# Features:
#   - NIC errors, disk space, SMART, Ceph, Corosync, peer reachability,
#     CPU, memory, load, systemd failed units, read-only filesystems
#   - Alert cooldown (default 1h) to avoid spam
#   - Configurable thresholds and checks via .conf file
#   - Local log + syslog via logger
#   - Telegram + email notifications
#
# Usage:
#   /usr/local/bin/host-healthcheck.sh
#   /usr/local/bin/host-healthcheck.sh --config /path/to/config
#   /usr/local/bin/host-healthcheck.sh --dry-run
###############################################################################

set -Euo pipefail

# ── Defaults (overridden by config file) ─────────────────────────────────────
CONF_FILE="/etc/host-healthcheck/host-healthcheck.conf"
DRY_RUN=0

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

EMAIL_ENABLED="false"
EMAIL_TO=""
EMAIL_FROM="healthcheck@$(hostname -f 2>/dev/null || hostname)"

SYSLOG_ENABLED="true"
SYSLOG_TAG="healthcheck"

ALERT_COOLDOWN_SEC=3600

CHECK_NIC="true"
CHECK_DISK="true"
CHECK_SMART="true"
CHECK_CEPH="true"
CHECK_COROSYNC="true"
CHECK_PEERS="true"
CHECK_CPU="true"
CHECK_MEMORY="true"
CHECK_LOAD="true"
CHECK_SYSTEMD="true"
CHECK_FILESYSTEM="true"

DISK_WARN_PCT=85
DISK_CRIT_PCT=95
CPU_WARN_PCT=90
MEM_WARN_PCT=90
MEM_CRIT_PCT=95
LOAD_WARN_MULTIPLIER=2
SMART_TEMP_WARN=55

PEER_HOSTS=""
PEER_PING_COUNT=3
PEER_PING_TIMEOUT=5

STATE_DIR="/var/lib/host-healthcheck"
LOG_FILE="/var/log/host-healthcheck.log"

NIC_EXCLUDE="lo|veth.*|fwbr.*|fwpr.*|fwln.*|tap.*|docker.*"

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONF_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--config <path>] [--dry-run]"
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
  local cooldown_file="${STATE_DIR}/$(echo "$alert_key" | md5sum | awk '{print $1}')"

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
  header="$(printf '🔥 %s alert(s) on %s' "$ALERT_COUNT" "$HOSTNAME_SHORT")"

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
    send_email "[ALERT] ${HOSTNAME_SHORT}: ${ALERT_COUNT} health issue(s)" "$full_message"
  fi

  log "Sent ${ALERT_COUNT} alert(s)"
}

# ── Checks ───────────────────────────────────────────────────────────────────

check_nic() {
  [[ "$CHECK_NIC" == "true" ]] || return 0
  log "Checking NIC health"

  local ifaces
  ifaces="$(ls /sys/class/net/ 2>/dev/null || true)"

  for iface in $ifaces; do
    # Skip excluded interfaces
    if echo "$iface" | grep -Eq "^(${NIC_EXCLUDE})$"; then
      continue
    fi

    # Interface operstate
    local operstate
    operstate="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")"
    if [[ "$operstate" == "down" ]]; then
      log_alert "CRITICAL" "NIC" "Interface ${iface} is DOWN"
    fi

    # RX errors
    local rx_errors
    rx_errors="$(cat "/sys/class/net/${iface}/statistics/rx_errors" 2>/dev/null || echo 0)"

    # TX errors
    local tx_errors
    tx_errors="$(cat "/sys/class/net/${iface}/statistics/tx_errors" 2>/dev/null || echo 0)"

    # Check against state file for delta
    local prev_rx_file="${STATE_DIR}/nic_rx_errors_${iface}"
    local prev_tx_file="${STATE_DIR}/nic_tx_errors_${iface}"

    local prev_rx=0 prev_tx=0
    [[ -f "$prev_rx_file" ]] && prev_rx="$(cat "$prev_rx_file")"
    [[ -f "$prev_tx_file" ]] && prev_tx="$(cat "$prev_tx_file")"

    local delta_rx=$(( rx_errors - prev_rx ))
    local delta_tx=$(( tx_errors - prev_tx ))

    if (( delta_rx > 0 )); then
      log_alert "WARNING" "NIC" "Interface ${iface} has ${delta_rx} new RX errors (total: ${rx_errors})"
    fi

    if (( delta_tx > 0 )); then
      log_alert "WARNING" "NIC" "Interface ${iface} has ${delta_tx} new TX errors (total: ${tx_errors})"
    fi

    # Save current values
    echo "$rx_errors" > "$prev_rx_file"
    echo "$tx_errors" > "$prev_tx_file"

    # RX drops
    local rx_drops
    rx_drops="$(cat "/sys/class/net/${iface}/statistics/rx_dropped" 2>/dev/null || echo 0)"
    local prev_drop_file="${STATE_DIR}/nic_rx_drops_${iface}"
    local prev_drops=0
    [[ -f "$prev_drop_file" ]] && prev_drops="$(cat "$prev_drop_file")"
    local delta_drops=$(( rx_drops - prev_drops ))

    if (( delta_drops > 10 )); then
      log_alert "WARNING" "NIC" "Interface ${iface} has ${delta_drops} new RX drops (total: ${rx_drops})"
    fi

    echo "$rx_drops" > "$prev_drop_file"
  done
}

check_disk() {
  [[ "$CHECK_DISK" == "true" ]] || return 0
  log "Checking disk space"

  df -P --exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=overlay \
    --exclude-type=squashfs 2>/dev/null | awk 'NR>1 {print $5, $6}' | \
  while read -r pct mount; do
    pct="${pct%\%}"
    if (( pct >= DISK_CRIT_PCT )); then
      log_alert "CRITICAL" "DISK" "${mount} is ${pct}% full"
    elif (( pct >= DISK_WARN_PCT )); then
      log_alert "WARNING" "DISK" "${mount} is ${pct}% full"
    fi
  done
}

check_smart() {
  [[ "$CHECK_SMART" == "true" ]] || return 0
  command -v smartctl &>/dev/null || { log "smartctl not found — skipping SMART check"; return 0; }
  log "Checking SMART health"

  local disks
  mapfile -t disks < <(smartctl --scan 2>/dev/null | awk '{print $1}' | sort -u)

  for disk in "${disks[@]}"; do
    [[ -b "$disk" ]] || continue
    local label
    label="$(basename "$disk")"

    # Overall health
    local health
    health="$(smartctl -H "$disk" 2>/dev/null || true)"
    if ! echo "$health" | grep -qiE "PASSED|OK"; then
      log_alert "CRITICAL" "SMART" "Disk ${label} SMART health FAILED"
    fi

    # ATA attributes
    local realloc pending temp
    realloc="$(smartctl -A "$disk" 2>/dev/null | awk '/Reallocated_Sector_Ct/ {print $NF}' || true)"
    pending="$(smartctl -A "$disk" 2>/dev/null | awk '/Current_Pending_Sector/ {print $NF}' || true)"
    temp="$(smartctl -A "$disk" 2>/dev/null | awk '/Temperature_Celsius/ {print $NF}' || true)"

    if [[ -n "$realloc" && "$realloc" =~ ^[0-9]+$ && "$realloc" -gt 0 ]]; then
      log_alert "WARNING" "SMART" "Disk ${label} has ${realloc} reallocated sectors"
    fi

    if [[ -n "$pending" && "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]]; then
      log_alert "WARNING" "SMART" "Disk ${label} has ${pending} pending sectors"
    fi

    if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ && "$temp" -gt "$SMART_TEMP_WARN" ]]; then
      log_alert "WARNING" "SMART" "Disk ${label} temperature is ${temp}°C"
    fi

    # NVMe health
    if smartctl -i "$disk" 2>/dev/null | grep -qi "NVMe"; then
      local media_errors
      media_errors="$(smartctl -A "$disk" 2>/dev/null | awk '/Media and Data Integrity Errors:/ {print $NF}' || true)"
      if [[ -n "$media_errors" && "$media_errors" =~ ^[0-9]+$ && "$media_errors" -gt 0 ]]; then
        log_alert "WARNING" "SMART" "NVMe ${label} has ${media_errors} media/integrity errors"
      fi

      local nvme_temp
      nvme_temp="$(smartctl -A "$disk" 2>/dev/null | awk '/Temperature:/ {print $2; exit}' || true)"
      if [[ -n "$nvme_temp" && "$nvme_temp" =~ ^[0-9]+$ && "$nvme_temp" -gt "$SMART_TEMP_WARN" ]]; then
        log_alert "WARNING" "SMART" "NVMe ${label} temperature is ${nvme_temp}°C"
      fi
    fi
  done
}

check_ceph() {
  [[ "$CHECK_CEPH" == "true" ]] || return 0
  command -v ceph &>/dev/null || { log "ceph not found — skipping Ceph check"; return 0; }
  log "Checking Ceph health"

  local ceph_json
  ceph_json="$(ceph status --format json 2>/dev/null || true)"
  if [[ -z "$ceph_json" ]]; then
    log_alert "WARNING" "CEPH" "Unable to query Ceph status"
    return 0
  fi

  # Health status
  local health
  health="$(echo "$ceph_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('health',{}).get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")"

  case "$health" in
    HEALTH_OK) ;;
    HEALTH_WARN) log_alert "WARNING" "CEPH" "Ceph cluster is in HEALTH_WARN" ;;
    HEALTH_ERR)  log_alert "CRITICAL" "CEPH" "Ceph cluster is in HEALTH_ERR" ;;
    *)           log_alert "WARNING" "CEPH" "Ceph cluster health is ${health}" ;;
  esac

  # OSD summary
  local osds_down
  osds_down="$(echo "$ceph_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
osdmap = data.get('osdmap', data.get('osd_map', {}))
num_osds = osdmap.get('num_osds', 0)
num_up = osdmap.get('num_up_osds', osdmap.get('num_up', 0))
print(max(0, num_osds - num_up))
" 2>/dev/null || echo "0")"

  if [[ "$osds_down" -gt 0 ]]; then
    log_alert "CRITICAL" "CEPH" "${osds_down} OSD(s) are down"
  fi

  # PG states
  local degraded_pgs
  degraded_pgs="$(echo "$ceph_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pgmap = data.get('pgmap', {})
states = pgmap.get('pgs_by_state', [])
bad = 0
for s in states:
    name = s.get('state_name', '')
    if 'degraded' in name or 'undersized' in name or 'stale' in name or 'incomplete' in name:
        bad += s.get('count', 0)
print(bad)
" 2>/dev/null || echo "0")"

  if [[ "$degraded_pgs" -gt 0 ]]; then
    log_alert "WARNING" "CEPH" "${degraded_pgs} PGs are unhealthy (degraded/undersized/stale)"
  fi
}

check_corosync() {
  [[ "$CHECK_COROSYNC" == "true" ]] || return 0
  command -v corosync-quorumtool &>/dev/null || { log "corosync-quorumtool not found — skipping"; return 0; }
  log "Checking Corosync"

  local quorum_output
  quorum_output="$(corosync-quorumtool -s 2>/dev/null || true)"

  if ! echo "$quorum_output" | grep -qi "Quorate:[[:space:]]*Yes"; then
    log_alert "CRITICAL" "COROSYNC" "Cluster is NOT quorate"
  fi

  # Ring / link health
  if command -v corosync-cfgtool &>/dev/null; then
    local ring_output
    ring_output="$(corosync-cfgtool -s 2>/dev/null || true)"
    local faults
    faults="$(echo "$ring_output" | grep -ci "FAULTY" || true)"
    if [[ "$faults" -gt 0 ]]; then
      log_alert "CRITICAL" "COROSYNC" "${faults} ring fault(s) detected"
    fi
  fi

  # Vote count
  local expected total
  expected="$(echo "$quorum_output" | awk '/Expected votes:/ {print $NF}')"
  total="$(echo "$quorum_output" | awk '/Total votes:/ {print $NF}')"
  if [[ -n "$expected" && -n "$total" ]]; then
    if (( total < expected )); then
      log_alert "WARNING" "COROSYNC" "Votes mismatch: ${total} present / ${expected} expected"
    fi
  fi
}

check_peers() {
  [[ "$CHECK_PEERS" == "true" ]] || return 0
  log "Checking peer reachability"

  local peers=()

  if [[ -n "$PEER_HOSTS" ]]; then
    # Manual mode: use the configured host list
    read -ra peers <<< "$PEER_HOSTS"
    log "Peer list source: config file (${#peers[@]} entries)"
  elif command -v pvecm &>/dev/null; then
    # Auto-detect mode: query pvecm nodes
    # pvecm nodes output format:
    #     Nodeid      Votes Name
    #          1          1 pve01
    #          2          1 pve02
    #          3          1 pve03
    mapfile -t peers < <(pvecm nodes 2>/dev/null | awk 'NR>1 && NF>=3 {print $NF}' | sort)
    log "Peer list source: pvecm nodes (${#peers[@]} entries)"
  else
    log "pvecm not found and PEER_HOSTS not set — skipping peer check"
    return 0
  fi

  if [[ "${#peers[@]}" -eq 0 ]]; then
    log "No peers found — skipping peer check"
    return 0
  fi

  local peer
  for peer in "${peers[@]}"; do
    [[ -n "$peer" ]] || continue

    # Skip self — compare against short hostname, FQDN, and localhost
    if [[ "$peer" == "$HOSTNAME_SHORT" ]] || \
       [[ "$peer" == "$(hostname -f 2>/dev/null || true)" ]] || \
       [[ "$peer" == "localhost" ]]; then
      log "Skipping self: ${peer}"
      continue
    fi

    # Ping the peer
    if ping -c "$PEER_PING_COUNT" -W "$PEER_PING_TIMEOUT" "$peer" >/dev/null 2>&1; then
      log "Peer reachable: ${peer}"
    else
      log_alert "CRITICAL" "PEER" "Node ${peer} is UNREACHABLE (ping failed)"
    fi
  done
}

check_cpu() {
  [[ "$CHECK_CPU" == "true" ]] || return 0
  log "Checking CPU usage"

  # Read two samples 2 seconds apart from /proc/stat
  local cpu1 cpu2
  cpu1="$(head -1 /proc/stat)"
  sleep 2
  cpu2="$(head -1 /proc/stat)"

  local idle1 total1 idle2 total2
  idle1="$(echo "$cpu1" | awk '{print $5}')"
  total1="$(echo "$cpu1" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')"
  idle2="$(echo "$cpu2" | awk '{print $5}')"
  total2="$(echo "$cpu2" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')"

  local diff_idle=$(( idle2 - idle1 ))
  local diff_total=$(( total2 - total1 ))
  local cpu_pct=0
  if (( diff_total > 0 )); then
    cpu_pct=$(( (diff_total - diff_idle) * 100 / diff_total ))
  fi

  if (( cpu_pct >= CPU_WARN_PCT )); then
    # Check if sustained (was also high last run)
    local cpu_state_file="${STATE_DIR}/cpu_high"
    if [[ -f "$cpu_state_file" ]]; then
      log_alert "WARNING" "CPU" "CPU usage is ${cpu_pct}% (sustained)"
    else
      date +%s > "$cpu_state_file"
      log "CPU is ${cpu_pct}% — marking for sustained check next run"
    fi
  else
    rm -f "${STATE_DIR}/cpu_high"
  fi
}

check_memory() {
  [[ "$CHECK_MEMORY" == "true" ]] || return 0
  log "Checking memory usage"

  local mem_total mem_avail
  mem_total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"

  if [[ "$mem_total" -gt 0 ]]; then
    local mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))

    if (( mem_used_pct >= MEM_CRIT_PCT )); then
      log_alert "CRITICAL" "MEMORY" "Memory usage is ${mem_used_pct}%"
    elif (( mem_used_pct >= MEM_WARN_PCT )); then
      log_alert "WARNING" "MEMORY" "Memory usage is ${mem_used_pct}%"
    fi
  fi
}

check_load() {
  [[ "$CHECK_LOAD" == "true" ]] || return 0
  log "Checking load average"

  local load15
  load15="$(awk '{printf "%.0f", $3}' /proc/loadavg)"
  local cpus
  cpus="$(nproc)"
  local threshold=$(( cpus * LOAD_WARN_MULTIPLIER ))

  if (( load15 >= threshold )); then
    local load_raw
    load_raw="$(awk '{print $3}' /proc/loadavg)"
    log_alert "WARNING" "LOAD" "15-min load average is ${load_raw} (threshold: ${threshold}, CPUs: ${cpus})"
  fi
}

check_systemd() {
  [[ "$CHECK_SYSTEMD" == "true" ]] || return 0
  log "Checking systemd failed units"

  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | head -20 || true)"

  if [[ -n "$failed" ]]; then
    local count
    count="$(echo "$failed" | wc -l)"
    local units
    units="$(echo "$failed" | awk '{print $1}' | tr '\n' ', ' | sed 's/,$//')"
    log_alert "WARNING" "SYSTEMD" "${count} failed unit(s): ${units}"
  fi
}

check_filesystem() {
  [[ "$CHECK_FILESYSTEM" == "true" ]] || return 0
  log "Checking for read-only filesystems"

  local ro_mounts
  ro_mounts="$(awk '$4 ~ /^ro,|,ro,|,ro$|^ro$/ && $3 !~ /^(proc|sysfs|tmpfs|devpts|cgroup|pstore|debugfs|tracefs|securityfs|configfs|fusectl|mqueue|hugetlbfs|bpf|binfmt_misc)$/ {print $2}' /proc/mounts 2>/dev/null || true)"

  if [[ -n "$ro_mounts" ]]; then
    while IFS= read -r mount; do
      log_alert "CRITICAL" "FILESYSTEM" "Filesystem ${mount} is mounted read-only"
    done <<< "$ro_mounts"
  fi
}

# ── Cleanup old cooldown files (older than 7 days) ───────────────────────────
cleanup_state() {
  find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  log "========== Health check starting =========="

  check_nic
  check_disk
  check_smart
  check_ceph
  check_corosync
  check_peers
  check_cpu
  check_memory
  check_load
  check_systemd
  check_filesystem
  cleanup_state
  fire_notifications

  log "========== Health check complete (${ALERT_COUNT} alert(s)) =========="
}

main
